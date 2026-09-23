import AppKit
import BristleCanvas
import BristleCore
import UniformTypeIdentifiers

/// A document window, laid out like Freeform's: the tools in the toolbar, the canvas filling the
/// window, a drawing bar at the bottom while drawing, and a format bar beside the selection.
@MainActor
final class Editor: NSWindowController, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  NSSharingServicePickerToolbarItemDelegate, CanvasViewDelegate
{
  let canvas: CanvasView
  let drawBar = DrawBar()
  let zoomBar = ZoomBar()
  let canvasBar = CanvasBar()
  let formatBar = FormatBar()
  private weak var note: BristleDocument?
  private(set) var toolGroup: NSToolbarItemGroup?
  private let root = NSView()
  private var inFullScreenTransition = false
  private var shownOnce = false
  /// The last shape tool chosen, which the Shapes button shows.
  private var lastShape: Tool = .rectangle
  /// While drawing, the drawing bar is shown and the Draw button is on, as in Freeform.
  private(set) var drawMode = false

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
    toolbar.centeredItemIdentifiers = [Self.toolsItem]
    if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    canvas.delegate = self
    canvas.styles = AppPreferences.toolStyles
    canvas.configuration = AppPreferences.canvasConfiguration
    canvas.tool = .select
    canvas.fitInsets = NSEdgeInsets(top: 24, left: 24, bottom: 64, right: 24)
    drawBar.canvas = canvas
    zoomBar.canvas = canvas
    canvasBar.canvas = canvas
    canvasBar.editor = self
    formatBar.canvas = canvas

