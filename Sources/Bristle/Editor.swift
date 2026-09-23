import AppKit
import BristleCanvas
import BristleCore
import UniformTypeIdentifiers

/// A document window: every tool in the toolbar, as in Excalidraw, in capsules as in Freeform;
/// the canvas filling the window; and the Palette at its side while there's something to style.
@MainActor
final class Editor: NSWindowController, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  NSSharingServicePickerToolbarItemDelegate, CanvasViewDelegate
{
  let canvas: CanvasView
  let palette = Palette()
  let zoomBar = ZoomBar()
  let canvasBar = CanvasBar()
  private weak var note: BristleDocument?
  private(set) var toolGroups: [NSToolbarItemGroup] = []
  private let root = NSView()
  private var inFullScreenTransition = false
  private var shownOnce = false
  /// The drawing tool Draw uses: the brush chosen last.
  private var lastBrush: Tool = .pen

  init(document: BristleDocument) {
    note = document
    canvas = CanvasView(drawing: document.drawing)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.delegate = self
    window.minSize = NSSize(width: 560, height: 380)
    window.tabbingIdentifier = "io.github.PoteNad.bristle.document"
    window.tabbingMode = .preferred
    shouldCascadeWindows = false
    let toolbar = NSToolbar(identifier: "BristleDocumentToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.centeredItemIdentifiers = [Self.drawItems, Self.shapeItems]
    if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    canvas.delegate = self
    canvas.styles = AppPreferences.toolStyles
    canvas.configuration = AppPreferences.canvasConfiguration
    canvas.tool = .select
    // Fitting the canvas leaves room for the Palette at the left and the bars at the bottom.
    canvas.fitInsets = NSEdgeInsets(top: 24, left: 248, bottom: 64, right: 24)
    palette.canvas = canvas
    palette.isHiddenByUser = UserDefaults.standard.bool(forKey: PreferenceKey.paletteHidden) && !isAutomatedCheck
    zoomBar.canvas = canvas
    canvasBar.canvas = canvas
    canvasBar.editor = self

    let scroll = canvas.scrollView
    root.addSubview(scroll)
    let overlays = [palette.view, zoomBar.bar, canvasBar.bar]
    overlays.forEach(root.addSubview)
    for view in [scroll] + overlays { view.translatesAutoresizingMaskIntoConstraints = false }
    let guide = root.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      palette.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
      palette.view.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
      palette.view.bottomAnchor.constraint(lessThanOrEqualTo: zoomBar.bar.topAnchor, constant: -12),
      zoomBar.bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
      zoomBar.bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
      canvasBar.bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
      canvasBar.bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
    ])
    let controller = NSViewController()
    controller.view = root
    window.contentViewController = controller
    placeWindow()
    updateBars()

    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(defaultsDidChange), name: .canvasDefaultsDidChange, object: nil)
    center.addObserver(self, selector: #selector(stylesChangedElsewhere), name: .toolStylesDidChange, object: nil)
    center.addObserver(self, selector: #selector(drawingChanged), name: .drawingDidChange, object: document.drawing)
    center.addObserver(self, selector: #selector(drawingChanged), name: .drawingSelectionDidChange, object: document.drawing)
    window.makeFirstResponder(canvas)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    showPaperOnce()
  }

  /// Opens showing the whole canvas, at actual size when it fits. Windows restored after a
  /// relaunch appear without `showWindow`, so this also runs when a window first updates.
  private func showPaperOnce() {
    guard !shownOnce, let window, window.isVisible else { return }
    shownOnce = true
    window.contentView?.layoutSubtreeIfNeeded()
    canvas.showPaper()
    zoomBar.update()
  }

  func windowDidUpdate(_ notification: Notification) { showPaperOnce() }

  /// Automated checks must leave the user's saved window state alone.
  var isAutomatedCheck: Bool { AppPreferences.isAutomatedCheck }

  // MARK: Window size

  /// Centres the window on the active screen, at the size the user last gave a window.
  private func placeWindow() {
    guard let window else { return }
    let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return window.center() }
    var size = NSSize(width: min(1180, visible.width * 0.85).rounded(), height: min(800, visible.height * 0.85).rounded())
    if let saved = Self.windowDefaults.string(forKey: PreferenceKey.windowSize).map(NSSizeFromString),
      saved.width > 0, saved.height > 0
    {
      size = saved
    }
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    frame.size.width = min(frame.width, visible.width)
    frame.size.height = min(frame.height, visible.height)
    window.setFrame(
      NSRect(
        x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded(),
        width: frame.width, height: frame.height), display: false)
  }

  func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) { placeWindow() }

  func windowDidResize(_ notification: Notification) {
    guard !inFullScreenTransition, let window, window.isVisible, !window.styleMask.contains(.fullScreen) else {
      return
    }
    let size = window.contentRect(forFrameRect: window.frame).size
    Self.windowDefaults.set(NSStringFromSize(size), forKey: PreferenceKey.windowSize)
  }

  func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }
  func windowDidExitFullScreen(_ notification: Notification) { inFullScreenTransition = false }

  /// Where the window size is kept. Automated checks use a store of their own.
  static let windowDefaults: UserDefaults = {
    #if BRISTLE_CHECKS
      if AppChecks.isChecking, let checks = UserDefaults(suiteName: "io.github.PoteNad.bristle.check-windows") {
        checks.removeObject(forKey: PreferenceKey.windowSize)
        return checks
      }
    #endif
    return .standard
  }()

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { note?.undoManager }

  // MARK: Canvas events

  func canvasViewToolDidChange(_ canvas: CanvasView) {
    if [.pencil, .pen, .highlighter].contains(canvas.tool) { lastBrush = canvas.tool }
    updateBars()
  }

  func canvasViewZoomDidChange(_ canvas: CanvasView) { zoomBar.update() }

  func canvasView(_ canvas: CanvasView, didPick color: Color) { palette.update() }

  func canvasViewStylesDidChange(_ canvas: CanvasView) {
    AppPreferences.toolStyles = canvas.styles
    palette.update()
    NotificationCenter.default.post(name: .toolStylesDidChange, object: self)
  }

  func canvasViewDidFinishInteraction(_ canvas: CanvasView) { palette.update() }

  /// Every window shares one set of tool styles.
  @objc private func stylesChangedElsewhere(_ notification: Notification) {
    guard notification.object as AnyObject? !== self else { return }
    canvas.styles = AppPreferences.toolStyles
    palette.update()
  }

  @objc private func defaultsDidChange() {
    canvas.configuration = AppPreferences.canvasConfiguration
    canvasBar.update()
  }

  private var paletteScheduled = false

  /// The Palette follows the drawing, at most once per turn of the run loop.
  @objc private func drawingChanged() {
    guard !paletteScheduled else { return }
    paletteScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.paletteScheduled = false
        self?.palette.update()
      }
    }
  }

  private func updateBars() {
    palette.update()
    zoomBar.update()
    canvasBar.update()
    updateToolGroups()
  }

  // MARK: Toolbar

  static let drawItems = NSToolbarItem.Identifier("draw")
  static let shapeItems = NSToolbarItem.Identifier("shapes")
  static let shareToolbarItem = NSToolbarItem.Identifier("share")

  /// The tools in the toolbar, in two capsules: drawing, then shapes, text, and images.
  enum Slot: Int, CaseIterable {
    case select, draw, eraser, fill, rectangle, ellipse, polygon, line, arrow, text, image

    static let drawing: [Slot] = [.select, .draw, .eraser, .fill]
    static let shapes: [Slot] = [.rectangle, .ellipse, .polygon, .line, .arrow, .text, .image]
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.drawItems, Self.shapeItems, .flexibleSpace, Self.shareToolbarItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  private func slotDetails(_ slot: Slot) -> (symbol: String, label: String, tip: String) {
    switch slot {
    case .select: ("cursorarrow", "Select", "Select (V)")
    case .draw: (lastBrush.symbol, "Draw", "Draw (P) — choose a pencil, brush, or highlighter in the Palette")
    case .eraser: ("eraser", "Eraser", "Eraser (E)")
    case .fill: ("drop", "Fill", "Fill (F)")
    case .rectangle: ("rectangle", "Rectangle", "Rectangle (R)")
    case .ellipse: ("circle", "Ellipse", "Ellipse (O)")
    case .polygon: ("pentagon", "Polygon", "Polygon (G)")
    case .line: ("line.diagonal", "Line", "Line (L)")
    case .arrow: ("arrow.up.right", "Arrow", "Arrow (A)")
    case .text: ("textformat", "Text", "Text (T)")
    case .image: ("photo", "Image", "Insert Image (⇧⌘I)")
    }
  }

  /// A tool's symbol; while it's the tool in use, a filled circle with the symbol cut out of it,
  /// as Freeform marks its drawing tool.
  private func slotImage(_ slot: Slot, on: Bool) -> NSImage? {
    let details = slotDetails(slot)
    let plain = NSImage(systemSymbolName: details.symbol, accessibilityDescription: details.label)
    guard on, let symbol = NSImage(systemSymbolName: details.symbol, accessibilityDescription: details.label)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    else { return plain }
    let side: CGFloat = 24
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(ovalIn: rect).fill()
      let size = symbol.size
      symbol.draw(
        in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height),
        from: .zero, operation: .destinationOut, fraction: 1)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = details.label + ", selected"
    return image
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if itemIdentifier == Self.shareToolbarItem {
      let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Share"
      item.paletteLabel = "Share"
      item.toolTip = "Share the drawing"
      item.delegate = self
      return item
    }
    let slots: [Slot]
    switch itemIdentifier {
    case Self.drawItems: slots = Slot.drawing
    case Self.shapeItems: slots = Slot.shapes
    default: return nil
    }
    let group = NSToolbarItemGroup(
      itemIdentifier: itemIdentifier, images: slots.map { slotImage($0, on: false)! }, selectionMode: .momentary,
      labels: slots.map { slotDetails($0).label }, target: self, action: #selector(chooseSlot(_:)))
    group.label = itemIdentifier == Self.drawItems ? "Draw" : "Shapes"
    group.paletteLabel = group.label
    for (item, slot) in zip(group.subitems, slots) {
      item.toolTip = slotDetails(slot).tip
      item.tag = slot.rawValue
    }
    if let control = group.view as? NSSegmentedControl {
      for (i, slot) in slots.enumerated() { control.setToolTip(slotDetails(slot).tip, forSegment: i) }
    }
    toolGroups.append(group)
    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateToolGroups() } }
    return group
  }

  var currentSlot: Slot? {
    switch canvas.tool {
    case .select: .select
    case .pencil, .pen, .highlighter: .draw
    case .eraser, .strokeEraser: .eraser
    case .fill: .fill
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .polygon: .polygon
    case .line: .line
    case .arrow: .arrow
    case .text: .text
    case .eyedropper: nil
    }
  }

  /// Shows which tool is in use in the toolbar.
  private func updateToolGroups() {
    let current = currentSlot
    for group in toolGroups {
      let slots = group.itemIdentifier == Self.drawItems ? Slot.drawing : Slot.shapes
      for (i, (item, slot)) in zip(group.subitems, slots).enumerated() {
        let image = slotImage(slot, on: slot == current)
        item.image = image
        (group.view as? NSSegmentedControl)?.setImage(image, forSegment: i)
      }
    }
  }

  @objc private func chooseSlot(_ sender: NSToolbarItemGroup) {
    let slots = sender.itemIdentifier == Self.drawItems ? Slot.drawing : Slot.shapes
    let index = (sender.view as? NSSegmentedControl)?.selectedSegment ?? -1
    guard slots.indices.contains(index) else { return }
    choose(slots[index], from: sender)
  }

  func choose(_ slot: Slot, from sender: Any? = nil) {
    switch slot {
    case .select: canvas.tool = .select
    case .draw: canvas.tool = lastBrush
    case .eraser: if canvas.tool != .strokeEraser { canvas.tool = .eraser }
    case .fill: canvas.tool = .fill
    case .rectangle: canvas.tool = .rectangle
    case .ellipse: canvas.tool = .ellipse
    case .polygon: canvas.tool = .polygon
    case .line: canvas.tool = .line
    case .arrow: canvas.tool = .arrow
    case .text: canvas.tool = .text
    case .image: insertImage(sender)
    }
    updateBars()
    window?.makeFirstResponder(canvas)
  }

  @objc func chooseTool(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String, let tool = Tool(rawValue: name) else { return }
    canvas.tool = tool
    updateBars()
    window?.makeFirstResponder(canvas)
  }

  func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
    guard let note else { return [] }
    // A saved drawing is shared as its file; an unsaved one as a PNG that opens editable in Bristle.
    if let url = note.fileURL, !note.isDocumentEdited { return [url] }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = folder.appendingPathComponent(note.baseName + ".png")
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
      let png = EmbeddedScene.png(note.drawing.scene, images: canvas.images), (try? png.write(to: url)) != nil
    else { return [] }
    return [url]
  }

  // MARK: Commands

  @objc func toggleGrid(_ sender: Any?) { flip(PreferenceKey.showsGrid) }
  @objc func toggleSnapToGrid(_ sender: Any?) { flip(PreferenceKey.snapsToGrid) }
  @objc func toggleGuides(_ sender: Any?) { flip(PreferenceKey.snapsToGuides) }

  private func flip(_ key: String) {
    guard !isAutomatedCheck else { return }
    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    NotificationCenter.default.post(name: .canvasDefaultsDidChange, object: nil)
  }

  /// Format ▸ Show Palette shows or hides the Palette beside the canvas.
  @objc func togglePalette(_ sender: Any?) {
    palette.isHiddenByUser.toggle()
    if !isAutomatedCheck { UserDefaults.standard.set(palette.isHiddenByUser, forKey: PreferenceKey.paletteHidden) }
    palette.update()
  }

  @objc func showFonts(_ sender: Any?) {
    let text = canvas.drawing.selectedElements.first { $0.kind == .text }
    let style = text.map(Style.init) ?? (canvas.styles[.text] ?? Tool.text.defaultStyle)
    let font = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
    NSFontManager.shared.setSelectedFont(font, isMultiple: false)
    NSFontManager.shared.orderFrontFontPanel(sender)
  }

  @objc func insertImage(_ sender: Any?) {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]
    panel.allowsMultipleSelection = true
    panel.message = "Choose images to place on the canvas."
    panel.beginSheetModal(for: window) { response in
      MainActor.assumeIsolated {
        guard response == .OK else { return }
        let files = panel.urls.compactMap { url -> ImageFile? in
          guard let data = try? Data(contentsOf: url) else { return nil }
          return ImageFile(type: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.png", data: data)
        }
        self.canvas.insertImages(files, at: nil)
        window.makeFirstResponder(self.canvas)
      }
    }
  }

  /// Canvas ▸ Canvas Size: a sheet with the size and which way the canvas grows.
  @objc func showCanvasSize(_ sender: Any?) {
    guard let window else { return }
    let paper = canvas.scene.paper
    let alert = NSAlert()
    alert.messageText = "Canvas Size"
    alert.informativeText = "The drawing stays where it is; choose which part of the canvas it keeps its place in."
    alert.addButton(withTitle: "Change")
    alert.addButton(withTitle: "Cancel")
    let number = NumberFormatter()
    number.numberStyle = .decimal
    number.minimum = 1
    number.maximum = 30_000
    number.maximumFractionDigits = 0
    let width = NSTextField(string: number.string(from: NSNumber(value: Double(paper.width))) ?? "")
    let height = NSTextField(string: number.string(from: NSNumber(value: Double(paper.height))) ?? "")
    for field in [width, height] {
      field.formatter = number
      field.widthAnchor.constraint(equalToConstant: 80).isActive = true
    }
    width.setAccessibilityLabel("Width")
    height.setAccessibilityLabel("Height")
    let anchor = AnchorPicker()
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Width:"), width],
      [NSTextField(labelWithString: "Height:"), height],
      [NSTextField(labelWithString: "Anchor:"), anchor],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.row(at: 2).yPlacement = .top
    grid.frame.size = grid.fittingSize
    alert.accessoryView = grid
    alert.window.initialFirstResponder = width
    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        guard let self, response == .alertFirstButtonReturn,
          let w = number.number(from: width.stringValue)?.doubleValue,
          let h = number.number(from: height.stringValue)?.doubleValue
        else { return }
        let size = CGSize(width: w, height: h)
        self.canvas.drawing.edit("Canvas Size") { $0.resizePaper(to: size, anchor: anchor.anchor) }
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let defaults = UserDefaults.standard
    switch menuItem.action {
    case #selector(togglePalette(_:)):
      menuItem.title = palette.isHiddenByUser ? "Show Palette" : "Hide Palette"
    case #selector(toggleGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.showsGrid) ? .on : .off
    case #selector(toggleSnapToGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGrid) ? .on : .off
    case #selector(toggleGuides(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGuides) ? .on : .off
    case #selector(chooseTool(_:)):
      menuItem.state = (menuItem.representedObject as? String) == canvas.tool.rawValue ? .on : .off
    default: break
    }
    return true
  }
}

extension Notification.Name {
  static let toolStylesDidChange = Notification.Name("BristleToolStylesDidChange")
}

/// Nine buttons choosing where the drawing stays when the canvas changes size.
final class AnchorPicker: NSView {
  private(set) var anchor: Scene.Anchor = .topLeft
  private var buttons: [NSButton] = []

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
    let names = ["top left", "top", "top right", "left", "center", "right", "bottom left", "bottom", "bottom right"]
    for (i, name) in names.enumerated() {
      let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(choose(_:)))
      button.tag = i
      button.setAccessibilityLabel("Anchor at \(name)")
      button.frame = NSRect(x: CGFloat(i % 3) * 24, y: CGFloat(2 - i / 3) * 24, width: 22, height: 22)
      addSubview(button)
      buttons.append(button)
    }
    buttons[0].state = .on
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: 72, height: 72) }

  @objc private func choose(_ sender: NSButton) {
    anchor = Scene.Anchor(rawValue: sender.tag) ?? .topLeft
    for button in buttons { button.state = button === sender ? .on : .off }
  }
}
