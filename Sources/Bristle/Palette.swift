import AppKit
import BristleCanvas
import BristleCore

/// What the Palette is choosing a color for.
struct PaletteTarget {
  var title: String
  var color: Color?
  /// Offer "None", as for a shape's fill or border.
  var allowsNone = false
  /// The element's opacity, shown as a slider when it applies.
  var opacity: CGFloat?
  var apply: @MainActor (Color?) -> Void
  var applyOpacity: (@MainActor (CGFloat) -> Void)?
}

/// A round color swatch; a slash marks no color.
final class SwatchButton: NSButton {
  var color: Color? { didSet { needsDisplay = true } }
  var diameter: CGFloat = 20 { didSet { invalidateIntrinsicContentSize() } }
  var isChosen = false { didSet { needsDisplay = true } }
  /// Draw as a ring, for a border or line color.
  var ring = false { didSet { needsDisplay = true } }

  init(color: Color?, diameter: CGFloat = 20) {
    self.color = color
    self.diameter = diameter
    super.init(frame: NSRect(x: 0, y: 0, width: diameter + 6, height: diameter + 6))
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: diameter + 6, height: diameter + 6) }

  override func draw(_ dirtyRect: NSRect) {
    let circle = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
    if isChosen {
      NSColor.controlAccentColor.setStroke()
      let outer = NSBezierPath(ovalIn: circle.insetBy(dx: -2.5, dy: -2.5))
      outer.lineWidth = 2
      outer.stroke()
    }
    if let color {
      if color.alpha < 1 {
        // A checkerboard behind translucent colors.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor.white.setFill()
        circle.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        let square = diameter / 4
        for i in 0..<4 {
          for j in 0..<4 where (i + j) % 2 == 0 {
            NSRect(x: circle.minX + CGFloat(i) * square, y: circle.minY + CGFloat(j) * square, width: square, height: square).fill()
          }
        }
        NSGraphicsContext.restoreGraphicsState()
      }
      let fill = NSColor(cgColor: color.cgColor) ?? .black
      if ring {
        fill.setStroke()
        let path = NSBezierPath(ovalIn: circle.insetBy(dx: 2.5, dy: 2.5))
        path.lineWidth = 5
        path.stroke()
      } else {
        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()
      }
      NSColor.separatorColor.setStroke()
      NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5)).stroke()
    } else {
      NSColor.windowBackgroundColor.setFill()
      NSBezierPath(ovalIn: circle).fill()
      NSColor.separatorColor.setStroke()
      NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5)).stroke()
      let slash = NSBezierPath()
      slash.move(to: NSPoint(x: circle.minX + diameter * 0.2, y: circle.minY + diameter * 0.2))
      slash.line(to: NSPoint(x: circle.maxX - diameter * 0.2, y: circle.maxY - diameter * 0.2))
      slash.lineWidth = 1.5
      NSColor.systemRed.setStroke()
      slash.stroke()
    }
  }
}

/// The Palette: Bristle's colors, as a grid of swatches beside the control that opened it, with
/// the colors used most recently, opacity, and the system color panel for anything else.
@MainActor
final class PaletteViewController: NSViewController {
  static let hues = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7", "#32ADE6", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#A2845E"]

