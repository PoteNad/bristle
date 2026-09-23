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
    ColorPanelRelay.open(canvas.scene.paper.background) { [weak canvas] color in
      canvas?.drawing.coalesce("Background") { $0.paper.background = color }
    }
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
