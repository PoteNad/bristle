import AppKit
import BristleCanvas
import BristleCore

/// Liquid Glass on macOS 26 and later, and a popover material before it.
@MainActor
func glass(around content: NSView, cornerRadius: CGFloat = 20) -> NSView {
  if #available(macOS 26.0, *) {
    let glass = NSGlassEffectView()
    glass.contentView = content
    glass.cornerRadius = cornerRadius
    return glass
  }
  let material = NSVisualEffectView()
  material.material = .popover
  material.state = .active
  material.wantsLayer = true
  material.layer?.cornerRadius = cornerRadius
  material.layer?.masksToBounds = true
  content.translatesAutoresizingMaskIntoConstraints = false
  material.addSubview(content)
  NSLayoutConstraint.activate([
    content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
    content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
    content.topAnchor.constraint(equalTo: material.topAnchor),
    content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
  ])
  return material
}

/// A row of controls in a glass capsule, as Freeform's floating bars are.
@MainActor
final class Bar: NSView {
  let row = NSStackView()

  init(_ views: [NSView] = [], label: String) {
    super.init(frame: .zero)
    row.orientation = .horizontal
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    views.forEach(row.addArrangedSubview)
    let capsule = glass(around: row, cornerRadius: 18)
    capsule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(capsule)
    NSLayoutConstraint.activate([
      capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
      capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
      capsule.topAnchor.constraint(equalTo: topAnchor),
      capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ views: [NSView]) {
    row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    views.forEach(row.addArrangedSubview)
  }
}

/// A plain symbol button for the bars, highlighted while on.
@MainActor
func barButton(_ symbol: String, _ title: String, target: AnyObject?, action: Selector?, toggles: Bool = false) -> NSButton {
  let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
    .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
  let button = NSButton(image: image, target: target, action: action)
  button.bezelStyle = .toolbar
  button.setButtonType(.momentaryPushIn)
  button.isBordered = true
  button.showsBorderOnlyWhileMouseInside = true
  button.toolTip = title
  button.setAccessibilityLabel(title)
  button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
  button.heightAnchor.constraint(equalToConstant: 28).isActive = true
  return button
}

/// Shows a bar toggle as on with the accent color, as Keynote's and Freeform's toggles do.
@MainActor
func setOn(_ button: NSButton, _ on: Bool) {
  button.contentTintColor = on ? .controlAccentColor : nil
  button.setAccessibilityValue(on ? "on" : "off")
}

/// A line of increasing width, for choosing stroke widths as Freeform shows them.
@MainActor
func widthImage(_ width: CGFloat, selected: Bool = false) -> NSImage {
  let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { rect in
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 5, y: 7))
    path.curve(to: NSPoint(x: 23, y: 15), controlPoint1: NSPoint(x: 11, y: 20), controlPoint2: NSPoint(x: 17, y: 2))
    path.lineWidth = min(9, max(1, width))
    path.lineCapStyle = .round
    NSColor.labelColor.setStroke()
    path.stroke()
    return true
  }
  image.isTemplate = true
  return image
}

/// The bar at the bottom of the window while drawing: Select, the drawing tool with its menu,
/// and the tool's color.
@MainActor
final class DrawBar: NSObject {
  static let drawingTools: [Tool] = [.pencil, .pen, .highlighter, .eraser, .strokeEraser, .fill, .eyedropper]

  /// Line widths offered for each tool.
  static func widths(for tool: Tool) -> [CGFloat] {
    switch tool {
    case .pencil: [1, 2, 3, 5, 8]
    case .pen: [3, 6, 10, 16, 24]
    case .highlighter: [10, 16, 24, 36, 52]
    case .eraser, .strokeEraser: [6, 12, 20, 36, 64]
    default: [1, 2, 4, 8, 12]
    }
  }

  weak var canvas: CanvasView?
  let bar: Bar
  let select: NSButton
  let toolButton: NSButton
  let swatch = SwatchButton(color: .ink, diameter: 18)
  /// The drawing tool used last, which the Draw button returns to.
  var lastTool: Tool = .pen

  override init() {
    select = barButton("square.dashed", "Select (V)", target: nil, action: nil, toggles: true)
    toolButton = NSButton(title: "", image: NSImage(), target: nil, action: nil)
    bar = Bar(label: "Drawing tools")
    super.init()
    select.target = self
    select.action = #selector(chooseSelect(_:))
    toolButton.bezelStyle = .toolbar
    toolButton.setButtonType(.momentaryPushIn)
    toolButton.showsBorderOnlyWhileMouseInside = true
    toolButton.imagePosition = .imageLeading
    toolButton.target = self
    toolButton.action = #selector(showToolMenu(_:))
    toolButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
    toolButton.setAccessibilityHelp("Choose a drawing tool and line width")
    swatch.target = self
    swatch.action = #selector(showPalette(_:))
    swatch.setAccessibilityLabel("Color")
    bar.set([select, toolButton, swatch])
  }

