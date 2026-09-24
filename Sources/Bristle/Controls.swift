import AppKit
import BristleCanvas
import BristleCore

/// A color swatch: a rounded square of the color, a slash for none, or a color wheel for any
/// other color.
final class SwatchButton: NSButton {
  enum Kind { case color(Color?), wheel }

  var kind: Kind { didSet { needsDisplay = true } }
  var isChosen = false { didSet { needsDisplay = true } }
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
      if color.alpha < 1 {
        // A see-through colour shows over a checkerboard.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.white.setFill()
        square.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        let cell = side / 4
        for row in 0..<4 {
          for column in 0..<4 where (row + column) % 2 == 0 {
            NSRect(x: square.minX + CGFloat(column) * cell, y: square.minY + CGFloat(row) * cell, width: cell, height: cell).fill()
          }
        }
        NSGraphicsContext.restoreGraphicsState()
      }
      (NSColor(cgColor: color.cgColor) ?? .black).setFill()
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

/// Any colour, as the pickers in Preview, Keynote, and Figma choose one: a square of the
/// current hue, paler to the left and darker toward the bottom, and a strip of every hue under
/// it. Clicking or dragging picks, in the window rather than in a panel of its own. A drag stays
/// in the part it started in, held at its edges, so the pointer can wander off it.
@MainActor
final class SpectrumView: NSView {
  private(set) var hue: CGFloat = 0
  private(set) var saturation: CGFloat = 0
  private(set) var brightness: CGFloat = 0
  private var dragging: Part?
  private enum Part { case square, hues }
  static let barHeight: CGFloat = 14
  static let gap: CGFloat = 10

  /// A colour is picked; `done` is true when the pointer is let go.
  var pick: ((Color, _ done: Bool) -> Void)?

  /// The colour shown. Setting it keeps the hue for greys, which have none of their own, so
  /// the square doesn't jump back to red.
  var color: Color? {
    get { Self.color(hue: hue, saturation: saturation, brightness: brightness) }
    set {
      guard dragging == nil, let newValue, let ns = NSColor(cgColor: newValue.cgColor)?.usingColorSpace(.sRGB) else {
        needsDisplay = true
        return
      }
      if ns.saturationComponent > 0.001 && ns.brightnessComponent > 0.001 { hue = ns.hueComponent }
      saturation = ns.saturationComponent
      brightness = ns.brightnessComponent
      needsDisplay = true
    }
  }

