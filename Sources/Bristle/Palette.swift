import AppKit
import BristleCanvas
import BristleCore

/// A color swatch: a rounded square of the color, a slash for none, or a color wheel for any
/// other color.
final class SwatchButton: NSButton {
  enum Kind { case color(Color?), wheel }

  var kind: Kind { didSet { needsDisplay = true } }
  var isChosen = false { didSet { needsDisplay = true } }
  static let side: CGFloat = 19

  init(_ kind: Kind) {
    self.kind = kind
    super.init(frame: NSRect(x: 0, y: 0, width: Self.side + 5, height: Self.side + 5))
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    focusRingType = .default
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: Self.side + 5, height: Self.side + 5) }

  override func draw(_ dirtyRect: NSRect) {
    let square = NSRect(x: 2.5, y: 2.5, width: Self.side, height: Self.side)
    let shape = NSBezierPath(roundedRect: square, xRadius: 5, yRadius: 5)
    switch kind {
    case .color(let color?):
      (NSColor(cgColor: color.cgColor) ?? .black).setFill()
      shape.fill()
    case .color(nil):
      NSColor.controlBackgroundColor.setFill()
      shape.fill()
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: square.minX + 5, y: square.minY + 5))
      slash.line(to: NSPoint(x: square.maxX - 5, y: square.maxY - 5))
      slash.lineWidth = 1.5
      NSColor.systemRed.setStroke()
      slash.stroke()
    case .wheel:
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      let center = NSPoint(x: square.midX, y: square.midY)
      for i in 0..<36 {
        let slice = NSBezierPath()
        slice.move(to: center)
        slice.appendArc(withCenter: center, radius: Self.side, startAngle: CGFloat(i) * 10, endAngle: CGFloat(i + 1) * 10 + 0.5)
        slice.close()
        NSColor(hue: CGFloat(i) / 36, saturation: 0.75, brightness: 1, alpha: 1).setFill()
        slice.fill()
      }
      NSGraphicsContext.restoreGraphicsState()
    }
    NSColor.tertiaryLabelColor.setStroke()
    let edge = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
    edge.lineWidth = 1
    edge.stroke()
    if isChosen {
      NSColor.controlAccentColor.setStroke()
      let ring = NSBezierPath(roundedRect: square.insetBy(dx: -1.5, dy: -1.5), xRadius: 7.5, yRadius: 7.5)
      ring.lineWidth = 2
      ring.stroke()
    }
  }
}

/// Sends the system color panel's changes to whatever last opened it.
@MainActor
final class ColorPanelRelay: NSObject {
  static let shared = ColorPanelRelay()
  var apply: ((Color) -> Void)?

  /// Opens the system color panel for any color beyond the Palette's own.
  static func open(_ color: Color?, apply: @escaping (Color) -> Void) {
    let panel = NSColorPanel.shared
    shared.apply = apply
    panel.setTarget(shared)
    panel.setAction(#selector(changed(_:)))
    panel.showsAlpha = true
    if let color { panel.color = NSColor(cgColor: color.cgColor) ?? .black }
    panel.orderFront(nil)
  }

  @objc func changed(_ sender: NSColorPanel) {
    guard let color = Color(sender.color.cgColor) else { return }
    apply?(color)
  }
}

/// Sends a control's action to a closure.
final class ClosureTarget: NSObject {
  let body: @MainActor (Any?) -> Void

  init(_ body: @escaping @MainActor (Any?) -> Void) { self.body = body }

