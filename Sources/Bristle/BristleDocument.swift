import AppKit
import BristleCanvas
import BristleCore
import UniformTypeIdentifiers

extension UTType {
  static let bristle = UTType(exportedAs: "io.github.PoteNad.bristle.drawing", conformingTo: .json)
}

@objc(BristleDocument)
final class BristleDocument: NSDocument {
  let drawing = Drawing()
  var editor: Editor?
  /// The file as it was opened. Saving it back unedited writes these same bytes.
  private var original: (data: Data, type: String, scene: Scene)?
  /// Objects a PNG carried from before it was changed in another app, offered for restoring.
  private(set) var staleScene: Scene?

  nonisolated override class var autosavesInPlace: Bool { true }
  nonisolated override class var autosavesDrafts: Bool { true }
  nonisolated override class var preservesVersions: Bool { true }

  /// Bristle drawings and PNGs can be written; other images are opened and saved as one of those.
  nonisolated static let writableTypeIdentifiers = [UTType.bristle.identifier, UTType.png.identifier]

  override init() {
    super.init()
    drawing.replace(Scene(paper: AppPreferences.newPaper))
    drawing.undoManager = undoManager
  }

  override var undoManager: UndoManager? {
    get { super.undoManager }
    set {
      super.undoManager = newValue
      drawing.undoManager = newValue
    }
  }

  /// A new drawing that's still blank closes without asking to be saved.
  override var isDocumentEdited: Bool {
    if fileURL == nil && drawing.scene.elements.isEmpty && original == nil { return false }
    return super.isDocumentEdited
  }

  func syncEditedIndicator() {
    for controller in windowControllers { controller.window?.isDocumentEdited = isDocumentEdited }
  }

  override func updateChangeCount(_ change: NSDocument.ChangeType) {
    super.updateChangeCount(change)
    syncEditedIndicator()
  }

  override func makeWindowControllers() {
    guard windowControllers.isEmpty else { return }
    let controller = Editor(document: self)
    editor = controller
    addWindowController(controller)
  }

  // MARK: Reading

  override func read(from data: Data, ofType typeName: String) throws {
    let type = UTType(typeName)
    var scene: Scene
    var stale: Scene?
    if type == .bristle || type?.conforms(to: .bristle) == true {
      scene = try SceneFile.scene(from: data)
    } else if PNG.isPNG(data), let embedded = EmbeddedScene(png: data) {
      if embedded.isCurrent {
        scene = embedded.scene
      } else {
        scene = try Self.imageScene(data, type: UTType.png.identifier)
        stale = embedded.scene
      }
    } else {
      scene = try Self.imageScene(data, type: type?.identifier ?? UTType.png.identifier)
    }
    MainActor.assumeIsolated {
      original = (data, typeName, scene)
      staleScene = stale
      drawing.replace(scene)
      drawing.selection = []
    }
  }

  /// A drawing of one image: the canvas is the image's size, with the image locked in place.
  nonisolated static func imageScene(_ data: Data, type: String) throws -> Scene {
    guard let size = ImageStore.pixelSize(of: data), size.width >= 1, size.height >= 1,
      ImageStore.decode(data) != nil
    else { throw CocoaError(.fileReadCorruptFile) }
    let file = ImageFile(type: type, data: data)
    var scene = Scene(paper: Paper(width: size.width, height: size.height, background: nil))
    scene.paper.resolution = ImageStore.resolution(of: data) ?? 72
    var image = Element(kind: .image)
    image.file = scene.addFile(file)
    image.frame = scene.paperRect
    image.locked = true
    scene.elements = [image]
    return scene
  }

  // MARK: Writing

  override func data(ofType typeName: String) throws -> Data {
    let scene = drawing.scene
    if let original, original.type == typeName, original.scene == scene { return original.data }
    let type = UTType(typeName)
    if type == .png {
      guard let png = EmbeddedScene.png(scene, images: editor?.canvas.images ?? ImageStore()) else {
        throw CocoaError(.fileWriteUnknown)
      }
      return png
    }
    if type == .bristle || type?.conforms(to: .bristle) == true {
      var tidy = scene
      tidy.removeUnusedFiles()
      return SceneFile.data(tidy)
    }
    throw CocoaError(.fileWriteUnsupportedScheme)
  }

