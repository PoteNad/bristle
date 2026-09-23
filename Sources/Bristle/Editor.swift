import AppKit
import BristleCanvas
import BristleCore
import UniformTypeIdentifiers

/// A document window: the canvas with the Tools column over it, the toolbar, and the inspector.
@MainActor
final class Editor: NSWindowController, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  NSSharingServicePickerToolbarItemDelegate, CanvasViewDelegate
{
  let canvas: CanvasView
  let tools: ToolsPalette
  let inspector = InspectorViewController()
  private weak var note: BristleDocument?
  private var inspectorItem: NSSplitViewItem!
  private var zoomItem: NSMenuToolbarItem?
  private var inFullScreenTransition = false
  private var shownOnce = false

  init(document: BristleDocument) {
    note = document
    canvas = CanvasView(drawing: document.drawing)
    tools = ToolsPalette()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    super.init(window: window)
    window.delegate = self
    window.minSize = NSSize(width: 520, height: 360)
    window.tabbingIdentifier = "io.github.PoteNad.bristle.document"
    window.tabbingMode = .preferred
    shouldCascadeWindows = false
    let toolbar = NSToolbar(identifier: "BristleDocumentToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    canvas.delegate = self
    canvas.styles = AppPreferences.toolStyles
    canvas.configuration = AppPreferences.canvasConfiguration
    canvas.tool = .select
    tools.canvas = canvas
    tools.isHidden = !UserDefaults.standard.bool(forKey: PreferenceKey.toolsVisible)
    updateFitInsets()
    inspector.canvas = canvas

    // The canvas fills the window and the Tools column floats over its leading edge, like
    // Freeform's; the inspector shares the window like Pages' Format sidebar.
    let root = NSView()
    let scroll = canvas.scrollView
    root.addSubview(scroll)
    root.addSubview(tools)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    tools.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      tools.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      tools.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
      tools.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
    ])
    let canvasController = NSViewController()
    canvasController.view = root
    let split = EditorSplitViewController()
    split.editor = self
    split.addSplitViewItem(NSSplitViewItem(viewController: canvasController))
    inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.canCollapse = true
    inspectorItem.minimumThickness = 250
    inspectorItem.maximumThickness = 340
    inspectorItem.isCollapsed = isAutomatedCheck || !UserDefaults.standard.bool(forKey: PreferenceKey.inspectorVisible)
    split.addSplitViewItem(inspectorItem)
    if !isAutomatedCheck { split.splitView.autosaveName = "BristleEditorSplit" }
    window.contentViewController = split
    placeWindow()
    tools.update()
    inspector.update()

    NotificationCenter.default.addObserver(
      self, selector: #selector(defaultsDidChange), name: .canvasDefaultsDidChange, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(stylesChangedElsewhere), name: .toolStylesDidChange, object: nil)
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
    updateZoomItem()
  }

  func windowDidUpdate(_ notification: Notification) { showPaperOnce() }

