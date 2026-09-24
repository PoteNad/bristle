import AppKit
import BristleCanvas
import BristleCore

/// The Palette: a sidebar beside the canvas, like Plainst's symbols sidebar and Keynote's Format
/// inspector. It has everything the bar at the bottom has, and more: for what's drawn next or
/// what's selected, a Style tab with every colour, brush, line, and text setting, and an Arrange
/// tab with the exact position, size, and turn, layers, alignment, and actions; with nothing
/// selected, the canvas: how selecting works, the frame, the background, the grid, and rulers.
@MainActor
final class Palette: NSViewController {
  enum Tab: Int { case style, arrange }

  weak var canvas: CanvasView? {
    didSet { controls.canvas = canvas }
  }
  weak var editor: Editor?
  private let controls = Controls()
  private let stack = NSStackView()
  private let scroll = NSScrollView()
  private var builtFor = ""
  var tab = Tab.style
  /// Space between the sidebar's edges and its controls, as in Plainst's sidebars.
  static let margin: CGFloat = 16

  override func loadView() {
    let root = NSView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 12, left: Self.margin, bottom: 24, right: Self.margin)
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
    ])
    view = root
    view.setAccessibilityLabel("Palette")
  }

  /// The sidebar's headings, top to bottom, for the checks.
  var sectionTitles: [String] {
    func labels(_ view: NSView) -> [String] {
      if let field = view as? NSTextField, !field.isEditable, field.identifier?.rawValue == "heading" { return [field.stringValue] }
      return view.subviews.flatMap(labels)
    }
    return labels(stack)
  }

  // MARK: What's shown

  private var elements: [Element] { controls.elements }
  private var kinds: Set<Element.Kind> { controls.kinds }

  func update() {
    guard isViewLoaded, canvas != nil else { return }
    let key = controls.key + "|\(tab)|\(canvas?.scene.frame != nil)"
    if key != builtFor {
      builtFor = key
      rebuild()
    }
    controls.refresh()
  }

  private func rebuild() {
    guard let canvas else { return }
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    controls.reset()
    title(heading)
    if canvas.drawing.selectedElements.contains(where: \.locked) && elements.isEmpty {
      note("Locked.")
      section("", NSButton(title: "Unlock All", target: canvas, action: #selector(CanvasView.unlockAll(_:))), fill: false)
      return
    }
    if controls.selecting {
      let tabs = NSSegmentedControl(labels: ["Style", "Arrange"], trackingMode: .selectOne, target: nil, action: nil)
      tabs.segmentDistribution = .fillEqually
      tabs.selectedSegment = tab.rawValue
      controls.wire(tabs) { [weak self, weak tabs] _ in
        guard let self, let tabs, let chosen = Tab(rawValue: tabs.selectedSegment) else { return }
        self.tab = chosen
        self.update()
      }
      full(tabs)
      if tab == .arrange { return arrangeSections() }
    }
    if kinds.isEmpty && ![Tool.eraser, .strokeEraser, .fill, .polygon].contains(canvas.tool) {
      return canvasSections()
    }
    styleSections()
  }

  /// What the sidebar is showing, as its heading.
  private var heading: String {
    guard let canvas else { return "" }
    let selected = elements
    if selected.count == 1 { return selected[0].kindName }
    if selected.count > 1 {
      let names = Set(selected.map(\.kindName))
      return names.count == 1
        ? "\(selected.count) \(names.first!)s".replacingOccurrences(of: "Texts", with: "Text Boxes") : "\(selected.count) Objects"
    }
    if canvas.tool == .select || canvas.tool == .eyedropper { return "Canvas" }
    if Controls.brushes.contains(canvas.tool) { return "Draw" }
    if canvas.tool == .eraser || canvas.tool == .strokeEraser { return "Eraser" }
    return canvas.tool.title
  }

  // MARK: Style

  private func styleSections() {
    guard let canvas else { return }
    let c = controls
    let kinds = self.kinds
    let selecting = c.selecting
    let tool = canvas.tool
    let freehand = kinds.contains(.freehand)

    if (!selecting && Controls.brushes.contains(tool)) || (selecting && kinds == [.freehand]) {
      section("Brush", brushGrid())
    }
    if !selecting && (tool == .eraser || tool == .strokeEraser) {
      section("Erase", c.segmented(labels: ["Pixel", "Object"], selected: { canvas.tool == .strokeEraser ? 0 : 1 }) {
        [weak canvas] i in canvas?.tool = i == 0 ? .strokeEraser : .eraser
      })
      section("Size", widthControl())
    }
    if !selecting && tool == .polygon { section("Shape", shapeGrid()) }
    if !selecting && tool == .fill {
      section("Fill With", c.colorRow(Controls.strokes + Controls.fills.dropFirst(), allowsNone: false, value: { [weak c] in
        c?.fillColor
      }) { [weak c] color, _ in c?.setFillColor(color) })
    }
    if !kinds.isEmpty && kinds != [.image] {
      let none = c.hasShapes && !freehand && !c.hasLines
      section(kinds == [.text] ? "Text Color" : "Stroke", c.colorRow(Controls.strokes, allowsNone: none, value: { [weak c] in
        c?.strokeColor
      }) { [weak c] color, live in c?.setStroke(color, live: live) })
    }
    if c.hasShapes || kinds.contains(.text) {
      section(kinds == [.text] ? "Background" : "Fill", c.colorRow(Controls.fills, allowsNone: true, value: { [weak c] in
        c?.fillColor2
      }) { [weak c] color, live in c?.setFill(color, live: live) })
    }
    if c.hasShapes || c.hasLines || freehand { section("Width", widthControl()) }
    for (title, control) in c.lineStyleControls() { section(title, control) }
    if kinds.contains(.rectangle) { section("Corner Radius", cornerSlider()) }
    if c.hasLines {
      let heads = Element.Arrowhead.allCases
      let row = NSStackView(views: [arrowPopUp(heads, start: true), arrowPopUp(heads, start: false)])
      row.spacing = 8
      row.distribution = .fillEqually
      section("Arrowheads", row)
    }
    if kinds.contains(.text) {
      let row = NSStackView(views: [fontPopUp(), sizeBox()])
      row.spacing = 8
      section("Font", row)
      section("Align", c.segmented(
        symbols: [("text.alignleft", "Align Left"), ("text.aligncenter", "Center"), ("text.alignright", "Align Right")],
        selected: { [weak c] in c.flatMap { Element.TextAlign.allCases.firstIndex(of: $0.style(for: Controls.texts).textAlign) } }
      ) { [weak canvas] i in canvas?.setStyle("Align Text") { $0.textAlign = Element.TextAlign.allCases[i] } })
    }
    if !kinds.isEmpty { section("Opacity", c.opacitySlider()) }
    if selecting && kinds == [.image] { actionsRow(imageActions) }
  }

  /// Every brush, a click each.
  private func brushGrid() -> NSView {
    let c = controls
    let buttons: [NSView] = Controls.brushes.map { brush in
      let button = BarButton(symbol: brush.symbol, title: brush.key.isEmpty ? brush.title : "\(brush.title) (\(brush.key.uppercased()))", target: nil, action: nil)
      c.wire(button) { [weak c] _ in
        guard let c, let canvas = c.canvas else { return }
        if c.selecting { brush.brush.map(c.setBrush) } else { canvas.tool = brush }
      }
      c.onRefresh { [weak c, weak button] in
        guard let c, let canvas = c.canvas else { return }
        button?.isOn = (c.selecting ? c.brushTool : canvas.tool) == brush
      }
      return button
    }
    return grid(buttons, columns: 5)
  }

  /// MS Paint's shapes, and placing corners one click at a time.
  private func shapeGrid() -> NSView {
    let c = controls
    let choices: [ShapePreset?] = [nil] + ShapePreset.allCases
    let buttons: [NSView] = choices.map { preset in
      let image = preset.map { StyleBar.shapeImage($0) } ?? NSImage(systemSymbolName: "pentagon", accessibilityDescription: nil)!
      let button = BarButton(image: image, title: preset?.title ?? "Corners: click each, then press Return", target: nil, action: nil)
      c.wire(button) { [weak c] _ in c?.canvas?.shapePreset = preset }
      c.onRefresh { [weak c, weak button] in button?.isOn = c?.canvas?.shapePreset == preset }
      return button
    }
    return grid(buttons, columns: 6)
  }

  private func widthControl() -> NSView {
    let c = controls
    let images = (0..<3).map { i in (Controls.lineImage(CGFloat(i) * 2.5 + 1.5), Controls.widthNames[i]) }
    let presets = c.segmented(images: images, selected: { [weak c] in c?.widthIndex }) { [weak c] i in c?.setWidth(i) }
    let slider = c.widthSlider()
    let column = NSStackView(views: [presets, slider])
    column.orientation = .vertical
    column.spacing = 8
    presets.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    slider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
  }

  private func cornerSlider() -> NSView {
    let c = controls
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 80, target: nil, action: nil)
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel("Corner radius")
    let label = valueLabel()
    c.wire(slider) { [weak c, weak slider] _ in
      guard let slider else { return }
      let radius = CGFloat(slider.doubleValue.rounded())
      c?.canvas?.setStyle("Round Corners", coalescing: true) { $0.cornerRadius = radius }
    }
    c.onRefresh { [weak c, weak slider, weak label] in
      let radius = c?.style(for: [.rectangle]).cornerRadius ?? 0
      slider?.doubleValue = Double(radius)
      label?.stringValue = "\(Int(radius)) pt"
    }
    return row(slider, label)
  }

  private func fontPopUp() -> NSPopUpButton {
    let c = controls
    let popup = NSPopUpButton()
    popup.controlSize = .small
    for font in Controls.fonts {
      popup.addItem(withTitle: font.title)
      popup.lastItem?.image = Controls.fontImage(font.name)
    }
    popup.menu?.addItem(.separator())
    popup.addItem(withTitle: "Other Fonts…")
    popup.setAccessibilityLabel("Font")
    c.wire(popup) { [weak c, weak self] sender in
      guard let popup = sender as? NSPopUpButton else { return }
      let i = popup.indexOfSelectedItem
      if Controls.fonts.indices.contains(i) {
        c?.canvas?.setStyle("Change Font") { $0.fontName = Controls.fonts[i].name }
      } else {
        self?.editor?.showFonts(nil)
        c?.refresh()
      }
    }
    c.onRefresh { [weak c, weak popup] in
      guard let c, let popup else { return }
      let name = c.style(for: Controls.texts).fontName
      // A font chosen in the font panel shows as Other Fonts.
      popup.selectItem(at: Controls.fonts.firstIndex { $0.name == name } ?? popup.numberOfItems - 1)
    }
    return popup
  }

  /// Any text size: a list of the usual ones, or type your own.
  private func sizeBox() -> NSComboBox {
    let c = controls
    let box = NSComboBox()
    box.controlSize = .small
    box.addItems(withObjectValues: Controls.pointSizes.map { "\(Int($0))" })
    box.numberOfVisibleItems = 12
    box.setAccessibilityLabel("Text size")
    box.widthAnchor.constraint(equalToConstant: 64).isActive = true
    c.wire(box) { [weak c, weak box] _ in
      guard let box, let size = Double(box.stringValue.filter { $0.isNumber || $0 == "." }), size >= 4, size <= 1000 else {
        return NSSound.beep()
      }
      c?.canvas?.setStyle("Change Font Size") { $0.fontSize = CGFloat(size) }
    }
    c.onRefresh { [weak c, weak box] in
      guard let c, let box, box.currentEditor() == nil else { return }
      let size = c.style(for: Controls.texts).fontSize
      box.stringValue = size == size.rounded() ? "\(Int(size))" : String(format: "%.1f", size)
    }
    return box
  }

  private func arrowPopUp(_ heads: [Element.Arrowhead], start: Bool) -> NSPopUpButton {
    let c = controls
    let popup = NSPopUpButton()
    popup.controlSize = .small
    for head in heads {
      popup.addItem(withTitle: head == .none ? "None" : head.rawValue.capitalized)
      popup.lastItem?.image = Controls.arrowImage(head, start: start)
    }
    popup.setAccessibilityLabel(start ? "Start arrowhead" : "End arrowhead")
    popup.toolTip = start ? "Start" : "End"
    c.wire(popup) { [weak c] sender in
      guard let popup = sender as? NSPopUpButton else { return }
      let head = heads[max(0, popup.indexOfSelectedItem)]
      c?.canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
    }
    c.onRefresh { [weak c, weak popup] in
      guard let c else { return }
      let style = c.style(for: Controls.lined)
      popup?.selectItem(at: heads.firstIndex(of: start ? style.startArrowhead : style.endArrowhead) ?? 0)
    }
    return popup
  }

  // MARK: Arrange

  private func arrangeSections() {
    guard let canvas else { return }
    let c = controls
    let single = elements.count == 1 ? elements.first : nil
    // Where and how big, exactly, as Keynote's Arrange tab has it.
    let x = numberField("X"), y = numberField("Y"), w = numberField("Width"), h = numberField("Height")
    let box = { [weak c] () -> CGRect in
      guard let c, let canvas = c.canvas else { return .null }
      return canvas.scene.frameBounds(of: Set(c.elements.map(\.id)))
    }
    let origin = canvas.scene.frame?.origin ?? .zero
    c.onRefresh {
      let b = box()
      guard !b.isNull else { return }
      for (field, value) in [(x, b.minX - origin.x), (y, b.minY - origin.y), (w, b.width), (h, b.height)] where field.currentEditor() == nil {
        field.doubleValue = Double(value.rounded())
      }
    }
    let ids = Set(elements.map(\.id))
    c.wire(x) { [weak canvas] _ in
      let b = box()
      canvas?.drawing.edit("Move") { $0.move(ids, dx: CGFloat(x.doubleValue) + origin.x - b.minX, dy: 0) }
    }
    c.wire(y) { [weak canvas] _ in
      let b = box()
      canvas?.drawing.edit("Move") { $0.move(ids, dx: 0, dy: CGFloat(y.doubleValue) + origin.y - b.minY) }
    }
    for field in [w, h] {
      c.wire(field) { [weak canvas] _ in
        let b = box()
        let size = CGSize(width: max(1, CGFloat(w.doubleValue)), height: max(1, CGFloat(h.doubleValue)))
        canvas?.drawing.edit("Resize") { $0.resize(ids, from: b, to: CGRect(origin: b.origin, size: size)) }
      }
    }
    let position = NSGridView(views: [[label("X"), x, label("Y"), y], [label("W"), w, label("H"), h]])
    position.rowSpacing = 8
    position.columnSpacing = 6
    section("Position and Size", position, fill: false)
    if let single, !single.isLinear {
      let turn = numberField("Rotation")
      c.onRefresh { [weak c] in
        guard turn.currentEditor() == nil, let e = c?.elements.first else { return }
        turn.doubleValue = Double((e.rotation * 180 / .pi).rounded())
      }
      c.wire(turn) { [weak canvas] _ in
        let angle = CGFloat(turn.doubleValue) * .pi / 180
        canvas?.drawing.edit("Rotate") { scene in
          if var e = scene[single.id] {
            e.rotation = angle
            scene[single.id] = e
          }
        }
      }
      section("Rotation", row(turn, label("°")), fill: false)
    }
    section("Layers", buttons([
      ("square.3.layers.3d.top.filled", "Bring to Front", #selector(CanvasView.bringToFront(_:))),
      ("square.2.layers.3d.top.filled", "Bring Forward", #selector(CanvasView.bringForward(_:))),
      ("square.2.layers.3d.bottom.filled", "Send Backward", #selector(CanvasView.sendBackward(_:))),
      ("square.3.layers.3d.bottom.filled", "Send to Back", #selector(CanvasView.sendToBack(_:))),
    ]), fill: false)
    section("Align", buttons([
      ("align.horizontal.left", "Align Left", #selector(CanvasView.alignObjects(_:))),
      ("align.horizontal.center", "Align Center", #selector(CanvasView.alignObjects(_:))),
      ("align.horizontal.right", "Align Right", #selector(CanvasView.alignObjects(_:))),
      ("align.vertical.top", "Align Top", #selector(CanvasView.alignObjects(_:))),
      ("align.vertical.center", "Align Middle", #selector(CanvasView.alignObjects(_:))),
      ("align.vertical.bottom", "Align Bottom", #selector(CanvasView.alignObjects(_:))),
    ], tags: true), fill: false)
    if elements.count > 2 {
      section("Distribute", buttons([
        ("distribute.horizontal.center", "Distribute Horizontally", #selector(CanvasView.distributeHorizontally(_:))),
        ("distribute.vertical.center", "Distribute Vertically", #selector(CanvasView.distributeVertically(_:))),
      ]), fill: false)
    }
    section("Flip and Rotate", buttons([
      ("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontally", #selector(CanvasView.flipHorizontal(_:))),
      ("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertically", #selector(CanvasView.flipVertical(_:))),
      ("rotate.left", "Rotate Left", #selector(CanvasView.rotateLeft(_:))),
      ("rotate.right", "Rotate Right", #selector(CanvasView.rotateRight(_:))),
    ]), fill: false)
    var actions: [(String, String, Selector)] = [
      ("plus.square.on.square", "Duplicate (⌘D)", #selector(CanvasView.duplicate(_:))),
      ("trash", "Delete", #selector(CanvasView.delete(_:))),
      ("lock", "Lock (⌘L)", #selector(CanvasView.lock(_:))),
    ]
    if elements.contains(where: { !$0.groups.isEmpty }) {
      actions.append(("square.dashed", "Ungroup (⇧⌥⌘G)", #selector(CanvasView.ungroup(_:))))
    } else if elements.count > 1 {
      actions.append(("square.on.square.dashed", "Group (⌥⌘G)", #selector(CanvasView.group(_:))))
    }
    section("Actions", buttons(actions), fill: false)
    if kinds == [.image] { actionsRow(imageActions) }
  }

  private var imageActions: [(String, String, Selector)] {
    var actions = [("crop", "Crop Image", #selector(CanvasView.cropSelectedImage(_:)))]
    if #available(macOS 14.0, *) { actions.append(("wand.and.stars", "Remove Background", #selector(CanvasView.removeBackground(_:)))) }
    return actions
  }

  private func actionsRow(_ items: [(String, String, Selector)]) { section("Image", buttons(items), fill: false) }

  // MARK: Canvas

  /// With nothing selected: how selecting works, the frame, the background, the grid, and rulers.
  private func canvasSections() {
    guard let canvas else { return }
    let c = controls
    if canvas.tool == .select {
      section("Select", c.segmented(
        symbols: [("rectangle.dashed", "Box Selection"), ("lasso", "Free-Form Selection")],
        selected: { canvas.lassoSelects ? 1 : 0 }
      ) { [weak canvas] i in canvas?.lassoSelects = i == 1 })
    }
    if let frame = canvas.scene.frame {
      let w = numberField("Frame width"), h = numberField("Frame height")
      c.onRefresh { [weak canvas] in
        guard let frame = canvas?.scene.frame else { return }
        if w.currentEditor() == nil { w.doubleValue = Double(frame.width) }
        if h.currentEditor() == nil { h.doubleValue = Double(frame.height) }
      }
      for field in [w, h] {
        c.wire(field) { [weak canvas] _ in
          let size = CGSize(width: max(1, w.doubleValue), height: max(1, h.doubleValue))
          canvas?.drawing.edit("Frame Size") { $0.resizeFrame(to: size) }
        }
      }
      _ = frame
      let size = NSGridView(views: [[label("W"), w, label("H"), h]])
      size.columnSpacing = 6
      let fit = NSButton(title: "Fit to Drawing", target: canvas, action: #selector(CanvasView.fitCanvasToDrawing(_:)))
      let remove = NSButton(title: "Remove", target: canvas, action: #selector(CanvasView.removeFrame(_:)))
      for button in [fit, remove] { button.controlSize = .small }
      let column = NSStackView(views: [size, row(fit, remove)])
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = 8
      section("Frame", column, fill: false)
    } else {
      let add = NSButton(title: "Add Frame", target: canvas, action: #selector(CanvasView.addFrame(_:)))
      add.controlSize = .small
      section("Frame", add, fill: false)
    }
    section("Background", c.colorRow(Controls.fills, allowsNone: true, value: { [weak c] in c?.background }) {
      [weak c] color, live in c?.setBackground(color, live: live)
    })
    let options: [(String, String)] = [
      ("Show Grid", PreferenceKey.showsGrid), ("Snap to Grid", PreferenceKey.snapsToGrid),
      ("Snap to Guides", PreferenceKey.snapsToGuides), ("Show Rulers", PreferenceKey.showsRulers),
    ]
    let boxes: [NSView] = options.map { title, key in
      let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
      c.wire(box) { [weak self] _ in self?.editor?.flip(key) }
      c.onRefresh { [weak box] in box?.state = UserDefaults.standard.bool(forKey: key) ? .on : .off }
      return box
    }
    let column = NSStackView(views: boxes)
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 6
    section("Grid and Rulers", column, fill: false)
  }

  // MARK: Building

  private func title(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
    label.identifier = NSUserInterfaceItemIdentifier("heading")
    stack.addArrangedSubview(label)
    stack.setCustomSpacing(10, after: label)
  }

  private func note(_ text: String) {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    full(label)
  }

  private func full(_ view: NSView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.margin * 2).isActive = true
  }

  /// A section: a small heading as Plainst's sidebars have, and its control, full width unless
  /// it's a row of buttons.
  private func section(_ title: String, _ control: NSView, fill: Bool = true) {
    var views = [control]
    if !title.isEmpty {
      let label = NSTextField(labelWithString: title)
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
      label.textColor = .secondaryLabelColor
      label.identifier = NSUserInterfaceItemIdentifier("heading")
      views.insert(label, at: 0)
    }
    let section = NSStackView(views: views)
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 6
    full(section)
    if fill { control.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
  }

  private func grid(_ views: [NSView], columns: Int) -> NSView {
    var rows: [[NSView]] = stride(from: 0, to: views.count, by: columns).map { Array(views[$0..<min($0 + columns, views.count)]) }
    if let last = rows.indices.last, rows[last].count < columns {
      rows[last] += Array(repeating: NSGridCell.emptyContentView, count: columns - rows[last].count)
    }
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 4
    grid.columnSpacing = 4
    return grid
  }

  private func buttons(_ items: [(String, String, Selector)], tags: Bool = false) -> NSView {
    let row = NSStackView()
    row.spacing = 2
    for (i, item) in items.enumerated() {
      let button = BarButton(symbol: item.0, title: item.1, target: canvas, action: item.2)
      if tags { button.tag = i }
      row.addArrangedSubview(button)
    }
    return row
  }

  private func label(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    return label
  }

  private func valueLabel() -> NSTextField {
    let label = self.label("")
    label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 38).isActive = true
    return label
  }

  private func row(_ views: NSView...) -> NSStackView {
    let row = NSStackView(views: views)
    row.spacing = 8
    return row
  }

  /// A small field for a number of points or degrees, set on Return or leaving it.
  private func numberField(_ name: String) -> NSTextField {
    let field = NSTextField()
    field.controlSize = .small
    field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let number = NumberFormatter()
    number.numberStyle = .decimal
    number.maximumFractionDigits = 1
    field.formatter = number
    field.alignment = .right
    field.setAccessibilityLabel(name)
    field.widthAnchor.constraint(equalToConstant: 68).isActive = true
    return field
  }
}