  nonisolated override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
    Self.writableTypeIdentifiers
  }

  nonisolated override var autosavingFileType: String? {
    // Images Bristle can't write, such as JPEG, keep their edits in a Bristle draft until saved.
    let type = fileType ?? UTType.bristle.identifier
    return Self.writableTypeIdentifiers.contains(type) ? type : UTType.bristle.identifier
  }

  override func save(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    completionHandler: @escaping ((any Error)?) -> Void
  ) {
    drawing.finishCoalescing()
    editor?.canvas.endTextEditing()
    super.save(to: url, ofType: typeName, for: saveOperation) { error in
      MainActor.assumeIsolated {
        if error == nil, saveOperation != .autosaveElsewhereOperation, saveOperation != .saveToOperation {
          // What was just written is now the file as it stands.
          if let data = try? Data(contentsOf: url) { self.original = (data, typeName, self.drawing.scene) }
        }
        self.syncEditedIndicator()
      }
      completionHandler(error)
    }
  }

  override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
    savePanel.isExtensionHidden = false
    return true
  }

  override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
    UTType(typeName)?.preferredFilenameExtension ?? super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
  }

  // MARK: Stale objects

  /// Offers to bring back the objects a PNG was saved with, after it was changed elsewhere.
  func offerStaleScene() {
    guard let stale = staleScene, let window = windowControllers.first?.window else { return }
    staleScene = nil
    let alert = NSAlert()
    alert.messageText = "This image was changed in another app"
    alert.informativeText =
      "Bristle opened the image as it is now. It also has the objects it was last saved with in Bristle, but they may no longer match the picture."
    alert.addButton(withTitle: "Keep Image")
    alert.addButton(withTitle: "Restore Objects")
    alert.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        guard response == .alertSecondButtonReturn else { return }
        self.drawing.edit("Restore Objects", select: []) { $0 = stale }
      }
    }
  }

  // MARK: Printing and exporting

  var baseName: String {
    let name = fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Untitled"
    return (name as NSString).deletingPathExtension
  }

  override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
    let info = printInfo.copy() as! NSPrintInfo
    info.dictionary().addEntries(from: printSettings)
    info.horizontalPagination = .fit
    info.verticalPagination = .fit
    info.isHorizontallyCentered = true
    info.isVerticallyCentered = true
    let paper = drawing.scene.paperRect
    info.orientation = paper.width > paper.height ? .landscape : .portrait
    let view = PrintView(scene: drawing.scene)
    let operation = NSPrintOperation(view: view, printInfo: info)
    operation.jobTitle = baseName
    return operation
  }

  @objc func exportDrawing(_ sender: Any?) {
    guard let window = windowControllers.first?.window else { return }
    let panel = NSSavePanel()
    let exporter = ExportOptions()
    panel.accessoryView = exporter.view
    exporter.panel = panel
    panel.nameFieldStringValue = baseName
    exporter.update()
    if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
    panel.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        do {
          try self.export(to: url, format: exporter.format, scale: exporter.scale, embed: exporter.embed)
        } catch {
          self.presentError(error)
        }
        _ = exporter
      }
    }
  }

  enum ExportFormat: Int, CaseIterable {
    case png, svg, pdf, jpeg

    var title: String { ["PNG", "SVG", "PDF", "JPEG"][rawValue] }
    var type: UTType { [.png, .svg, .pdf, .jpeg][rawValue] }
  }

  func export(to url: URL, format: ExportFormat, scale: CGFloat, embed: Bool) throws {
    drawing.finishCoalescing()
    let scene = drawing.scene
    let images = editor?.canvas.images ?? ImageStore()
    let data: Data?
    switch format {
    case .png:
      if embed && scale == 1 {
        data = EmbeddedScene.png(scene, images: images)
      } else {
        data = Renderer.image(scene, scale: scale, images: images).flatMap {
          Renderer.png($0, resolution: scene.paper.resolution * scale)
        }
      }
    case .svg: data = SVG.document(scene)
    case .pdf: data = Renderer.pdf(scene, images: images, title: baseName)
    case .jpeg:
      var opaque = scene
      if opaque.paper.background == nil { opaque.paper.background = .white }
      data = Renderer.image(opaque, scale: scale, images: images).flatMap { image in
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
          return nil
        }
        let dpi = scene.paper.resolution * scale
        CGImageDestinationAddImage(
          destination, image,
          [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
      }
    }
    guard let data else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url, options: .atomic)
  }
}

