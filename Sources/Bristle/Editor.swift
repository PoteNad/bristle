import AppKit
import BristleCanvas
import BristleCore
import UniformTypeIdentifiers

/// A document window: every tool in the toolbar, as in Excalidraw, in capsules as in Freeform;
/// the canvas, a page as MS Paint's is; bars over its bottom edge for zoom and the style of
/// what's drawn or selected; and the Palette in a sidebar, like Plainst's symbols.
@MainActor
final class Editor: NSWindowController, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  NSSharingServicePickerToolbarItemDelegate, CanvasViewDelegate
{
  let canvas: CanvasView
  let palette = Palette()
  let zoomBar = ZoomBar()
  let styleBar = StyleBar()
  private weak var note: BristleDocument?
  /// The toolbar's tools, in order.
  private(set) var toolButtons: [(slot: Slot, button: BarButton)] = []
  private let root = EditorView()
  private var paletteItem: NSSplitViewItem!
  private var inFullScreenTransition = false
  private var shownOnce = false
  /// The drawing tool Draw uses: the brush chosen last.
  private var lastBrush: Tool = .pen
  /// The eraser the Eraser button chooses: the one used last, rubbing out pixels at first, as
  /// MS Paint's does.
  private var lastEraser: Tool = .strokeEraser

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
    toolbar.centeredItemIdentifiers = Set(Self.toolItems)
    if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    canvas.delegate = self
    canvas.styles = AppPreferences.toolStyles
    canvas.configuration = AppPreferences.canvasConfiguration
    canvas.tool = .select
    // Fitting the canvas leaves a margin around it, beyond the toolbar and the bars.
    canvas.fitInsets = NSEdgeInsets(top: 24, left: 32, bottom: 12, right: 32)
    palette.canvas = canvas
    palette.editor = self
    zoomBar.canvas = canvas
    styleBar.canvas = canvas
    styleBar.editor = self