  @MainActor @objc func fire(_ sender: Any?) { body(sender) }
}

/// The Palette: a sidebar beside the canvas, like Plainst's symbols sidebar, with everything
/// about the current tool or the selection in plain view, as Excalidraw shows it — colors,
/// width, line style, text, opacity, layers, and actions — and the canvas when there's
/// nothing else to style.
@MainActor
final class Palette: NSViewController {
  static let strokes = ["#1D1D1F", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE"].compactMap(Color.init(hex:))
  static let fills = ["#FFFFFF", "#FFD8D6", "#FFE8CC", "#FFF4C2", "#D3F5DB", "#D1E7FF", "#EEDCF9"].compactMap(Color.init(hex:))
  static let fonts: [(name: String, title: String, font: String)] = [
    ("", "Sans", ""), ("Charter-Roman", "Serif", "Charter-Roman"), (Palette.roundedName, "Rounded", Palette.roundedName),
    ("Menlo-Regular", "Mono", "Menlo-Regular"), ("Noteworthy-Light", "Hand", "Noteworthy-Light"),
  ]
  static let roundedName: String = {
    let base = NSFont.systemFont(ofSize: 24)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return "" }
    return NSFont(descriptor: descriptor, size: 24)?.fontName ?? ""
  }()
  static let sizes: [(String, CGFloat)] = [("S", 16), ("M", 24), ("L", 36), ("XL", 56)]

  weak var canvas: CanvasView?
  weak var editor: Editor?
  private let stack = NSStackView()
  private let scroll = NSScrollView()
  private var builtFor = ""
  private var refreshers: [() -> Void] = []
  private var targets: [ClosureTarget] = []
  /// Space between the sidebar's edges and its controls, as in Plainst's sidebars.
  static let margin: CGFloat = 14