/// The export panel's options: format, scale, and whether a PNG keeps the drawing editable.
@MainActor
final class ExportOptions: NSObject {
  let view = NSView()
  weak var panel: NSSavePanel?
  private let formatPopup = NSPopUpButton()
  private let scalePopup = NSPopUpButton()
  private let embedBox = NSButton(checkboxWithTitle: "Keep editable in Bristle", target: nil, action: nil)

  override init() {
    super.init()
    for format in BristleDocument.ExportFormat.allCases { formatPopup.addItem(withTitle: format.title) }
    for scale in [1, 2, 3] {
      scalePopup.addItem(withTitle: "\(scale)×")
      scalePopup.lastItem?.tag = scale
    }
    embedBox.state = .on
    embedBox.toolTip = "The PNG reopens in Bristle with every object still editable, and is an ordinary image everywhere else."
    for control in [formatPopup, scalePopup, embedBox] as [NSControl] {
      control.target = self
      control.action = #selector(changed)
    }
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Format:"), formatPopup],
      [NSTextField(labelWithString: "Scale:"), scalePopup],
      [NSGridCell.emptyContentView, embedBox],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
      grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
    view.frame.size = CGSize(width: 360, height: grid.fittingSize.height + 24)
  }

  var format: BristleDocument.ExportFormat { .init(rawValue: formatPopup.indexOfSelectedItem) ?? .png }
  var scale: CGFloat { CGFloat(max(1, scalePopup.selectedTag())) }
  var embed: Bool { embedBox.state == .on && format == .png && scale == 1 }

  @objc private func changed() { update() }

  func update() {
    let raster = format == .png || format == .jpeg
    scalePopup.isEnabled = raster
    embedBox.isEnabled = format == .png && scale == 1
    panel?.allowedContentTypes = [format.type]
  }
}

/// The drawing laid out for printing on one page.
final class PrintView: NSView {
  let scene: Scene
  let images = ImageStore()

  init(scene: Scene) {
    self.scene = scene
    super.init(frame: scene.paperRect)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.clip(to: scene.paperRect)
    Renderer.draw(scene, in: context, rect: dirtyRect, images: images)
  }

  override func knowsPageRange(_ range: NSRangePointer) -> Bool {
    range.pointee = NSRange(location: 1, length: 1)
    return true
  }

  override func rectForPage(_ page: Int) -> NSRect { bounds }
}

@objc(BristleDocumentController)
final class BristleDocumentController: NSDocumentController {
  override func reopenDocument(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
    completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
  ) {
    // Automated checks start clean instead of restoring drafts from earlier runs, unless the
    // check is of restoring itself.
    #if BRISTLE_CHECKS
      guard !AppChecks.isChecking || AppChecks.restoresState else { return completionHandler(nil, false, nil) }
    #endif
    super.reopenDocument(
      for: urlOrNil, withContentsOf: contentsURL, display: displayDocument, completionHandler: completionHandler)
  }

  @IBAction func newWindowForTab(_ sender: Any?) {
    let sourceWindow = NSApp.keyWindow ?? NSApp.mainWindow
    do {
      let document = try openUntitledDocumentAndDisplay(false)
      document.makeWindowControllers()
      guard let window = document.windowControllers.first?.window else {
        document.close()
        return
      }
      if let sourceWindow, sourceWindow.isVisible { sourceWindow.addTabbedWindow(window, ordered: .above) }
      document.showWindows()
    } catch {
      NSApp.presentError(error)
    }
  }

  override func beginOpenPanel(
    _ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void
  ) {
    openPanel.allowedContentTypes = [.bristle, .png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
    super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
  }

  override func openDocument(
    withContentsOf url: URL, display displayDocument: Bool,
    completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
  ) {
    let transient = documents.first(where: isTransientUntitledDocument)
    super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
      MainActor.assumeIsolated {
        if document != nil, let transient, transient !== document { transient.close() }
        (document as? BristleDocument)?.offerStaleScene()
      }
      completionHandler(document, alreadyOpen, error)
    }
  }

  private func isTransientUntitledDocument(_ document: NSDocument) -> Bool {
    guard let document = document as? BristleDocument else { return false }
    return document.fileURL == nil && !document.isDocumentEdited && document.drawing.scene.elements.isEmpty
  }
}