    let scroll = canvas.scrollView
    root.addSubview(scroll)
    let bottom = [drawBar.bar, zoomBar.bar, canvasBar.bar]
    bottom.forEach(root.addSubview)
    root.addSubview(formatBar.bar)
    for view in [scroll] + bottom { view.translatesAutoresizingMaskIntoConstraints = false }
    // The format bar is placed by hand beside the selection.
    formatBar.bar.translatesAutoresizingMaskIntoConstraints = true
    formatBar.bar.isHidden = true
    let guide = root.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      drawBar.bar.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      drawBar.bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
      zoomBar.bar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
      zoomBar.bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
      canvasBar.bar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
      canvasBar.bar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
    ])
    drawBar.bar.isHidden = true
    let controller = NSViewController()
    controller.view = root
    window.contentViewController = controller
    placeWindow()
    updateBars()

    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(defaultsDidChange), name: .canvasDefaultsDidChange, object: nil)
    center.addObserver(self, selector: #selector(stylesChangedElsewhere), name: .toolStylesDidChange, object: nil)
    center.addObserver(self, selector: #selector(placeFormatBar), name: .drawingDidChange, object: document.drawing)
    center.addObserver(self, selector: #selector(selectionChanged), name: .drawingSelectionDidChange, object: document.drawing)
    scroll.contentView.postsBoundsChangedNotifications = true
    center.addObserver(self, selector: #selector(placeFormatBar), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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
    placeFormatBar()
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
    let tool = canvas.tool
    // Choosing a drawing tool, by key or menu, starts drawing; a shape or text ends it.
    if DrawBar.drawingTools.contains(tool) {
      drawMode = true
    } else if tool != .select {
      drawMode = false
    }
    if [.rectangle, .ellipse, .polygon, .line, .arrow].contains(tool) { lastShape = tool }
    updateBars()
  }

  func canvasViewZoomDidChange(_ canvas: CanvasView) {
    zoomBar.update()
    placeFormatBar()
  }

  func canvasView(_ canvas: CanvasView, didPick color: Color) {
    PaletteViewController.remember(color)
    drawBar.update()
  }

  func canvasViewStylesDidChange(_ canvas: CanvasView) {
    AppPreferences.toolStyles = canvas.styles
    drawBar.update()
    NotificationCenter.default.post(name: .toolStylesDidChange, object: self)
  }

  func canvasViewDidFinishInteraction(_ canvas: CanvasView) { placeFormatBar() }

  /// Every window shares one set of tool styles.
  @objc private func stylesChangedElsewhere(_ notification: Notification) {
    guard notification.object as AnyObject? !== self else { return }
    canvas.styles = AppPreferences.toolStyles
    drawBar.update()
  }

  @objc private func defaultsDidChange() {
    canvas.configuration = AppPreferences.canvasConfiguration
    canvasBar.update()
  }

  @objc private func selectionChanged() {
    formatBar.update()
    placeFormatBar()
  }

  private func updateBars() {
    drawBar.bar.isHidden = !drawMode
    drawBar.update()
    zoomBar.update()
    canvasBar.update()
    updateToolGroup()
    formatBar.update()
    placeFormatBar()
  }

  /// Puts the format bar above the selection, or below it when there's no room above, and hides
  /// it while the selection is being changed with the pointer.
  @objc func placeFormatBar() {
    let bar = formatBar.bar
    let selected = canvas.drawing.selectedElements.filter { !$0.locked }
    guard !selected.isEmpty, canvas.tool == .select, !canvas.isInteracting, !canvas.isEditingText,
      let box = canvas.selectionBounds
    else {
      bar.isHidden = true
      return
    }
    formatBar.update()
    let size = bar.fittingSize
    let rect = root.convert(canvas.convert(box, to: nil), from: nil)
    let visible = root.bounds
    let top = visible.maxY - root.safeAreaInsets.top
    var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.maxY + 16)
    if origin.y + size.height > top - 8 { origin.y = rect.minY - size.height - 16 }
    origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
    origin.y = min(max(origin.y, visible.minY + 64), top - size.height - 8)
    bar.frame = NSRect(origin: origin, size: size).integral
    bar.isHidden = false
  }

  // MARK: Toolbar

  static let shareToolbarItem = NSToolbarItem.Identifier("share")

  /// The tools in the toolbar, in order.
  enum Slot: String, CaseIterable { case select, draw, shapes, text, image }

  static let toolsItem = NSToolbarItem.Identifier("tools")

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.toolsItem, .flexibleSpace, Self.shareToolbarItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  private func slotDetails(_ slot: Slot) -> (symbol: String, label: String, tip: String) {
    switch slot {
    case .select: ("cursorarrow", "Select", "Select and move objects (V)")
    case .draw: ("pencil.tip.crop.circle", "Draw", "Draw with a pencil, brush, or highlighter (P)")
    case .shapes: (lastShape.symbol, "Shapes", "Draw shapes, lines, and arrows; click again for more")
    case .text: ("textformat", "Text", "Add text (T)")
    case .image: ("photo", "Image", "Insert an image (⇧⌘I)")
    }
  }

  /// A tool's symbol; while it's the tool in use, a filled circle with the symbol cut out of it,
  /// as Freeform marks its drawing tool.
  private func slotImage(_ slot: Slot, on: Bool) -> NSImage? {
    let details = slotDetails(slot)
    guard let symbol = NSImage(systemSymbolName: details.symbol, accessibilityDescription: details.label)?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
    else { return nil }
    guard on else { return NSImage(systemSymbolName: details.symbol, accessibilityDescription: details.label) }
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
    guard itemIdentifier == Self.toolsItem else { return nil }
    // One group, so the tools share a capsule in the middle of the toolbar as Freeform's do.
    let slots = Slot.allCases
    let group = NSToolbarItemGroup(
      itemIdentifier: itemIdentifier, images: slots.map { slotImage($0, on: false)! }, selectionMode: .momentary,
      labels: slots.map { slotDetails($0).label }, target: self, action: #selector(chooseSlot(_:)))
    group.label = "Tools"
    group.paletteLabel = "Tools"
    for (item, slot) in zip(group.subitems, slots) {
      item.toolTip = slotDetails(slot).tip
      item.target = self
      item.action = #selector(chooseSlotItem(_:))
      item.tag = Slot.allCases.firstIndex(of: slot) ?? 0
    }
    toolGroup = group
    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateToolGroup() } }
    return group
  }

  func shapesMenu() -> NSMenu {
    let menu = NSMenu(title: "Shapes")
    for tool in [Tool.rectangle, .ellipse, .polygon, .line, .arrow] {
      if tool == .line { menu.addItem(.separator()) }
      let item = menu.addItem(withTitle: tool.title, action: #selector(chooseTool(_:)), keyEquivalent: "")
      item.representedObject = tool.rawValue
      item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
      item.target = self
    }
    return menu
  }

  var currentSlot: Slot? {
    let tool = canvas.tool
    if drawMode { return .draw }
    if tool == .select { return .select }
    if tool == .text { return .text }
    if [.rectangle, .ellipse, .polygon, .line, .arrow].contains(tool) { return .shapes }
    return nil
  }

  /// Shows which tool is in use in the toolbar.
  private func updateToolGroup() {
    guard let group = toolGroup else { return }
    let current = currentSlot
    for (item, slot) in zip(group.subitems, Slot.allCases) {
      item.image = slotImage(slot, on: slot == current)
    }
    if let control = group.view as? NSSegmentedControl {
      for (i, slot) in Slot.allCases.enumerated() { control.setImage(slotImage(slot, on: slot == current), forSegment: i) }
    }
  }

  @objc private func chooseSlot(_ sender: NSToolbarItemGroup) {
    let index = (sender.view as? NSSegmentedControl)?.selectedSegment ?? -1
    choose(Slot.allCases.indices.contains(index) ? Slot.allCases[index] : nil, from: sender)
  }

  @objc private func chooseSlotItem(_ sender: NSToolbarItem) {
    choose(Slot.allCases.indices.contains(sender.tag) ? Slot.allCases[sender.tag] : nil, from: sender)
  }

  func choose(_ slot: Slot?, from sender: Any? = nil) {
    switch slot {
    case .select:
      drawMode = false
      canvas.tool = .select
    case .draw:
      toggleDraw(sender)
      return
    case .shapes:
      // Shapes uses the last shape; clicking it again offers the others.
      if currentSlot == .shapes, let view = toolGroup?.view {
        let width = view.bounds.width / CGFloat(Slot.allCases.count)
        shapesMenu().popUp(positioning: nil, at: NSPoint(x: width * 2, y: view.bounds.height + 4), in: view)
      } else {
        drawMode = false
        canvas.tool = lastShape
      }
    case .text:
      drawMode = false
      canvas.tool = .text
    case .image:
      insertImage(sender)
    case nil: break
    }
    updateBars()
    window?.makeFirstResponder(canvas)
  }

  /// Draw starts drawing with the last drawing tool, or stops, returning to Select.
  @objc func toggleDraw(_ sender: Any?) {
    if drawMode {
      drawMode = false
      canvas.tool = .select
    } else {
      drawMode = true
      canvas.tool = drawBar.lastTool
    }
    updateBars()
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

  /// Format ▸ Show Palette opens the Palette for the selection, or the current tool.
  @objc func showPalette(_ sender: Any?) {
    if !formatBar.bar.isHidden, let swatch = formatBar.bar.row.arrangedSubviews.last(where: { $0 is SwatchButton }) {
      (swatch as? NSButton)?.performClick(sender)
    } else if !drawBar.bar.isHidden {
      drawBar.swatch.performClick(sender)
    } else {
      let tool = canvas.tool
      let target = PaletteTarget(title: "\(tool.title) Color", color: canvas.style.stroke) { [weak self] color in
        guard let self, let color else { return }
        self.canvas.setStyle("Change Color") { $0.stroke = color }
      }
      PaletteViewController.show(target, relativeTo: canvasBar.options, edge: .maxY)
    }
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
    case #selector(toggleDraw(_:)):
      menuItem.state = drawMode ? .on : .off
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