  /// Automated checks must leave the user's saved window and sidebar state alone.
  var isAutomatedCheck: Bool {
    #if BRISTLE_CHECKS
      AppChecks.isChecking
    #else
      false
    #endif
  }

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
    tools.update()
    inspector.update()
  }

  func canvasViewZoomDidChange(_ canvas: CanvasView) { updateZoomItem() }

  func canvasView(_ canvas: CanvasView, didPick color: Color) {
    NSColorPanel.shared.color = NSColor(cgColor: color.cgColor) ?? .black
  }

  func canvasViewStylesDidChange(_ canvas: CanvasView) {
    AppPreferences.toolStyles = canvas.styles
    tools.update()
    inspector.update()
    NotificationCenter.default.post(name: .toolStylesDidChange, object: self)
  }

  /// Every window shares one set of tool styles.
  @objc private func stylesChangedElsewhere(_ notification: Notification) {
    guard notification.object as AnyObject? !== self else { return }
    canvas.styles = AppPreferences.toolStyles
    tools.update()
    inspector.update()
  }

  @objc private func defaultsDidChange() {
    canvas.configuration = AppPreferences.canvasConfiguration
  }

  // MARK: Toolbar

  private static let zoomToolbarItem = NSToolbarItem.Identifier("zoom")
  private static let shareToolbarItem = NSToolbarItem.Identifier("share")
  private static let inspectorToolbarItem = NSToolbarItem.Identifier("inspector")

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.zoomToolbarItem, Self.shareToolbarItem, Self.inspectorToolbarItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
    case Self.zoomToolbarItem:
      let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Zoom"
      item.paletteLabel = "Zoom"
      item.toolTip = "Zoom in or out, or fit the canvas to the window"
      item.showsIndicator = true
      item.menu = zoomMenu()
      zoomItem = item
      updateZoomItem()
      return item
    case Self.shareToolbarItem:
      let item = NSSharingServicePickerToolbarItem(itemIdentifier: itemIdentifier)
      item.label = "Share"
      item.paletteLabel = "Share"
      item.toolTip = "Share the drawing"
      item.delegate = self
      return item
    case Self.inspectorToolbarItem:
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")
      item.label = "Inspector"
      item.paletteLabel = "Inspector"
      item.toolTip = "Show or hide the inspector (⌥⌘I)"
      item.target = self
      item.action = #selector(toggleInspector(_:))
      item.isBordered = true
      return item
    default:
      return nil
    }
  }

  private func zoomMenu() -> NSMenu {
    let menu = NSMenu(title: "Zoom")
    for percent in [25, 50, 75, 100, 150, 200, 400, 800] {
      let item = menu.addItem(withTitle: "\(percent)%", action: #selector(zoomToPercent(_:)), keyEquivalent: "")
      item.tag = percent
      item.target = self
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasView.zoomToFit(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Zoom In", action: #selector(CanvasView.zoomIn(_:)), keyEquivalent: "")
    menu.addItem(withTitle: "Zoom Out", action: #selector(CanvasView.zoomOut(_:)), keyEquivalent: "")
    for item in menu.items.suffix(3) { item.target = canvas }
    return menu
  }

  @objc private func zoomToPercent(_ sender: NSMenuItem) { canvas.zoom(to: CGFloat(sender.tag) / 100) }

  private func updateZoomItem() {
    zoomItem?.title = "\(canvas.zoomPercent)%"
    zoomItem?.image = nil
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

  var inspectorVisible: Bool { !inspectorItem.isCollapsed }

  @objc func toggleInspector(_ sender: Any?) {
    let show = inspectorItem.isCollapsed
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      inspectorItem.animator().isCollapsed = !show
    }
    if show { inspector.update() }
    if !isAutomatedCheck { UserDefaults.standard.set(show, forKey: PreferenceKey.inspectorVisible) }
  }

  /// Fitting the canvas leaves room for the Tools column.
  private func updateFitInsets() {
    canvas.fitInsets = NSEdgeInsets(top: 24, left: tools.isHidden ? 24 : 80, bottom: 24, right: 24)
  }

  @objc func toggleTools(_ sender: Any?) {
    tools.isHidden.toggle()
    updateFitInsets()
    tools.collapse()
    if !isAutomatedCheck { UserDefaults.standard.set(!tools.isHidden, forKey: PreferenceKey.toolsVisible) }
  }

  @objc func toggleGrid(_ sender: Any?) { flip(PreferenceKey.showsGrid) }
  @objc func toggleSnapToGrid(_ sender: Any?) { flip(PreferenceKey.snapsToGrid) }
  @objc func toggleGuides(_ sender: Any?) { flip(PreferenceKey.snapsToGuides) }

  private func flip(_ key: String) {
    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    NotificationCenter.default.post(name: .canvasDefaultsDidChange, object: nil)
  }

  @objc func showPalette(_ sender: Any?) {
    let panel = NSColorPanel.shared
    panel.title = "Palette"
    if let color = canvas.drawing.selectedElements.first?.stroke ?? canvas.style.stroke {
      panel.color = NSColor(cgColor: color.cgColor) ?? .black
    }
    panel.orderFront(sender)
  }

  @objc func showFonts(_ sender: Any?) {
    let text = canvas.drawing.selectedElements.first { $0.kind == .text }
    let style = text.map(Style.init) ?? (canvas.styles[.text] ?? Tool.text.defaultStyle)
    let font = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
    NSFontManager.shared.setSelectedFont(font, isMultiple: false)
    NSFontManager.shared.orderFrontFontPanel(sender)
  }

  @objc func chooseTool(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String, let tool = Tool(rawValue: name) else { return }
    canvas.tool = tool
    window?.makeFirstResponder(canvas)
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
    case #selector(toggleInspector(_:)):
      menuItem.title = inspectorVisible ? "Hide Inspector" : "Show Inspector"
    case #selector(toggleTools(_:)):
      menuItem.title = tools.isHidden ? "Show Tools" : "Hide Tools"
    case #selector(toggleGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.showsGrid) ? .on : .off
    case #selector(toggleSnapToGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGrid) ? .on : .off
    case #selector(toggleGuides(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGuides) ? .on : .off
    case #selector(chooseTool(_:)):
      menuItem.state = (menuItem.representedObject as? String) == canvas.tool.rawValue ? .on : .off
    case #selector(zoomToPercent(_:)):
      menuItem.state = canvas.zoomPercent == menuItem.tag ? .on : .off
    default: break
    }
    return true
  }
}

extension Notification.Name {
  static let toolStylesDidChange = Notification.Name("BristleToolStylesDidChange")
}

/// Keeps the inspector's toolbar button and menu item working when the canvas has focus, where
/// the split view would otherwise take ⌥⌘I for itself.
final class EditorSplitViewController: NSSplitViewController {
  weak var editor: Editor?

  @available(macOS 14.0, *)
  override func toggleInspector(_ sender: Any?) {
    if let editor { editor.toggleInspector(sender) } else { super.toggleInspector(sender) }
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(Editor.toggleInspector(_:)), let menuItem = item as? NSMenuItem, let editor {
      return editor.validateMenuItem(menuItem)
    }
    return super.validateUserInterfaceItem(item)
  }
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