  static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> Color {
    Color(NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).cgColor) ?? .black
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 236, height: 128 + Self.gap + Self.barHeight) }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  var square: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.barHeight - Self.gap) }
  var hues: NSRect { NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: Self.barHeight) }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // The square: the hue, whitened to the left and darkened toward the bottom.
    let squareShape = NSBezierPath(roundedRect: square, xRadius: 6, yRadius: 6)
    context.saveGState()
    squareShape.addClip()
    context.setFillColor(Self.color(hue: hue, saturation: 1, brightness: 1).cgColor)
    context.fill(square)
    let white = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(white, start: CGPoint(x: square.minX, y: 0), end: CGPoint(x: square.maxX, y: 0), options: [])
    let black = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(black, start: CGPoint(x: 0, y: square.minY), end: CGPoint(x: 0, y: square.maxY), options: [])
    context.restoreGState()
    NSColor.tertiaryLabelColor.setStroke()
    squareShape.lineWidth = 1
    squareShape.stroke()
    // Every hue.
    let hueShape = NSBezierPath(roundedRect: hues, xRadius: Self.barHeight / 2, yRadius: Self.barHeight / 2)
    context.saveGState()
    hueShape.addClip()
    let stops = (0...6).map { Self.color(hue: CGFloat($0) / 6, saturation: 1, brightness: 1).cgColor }
    let rainbow = CGGradient(colorsSpace: space, colors: stops as CFArray, locations: (0...6).map { CGFloat($0) / 6 })!
    context.drawLinearGradient(rainbow, start: CGPoint(x: hues.minX + hues.height / 2, y: 0), end: CGPoint(x: hues.maxX - hues.height / 2, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    NSColor.tertiaryLabelColor.setStroke()
    hueShape.lineWidth = 1
    hueShape.stroke()
    // Where the colour is.
    knob(at: NSPoint(x: square.minX + saturation * square.width, y: square.minY + (1 - brightness) * square.height), fill: color)
    let inset = hues.height / 2
    knob(at: NSPoint(x: hues.minX + inset + hue * (hues.width - inset * 2), y: hues.midY), fill: Self.color(hue: hue, saturation: 1, brightness: 1))
  }

  private func knob(at center: NSPoint, fill: Color?) {
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
    if let fill { (NSColor(cgColor: fill.cgColor) ?? .black).setFill() }
    ring.fill()
    ring.lineWidth = 2.5
    NSColor.white.setStroke()
    ring.stroke()
    let edge = NSBezierPath(ovalIn: NSRect(x: center.x - 8.25, y: center.y - 8.25, width: 16.5, height: 16.5))
    edge.lineWidth = 0.75
    NSColor.black.withAlphaComponent(0.35).setStroke()
    edge.stroke()
  }

  private func choose(_ event: NSEvent, done: Bool) {
    let p = convert(event.locationInWindow, from: nil)
    if dragging == nil { dragging = hues.insetBy(dx: 0, dy: -4).contains(p) ? .hues : .square }
    func unit(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }
    switch dragging {
    case .hues:
      let inset = hues.height / 2
      hue = unit((p.x - hues.minX - inset) / (hues.width - inset * 2))
      // Choosing a hue for a grey gives it colour, as the square would show it.
      if saturation < 0.05 { saturation = 1 }
      if brightness < 0.05 { brightness = 1 }
    default:
      saturation = unit((p.x - square.minX) / square.width)
      brightness = 1 - unit((p.y - square.minY) / square.height)
    }
    needsDisplay = true
    let picked = color ?? .black
    if done { dragging = nil }
    pick?(picked, done)
  }

  override func mouseDown(with event: NSEvent) { choose(event, done: false) }
  override func mouseDragged(with event: NSEvent) { choose(event, done: false) }
  override func mouseUp(with event: NSEvent) { choose(event, done: true) }
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
  /// Every text size the size menu offers.
  static let pointSizes: [CGFloat] = [10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 56, 64, 72, 96, 128]
  static let brushes: [Tool] = [.pencil, .pen, .calligraphy, .oil, .crayon, .marker, .watercolor, .airbrush, .highlighter, .pixel]

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
    case .pencil, .pen, .highlighter, .pixel, .calligraphy, .airbrush, .crayon, .marker, .watercolor, .oil: return [.freehand]
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

  /// The style of the first selected object that has the property being shown, so a mixed
  /// selection shows a line's dash, not a text box's lack of one.
  func style(for kinds: Set<Element.Kind>) -> Style {
    guard let canvas else { return Style() }
    return (elements.first { kinds.contains($0.kind) } ?? elements.first).map(Style.init) ?? canvas.style
  }

  static let stroked: Set<Element.Kind> = [.rectangle, .ellipse, .polygon, .line, .arrow, .freehand, .text]
  static let filled: Set<Element.Kind> = [.rectangle, .ellipse, .polygon, .text]
  static let widened: Set<Element.Kind> = [.rectangle, .ellipse, .polygon, .line, .arrow, .freehand]
  static let dashed: Set<Element.Kind> = [.rectangle, .ellipse, .polygon, .line, .arrow]
  static let lined: Set<Element.Kind> = [.line, .arrow]
  static let texts: Set<Element.Kind> = [.text]

  // Colours, for the bar and the Palette alike.

  var strokeColor: Color? { style(for: Self.stroked).stroke }
  var fillColor2: Color? { style(for: Self.filled).fill }

  func setStroke(_ color: Color?, live: Bool) { canvas?.setStyle("Change Color", coalescing: live) { $0.stroke = color } }
  func setFill(_ color: Color?, live: Bool) { canvas?.setStyle("Change Fill", coalescing: live) { $0.fill = color } }

  var background: Color? { canvas?.scene.paper.background }

  func setBackground(_ color: Color?, live: Bool) {
    guard let canvas else { return }
    let name = color == nil ? "Clear Background" : "Background"
    if live { canvas.drawing.coalesce(name) { $0.paper.background = color } } else { canvas.drawing.edit(name) { $0.paper.background = color } }
  }

  /// What changes and what's shown: the tool, the kinds of object, and how many there are.
  /// Choosing another brush, eraser, or shape changes what the controls show, not which
  /// controls there are, so they're kept, and don't flicker or move.
  var key: String {
    guard let canvas else { return "" }
    let elements = self.elements
    let tool = Controls.brushes.contains(canvas.tool) ? "brush" : [.eraser, .strokeEraser].contains(canvas.tool) ? "eraser" : canvas.tool.rawValue
    return "\(tool)|\(kinds.map(\.rawValue).sorted())|\(elements.count)|\(elements.contains { !$0.groups.isEmpty })|\(canvas.drawing.selectedElements.contains(where: \.locked))"
  }

  /// The brush of the selected strokes, as the tool that draws them.
  var brushTool: Tool {
    let brush = elements.first?.brush ?? .pen
    return Controls.brushes.first { $0.brush == brush } ?? .pen
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
    case .pixel: [1, 2, 4]
    case .calligraphy: [6, 10, 18]
    case .airbrush: [16, 28, 48]
    case .crayon: [4, 8, 16]
    case .marker: [6, 10, 18]
    case .watercolor: [10, 20, 36]
    case .oil: [8, 16, 28]
    case .eraser, .strokeEraser: [10, 24, 48]
    default: [1.5, 3, 6]
    }
  }

  static let widthNames = ["Thin", "Medium", "Bold"]

  var widthIndex: Int? {
    guard let canvas else { return nil }
    let tool = widthTool
    let width = tool == .eraser ? (canvas.styles[.eraser]?.strokeWidth ?? Tool.eraser.defaultStyle.strokeWidth) : style(for: Self.widened).strokeWidth
    return Self.widths(for: tool).firstIndex { abs($0 - width) < 0.01 }
  }

  func setWidth(_ i: Int) {
    let widths = Self.widths(for: widthTool)
    guard widths.indices.contains(i) else { return }
    setWidth(value: widths[i])
  }

  /// The width now, of the eraser or of what's styled.
  var width: CGFloat {
    guard let canvas else { return 3 }
    return widthTool == .eraser ? (canvas.styles[.eraser]?.strokeWidth ?? Tool.eraser.defaultStyle.strokeWidth) : style(for: Self.widened).strokeWidth
  }

  /// The widths the slider offers for the tool.
  static func widthRange(for tool: Tool) -> ClosedRange<CGFloat> {
    switch tool {
    case .pixel: 1...16
    case .eraser, .strokeEraser: 4...120
    case .highlighter, .airbrush: 4...120
    default: 0.5...48
    }
  }

  func setWidth(value: CGFloat, coalescing: Bool = false) {
    guard let canvas else { return }
    let value = widthTool == .pixel ? value.rounded() : (value * 2).rounded() / 2
    if widthTool == .eraser {
      canvas.styles[.eraser, default: Tool.eraser.defaultStyle].strokeWidth = value
      canvas.styles[.strokeEraser, default: Tool.strokeEraser.defaultStyle].strokeWidth = value
      canvas.delegate?.canvasViewStylesDidChange(canvas)
      canvas.window?.invalidateCursorRects(for: canvas)
    } else {
      canvas.setStyle("Change Width", coalescing: coalescing) { $0.strokeWidth = value }
    }
  }

  /// A slider for any width, with the width beside it.
  func widthSlider() -> NSView {
    let range = Self.widthRange(for: widthTool)
    let slider = NSSlider(value: Double(width), minValue: Double(range.lowerBound), maxValue: Double(range.upperBound), target: nil, action: nil)
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel("Width")
    let label = NSTextField(labelWithString: "")
    label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 34).isActive = true
    wire(slider) { [weak self, weak slider] _ in
      guard let self, let slider else { return }
      self.setWidth(value: CGFloat(slider.doubleValue), coalescing: true)
    }
    refreshers.append { [weak self, weak slider, weak label] in
      guard let self else { return }
      // Each brush has its own range of widths.
      let range = Self.widthRange(for: self.widthTool)
      slider?.minValue = Double(range.lowerBound)
      slider?.maxValue = Double(range.upperBound)
      slider?.doubleValue = Double(self.width)
      let width = self.width
      label?.stringValue = width == width.rounded() ? "\(Int(width)) pt" : String(format: "%.1f pt", width)
    }
    let row = NSStackView(views: [slider, label])
    row.spacing = 8
    return row
  }

  func setBrush(_ brush: Element.Brush) {
    guard let canvas else { return }
    let ids = Set(elements.filter { $0.kind == .freehand }.map(\.id))
    canvas.drawing.edit("Change Brush") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
        var e = scene.elements[i]
        // Strokes made into pixels land on the pixel grid.
        if brush == .pixel && e.brush != .pixel {
          e.strokeWidth = max(1, min(8, (e.strokeWidth / 3).rounded()))
          e.setWorldPoints(Freehand.pixels(e.points.map { CGPoint(x: $0.x + e.x, y: $0.y + e.y) }, size: e.strokeWidth))
          e.pressures = []
        }
        e.brush = brush
        scene.elements[i] = e
      }
    }
  }

  var fillColor: Color? { canvas?.styles[.fill]?.stroke }

  func setFillColor(_ color: Color?) {
    guard let canvas, let color else { return }
    canvas.styles[.fill, default: Tool.fill.defaultStyle].stroke = color
    canvas.delegate?.canvasViewStylesDidChange(canvas)
  }

  // MARK: Controls

  /// Gives a colour to something. `live` is true while a colour is being dragged out, so the
  /// changes make one undo step.
  typealias ColorApply = @MainActor (_ color: Color?, _ live: Bool) -> Void

  /// What the none swatch is called: None, or Transparent for the canvas.
  var noneTitle = "None"

  /// A row of swatches, a none swatch first when allowed, and a wheel for any other color.
  func colorRow(
    _ colors: [Color], allowsNone: Bool, side: CGFloat = 19, value: @escaping @MainActor () -> Color??,
    apply: @escaping ColorApply
  ) -> NSStackView {
    let choices: [Color?] = (allowsNone ? [nil] : []) + colors.prefix(allowsNone ? 6 : 7).map { $0 }
    let row = NSStackView()
    row.distribution = .equalSpacing
    swatches(choices, side: side, value: value, apply: apply).forEach(row.addArrangedSubview)
    return row
  }

  /// Every color in two rows, as the bar's color popover shows them.
  func colorGrid(allowsNone: Bool, value: @escaping @MainActor () -> Color??, apply: @escaping ColorApply) -> NSView {
    let top: [Color?] = Self.strokes.map { $0 } + (allowsNone ? [nil] : [])
    let bottom: [Color?] = Self.fills.map { $0 }
    let all = swatches(top + bottom, side: 22, value: value, apply: apply, wheel: false)
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
    apply: @escaping ColorApply, wheel: Bool = true
  ) -> [NSView] {
    var swatches: [SwatchButton] = []
    for color in choices {
      let swatch = SwatchButton(.color(color), side: side)
      wire(swatch) { _ in apply(color, false) }
      swatch.toolTip = color.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() } ?? noneTitle
      swatch.setAccessibilityLabel(swatch.toolTip)
      swatches.append(swatch)
    }
    // Any other colour, from a spectrum in a popover beside it; the swatch shows it once chosen.
    let custom = SwatchButton(.wheel, side: side)
    wire(custom) { [weak self, weak custom] _ in
      guard let self, let custom else { return }
      self.showPicker(from: custom, value: value, apply: apply)
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
    return wheel ? swatches + [custom] : swatches
  }

  /// The spectrum popover a wheel swatch opens, and the controls in it.
  private var picker: (popover: NSPopover, controls: Controls)?

  private func showPicker(from view: NSView, value: @escaping @MainActor () -> Color??, apply: @escaping ColorApply) {
    picker?.popover.close()
    let controls = Controls()
    controls.canvas = canvas
    let content = controls.colorPicker(value: value) { [weak self] color, live in
      apply(color, live)
      self?.refresh()
      self?.picker?.controls.refresh()
    }
    controls.refresh()
    let popover = popoverAbove(content, from: view, edge: .minY)
    picker = (popover, controls)
  }

  /// The spectrum and a hex field, for any colour, in the window.
  func colorPicker(value: @escaping @MainActor () -> Color??, apply: @escaping ColorApply) -> NSView {
    let spectrum = SpectrumView()
    spectrum.setAccessibilityLabel("Color spectrum")
    // A drag in the spectrum, let go and all, is one change to undo.
    spectrum.pick = { [weak self] color, done in
      apply(color, true)
      if done { self?.canvas?.drawing.finishCoalescing() }
    }
    let hex = NSTextField(string: "")
    hex.placeholderString = "#RRGGBB"
    hex.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    hex.controlSize = .small
    hex.setAccessibilityLabel("Hex color")
    // Only Return applies it: leaving the field, as closing the popover does, changes nothing.
    hex.cell?.sendsActionOnEndEditing = false
    hex.widthAnchor.constraint(equalToConstant: 84).isActive = true
    wire(hex) { [weak hex] _ in
      guard let text = hex?.stringValue, let color = Color(hex: text) else { return NSSound.beep() }
      apply(color, false)
    }
    let label = NSTextField(labelWithString: "Hex")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .secondaryLabelColor
    let row = NSStackView(views: [label, hex])
    row.spacing = 6
    refreshers.append { [weak spectrum, weak hex] in
      let current = value() ?? nil
      spectrum?.color = current
      if let hex, hex.currentEditor() == nil { hex.stringValue = current?.hex ?? "" }
    }
    let column = NSStackView(views: [spectrum, row])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    return column
  }

  /// A slider for the opacity, with the percentage beside it.
  func opacitySlider() -> NSView {
    let slider = opacityControl()
    let label = NSTextField(labelWithString: "")
    label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .right
    label.widthAnchor.constraint(equalToConstant: 34).isActive = true
    refreshers.append { [weak self, weak label] in
      label?.stringValue = "\(Int(((self?.style.opacity ?? 1) * 100).rounded()))%"
    }
    let row = NSStackView(views: [slider, label])
    row.spacing = 8
    return row
  }

  private func opacityControl() -> NSSlider {
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
        selected: { [weak self] in self.flatMap { Element.Dash.allCases.firstIndex(of: $0.style(for: Controls.dashed).dash) } }
      ) { [weak canvas] i in canvas?.setStyle("Change Line") { $0.dash = Element.Dash.allCases[i] } }))
    }
    if kinds == [.rectangle] {
      rows.append(("Corners", segmented(images: [(Self.cornerImage(false), "Sharp"), (Self.cornerImage(true), "Round")], selected: {
        [weak self] in (self?.style(for: [.rectangle]).cornerRadius ?? 0) > 0 ? 1 : 0
      }) { [weak canvas] i in canvas?.setStyle(i == 0 ? "Sharp Corners" : "Round Corners") { $0.cornerRadius = i == 0 ? 0 : 16 } }))
    }
    if hasLines || kinds == [.polygon] {
      rows.append(("Line", segmented(images: [(Self.curveImage(false), "Straight"), (Self.curveImage(true), "Curved")], selected: {
        [weak self] in self?.style(for: [.line, .arrow, .polygon]).curved == true ? 1 : 0
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