  func update() {
    guard let canvas else { return }
    if Self.drawingTools.contains(canvas.tool) { lastTool = canvas.tool }
    let tool = lastTool
    let symbol = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    toolButton.image = Self.combine(symbol, chevron)
    toolButton.toolTip = tool.title + (tool.key.isEmpty ? "" : " (\(tool.key.uppercased()))")
    toolButton.setAccessibilityLabel(tool.title)
    setOn(toolButton, canvas.tool == tool)
    setOn(select, canvas.tool == .select)
    let style = canvas.styles[tool] ?? tool.defaultStyle
    swatch.color = style.stroke
    swatch.isEnabled = tool != .eraser && tool != .strokeEraser && tool != .eyedropper
    swatch.toolTip = tool == .fill ? "Fill color" : "Color"
  }

  static func combine(_ symbol: NSImage?, _ chevron: NSImage?) -> NSImage? {
    guard let symbol else { return nil }
    let size = NSSize(width: symbol.size.width + 12, height: max(symbol.size.height, 16))
    let image = NSImage(size: size, flipped: false) { rect in
      symbol.draw(in: NSRect(x: 0, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
      if let chevron {
        chevron.draw(in: NSRect(x: rect.width - chevron.size.width, y: (rect.height - chevron.size.height) / 2, width: chevron.size.width, height: chevron.size.height))
      }
      return true
    }
    image.isTemplate = true
    return image
  }

  @objc private func chooseSelect(_ sender: Any?) {
    canvas?.tool = .select
    update()
  }

  /// The menu of drawing tools, with a row of line widths at the top as in Freeform.
  func toolMenu() -> NSMenu {
    let menu = NSMenu(title: "Drawing Tools")
    guard let canvas else { return menu }
    let tool = lastTool
    let widths = Self.widths(for: tool)
    let current = (canvas.styles[tool] ?? tool.defaultStyle).strokeWidth
    let row = NSStackView()
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    for width in widths {
      let button = NSButton(image: widthImage(min(9, width / widths[0] * 1.5)), target: self, action: #selector(chooseWidth(_:)))
      button.bezelStyle = .toolbar
      button.setButtonType(.pushOnPushOff)
      button.state = abs(width - current) < 0.01 ? .on : .off
      button.tag = Int(width * 10)
      button.toolTip = "\(Int(width)) point line"
      button.setAccessibilityLabel("\(Int(width)) point line")
      row.addArrangedSubview(button)
    }
    row.frame.size = row.fittingSize
    let widthItem = NSMenuItem()
    widthItem.view = row
    menu.addItem(widthItem)
    menu.addItem(.separator())
    for (i, choice) in Self.drawingTools.enumerated() {
      if i == 3 || i == 5 { menu.addItem(.separator()) }
      let item = NSMenuItem(title: choice.title, action: #selector(chooseTool(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = choice.rawValue
      item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
      item.state = choice == tool ? .on : .off
      menu.addItem(item)
    }
    return menu
  }

  @objc private func showToolMenu(_ sender: NSButton) {
    guard let canvas else { return }
    // The first click chooses the tool; a click on the chosen tool opens its menu.
    if canvas.tool != lastTool {
      canvas.tool = lastTool
      update()
      return
    }
    update()
    let menu = toolMenu()
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    update()
  }

  @objc func chooseTool(_ sender: NSMenuItem) {
    guard let name = sender.representedObject as? String, let tool = Tool(rawValue: name) else { return }
    lastTool = tool
    canvas?.tool = tool
    update()
  }

  @objc private func chooseWidth(_ sender: NSButton) {
    guard let canvas else { return }
    let width = CGFloat(sender.tag) / 10
    let tool = lastTool
    canvas.styles[tool, default: tool.defaultStyle].strokeWidth = width
    canvas.window?.invalidateCursorRects(for: canvas)
    canvas.delegate?.canvasViewStylesDidChange(canvas)
    sender.enclosingMenuItem?.menu?.cancelTracking()
  }

  @objc private func showPalette(_ sender: SwatchButton) {
    guard let canvas else { return }
    let tool = lastTool
    let style = canvas.styles[tool] ?? tool.defaultStyle
    let target = PaletteTarget(
      title: tool == .fill ? "Fill Color" : "\(tool.title) Color", color: style.stroke, opacity: tool.brush != nil ? style.opacity : nil,
      apply: { [weak self] color in
        guard let self, let canvas = self.canvas, let color else { return }
        canvas.styles[tool, default: tool.defaultStyle].stroke = color
        canvas.delegate?.canvasViewStylesDidChange(canvas)
        self.update()
      },
      applyOpacity: { [weak self] value in
        guard let canvas = self?.canvas else { return }
        canvas.styles[tool, default: tool.defaultStyle].opacity = value
        canvas.delegate?.canvasViewStylesDidChange(canvas)
      })
    PaletteViewController.show(target, relativeTo: sender, edge: .maxY)
  }
}

/// Zoom out, the zoom level with a menu of levels, and zoom in, at the bottom left.
@MainActor
final class ZoomBar: NSObject {
  weak var canvas: CanvasView?
  let bar = Bar(label: "Zoom")
  private let level = NSButton(title: "100%", target: nil, action: nil)

  override init() {
    super.init()
    let out = barButton("minus", "Zoom Out (⌘−)", target: self, action: #selector(zoomOut(_:)))
    let into = barButton("plus", "Zoom In (⌘+)", target: self, action: #selector(zoomIn(_:)))
    level.bezelStyle = .toolbar
    level.showsBorderOnlyWhileMouseInside = true
    level.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    level.target = self
    level.action = #selector(showLevels(_:))
    level.toolTip = "Choose a zoom level"
    level.widthAnchor.constraint(equalToConstant: 58).isActive = true
    level.heightAnchor.constraint(equalToConstant: 28).isActive = true
    bar.set([out, level, into])
  }

  func update() {
    guard let canvas else { return }
    level.title = "\(canvas.zoomPercent)%"
    level.setAccessibilityLabel("Zoom \(canvas.zoomPercent) percent")
  }

  @objc private func zoomOut(_ sender: Any?) { canvas?.zoomOut(sender) }
  @objc private func zoomIn(_ sender: Any?) { canvas?.zoomIn(sender) }

  @objc private func showLevels(_ sender: NSButton) {
    guard let canvas else { return }
    let menu = NSMenu(title: "Zoom")
    for percent in [25, 50, 75, 100, 150, 200, 400, 800] {
      let item = menu.addItem(withTitle: "\(percent)%", action: #selector(zoomTo(_:)), keyEquivalent: "")
      item.tag = percent
      item.target = self
      item.state = canvas.zoomPercent == percent ? .on : .off
    }
    menu.addItem(.separator())
    let fit = menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasView.zoomToFit(_:)), keyEquivalent: "9")
    fit.target = canvas
    let actual = menu.addItem(withTitle: "Actual Size", action: #selector(CanvasView.actualSize(_:)), keyEquivalent: "0")
    actual.target = canvas
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
  }

  @objc private func zoomTo(_ sender: NSMenuItem) { canvas?.zoom(to: CGFloat(sender.tag) / 100) }
}

/// The grid, and the canvas's size and background, at the bottom right.
@MainActor
final class CanvasBar: NSObject {
  weak var canvas: CanvasView?
  weak var editor: Editor?
  let bar = Bar(label: "Canvas")
  let grid: NSButton
  let options: NSButton

  override init() {
    grid = barButton("squareshape.split.3x3", "Show Grid (⌘')", target: nil, action: #selector(Editor.toggleGrid(_:)), toggles: true)
    options = barButton("rectangle.dashed", "Canvas", target: nil, action: nil)
    super.init()
    options.target = self
    options.action = #selector(showOptions(_:))
    options.toolTip = "Canvas size and background"
    bar.set([grid, options])
  }

  func update() {
    setOn(grid, UserDefaults.standard.bool(forKey: PreferenceKey.showsGrid))
  }

  @objc private func showOptions(_ sender: NSButton) {
    guard let canvas, let editor else { return }
    let menu = NSMenu(title: "Canvas")
    let paper = canvas.scene.paper
    let size = menu.addItem(withTitle: "Canvas Size…", action: #selector(Editor.showCanvasSize(_:)), keyEquivalent: "")
    size.target = editor
    let fit = menu.addItem(withTitle: "Fit Canvas to Drawing", action: #selector(CanvasView.fitCanvasToDrawing(_:)), keyEquivalent: "")
    fit.target = canvas
    let info = NSMenuItem(title: "\(Int(paper.width)) × \(Int(paper.height)) points", action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    menu.addItem(.separator())
    let header = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    let white = menu.addItem(withTitle: "White", action: #selector(setWhite(_:)), keyEquivalent: "")
    white.target = self
    white.state = paper.background == .white ? .on : .off
    let clear = menu.addItem(withTitle: "Transparent", action: #selector(setTransparent(_:)), keyEquivalent: "")
    clear.target = self
    clear.state = paper.background == nil ? .on : .off
    let color = menu.addItem(withTitle: "Color…", action: #selector(chooseColor(_:)), keyEquivalent: "")
    color.target = self
    color.state = paper.background != nil && paper.background != .white ? .on : .off
    menu.addItem(.separator())
    let guides = menu.addItem(withTitle: "Snap to Guides", action: #selector(Editor.toggleGuides(_:)), keyEquivalent: "")
    guides.target = editor
    let snap = menu.addItem(withTitle: "Snap to Grid", action: #selector(Editor.toggleSnapToGrid(_:)), keyEquivalent: "")
    snap.target = editor
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
  }

  @objc private func setWhite(_ sender: Any?) { canvas?.drawing.edit("Background") { $0.paper.background = .white } }
  @objc private func setTransparent(_ sender: Any?) { canvas?.drawing.edit("Clear Background") { $0.paper.background = nil } }

  @objc private func chooseColor(_ sender: Any?) {
    guard let canvas else { return }
    let target = PaletteTarget(title: "Background", color: canvas.scene.paper.background, allowsNone: true) { [weak canvas] color in
      canvas?.drawing.edit("Background") { $0.paper.background = color }
    }
    PaletteViewController.show(target, relativeTo: options, edge: .maxY)
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