  /// Five tints and shades of each hue, and a row of grays.
  static let colors: [[Color]] = {
    func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
      Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t)
    }
    let base = hues.compactMap(Color.init(hex:))
    let grays = ["#FFFFFF", "#E5E5EA", "#C7C7CC", "#AEAEB2", "#8E8E93", "#636366", "#48484A", "#3A3A3C", "#2C2C2E", "#1C1C1E", "#1D1D1F", "#000000"]
    var rows = [grays.compactMap(Color.init(hex:))]
    for t in [0.75, 0.45] as [CGFloat] { rows.append(base.map { mix($0, .white, t) }) }
    rows.append(base)
    for t in [0.3, 0.55] as [CGFloat] { rows.append(base.map { mix($0, .black, t) }) }
    return rows
  }()

  static let recentKey = "recentColors"

  static var recent: [Color] {
    (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).compactMap(Color.init(hex:))
  }

  static func remember(_ color: Color) {
    guard !AppPreferences.isAutomatedCheck else { return }
    var list = recent.filter { $0 != color }
    list.insert(color, at: 0)
    UserDefaults.standard.set(list.prefix(12).map(\.hex), forKey: recentKey)
  }

  private var target: PaletteTarget
  private var swatches: [SwatchButton] = []
  private var opacityField = NSTextField()
  private weak var popover: NSPopover?

  init(target: PaletteTarget) {
    self.target = target
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Opens the Palette beside a control.
  static func show(_ target: PaletteTarget, relativeTo view: NSView, edge: NSRectEdge = .maxY) {
    let popover = NSPopover()
    let controller = PaletteViewController(target: target)
    controller.popover = popover
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.animates = true
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
    current = popover
  }

  /// The open Palette, if any.
  static weak var current: NSPopover?

  override func loadView() {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    let title = NSTextField(labelWithString: target.title)
    title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    stack.addArrangedSubview(title)
    let grid = NSGridView()
    grid.rowSpacing = 2
    grid.columnSpacing = 2
    for row in Self.colors {
      grid.addRow(with: row.map { swatch($0) })
    }
    stack.addArrangedSubview(grid)
    let recent = Self.recent
    if !recent.isEmpty {
      let label = NSTextField(labelWithString: "Recent")
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      label.textColor = .secondaryLabelColor
      let row = NSStackView(views: recent.map { swatch($0) })
      row.spacing = 2
      stack.addArrangedSubview(label)
      stack.addArrangedSubview(row)
    }
    if let opacity = target.opacity, target.applyOpacity != nil {
      let slider = NSSlider(value: Double(opacity * 100), minValue: 5, maxValue: 100, target: self, action: #selector(opacityChanged(_:)))
      slider.isContinuous = true
      slider.setAccessibilityLabel("Opacity")
      slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
      opacityField = NSTextField(labelWithString: "\(Int((opacity * 100).rounded()))%")
      opacityField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      let label = NSTextField(labelWithString: "Opacity")
      let row = NSStackView(views: [label, slider, opacityField])
      row.spacing = 8
      stack.addArrangedSubview(row)
    }
    var buttons: [NSView] = []
    if target.allowsNone {
      let none = NSButton(title: "None", target: self, action: #selector(chooseNone(_:)))
      none.controlSize = .small
      buttons.append(none)
    }
    buttons.append(NSView())
    let more = NSButton(title: "More Colors…", target: self, action: #selector(moreColors(_:)))
    more.controlSize = .small
    more.toolTip = "Choose any color with the system color panel"
    buttons.append(more)
    let row = NSStackView(views: buttons)
    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
    view = stack
    view.setAccessibilityLabel("Palette")
  }

  private func swatch(_ color: Color) -> SwatchButton {
    let button = SwatchButton(color: color, diameter: 20)
    button.target = self
    button.action = #selector(choose(_:))
    button.isChosen = color == target.color?.withAlpha(1) || color == target.color
    button.toolTip = color.hex
    button.setAccessibilityLabel(color.name.prefix(1).uppercased() + color.name.dropFirst())
    swatches.append(button)
    return button
  }

  @objc private func choose(_ sender: SwatchButton) {
    guard let color = sender.color else { return }
    target.apply(color)
    target.color = color
    Self.remember(color)
    popover?.performClose(nil)
  }

  @objc private func chooseNone(_ sender: Any?) {
    target.apply(nil)
    popover?.performClose(nil)
  }

  @objc private func opacityChanged(_ sender: NSSlider) {
    let value = CGFloat(sender.doubleValue.rounded()) / 100
    opacityField.stringValue = "\(Int(sender.doubleValue.rounded()))%"
    target.applyOpacity?(value)
  }

  @objc private func moreColors(_ sender: Any?) {
    let panel = NSColorPanel.shared
    let apply = target.apply
    ColorPanelRelay.shared.apply = { color in
      apply(color)
      Self.remember(color)
    }
    panel.setTarget(ColorPanelRelay.shared)
    panel.setAction(#selector(ColorPanelRelay.changed(_:)))
    if let color = target.color { panel.color = NSColor(cgColor: color.cgColor) ?? .black }
    panel.showsAlpha = true
    popover?.performClose(nil)
    panel.orderFront(nil)
  }
}

/// Sends the system color panel's changes to whatever the Palette last chose for.
@MainActor
final class ColorPanelRelay: NSObject {
  static let shared = ColorPanelRelay()
  var apply: ((Color) -> Void)?

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
