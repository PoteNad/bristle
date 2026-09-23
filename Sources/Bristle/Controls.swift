import AppKit
import BristleCanvas
import BristleCore

/// A color swatch: a rounded square of the color, a slash for none, or a color wheel for any
/// other color.
final class SwatchButton: NSButton {
  enum Kind { case color(Color?), wheel }

  var kind: Kind { didSet { needsDisplay = true } }
  var isChosen = false { didSet { needsDisplay = true } }
  /// How a color shows on the canvas, so swatches match a dark canvas's colors.
  var display: ((Color) -> Color)? { didSet { needsDisplay = true } }
  let side: CGFloat

  init(_ kind: Kind, side: CGFloat = 19) {
    self.kind = kind
    self.side = side
    super.init(frame: NSRect(x: 0, y: 0, width: side + 5, height: side + 5))
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    focusRingType = .default
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: side + 5, height: side + 5) }

  override func draw(_ dirtyRect: NSRect) {
    let square = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    let radius = side * 0.26
    let shape = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)
    switch kind {
    case .color(let color?):
      (NSColor(cgColor: (display?(color) ?? color).cgColor) ?? .black).setFill()
      shape.fill()
    case .color(nil):
      NSColor.controlBackgroundColor.setFill()
      shape.fill()
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: square.minX + side * 0.25, y: square.minY + side * 0.25))
      slash.line(to: NSPoint(x: square.maxX - side * 0.25, y: square.maxY - side * 0.25))
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
        slice.appendArc(withCenter: center, radius: side, startAngle: CGFloat(i) * 10, endAngle: CGFloat(i + 1) * 10 + 0.5)
        slice.close()
        NSColor(hue: CGFloat(i) / 36, saturation: 0.75, brightness: 1, alpha: 1).setFill()
        slice.fill()
      }
      NSGraphicsContext.restoreGraphicsState()
    }
    NSColor.tertiaryLabelColor.setStroke()
    let edge = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
    edge.lineWidth = 1
    edge.stroke()
    if isChosen {
      NSColor.controlAccentColor.setStroke()
      let ring = NSBezierPath(roundedRect: square.insetBy(dx: -1.5, dy: -1.5), xRadius: radius + 2.5, yRadius: radius + 2.5)
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

/// The controls for styling what's drawn next or what's selected, shared by the bar at the
/// bottom of the window and the Palette sidebar. It keeps the controls' targets alive and puts
/// each control right when the drawing changes.
@MainActor
final class Controls {
  static let strokes = ["#1D1D1F", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE"].compactMap(Color.init(hex:))
  static let fills = ["#FFFFFF", "#FFD8D6", "#FFE8CC", "#FFF4C2", "#D3F5DB", "#D1E7FF", "#EEDCF9"].compactMap(Color.init(hex:))
  static let fonts: [(name: String, title: String)] = [
    ("", "Sans"), ("Charter-Roman", "Serif"), (Controls.roundedName, "Rounded"), ("Menlo-Regular", "Mono"),
    ("Noteworthy-Light", "Hand"),
  ]
  static let roundedName: String = {
    let base = NSFont.systemFont(ofSize: 24)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return "" }
    return NSFont(descriptor: descriptor, size: 24)?.fontName ?? ""
  }()
  static let sizes: [(String, CGFloat)] = [("S", 16), ("M", 24), ("L", 36), ("XL", 56)]
  static let brushes: [Tool] = [.pencil, .pen, .highlighter]

  weak var canvas: CanvasView?
  private var targets: [ClosureTarget] = []
  private(set) var refreshers: [() -> Void] = []

  func reset() {
    targets = []
    refreshers = []
  }

  func refresh() { refreshers.forEach { $0() } }

  func onRefresh(_ body: @escaping () -> Void) { refreshers.append(body) }

  /// Sends a control's action to `body`.
  func wire(_ control: NSControl, _ body: @escaping @MainActor (Any?) -> Void) {
    let target = ClosureTarget(body)
    targets.append(target)
    control.target = target
    control.action = #selector(ClosureTarget.fire(_:))
  }

  // MARK: What's being styled

  /// The selected objects that can be changed.
  var elements: [Element] { canvas?.drawing.selectedElements.filter { !$0.locked } ?? [] }

  var selecting: Bool { !elements.isEmpty }

  /// What kinds of object are styled: the selection's, or what the tool draws.
  var kinds: Set<Element.Kind> {
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

  var hasShapes: Bool { !kinds.isDisjoint(with: [.rectangle, .ellipse, .polygon]) }
  var hasLines: Bool { !kinds.isDisjoint(with: [.line, .arrow]) }

  var style: Style {
    guard let canvas else { return Style() }
    return elements.first.map(Style.init) ?? canvas.style
  }

  /// What changes and what's shown: the tool, the kinds of object, and how many there are.
  var key: String {
    guard let canvas else { return "" }
    let elements = self.elements
    return "\(canvas.tool)|\(kinds.map(\.rawValue).sorted())|\(elements.count)|\(elements.contains { !$0.groups.isEmpty })|\(elements.first?.brush.rawValue ?? "")|\(canvas.drawing.selectedElements.contains(where: \.locked))|\(canvas.frameSelected)"
  }

  /// The brush of the selected strokes, as the tool that draws them.
  var brushTool: Tool {
    switch elements.first?.brush {
    case .pencil: .pencil
    case .highlighter: .highlighter
    default: .pen
    }
  }

  /// The tool whose widths the width controls offer.
  var widthTool: Tool {
    guard let canvas else { return .line }
    if canvas.tool == .eraser || canvas.tool == .strokeEraser { return .eraser }
    if kinds.contains(.freehand) { return selecting ? brushTool : canvas.tool }
    return .line
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

  static let widthNames = ["Thin", "Medium", "Bold"]

  var widthIndex: Int? {
    guard let canvas else { return nil }
    let tool = widthTool
    let width = tool == .eraser ? (canvas.styles[.eraser]?.strokeWidth ?? 16) : style.strokeWidth
    return Self.widths(for: tool).firstIndex { abs($0 - width) < 0.01 }
  }

  func setWidth(_ i: Int) {
    guard let canvas else { return }
    let tool = widthTool
    let widths = Self.widths(for: tool)
    guard widths.indices.contains(i) else { return }
    if tool == .eraser {
      canvas.styles[.eraser, default: Tool.eraser.defaultStyle].strokeWidth = widths[i]
      canvas.styles[.strokeEraser, default: Tool.strokeEraser.defaultStyle].strokeWidth = widths[i]
      canvas.delegate?.canvasViewStylesDidChange(canvas)
      canvas.window?.invalidateCursorRects(for: canvas)
    } else {
      canvas.setStyle("Change Width") { $0.strokeWidth = widths[i] }
    }
  }

  func setBrush(_ brush: Element.Brush) {
    guard let canvas else { return }
    let ids = Set(elements.filter { $0.kind == .freehand }.map(\.id))
    canvas.drawing.edit("Change Brush") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) { scene.elements[i].brush = brush }
    }
  }

  var fillColor: Color? { canvas?.styles[.fill]?.stroke }

  /// Shows colors as the canvas does, turned around on a dark canvas.
  var display: (Color) -> Color { { [weak canvas] color in canvas?.shown(color) ?? color } }

  func setFillColor(_ color: Color?) {
    guard let canvas, let color else { return }
    canvas.styles[.fill, default: Tool.fill.defaultStyle].stroke = color
    canvas.delegate?.canvasViewStylesDidChange(canvas)
  }

  // MARK: Controls

  /// A row of swatches, a none swatch first when allowed, and a wheel for any other color.
  func colorRow(
    _ colors: [Color], allowsNone: Bool, side: CGFloat = 19, value: @escaping @MainActor () -> Color??,
    apply: @escaping @MainActor (Color?) -> Void
  ) -> NSStackView {
    let choices: [Color?] = (allowsNone ? [nil] : []) + colors.prefix(allowsNone ? 6 : 7).map { $0 }
    let row = NSStackView()
    row.distribution = .equalSpacing
    swatches(choices, side: side, value: value, apply: apply).forEach(row.addArrangedSubview)
    return row
  }

  /// Every color in two rows, as the bar's color popover shows them.
  func colorGrid(allowsNone: Bool, value: @escaping @MainActor () -> Color??, apply: @escaping @MainActor (Color?) -> Void) -> NSView {
    let top: [Color?] = Self.strokes.map { $0 } + (allowsNone ? [nil] : [])
    let bottom: [Color?] = Self.fills.map { $0 }
    let all = swatches(top + bottom, side: 22, value: value, apply: apply, wheel: true)
    var rows = [Array(all.prefix(top.count)), Array(all.dropFirst(top.count))]
    let columns = max(rows[0].count, rows[1].count)
    for i in rows.indices where rows[i].count < columns { rows[i] += Array(repeating: NSGridCell.emptyContentView, count: columns - rows[i].count) }
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 4
    grid.columnSpacing = 4
    return grid
  }

  private func swatches(
    _ choices: [Color?], side: CGFloat, value: @escaping @MainActor () -> Color??,
    apply: @escaping @MainActor (Color?) -> Void, wheel: Bool = true
  ) -> [NSView] {
    var swatches: [SwatchButton] = []
    for color in choices {
      let swatch = SwatchButton(.color(color), side: side)
      swatch.display = display
      wire(swatch) { _ in apply(color) }
      swatch.toolTip = color.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? "None"
      swatch.setAccessibilityLabel(swatch.toolTip)
      swatches.append(swatch)
    }
    // Any other color, from the system color panel; the swatch shows it once chosen.
    let custom = SwatchButton(.wheel, side: side)
    custom.display = display
    wire(custom) { _ in
      let current = value() ?? nil
      ColorPanelRelay.open(current) { apply($0) }
    }
    custom.toolTip = "Other Colors…"
    custom.setAccessibilityLabel("Other colors")
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
    return swatches + [custom]
  }

  func opacitySlider() -> NSSlider {
    let slider = NSSlider(value: 100, minValue: 5, maxValue: 100, target: nil, action: nil)
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel("Opacity")
    wire(slider) { [weak canvas, weak slider] _ in
      guard let slider else { return }
      let value = CGFloat(slider.doubleValue.rounded()) / 100
      canvas?.setStyle("Change Opacity", coalescing: true) { $0.opacity = value }
    }
    refreshers.append { [weak self, weak slider] in slider?.doubleValue = Double((self?.style.opacity ?? 1) * 100) }
    return slider
  }

  func segmented(
    symbols: [(String, String)], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    segmented(
      images: symbols.map { (NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1) ?? NSImage(), $0.1) },
      selected: selected, choose: choose)
  }

  func segmented(
    images: [(NSImage, String)], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    let control = NSSegmentedControl(images: images.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
    for (i, item) in images.enumerated() { control.setToolTip(item.1, forSegment: i) }
    control.segmentDistribution = .fillEqually
    wire(control, selected: selected, choose: choose)
    return control
  }

  func segmented(
    labels: [String], selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void
  ) -> NSSegmentedControl {
    let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
    control.segmentDistribution = .fillEqually
    wire(control, selected: selected, choose: choose)
    return control
  }

  private func wire(_ control: NSSegmentedControl, selected: @escaping @MainActor () -> Int?, choose: @escaping @MainActor (Int) -> Void) {
    wire(control) { sender in
      guard let control = sender as? NSSegmentedControl, control.selectedSegment >= 0 else { return }
      choose(control.selectedSegment)
    }
    refreshers.append { [weak control] in control?.selectedSegment = selected() ?? -1 }
  }

  /// The segmented controls for the styles that don't fit in the bar: dash, corners, and curves.
  func lineStyleControls() -> [(String, NSView)] {
    var rows: [(String, NSView)] = []
    let kinds = self.kinds
    if hasShapes || hasLines {
      rows.append(("Style", segmented(
        images: Element.Dash.allCases.map { (Self.dashImage($0), $0.rawValue.capitalized) },
        selected: { [weak self] in self.flatMap { Element.Dash.allCases.firstIndex(of: $0.style.dash) } }
      ) { [weak canvas] i in canvas?.setStyle("Change Line") { $0.dash = Element.Dash.allCases[i] } }))
    }
    if kinds == [.rectangle] {
      rows.append(("Corners", segmented(images: [(Self.cornerImage(false), "Sharp"), (Self.cornerImage(true), "Round")], selected: {
        [weak self] in (self?.style.cornerRadius ?? 0) > 0 ? 1 : 0
      }) { [weak canvas] i in canvas?.setStyle(i == 0 ? "Sharp Corners" : "Round Corners") { $0.cornerRadius = i == 0 ? 0 : 16 } }))
    }
    if hasLines || kinds == [.polygon] {
      rows.append(("Line", segmented(images: [(Self.curveImage(false), "Straight"), (Self.curveImage(true), "Curved")], selected: {
        [weak self] in self?.style.curved == true ? 1 : 0
      }) { [weak canvas] i in canvas?.setStyle(i == 0 ? "Straighten" : "Curve") { $0.curved = i == 1 } }))
    }
    return rows
  }

  // MARK: Pictures for the controls

  static func picture(width: CGFloat = 26, height: CGFloat = 16, _ draw: @escaping (NSRect) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      draw(rect)
      return true
    }
    image.isTemplate = true
    return image
  }

  static func lineImage(_ width: CGFloat) -> NSImage {
    picture { rect in
      let path = NSBezierPath()
      path.move(to: NSPoint(x: 4, y: rect.midY))
      path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
      path.lineWidth = width
      path.lineCapStyle = .round
      path.stroke()
    }
  }

  /// A dot as wide as a stroke width, for the bar's width buttons, as Excalidraw shows them.
  static func widthImage(_ index: Int, of count: Int = 3) -> NSImage {
    let diameter = [3.5, 7, 11.5][min(index, 2)]
    return picture(width: 18, height: 18) { rect in
      NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)).fill()
    }
  }

  static func dashImage(_ dash: Element.Dash) -> NSImage {
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

  static func cornerImage(_ round: Bool) -> NSImage {
    picture { rect in
      let box = NSRect(x: 6, y: 2, width: rect.width - 12, height: rect.height - 4)
      let path = round ? NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4) : NSBezierPath(rect: box)
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  static func curveImage(_ curved: Bool) -> NSImage {
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

  static func fontImage(_ name: String) -> NSImage {
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

  static func arrowImage(_ head: Element.Arrowhead, start: Bool) -> NSImage {
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