  override func loadView() {
    let root = NSView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 10, left: Self.margin, bottom: 20, right: Self.margin)
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
      if let field = view as? NSTextField, !field.isEditable, !field.isSelectable || true, field.font?.pointSize ?? 0 <= NSFont.systemFontSize + 1,
        field.font?.fontDescriptor.symbolicTraits.contains(.bold) == true || (field.font?.fontName.contains("Semibold") ?? false)
      {
        return [field.stringValue]
      }
      return view.subviews.flatMap(labels)
    }
    return labels(stack)
  }

  /// The width of the controls, the sidebar less its margins.
  private var contentWidth: NSLayoutDimension { stack.widthAnchor }

  // MARK: What's shown

  private var elements: [Element] { canvas?.drawing.selectedElements.filter { !$0.locked } ?? [] }

  private var kinds: Set<Element.Kind> {
    guard let canvas else { return [] }
    if !elements.isEmpty { return Set(elements.map(\.kind)) }
    switch canvas.tool {
    case .pencil, .pen, .highlighter: return [.freehand]
    case .line: return [.line]
    case .arrow: return [.arrow]
    case .rectangle: return [.rectangle]
    case .ellipse: return [.ellipse]
    case .polygon: return [.polygon]
    case .text: return [.text]
    default: return []
    }
  }

  private var style: Style {
    guard let canvas else { return Style() }
    return elements.first.map(Style.init) ?? canvas.style
  }

  func update() {
    guard isViewLoaded, let canvas else { return }
    let key = "\(canvas.tool)|\(kinds.map(\.rawValue).sorted())|\(elements.count)|\(elements.contains { !$0.groups.isEmpty })|\(elements.first?.brush.rawValue ?? "")|\(canvas.drawing.selectedElements.contains(where: \.locked))"
    if key != builtFor {
      builtFor = key
      rebuild()
    }
    refreshers.forEach { $0() }
  }

  private func rebuild() {
    guard let canvas else { return }
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    refreshers = []
    targets = []
    let kinds = self.kinds
    title(heading)
    if canvas.drawing.selectedElements.contains(where: \.locked) && elements.isEmpty {
      note("Locked objects can’t be changed. Choose Arrange ▸ Unlock All to change them.")
      return
    }
    if kinds.isEmpty && ![Tool.eraser, .strokeEraser, .fill].contains(canvas.tool) {
      canvasSection()
      return
    }
    let selecting = !elements.isEmpty
    let tool = canvas.tool
    let shapes = !kinds.isDisjoint(with: [.rectangle, .ellipse, .polygon])
    let lines = !kinds.isDisjoint(with: [.line, .arrow])
    let freehand = kinds.contains(.freehand)

    if !selecting && [.pencil, .pen, .highlighter].contains(tool) {
      add("Brush", segmented(
        symbols: [Tool.pencil, .pen, .highlighter].map { ($0.symbol, $0.title) },
        selected: { [Tool.pencil, .pen, .highlighter].firstIndex(of: canvas.tool) }
      ) { [weak canvas] i in canvas?.tool = [Tool.pencil, .pen, .highlighter][i] })
    }
    if selecting && kinds == [.freehand] {
      let brushes = Element.Brush.allCases
      add("Brush", segmented(
        symbols: [("pencil", "Pencil"), ("paintbrush.pointed", "Brush"), ("highlighter", "Highlighter")],
        selected: { [weak self] in self?.elements.first.map { brushes.firstIndex(of: $0.brush) ?? 0 } }
      ) { [weak self] i in self?.setBrush(brushes[i]) })
    }
    if tool == .eraser || tool == .strokeEraser, !selecting {
      add("Erase", segmented(labels: ["Objects", "Parts"], selected: { canvas.tool == .strokeEraser ? 1 : 0 }) {
        [weak canvas] i in canvas?.tool = i == 0 ? .eraser : .strokeEraser
      })
      add("Size", widthControl(for: .eraser))
    }
    if tool == .fill && !selecting {
      add("Fill with", colorRow(Self.strokes + Self.fills.dropFirst(), allowsNone: false, value: { [weak canvas] in
        canvas?.styles[.fill]?.stroke
      }) { [weak canvas] color in
        guard let canvas, let color else { return }
        canvas.styles[.fill, default: Tool.fill.defaultStyle].stroke = color
        canvas.delegate?.canvasViewStylesDidChange(canvas)
      })
    }
    if !kinds.isEmpty && kinds != [.image] {
      add(kinds == [.text] ? "Text color" : "Stroke", colorRow(Self.strokes, allowsNone: shapes && !freehand && !lines, value: { [weak self] in
        self?.style.stroke
      }) { [weak canvas] color in canvas?.setStyle("Change Color") { $0.stroke = color } })
    }
    if shapes || kinds == [.text] {
      add(kinds == [.text] ? "Background" : "Fill", colorRow(Self.fills, allowsNone: true, value: { [weak self] in
        self?.style.fill
      }) { [weak canvas] color in canvas?.setStyle("Change Fill") { $0.fill = color } })
    }
    if shapes || lines || freehand {
      add("Width", widthControl(for: freehand ? (selecting ? brushTool : tool) : .line))
    }
    if shapes || lines {
      add("Style", segmented(
        images: Element.Dash.allCases.map { (dashImage($0), $0.rawValue.capitalized) },
        selected: { [weak self] in self.flatMap { Element.Dash.allCases.firstIndex(of: $0.style.dash) } }
      ) { [weak canvas] i in canvas?.setStyle("Change Line") { $0.dash = Element.Dash.allCases[i] } })
    }
    if kinds == [.rectangle] {
      add("Corners", segmented(images: [(cornerImage(false), "Sharp"), (cornerImage(true), "Round")], selected: { [weak self] in
        (self?.style.cornerRadius ?? 0) > 0 ? 1 : 0
      }) { [weak canvas] i in canvas?.setStyle(i == 0 ? "Sharp Corners" : "Round Corners") { $0.cornerRadius = i == 0 ? 0 : 16 } })
    }
    if lines || kinds == [.polygon] {
      add("Line", segmented(images: [(curveImage(false), "Straight"), (curveImage(true), "Curved")], selected: { [weak self] in
        self?.style.curved == true ? 1 : 0
      }) { [weak canvas] i in canvas?.setStyle(i == 0 ? "Straighten" : "Curve") { $0.curved = i == 1 } })
    }
    if lines {
      let heads = Element.Arrowhead.allCases
      let start = arrowPopUp(heads, start: true)
      let end = arrowPopUp(heads, start: false)
      let row = NSStackView(views: [start, end])
      row.spacing = 6
      row.distribution = .fillEqually
      add("Arrowheads", row)
    }
    if kinds.contains(.text) {
      add("Font", segmented(images: Self.fonts.map { (fontImage($0.font), $0.title) }, selected: { [weak self] in
        guard let name = self?.style.fontName else { return nil }
        return Self.fonts.firstIndex { $0.name == name }
      }) { [weak canvas] i in canvas?.setStyle("Change Font") { $0.fontName = Self.fonts[i].name } })
      add("Size", segmented(labels: Self.sizes.map(\.0), selected: { [weak self] in
        guard let size = self?.style.fontSize else { return nil }
        return Self.sizes.firstIndex { abs($0.1 - size) < 0.01 }
      }) { [weak canvas] i in canvas?.setStyle("Change Font Size") { $0.fontSize = Self.sizes[i].1 } })
      add("Align", segmented(
        symbols: [("text.alignleft", "Align Left"), ("text.aligncenter", "Center"), ("text.alignright", "Align Right")],
        selected: { [weak self] in self.flatMap { Element.TextAlign.allCases.firstIndex(of: $0.style.textAlign) } }
      ) { [weak canvas] i in canvas?.setStyle("Align Text") { $0.textAlign = Element.TextAlign.allCases[i] } })
    }
    if !kinds.isEmpty {
      let slider = NSSlider(value: 100, minValue: 5, maxValue: 100, target: nil, action: nil)
      slider.isContinuous = true
      slider.controlSize = .small
      slider.setAccessibilityLabel("Opacity")
      let target = ClosureTarget { [weak canvas, weak slider] _ in
        guard let slider else { return }
        let value = CGFloat(slider.doubleValue.rounded()) / 100
        canvas?.setStyle("Change Opacity", coalescing: true) { $0.opacity = value }
      }
      targets.append(target)
      slider.target = target
      slider.action = #selector(ClosureTarget.fire(_:))
      refreshers.append { [weak self, weak slider] in slider?.doubleValue = Double((self?.style.opacity ?? 1) * 100) }
      add("Opacity", slider)
    }
    if selecting {
      divider()
      add("Layers", fill: false, buttons([
        ("square.3.layers.3d.bottom.filled", "Send to Back", #selector(CanvasView.sendToBack(_:))),
        ("square.2.layers.3d.bottom.filled", "Send Backward", #selector(CanvasView.sendBackward(_:))),
        ("square.2.layers.3d.top.filled", "Bring Forward", #selector(CanvasView.bringForward(_:))),
        ("square.3.layers.3d.top.filled", "Bring to Front", #selector(CanvasView.bringToFront(_:))),
      ]))
      if elements.count > 1 {
        add("Align", fill: false, buttons([
          ("align.horizontal.left", "Align Left", #selector(CanvasView.alignObjects(_:))),
          ("align.horizontal.center", "Align Center", #selector(CanvasView.alignObjects(_:))),
          ("align.horizontal.right", "Align Right", #selector(CanvasView.alignObjects(_:))),
          ("align.vertical.top", "Align Top", #selector(CanvasView.alignObjects(_:))),
          ("align.vertical.center", "Align Middle", #selector(CanvasView.alignObjects(_:))),
          ("align.vertical.bottom", "Align Bottom", #selector(CanvasView.alignObjects(_:))),
        ], tags: true))
      }
      var actions: [(String, String, Selector)] = [
        ("plus.square.on.square", "Duplicate (⌘D)", #selector(CanvasView.duplicate(_:))),
        ("trash", "Delete", #selector(CanvasView.delete(_:))),
      ]
      if elements.contains(where: { !$0.groups.isEmpty }) {
        actions.append(("square.dashed", "Ungroup (⇧⌥⌘G)", #selector(CanvasView.ungroup(_:))))
      } else if elements.count > 1 {
        actions.append(("square.on.square.dashed", "Group (⌥⌘G)", #selector(CanvasView.group(_:))))
      }
      actions.append(("lock", "Lock (⌘L)", #selector(CanvasView.lock(_:))))
      if kinds == [.image] { actions.append(("crop", "Crop", #selector(CanvasView.cropSelectedImage(_:)))) }
      add("Actions", fill: false, buttons(actions))
    }
  }

  // MARK: Building

  /// What the sidebar is showing, as its heading.
  private var heading: String {
    guard let canvas else { return "" }
    let selected = elements
    if selected.count == 1 { return selected[0].kindName }
    if selected.count > 1 {
      let names = Set(selected.map(\.kindName))
      return names.count == 1 ? "\(selected.count) \(names.first!)s".replacingOccurrences(of: "Texts", with: "Text Boxes") : "\(selected.count) Objects"
    }
    if canvas.tool == .select || canvas.tool == .eyedropper { return "Canvas" }
    return canvas.tool.title
  }

  private func title(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
    stack.addArrangedSubview(label)
    stack.setCustomSpacing(12, after: label)
  }

  private func note(_ text: String) {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    stack.addArrangedSubview(label)
    label.widthAnchor.constraint(equalTo: contentWidth, constant: -Self.margin * 2).isActive = true
  }

  /// A section: a small heading as Plainst's sidebars have, and its control at full width.
  private func add(_ title: String, _ control: NSView, fill: Bool = true) {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.textColor = .secondaryLabelColor
    let section = NSStackView(views: [label, control])
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 6
    stack.addArrangedSubview(section)
    section.widthAnchor.constraint(equalTo: contentWidth, constant: -Self.margin * 2).isActive = true
    if fill { control.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
  }

  private func add(_ title: String, fill: Bool, _ control: NSView) { add(title, control, fill: fill) }

  private func divider() {
    let line = NSBox()
    line.boxType = .separator
    stack.addArrangedSubview(line)
    line.widthAnchor.constraint(equalTo: contentWidth, constant: -Self.margin * 2).isActive = true
  }

  /// When nothing is selected: the canvas's size and background.
  private func canvasSection() {
    guard let canvas else { return }
    let size = NSTextField(labelWithString: "")
    size.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    refreshers.append { [weak canvas] in
      guard let paper = canvas?.scene.paper else { return }
      size.stringValue = "\(Int(paper.width)) × \(Int(paper.height)) points"
    }
    let change = NSButton(title: "Canvas Size…", target: editor, action: #selector(Editor.showCanvasSize(_:)))
    let fit = NSButton(title: "Fit to Drawing", target: canvas, action: #selector(CanvasView.fitCanvasToDrawing(_:)))
    for button in [change, fit] { button.controlSize = .small }
    let buttons = NSStackView(views: [change, fit])
    buttons.spacing = 6
    let column = NSStackView(views: [size, buttons])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    add("Size", column, fill: false)
    add("Background", colorRow(Self.fills, allowsNone: true, value: { [weak canvas] in canvas?.scene.paper.background }) {
      [weak canvas] color in canvas?.drawing.edit(color == nil ? "Clear Background" : "Background") { $0.paper.background = color }
    })
    divider()
    note("Choose a tool in the toolbar to draw, or select something to change how it looks. Objects past the canvas’s edges are kept, but left out of exports.")
  }

  private func colorRow(
    _ colors: [Color], allowsNone: Bool, value: @escaping @MainActor () -> Color??,
    apply: @escaping @MainActor (Color?) -> Void
  ) -> NSView {
    var swatches: [SwatchButton] = []
    let row = NSStackView()
    row.distribution = .equalSpacing
    let choices: [Color?] = (allowsNone ? [nil] : []) + colors.prefix(allowsNone ? 6 : 7).map { $0 }
    for color in choices {
      let swatch = SwatchButton(.color(color))
      let target = ClosureTarget { _ in apply(color) }
      targets.append(target)
      swatch.target = target
      swatch.action = #selector(ClosureTarget.fire(_:))
      swatch.toolTip = color.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? "None"
      swatch.setAccessibilityLabel(swatch.toolTip)
      swatches.append(swatch)
      row.addArrangedSubview(swatch)
    }
    // Any other color, from the system color panel; the swatch shows it once chosen.
    let custom = SwatchButton(.wheel)
    let customTarget = ClosureTarget { _ in
      let current = value() ?? nil
      ColorPanelRelay.open(current) { apply($0) }
    }
    targets.append(customTarget)
    custom.target = customTarget
    custom.action = #selector(ClosureTarget.fire(_:))
    custom.toolTip = "Other Colors…"
    custom.setAccessibilityLabel("Other colors")
    row.addArrangedSubview(custom)
    refreshers.append {
      let current = value() ?? nil
      var matched = false
      for (swatch, color) in zip(swatches, choices) {
        swatch.isChosen = color == current
        matched = matched || color == current
      }
      custom.kind = matched || current == nil ? .wheel : .color(current)
      custom.isChosen = !matched && current != nil
    }
    return row
  }

  /// Three widths, as Excalidraw offers, suited to the tool.
  private func widthControl(for tool: Tool) -> NSView {
    let widths = Self.widths(for: tool)
    let images = widths.enumerated().map { i, _ in (lineImage(CGFloat(i) * 2.5 + 1.5), "\(["Thin", "Medium", "Bold"][i])") }
    let isEraser = tool == .eraser || tool == .strokeEraser
    return segmented(images: images, selected: { [weak self, weak canvas] in
      guard let canvas else { return nil }
      let width = isEraser ? (canvas.styles[.eraser]?.strokeWidth ?? 16) : (self?.style.strokeWidth ?? 3)
      return widths.firstIndex { abs($0 - width) < 0.01 }
    }) { [weak canvas] i in
      guard let canvas else { return }
      if isEraser {
        canvas.styles[.eraser, default: Tool.eraser.defaultStyle].strokeWidth = widths[i]
        canvas.styles[.strokeEraser, default: Tool.strokeEraser.defaultStyle].strokeWidth = widths[i]
        canvas.delegate?.canvasViewStylesDidChange(canvas)
        canvas.window?.invalidateCursorRects(for: canvas)
      } else {
        canvas.setStyle("Change Width") { $0.strokeWidth = widths[i] }
      }
    }
  }

  static func widths(for tool: Tool) -> [CGFloat] {
    switch tool {
    case .pencil: [1.5, 3, 6]
    case .pen: [4, 8, 16]
    case .highlighter: [14, 24, 40]
    case .eraser, .strokeEraser: [10, 24, 48]
    default: [2, 4, 8]
    }
  }

  private var brushTool: Tool {
    switch elements.first?.brush {
    case .pencil: .pencil
    case .highlighter: .highlighter
    default: .pen
    }
  }

  private func setBrush(_ brush: Element.Brush) {
    guard let canvas else { return }
    let ids = Set(elements.filter { $0.kind == .freehand }.map(\.id))
    canvas.drawing.edit("Change Brush") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) { scene.elements[i].brush = brush }
    }
  }

  private func segmented(
    symbols: [(String, String)], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    segmented(images: symbols.map { (NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) ?? NSImage(), $0.1) },
      selected: selected, choose: choose)
  }

  private func segmented(
    images: [(NSImage, String)], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    let control = NSSegmentedControl(images: images.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
    for (i, item) in images.enumerated() { control.setToolTip(item.1, forSegment: i) }
    control.segmentDistribution = .fillEqually
    wire(control, selected: selected, choose: choose)
    return control
  }

  private func segmented(
    labels: [String], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
    control.segmentDistribution = .fillEqually
    wire(control, selected: selected, choose: choose)
    return control
  }

  private func wire(_ control: NSSegmentedControl, selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void) {
    let target = ClosureTarget { sender in
      guard let control = sender as? NSSegmentedControl, control.selectedSegment >= 0 else { return }
      choose(control.selectedSegment)
    }
    targets.append(target)
    control.target = target
    control.action = #selector(ClosureTarget.fire(_:))
    refreshers.append { [weak control] in control?.selectedSegment = selected() ?? -1 }
  }

  private func buttons(_ items: [(String, String, Selector)], tags: Bool = false) -> NSView {
    let row = NSStackView()
    row.spacing = 2
    for (i, item) in items.enumerated() {
      let button = barButton(item.0, item.1, target: canvas, action: item.2)
      if tags { button.tag = i }
      row.addArrangedSubview(button)
    }
    return row
  }

  private func arrowPopUp(_ heads: [Element.Arrowhead], start: Bool) -> NSPopUpButton {
    let popup = NSPopUpButton()
    popup.controlSize = .small
    for head in heads {
      popup.addItem(withTitle: head == .none ? "None" : head.rawValue.capitalized)
      popup.lastItem?.image = arrowImage(head, start: start)
    }
    // The button shows the arrowhead; its menu names them.
    (popup.cell as? NSPopUpButtonCell)?.imagePosition = .imageOnly
    popup.setAccessibilityLabel(start ? "Start arrowhead" : "End arrowhead")
    popup.toolTip = start ? "Start" : "End"
    let target = ClosureTarget { [weak canvas] sender in
      guard let popup = sender as? NSPopUpButton else { return }
      let head = heads[max(0, popup.indexOfSelectedItem)]
      canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
    }
    targets.append(target)
    popup.target = target
    popup.action = #selector(ClosureTarget.fire(_:))
    refreshers.append { [weak self, weak popup] in
      guard let self else { return }
      popup?.selectItem(at: heads.firstIndex(of: start ? self.style.startArrowhead : self.style.endArrowhead) ?? 0)
    }
    return popup
  }

  // MARK: Pictures for the controls

  private func picture(_ draw: @escaping (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { rect in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      draw(rect)
      return true
    }
    image.isTemplate = true
    return image
  }

  private func lineImage(_ width: CGFloat) -> NSImage {
    picture { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 4, y: rect.midY))
      path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
      path.lineWidth = width
      path.lineCapStyle = .round
      path.stroke()
    }
  }

  private func dashImage(_ dash: Element.Dash) -> NSImage {
    picture { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 4, y: rect.midY))
      path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
      path.lineWidth = 2
      path.lineCapStyle = dash == .dotted ? .round : .butt
      switch dash {
      case .solid: break
      case .dashed: path.setLineDash([5, 3], count: 2, phase: 0)
      case .dotted: path.setLineDash([0.01, 4], count: 2, phase: 0)
      }
      path.stroke()
    }
  }

  private func cornerImage(_ round: Bool) -> NSImage {
    picture { rect in
      let box = NSRect(x: 6, y: 2, width: rect.width - 12, height: rect.height - 4)
      let path = round ? NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4) : NSBezierPath(rect: box)
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  private func curveImage(_ curved: Bool) -> NSImage {
    picture { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 4, y: 3))
      if curved {
        path.curve(to: NSPoint(x: rect.maxX - 4, y: rect.maxY - 3), controlPoint1: NSPoint(x: 14, y: 3), controlPoint2: NSPoint(x: 12, y: rect.maxY - 3))
      } else {
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 3))
        path.line(to: NSPoint(x: rect.maxX - 4, y: 3))
      }
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  private func fontImage(_ name: String) -> NSImage {
    let font = NSFont(name: name, size: 13) ?? .systemFont(ofSize: 13)
    let image = NSImage(size: NSSize(width: 26, height: 16), flipped: false) { rect in
      let string = NSAttributedString(string: "Aa", attributes: [.font: font, .foregroundColor: NSColor.black])
      let size = string.size()
      string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
      return true
    }
    image.isTemplate = true
    return image
  }

  private func arrowImage(_ head: Element.Arrowhead, start: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 24, height: 12), flipped: false) { rect in
      var line = Element(kind: .line)
      line.setWorldPoints(start ? [CGPoint(x: 5, y: 6), CGPoint(x: 22, y: 6)] : [CGPoint(x: 2, y: 6), CGPoint(x: 19, y: 6)])
      line.strokeWidth = 1.5
      line.stroke = .black
      if start { line.startArrowhead = head } else { line.endArrowhead = head }
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      Renderer.draw(line, in: context, scene: Scene(), images: ImageStore())
      return true
    }
    image.isTemplate = true
    return image
  }
}