    root.canvas = canvas.scrollView
    root.zoom = zoomBar.bar
    root.style = styleBar.bar
    // Over the bars and the toolbar, the pointer is the arrow, not the tool's.
    canvas.coveredRects = { [weak self] in
      guard let self, let window = self.window else { return [] }
      var rects = [self.zoomBar.bar, self.styleBar.bar].filter { !$0.isHidden && $0.alphaValue > 0.1 && $0.window != nil }
        .map { $0.convert($0.bounds, to: nil) }
      let top = window.contentLayoutRect.maxY
      rects.append(NSRect(x: 0, y: top, width: window.frame.width, height: max(0, window.frame.height - top)))
      return rects
    }
    root.didLayout = { [weak self] in
      guard let self else { return }
      self.window?.invalidateCursorRects(for: self.canvas)
      self.updateBarAppearance()
    }
    root.autoHides = UserDefaults.standard.bool(forKey: PreferenceKey.barsAutoHide) && !isAutomatedCheck
    let controller = NSViewController()
    controller.view = root
    // The Palette shares the window beside the canvas, like Plainst's symbols sidebar.
    let split = EditorSplitViewController()
    split.editor = self
    split.addSplitViewItem(NSSplitViewItem(viewController: controller))
    paletteItem = NSSplitViewItem(inspectorWithViewController: palette)
    paletteItem.canCollapse = true
    paletteItem.minimumThickness = 260
    paletteItem.maximumThickness = 380
    paletteItem.isCollapsed = isAutomatedCheck || !UserDefaults.standard.bool(forKey: PreferenceKey.paletteVisible)
    split.addSplitViewItem(paletteItem)
    if !isAutomatedCheck { split.splitView.autosaveName = "BristleEditorSplit" }
    window.contentViewController = split
    placeWindow()
    updateBars()

    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(defaultsDidChange), name: .canvasDefaultsDidChange, object: nil)
    center.addObserver(self, selector: #selector(stylesChangedElsewhere), name: .toolStylesDidChange, object: nil)
    center.addObserver(self, selector: #selector(drawingChanged), name: .drawingDidChange, object: document.drawing)
    center.addObserver(self, selector: #selector(drawingChanged), name: .drawingSelectionDidChange, object: document.drawing)
    // Scrolling moves the page under the bars.
    center.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: canvas.scrollView.contentView)
    window.makeFirstResponder(canvas)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    showDrawingOnce()
  }

  /// Opens showing the whole drawing, at actual size when it fits. Windows restored after a
  /// relaunch appear without `showWindow`, so this also runs when a window first updates.
  private func showDrawingOnce() {
    guard !shownOnce, let window, window.isVisible else { return }
    shownOnce = true
    window.contentView?.layoutSubtreeIfNeeded()
    canvas.showDrawing()
    zoomBar.update()
  }

  func windowDidUpdate(_ notification: Notification) { showDrawingOnce() }

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
    if Controls.brushes.contains(canvas.tool) { lastBrush = canvas.tool }
    if canvas.tool == .eraser || canvas.tool == .strokeEraser { lastEraser = canvas.tool }
    updateBars()
  }

  func canvasViewZoomDidChange(_ canvas: CanvasView) {
    zoomBar.update()
    updateBarAppearance()
  }

  func canvasView(_ canvas: CanvasView, didPick color: Color) {
    palette.update()
    styleBar.update()
  }

  func canvasViewStylesDidChange(_ canvas: CanvasView) {
    AppPreferences.toolStyles = canvas.styles
    palette.update()
    styleBar.update()
    NotificationCenter.default.post(name: .toolStylesDidChange, object: self)
  }

  func canvasViewDidFinishInteraction(_ canvas: CanvasView) {
    palette.update()
    styleBar.update()
  }

  /// Every window shares one set of tool styles.
  @objc private func stylesChangedElsewhere(_ notification: Notification) {
    guard notification.object as AnyObject? !== self else { return }
    canvas.styles = AppPreferences.toolStyles
    palette.update()
    styleBar.update()
  }

  @objc private func defaultsDidChange() {
    canvas.configuration = AppPreferences.canvasConfiguration
    // Rulers coming or going change the room the canvas has.
    root.needsLayout = true
    palette.update()
    updateStyleBarPlace()
    root.autoHides = UserDefaults.standard.bool(forKey: PreferenceKey.barsAutoHide) && !isAutomatedCheck
  }

  /// The style bar steps aside while the Palette is open, if that's the setting.
  private func updateStyleBarPlace() {
    styleBar.suppressed = paletteVisible && UserDefaults.standard.bool(forKey: PreferenceKey.barHidesWithPalette)
  }

  @objc private func viewMoved() { updateBarAppearance() }

  private var paletteScheduled = false

  /// The Palette follows the drawing, at most once per turn of the run loop.
  @objc private func drawingChanged() {
    guard !paletteScheduled else { return }
    paletteScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.paletteScheduled = false
        self?.updateBarAppearance()
        self?.palette.update()
        self?.styleBar.update()
      }
    }
  }

  /// The bars float over the canvas, so each takes the lightness of what's under it: the page's
  /// own colour, light even in dark mode for a white page, or the window's around it, so their
  /// symbols always stand out.
  func updateBarAppearance() {
    guard let window else { return }
    let page = canvas.convert(canvas.scene.canvas, to: nil)
    let light = canvas.scene.paper.background.map { 0.299 * $0.red + 0.587 * $0.green + 0.114 * $0.blue >= 0.5 || $0.alpha < 0.5 } ?? true
    for bar in [zoomBar.bar, styleBar.bar] where bar.window != nil {
      let frame = bar.convert(bar.bounds, to: nil)
      let over = frame.intersection(page)
      let onPage = !over.isNull && over.width * over.height > frame.width * frame.height / 2
      let appearance = onPage ? NSAppearance(named: light ? .aqua : .darkAqua) : nil
      if bar.appearance?.name != appearance?.name { bar.appearance = appearance }
      _ = window
    }
  }

  private func updateBars() {
    updateBarAppearance()
    updateStyleBarPlace()
    palette.update()
    styleBar.update()
    zoomBar.update()
    updateToolGroups()
  }

  // MARK: Toolbar

  /// The tools in capsules, as MS Paint's ribbon groups them: selecting; the tools that paint;
  /// shapes and lines; and what's put on the canvas, text and pictures.
  static let groups: [(id: NSToolbarItem.Identifier, label: String, slots: [Slot])] = [
    (NSToolbarItem.Identifier("select"), "Select", [.select]),
    (NSToolbarItem.Identifier("paint"), "Paint", [.draw, .eraser, .fill, .eyedropper]),
    (NSToolbarItem.Identifier("shapes"), "Shapes", [.rectangle, .ellipse, .polygon, .line, .arrow]),
    (NSToolbarItem.Identifier("insert"), "Insert", [.text, .image]),
  ]

  static func slots(in id: NSToolbarItem.Identifier) -> [Slot] { groups.first { $0.id == id }?.slots ?? [] }
  /// The tool groups with a gap between each, all centred over the canvas together.
  static let toolItems: [NSToolbarItem.Identifier] = groups.enumerated().flatMap { i, group in
    i == 0 ? [group.id] : [NSToolbarItem.Identifier("gap\(i)"), group.id]
  }
  static let shareToolbarItem = NSToolbarItem.Identifier("share")
  static let paletteToolbarItem = NSToolbarItem.Identifier("palette")

  /// The tools in the toolbar.
  enum Slot: Int, CaseIterable {
    case select, draw, eraser, fill, rectangle, ellipse, polygon, line, arrow, text, image, eyedropper
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // The tools centre over the canvas, and Share and the Palette's button stay over the
    // Palette, so opening it doesn't push the tools off centre.
    // A gap between groups keeps each in a capsule of its own.
    let tools = Self.toolItems
    if #available(macOS 14.0, *) {
      return [.flexibleSpace] + tools + [
        .flexibleSpace, .inspectorTrackingSeparator, .flexibleSpace, Self.shareToolbarItem, Self.paletteToolbarItem,
      ]
    }
    return [.flexibleSpace] + tools + [.flexibleSpace, Self.shareToolbarItem, Self.paletteToolbarItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  private func slotDetails(_ slot: Slot) -> (symbol: String, label: String, tip: String) {
    switch slot {
    case .select: ("cursorarrow", "Select", "Select (V)")
    case .draw: (lastBrush.symbol, "Draw", lastBrush.key.isEmpty ? "Draw: \(lastBrush.title)" : "Draw: \(lastBrush.title) (\(lastBrush.key.uppercased()))")
    case .eraser: ("eraser", "Eraser", "Eraser (E)")
    case .fill: ("drop", "Fill", "Fill (F)")
    case .eyedropper: ("eyedropper", "Pick Color", "Pick Color (I)")
    case .rectangle: ("rectangle", "Rectangle", "Rectangle (R)")
    case .ellipse: ("circle", "Ellipse", "Ellipse (O)")
    case .polygon: ("pentagon", "Shapes", "Shapes and Polygon (G)")
    case .line: ("line.diagonal", "Line", "Line (L)")
    case .arrow: ("arrow.up.right", "Arrow", "Arrow (A)")
    case .text: ("textformat", "Text", "Text (T)")
    case .image: ("photo", "Image", "Insert Image (⇧⌘I)")
    }
  }

  /// A tool's symbol. The arrow's weight is in its head, at the left, so it's moved a point to
  /// the right to look centred in its circle.
  private func slotImage(_ slot: Slot) -> NSImage {
    let details = slotDetails(slot)
    let symbol = NSImage(systemSymbolName: details.symbol, accessibilityDescription: details.label)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
    guard slot == .select else { return symbol }
    let shift: CGFloat = 1
    let image = NSImage(size: NSSize(width: symbol.size.width + shift * 2, height: symbol.size.height), flipped: false) { rect in
      symbol.draw(in: NSRect(x: shift * 2, y: 0, width: symbol.size.width, height: symbol.size.height))
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = details.label
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
    if itemIdentifier == Self.paletteToolbarItem {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "Palette")
      item.label = "Palette"
      item.paletteLabel = "Palette"
      item.toolTip = "Show or hide the Palette (⇧⌘C)"
      item.target = self
      item.action = #selector(togglePalette(_:))
      item.isBordered = true
      return item
    }
    if itemIdentifier.rawValue.hasPrefix("gap") {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      let gap = NSView()
      gap.widthAnchor.constraint(equalToConstant: 2).isActive = true
      item.view = gap
      item.isBordered = false
      return item
    }
    guard let spec = Self.groups.first(where: { $0.id == itemIdentifier }) else { return nil }
    // The tools are the bars' own buttons, so the one in use is marked with the same circle the
    // pointer's highlight makes over any of them, as in the bars at the bottom.
    let buttons = spec.slots.map { slot -> BarButton in
      let details = slotDetails(slot)
      let button = BarButton(image: slotImage(slot), title: details.tip, target: self, action: #selector(chooseSlotButton(_:)))
      button.tag = slot.rawValue
      button.setAccessibilityLabel(details.label)
      toolButtons.append((slot, button))
      return button
    }
    let row = NSStackView(views: buttons)
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.view = row
    item.label = spec.label
    item.paletteLabel = spec.label
    // In a narrow window the group moves into the toolbar's overflow menu, as a menu of its tools.
    let menu = NSMenu(title: spec.label)
    for slot in spec.slots {
      let details = slotDetails(slot)
      let entry = menu.addItem(withTitle: details.label, action: #selector(chooseSlotButton(_:)), keyEquivalent: "")
      entry.target = self
      entry.tag = slot.rawValue
      entry.image = slotImage(slot)
    }
    let overflow = NSMenuItem(title: spec.label, action: nil, keyEquivalent: "")
    overflow.submenu = menu
    item.menuFormRepresentation = overflow
    DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.updateToolGroups() } }
    return item
  }

  var currentSlot: Slot? {
    switch canvas.tool {
    case .select: .select
    case .pencil, .pen, .highlighter, .pixel, .calligraphy, .airbrush, .crayon, .marker, .watercolor, .oil: .draw
    case .eraser, .strokeEraser: .eraser
    case .fill: .fill
    case .rectangle: .rectangle
    case .ellipse: .ellipse
    case .polygon: .polygon
    case .line: .line
    case .arrow: .arrow
    case .text: .text
    case .eyedropper: .eyedropper
    }
  }

  /// Shows which tool is in use in the toolbar, and the brush Draw uses.
  private func updateToolGroups() {
    let current = currentSlot
    for (slot, button) in toolButtons {
      button.isOn = slot == current
      if slot == .draw {
        button.image = slotImage(.draw)
        button.toolTip = slotDetails(.draw).tip
      }
    }
  }

  @objc func chooseSlotButton(_ sender: Any?) {
    guard let tag = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag, let slot = Slot(rawValue: tag) else { return }
    choose(slot, from: sender)
  }

  func choose(_ slot: Slot, from sender: Any? = nil) {
    switch slot {
    case .select: canvas.tool = .select
    case .draw: canvas.tool = lastBrush
    case .eraser: canvas.tool = lastEraser
    case .fill: canvas.tool = .fill
    case .rectangle: canvas.tool = .rectangle
    case .ellipse: canvas.tool = .ellipse
    case .polygon: canvas.tool = .polygon
    case .line: canvas.tool = .line
    case .arrow: canvas.tool = .arrow
    case .text: canvas.tool = .text
    case .image:
      // Image is a command, not a tool: the tool in use stays marked.
      updateToolGroups()
      insertImage(sender)
    case .eyedropper: canvas.tool = .eyedropper
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
  @objc func toggleRulers(_ sender: Any?) { flip(PreferenceKey.showsRulers) }
  @objc func toggleSnapToGrid(_ sender: Any?) { flip(PreferenceKey.snapsToGrid) }
  @objc func toggleGuides(_ sender: Any?) { flip(PreferenceKey.snapsToGuides) }

  func flip(_ key: String) {
    guard !isAutomatedCheck else { return }
    UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    NotificationCenter.default.post(name: .canvasDefaultsDidChange, object: nil)
  }

  var paletteVisible: Bool { paletteItem.map { !$0.isCollapsed } ?? false }

  /// The Palette's width until it's dragged wider or narrower.
  static let paletteWidth: CGFloat = 280

  func resetPaletteWidth() {
    guard let split = window?.contentViewController as? NSSplitViewController, !paletteItem.isCollapsed else { return }
    let view = split.splitView
    let position = view.bounds.width - view.dividerThickness - Self.paletteWidth
    NSAnimationContext.runAnimationGroup { context in
      context.duration = isAutomatedCheck ? 0 : 0.2
      context.allowsImplicitAnimation = true
      view.setPosition(position, ofDividerAt: 0)
      view.layoutSubtreeIfNeeded()
    }
  }

  /// The brush button and Format ▸ Show Palette slide the Palette in and out, as Plainst's
  /// symbols sidebar does, without resizing the window.
  @objc func togglePalette(_ sender: Any?) {
    let show = paletteItem.isCollapsed
    if show {
      _ = palette.view
      palette.update()
    }
    // Checks look at the layout right away, so they skip the slide.
    guard !isAutomatedCheck else {
      paletteItem.isCollapsed = !show
      updateStyleBarPlace()
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.allowsImplicitAnimation = true
      paletteItem.animator().isCollapsed = !show
    }
    if !isAutomatedCheck { UserDefaults.standard.set(show, forKey: PreferenceKey.paletteVisible) }
    updateStyleBarPlace()
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

  /// Canvas ▸ Canvas Size: a sheet with the canvas's size, common sizes, and where the drawing
  /// stays as it grows or shrinks, as MS Paint's Resize does.
  @objc func showCanvasSize(_ sender: Any?) {
    guard let window else { return }
    let current = canvas.scene.paper.size
    let alert = NSAlert()
    alert.messageText = "Canvas Size"
    alert.informativeText = "Sizes are in points, which are pixels in exported images."
    alert.addButton(withTitle: "Change")
    alert.addButton(withTitle: "Cancel")
    let number = NumberFormatter()
    number.numberStyle = .decimal
    number.minimum = 1
    number.maximum = NSNumber(value: Double(Paper.maximumSide))
    number.maximumFractionDigits = 0
    let width = NSTextField(string: number.string(from: NSNumber(value: Double(current.width))) ?? "")
    let height = NSTextField(string: number.string(from: NSNumber(value: Double(current.height))) ?? "")
    for field in [width, height] {
      field.formatter = number
      field.widthAnchor.constraint(equalToConstant: 80).isActive = true
    }
    width.setAccessibilityLabel("Width")
    height.setAccessibilityLabel("Height")
    let presets = NSPopUpButton()
    presets.addItem(withTitle: "Custom")
    for size in CanvasSize.allCases {
      presets.addItem(withTitle: size.title)
      presets.lastItem?.representedObject = size.rawValue
    }
    let presetTarget = ClosureTarget { _ in
      guard let name = presets.selectedItem?.representedObject as? String, let size = CanvasSize(rawValue: name) else { return }
      width.stringValue = number.string(from: NSNumber(value: Double(size.size.width))) ?? ""
      height.stringValue = number.string(from: NSNumber(value: Double(size.size.height))) ?? ""
    }
    presets.target = presetTarget
    presets.action = #selector(ClosureTarget.fire(_:))
    let anchor = AnchorPicker()
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Size:"), presets],
      [NSTextField(labelWithString: "Width:"), width],
      [NSTextField(labelWithString: "Height:"), height],
      [NSTextField(labelWithString: "Keep drawing at:"), anchor],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.row(at: 3).yPlacement = .top
    grid.frame.size = grid.fittingSize
    alert.accessoryView = grid
    alert.window.initialFirstResponder = width
    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        _ = presetTarget
        guard let self, response == .alertFirstButtonReturn,
          let w = number.number(from: width.stringValue)?.doubleValue,
          let h = number.number(from: height.stringValue)?.doubleValue
        else { return }
        self.canvas.resizeCanvas(to: CGSize(width: w, height: h), anchor: anchor.anchor)
      }
    }
  }

  /// Canvas ▸ Background: white, transparent, or any color.
  @objc func chooseBackground(_ sender: NSMenuItem) {
    switch sender.tag {
    case 0: canvas.drawing.edit("Transparent Background") { $0.paper.background = nil }
    case 1: canvas.drawing.edit("Background") { $0.paper.background = .white }
    default:
      ColorPanelRelay.open(canvas.scene.paper.background ?? .white) { [weak canvas] color in
        canvas?.drawing.coalesce("Background") { $0.paper.background = color }
      }
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let defaults = UserDefaults.standard
    switch menuItem.action {
    case #selector(togglePalette(_:)):
      menuItem.title = paletteVisible ? "Hide Palette" : "Show Palette"
    case #selector(toggleGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.showsGrid) ? .on : .off
    case #selector(toggleRulers(_:)):
      menuItem.title = defaults.bool(forKey: PreferenceKey.showsRulers) ? "Hide Rulers" : "Show Rulers"
    case #selector(toggleSnapToGrid(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGrid) ? .on : .off
    case #selector(toggleGuides(_:)):
      menuItem.state = defaults.bool(forKey: PreferenceKey.snapsToGuides) ? .on : .off
    case #selector(chooseBackground(_:)):
      let background = canvas.scene.paper.background
      let chosen = background == nil ? 0 : background == .white ? 1 : 2
      menuItem.state = menuItem.tag == chosen ? .on : .off
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

/// The canvas under the window's bars: zoom at the bottom left, and the style bar centred,
/// raised above the zoom bar when the window is too narrow for both in a row.
final class EditorView: NSView {
  static let margin: CGFloat = 14
  var canvas: NSView? { didSet { replace(oldValue, canvas, below: true) } }
  var zoom: NSView? { didSet { replace(oldValue, zoom) } }
  var style: NSView? { didSet { replace(oldValue, style) } }
  var didLayout: (() -> Void)?
  /// Whether the bars show only when the pointer comes near the bottom of the window.
  var autoHides = false {
    didSet {
      guard autoHides != oldValue else { return }
      updateTrackingAreas()
      setBarsShown(!autoHides, animated: false)
    }
  }
  private var barsShown = true

  private var bars: [NSView] { [zoom, style].compactMap { $0 } }

  private var nearArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let nearArea { removeTrackingArea(nearArea) }
    nearArea = nil
    guard autoHides else { return }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    addTrackingArea(area)
    nearArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    guard autoHides else { return }
    let p = convert(event.locationInWindow, from: nil)
    // Near the bottom edge, where the bars are, they come up.
    setBarsShown(p.y < Self.margin * 2 + Bar.height * 2 + 20, animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    if autoHides { setBarsShown(false, animated: true) }
  }

  private func setBarsShown(_ shown: Bool, animated: Bool) {
    guard shown != barsShown || !animated else { return }
    barsShown = shown
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated ? 0.18 : 0
      for bar in bars { (animated ? bar.animator() : bar).alphaValue = shown ? 1 : 0 }
    }
    didLayout?()
  }

  private func replace(_ old: NSView?, _ new: NSView?, below: Bool = false) {
    old?.removeFromSuperview()
    guard let new else { return }
    new.translatesAutoresizingMaskIntoConstraints = true
    if below { addSubview(new, positioned: .below, relativeTo: nil) } else { addSubview(new) }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    canvas?.frame = bounds
    let margin = Self.margin
    var inset = safeAreaInsets
    // The bars sit beside the vertical ruler, not over it.
    if let scroll = canvas as? NSScrollView, scroll.rulersVisible { inset.left += scroll.verticalRulerView?.requiredThickness ?? 0 }
    var left = NSRect.zero
    if let zoom {
      let size = zoom.fittingSize
      left = NSRect(x: inset.left + margin, y: inset.bottom + margin, width: size.width, height: size.height)
      zoom.frame = left
    }
    var top = left.maxY
    if let style, !style.isHidden {
      let size = style.fittingSize
      var frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: inset.bottom + margin, width: size.width, height: size.height)
      if frame.minX < left.maxX + 8 || frame.maxX > bounds.maxX - (left.maxX - inset.left) - 8 { frame.origin.y = left.maxY + 8 }
      style.frame = frame
      top = max(top, frame.maxY)
    }
    // The canvas's edges can be scrolled clear of the toolbar and the bars.
    if let scroll = canvas as? NSScrollView {
      let insets = NSEdgeInsets(top: inset.top, left: 0, bottom: top + margin, right: 0)
      if scroll.automaticallyAdjustsContentInsets { scroll.automaticallyAdjustsContentInsets = false }
      if scroll.contentInsets.top != insets.top || scroll.contentInsets.bottom != insets.bottom || scroll.contentInsets.left != insets.left {
        scroll.contentInsets = insets
        // The canvas moves to suit the new room, centred if it fits.
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        scroll.reflectScrolledClipView(clip)
      }
    }
    didLayout?()
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

/// Sends the system's Toggle Inspector command to the Palette, so the split view doesn't take
/// it for itself.
final class EditorSplitViewController: NSSplitViewController {
  weak var editor: Editor?

  override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    let splitView = DividerSplitView()
    splitView.isVertical = true
    splitView.dividerStyle = .thin
    // Double-clicking the Palette's edge puts it back to its usual width, as Plainst's
    // preview does.
    splitView.onDoubleClick = { [weak self] _ in
      self?.editor?.resetPaletteWidth()
      return self?.editor != nil
    }
    self.splitView = splitView
  }

  required init?(coder: NSCoder) { fatalError() }

  @available(macOS 14.0, *)
  override func toggleInspector(_ sender: Any?) {
    if let editor { editor.togglePalette(sender) } else { super.toggleInspector(sender) }
  }
}

/// A split view that reports double-clicks on its dividers, and stops its dividers at the
/// toolbar rather than drawing them across the title bar, as Plainst's does.
final class DividerSplitView: NSSplitView {
  /// Returns true when the double-click on the divider at an index was handled.
  var onDoubleClick: ((Int) -> Bool)?

  override func drawDivider(in rect: NSRect) {
    let top = bounds.maxY - safeAreaInsets.top
    guard rect.maxY > top else { return super.drawDivider(in: rect) }
    let visible = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, top - rect.minY))
    guard visible.height > 0 else { return }
    super.drawDivider(in: visible)
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2, let index = divider(at: convert(event.locationInWindow, from: nil)),
      onDoubleClick?(index) == true
    {
      return
    }
    super.mouseDown(with: event)
  }

  private func divider(at point: NSPoint) -> Int? {
    let panes = arrangedSubviews
    guard panes.count > 1 else { return nil }
    for index in 0..<(panes.count - 1) {
      let drawn = NSRect(
        x: panes[index].frame.maxX, y: bounds.minY,
        width: max(dividerThickness, panes[index + 1].frame.minX - panes[index].frame.maxX), height: bounds.height)
      if drawn.insetBy(dx: -4, dy: 0).contains(point) { return index }
    }
    return nil
  }
}
