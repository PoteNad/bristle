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
  static let height: CGFloat = 44
  let row = NSStackView()

  init(_ views: [NSView] = [], label: String) {
    super.init(frame: .zero)
    row.orientation = .horizontal
    row.spacing = 2
    row.alignment = .centerY
    row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    views.forEach(row.addArrangedSubview)
    let capsule = glass(around: row, cornerRadius: Self.height / 2)
    capsule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(capsule)
    NSLayoutConstraint.activate([
      capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
      capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
      capsule.topAnchor.constraint(equalTo: topAnchor),
      capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.heightAnchor.constraint(equalToConstant: Self.height),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel(label)
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ views: [NSView]) {
    row.arrangedSubviews.forEach { $0.removeFromSuperview() }
    views.forEach(row.addArrangedSubview)
    invalidateIntrinsicContentSize()
    superview?.needsLayout = true
  }

  var buttons: [NSButton] { row.arrangedSubviews.compactMap { $0 as? NSButton } }

  /// A thin line between groups of controls.
  static func divider() -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 20).isActive = true
    return line
  }
}

/// A button for the bars, the size of Freeform's: a symbol or a short title on a rounded
/// highlight that shows while the pointer is over it, while it's pressed, and while it's on.
@MainActor
final class BarButton: NSButton {
  /// Whether the choice the button stands for is the current one.
  var isOn = false {
    didSet {
      guard isOn != oldValue else { return }
      contentTintColor = isOn ? .controlAccentColor : nil
      setAccessibilityValue(isOn ? "on" : "off")
      needsDisplay = true
    }
  }
  private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
  private var minimumWidth: CGFloat = 34

  convenience init(symbol: String, title: String, target: AnyObject?, action: Selector?) {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? NSImage()
    self.init(image: image, title: title, target: target, action: action)
  }

  convenience init(image: NSImage, title: String, target: AnyObject?, action: Selector?) {
    self.init(frame: .zero)
    self.image = image
    imagePosition = .imageOnly
    self.title = ""
    setup(tip: title, target: target, action: action)
  }

  /// A button showing text, such as the zoom level or a font, with a small arrow when it opens a menu.
  convenience init(text: String, tip: String, menu: Bool = false, target: AnyObject?, action: Selector?) {
    self.init(frame: .zero)
    imagePosition = .noImage
    setText(text, menu: menu)
    setup(tip: tip, target: target, action: action)
    minimumWidth = 44
  }

  private func setup(tip: String, target: AnyObject?, action: Selector?) {
    isBordered = false
    setButtonType(.momentaryChange)
    imageScaling = .scaleNone
    self.target = target
    self.action = action
    toolTip = tip
    setAccessibilityLabel(tip.replacingOccurrences(of: #" \(.*\)$"#, with: "", options: .regularExpression))
    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.required, for: .horizontal)
  }

  func setText(_ text: String, menu: Bool = false) {
    let string = NSMutableAttributedString(
      string: text,
      attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
    if menu {
      string.append(NSAttributedString(
        string: " ▾", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor, .baselineOffset: 1]))
    }
    attributedTitle = string
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: NSSize {
    let content = super.intrinsicContentSize
    return NSSize(width: max(minimumWidth, content.width + (imagePosition == .noImage ? 20 : 12)), height: 32)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }
  override func mouseExited(with event: NSEvent) { hovering = false }

  override func draw(_ dirtyRect: NSRect) {
    let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
    let alpha: CGFloat = isHighlighted ? 0.16 : isOn ? 0.11 : hovering && isEnabled ? 0.07 : 0
    if alpha > 0 {
      NSColor.labelColor.withAlphaComponent(alpha).setFill()
      pill.fill()
    }
    super.draw(dirtyRect)
  }
}

/// A color swatch for the bars, with a popover of every color above it.
@MainActor
final class BarSwatch: NSButton {
  private let swatch: SwatchButton

  init(tip: String) {
    swatch = SwatchButton(.color(nil), side: 20)
    super.init(frame: .zero)
    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    toolTip = tip
    setAccessibilityLabel(tip)
    translatesAutoresizingMaskIntoConstraints = false
    swatch.frame = NSRect(x: 4.5, y: 3.5, width: 25, height: 25)
    swatch.isEnabled = false
    addSubview(swatch)
  }

  required init?(coder: NSCoder) { fatalError() }

  var display: ((Color) -> Color)? {
    get { swatch.display }
    set { swatch.display = newValue }
  }

  var color: Color? {
    get { if case .color(let color) = swatch.kind { return color } else { return nil } }
    set {
      swatch.kind = .color(newValue)
      setAccessibilityValue(newValue?.name ?? "none")
    }
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 32) }

  // The swatch inside only draws; clicks belong to the bar button.
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

/// Shows a menu above a bar button, inside the window, as Freeform's bar menus open.
@MainActor
func popUpAbove(_ menu: NSMenu, from view: NSView) {
  let height = menu.size.height
  let y = view.isFlipped ? -height - 6 : view.bounds.height + height + 6
  menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
}

/// Shows a popover above a bar button.
@MainActor
func popoverAbove(_ content: NSView, from view: NSView) -> NSPopover {
  let controller = NSViewController()
  controller.view = content
  let popover = NSPopover()
  popover.contentViewController = controller
  popover.behavior = .transient
  popover.animates = !AppPreferences.isAutomatedCheck
  popover.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
  return popover
}

/// A stack of labelled rows with the margins a popover wants.
@MainActor
func popoverStack(_ rows: [(String, NSView)]) -> NSView {
  let stack = NSStackView()
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 10
  stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
  for (title, control) in rows {
    if title.isEmpty {
      stack.addArrangedSubview(control)
      continue
    }
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.textColor = .secondaryLabelColor
    let section = NSStackView(views: [label, control])
    section.orientation = .vertical
    section.alignment = .leading
    section.spacing = 5
    stack.addArrangedSubview(section)
    control.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
  }
  return stack
}

/// Zoom out, the zoom level with a menu of levels, and zoom in, at the bottom left.
@MainActor
final class ZoomBar: NSObject {
  weak var canvas: CanvasView?
  let bar = Bar(label: "Zoom")
  private(set) var level: BarButton!

  override init() {
    super.init()
    let out = BarButton(symbol: "minus", title: "Zoom Out (⌘−)", target: self, action: #selector(zoomOut(_:)))
    let into = BarButton(symbol: "plus", title: "Zoom In (⌘+)", target: self, action: #selector(zoomIn(_:)))
    level = BarButton(text: "100%", tip: "Choose a zoom level", target: self, action: #selector(showLevels(_:)))
    level.widthAnchor.constraint(equalToConstant: 60).isActive = true
    bar.set([out, level, into])
  }

  func update() {
    guard let canvas else { return }
    level.setText("\(canvas.zoomPercent)%")
    level.setAccessibilityLabel("Zoom \(canvas.zoomPercent) percent")
  }

  @objc private func zoomOut(_ sender: Any?) { canvas?.zoomOut(sender) }
  @objc private func zoomIn(_ sender: Any?) { canvas?.zoomIn(sender) }

  func levelsMenu() -> NSMenu {
    let menu = NSMenu(title: "Zoom")
    guard let canvas else { return menu }
    for percent in [25, 50, 100, 200, 400] {
      let item = menu.addItem(withTitle: "\(percent)%", action: #selector(zoomTo(_:)), keyEquivalent: "")
      item.tag = percent
      item.target = self
      item.state = canvas.zoomPercent == percent ? .on : .off
    }
    menu.addItem(.separator())
    let fit = menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasView.zoomToFit(_:)), keyEquivalent: "9")
    fit.target = canvas
    let selection = menu.addItem(withTitle: "Zoom to Selection", action: #selector(CanvasView.zoomToSelection(_:)), keyEquivalent: "9")
    selection.keyEquivalentModifierMask = [.command, .option]
    selection.target = canvas
    let actual = menu.addItem(withTitle: "Actual Size", action: #selector(CanvasView.actualSize(_:)), keyEquivalent: "0")
    actual.target = canvas
    return menu
  }

  @objc private func showLevels(_ sender: NSButton) { popUpAbove(levelsMenu(), from: sender) }

  @objc func zoomTo(_ sender: NSMenuItem) { canvas?.zoom(to: CGFloat(sender.tag) / 100) }
}

/// The grid, the frame, and the canvas's other options, at the bottom right.
@MainActor
final class CanvasBar: NSObject {
  weak var canvas: CanvasView?
  weak var editor: Editor?
  let bar = Bar(label: "Canvas")
  let grid: BarButton
  let frame: BarButton
  let options: BarButton

  override init() {
    grid = BarButton(symbol: "circle.grid.3x3.fill", title: "Show Grid (⌘')", target: nil, action: #selector(Editor.toggleGrid(_:)))
    frame = BarButton(symbol: "viewfinder", title: "Frame", target: nil, action: #selector(CanvasView.toggleFrame(_:)))
    options = BarButton(symbol: "ellipsis", title: "Canvas Options", target: nil, action: nil)
    super.init()
    options.target = self
    options.action = #selector(showOptions(_:))
    bar.set([grid, frame, options])
  }

  func update() {
    // Sent straight to the window's own canvas and editor, whichever window is key.
    grid.target = editor
    frame.target = canvas
    grid.isOn = UserDefaults.standard.bool(forKey: PreferenceKey.showsGrid)
    let framed = canvas?.scene.frame != nil
    frame.isOn = framed
    frame.toolTip = framed ? "Remove the frame" : "Add a frame: the part of the canvas that’s exported and printed"
  }

  func optionsMenu() -> NSMenu {
    let menu = NSMenu(title: "Canvas")
    guard let canvas, let editor else { return menu }
    let size = menu.addItem(withTitle: "Frame Size…", action: #selector(Editor.showFrameSize(_:)), keyEquivalent: "")
    size.target = editor
    let fit = menu.addItem(withTitle: "Fit Frame to Drawing", action: #selector(CanvasView.fitCanvasToDrawing(_:)), keyEquivalent: "")
    fit.target = canvas
    if canvas.scene.frame != nil {
      let remove = menu.addItem(withTitle: "Remove Frame", action: #selector(CanvasView.removeFrame(_:)), keyEquivalent: "")
      remove.target = canvas
    }
    menu.addItem(.separator())
    let header = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for (i, title) in ["None", "White", "Color…"].enumerated() {
      let item = menu.addItem(withTitle: title, action: #selector(Editor.chooseBackground(_:)), keyEquivalent: "")
      item.tag = i
      item.target = editor
    }
    menu.addItem(.separator())
    let guides = menu.addItem(withTitle: "Snap to Guides", action: #selector(Editor.toggleGuides(_:)), keyEquivalent: "")
    guides.target = editor
    let snap = menu.addItem(withTitle: "Snap to Grid", action: #selector(Editor.toggleSnapToGrid(_:)), keyEquivalent: "")
    snap.target = editor
    return menu
  }

  @objc private func showOptions(_ sender: NSButton) { popUpAbove(optionsMenu(), from: sender) }
}

/// The bar at the bottom centre that changes with what's being done, as Freeform's does: the
/// brush, its width, and its color while drawing; the colors, line, and text of a selection,
/// and a menu to arrange it. It hides when there's nothing to style.
@MainActor
final class StyleBar: NSObject {
  weak var canvas: CanvasView? {
    didSet { controls.canvas = canvas }
  }
  weak var editor: Editor?
  let bar = Bar(label: "Style")
  let controls = Controls()
  /// The controls in the popover that's open, kept current with the drawing.
  private var popoverControls: Controls?
  private(set) weak var popover: NSPopover?
  private var builtFor = ""

  func update() {
    guard let canvas else { return }
    let key = controls.key
    if key != builtFor {
      builtFor = key
      popover?.close()
      rebuild(canvas)
    }
    controls.refresh()
    popoverControls?.refresh()
  }

  private func rebuild(_ canvas: CanvasView) {
    controls.reset()
    let c = controls
    var views: [NSView] = []
    let kinds = c.kinds
    let tool = canvas.tool
    let selecting = c.selecting
    let lockedOnly = !selecting && canvas.drawing.selectedElements.contains(where: \.locked)

    func group(_ items: [NSView]) {
      guard !items.isEmpty else { return }
      if !views.isEmpty { views.append(Bar.divider()) }
      views += items
    }

    if canvas.frameSelected {
      let size = BarButton(text: "", tip: "Frame Size…", menu: false, target: editor, action: #selector(Editor.showFrameSize(_:)))
      c.onRefresh { [weak canvas, weak size] in
        guard let frame = canvas?.scene.frame else { return }
        size?.setText("\(Int(frame.width)) × \(Int(frame.height))")
      }
      group([size])
      group([
        BarButton(symbol: "arrow.up.left.and.arrow.down.right", title: "Fit Frame to Drawing", target: canvas, action: #selector(CanvasView.fitCanvasToDrawing(_:))),
        BarButton(symbol: "trash", title: "Remove Frame", target: canvas, action: #selector(CanvasView.removeFrame(_:))),
      ])
    } else if lockedOnly {
      group([BarButton(symbol: "lock.open", title: "Unlock All (⌥⌘L)", target: canvas, action: #selector(CanvasView.unlockAll(_:)))])
    } else {
      // Brushes, or the eraser's two ways of erasing.
      if !selecting && Controls.brushes.contains(tool) {
        group(Controls.brushes.map { brush in
          toggle(BarButton(symbol: brush.symbol, title: "\(brush.title) (\(brush.key.uppercased()))", target: nil, action: nil),
            on: { [weak canvas] in canvas?.tool == brush }) { [weak canvas] in canvas?.tool = brush }
        })
      } else if selecting && kinds == [.freehand] {
        group(zip(Controls.brushes, Element.Brush.allCases).map { tool, brush in
          toggle(BarButton(symbol: tool.symbol, title: tool.title, target: nil, action: nil),
            on: { [weak c] in c?.elements.first?.brush == brush }) { [weak c] in c?.setBrush(brush) }
        })
      } else if !selecting && (tool == .eraser || tool == .strokeEraser) {
        group([
          toggle(BarButton(symbol: "eraser", title: "Erase Objects", target: nil, action: nil),
            on: { [weak canvas] in canvas?.tool == .eraser }) { [weak canvas] in canvas?.tool = .eraser },
          toggle(BarButton(symbol: "eraser.line.dashed", title: "Erase Parts", target: nil, action: nil),
            on: { [weak canvas] in canvas?.tool == .strokeEraser }) { [weak canvas] in canvas?.tool = .strokeEraser },
        ])
      }
      // Colors.
      var colors: [NSView] = []
      if !selecting && tool == .fill {
        colors.append(swatch("Fill Color", allowsNone: false, value: { [weak c] in c?.fillColor }) { [weak c] in c?.setFillColor($0) })
      }
      if !kinds.isEmpty && kinds != [.image] {
        let none = c.hasShapes && !kinds.contains(.freehand) && !c.hasLines
        colors.append(swatch(kinds == [.text] ? "Text Color" : "Stroke Color", allowsNone: none, opacity: true, value: {
          [weak c] in c?.style.stroke
        }) { [weak canvas] color in canvas?.setStyle("Change Color") { $0.stroke = color } })
      }
      if c.hasShapes || kinds == [.text] {
        colors.append(swatch(kinds == [.text] ? "Background Color" : "Fill Color", allowsNone: true, value: { [weak c] in
          c?.style.fill
        }) { [weak canvas] color in canvas?.setStyle("Change Fill") { $0.fill = color } })
      }
      group(colors)
      // Widths, and the line's style.
      if c.hasShapes || c.hasLines || kinds.contains(.freehand) || (!selecting && (tool == .eraser || tool == .strokeEraser)) {
        group((0..<3).map { i in
          toggle(BarButton(image: Controls.widthImage(i), title: Controls.widthNames[i], target: nil, action: nil),
            on: { [weak c] in c?.widthIndex == i }) { [weak c] in c?.setWidth(i) }
        })
      }
      var line: [NSView] = []
      if c.hasShapes || c.hasLines {
        line.append(action(BarButton(image: Controls.dashImage(.dashed), title: "Line Style", target: nil, action: nil)) {
          [weak self] sender in self?.showLineStyle(sender)
        })
      }
      if c.hasLines {
        for start in [true, false] {
          let heads = Element.Arrowhead.allCases
          let button = BarButton(image: Controls.arrowImage(.none, start: start), title: start ? "Start Arrowhead" : "End Arrowhead", target: nil, action: nil)
          c.onRefresh { [weak c, weak button] in
            guard let c else { return }
            button?.image = Controls.arrowImage(start ? c.style.startArrowhead : c.style.endArrowhead, start: start)
          }
          line.append(action(button) { [weak canvas] sender in
            let menu = NSMenu(title: "Arrowhead")
            for head in heads {
              let item = menu.addItem(withTitle: head == .none ? "None" : head.rawValue.capitalized, action: nil, keyEquivalent: "")
              item.image = Controls.arrowImage(head, start: start)
              item.representedObject = head.rawValue
            }
            let relay = MenuRelay { item in
              guard let head = (item.representedObject as? String).flatMap(Element.Arrowhead.init(rawValue:)) else { return }
              canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
            }
            relay.attach(to: menu)
            popUpAbove(menu, from: sender)
          })
        }
      }
      group(line)
      // Text.
      if kinds.contains(.text) {
        let font = BarButton(text: "Sans", tip: "Font", menu: true, target: nil, action: nil)
        c.onRefresh { [weak c, weak font] in
          font?.setText(Controls.fonts.first { $0.name == c?.style.fontName }?.title ?? "Font", menu: true)
        }
        let size = BarButton(text: "M", tip: "Text Size", menu: true, target: nil, action: nil)
        c.onRefresh { [weak c, weak size] in
          guard let c else { return }
          size?.setText(Controls.sizes.first { abs($0.1 - c.style.fontSize) < 0.01 }?.0 ?? "\(Int(c.style.fontSize))", menu: true)
        }
        let align = BarButton(symbol: "text.alignleft", title: "Text Alignment", target: nil, action: nil)
        let symbols = ["text.alignleft", "text.aligncenter", "text.alignright"]
        c.onRefresh { [weak c, weak align] in
          guard let c, let i = Element.TextAlign.allCases.firstIndex(of: c.style.textAlign) else { return }
          align?.image = NSImage(systemSymbolName: symbols[i], accessibilityDescription: "Text Alignment")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        }
        group([
          action(font) { [weak canvas, weak c] sender in
            popUpAbove(Self.menu(Controls.fonts.map(\.title), chosen: Controls.fonts.firstIndex { $0.name == c?.style.fontName }) { i in
              canvas?.setStyle("Change Font") { $0.fontName = Controls.fonts[i].name }
            }, from: sender)
          },
          action(size) { [weak canvas, weak c] sender in
            popUpAbove(Self.menu(["Small", "Medium", "Large", "Extra Large"], chosen: Controls.sizes.firstIndex { abs($0.1 - (c?.style.fontSize ?? 0)) < 0.01 }) { i in
              canvas?.setStyle("Change Font Size") { $0.fontSize = Controls.sizes[i].1 }
            }, from: sender)
          },
          action(align) { [weak canvas, weak c] sender in
            popUpAbove(Self.menu(["Left", "Center", "Right"], chosen: c.flatMap { Element.TextAlign.allCases.firstIndex(of: $0.style.textAlign) }) { i in
              canvas?.setStyle("Align Text") { $0.textAlign = Element.TextAlign.allCases[i] }
            }, from: sender)
          },
        ])
      }
      if selecting {
        var tail: [NSView] = []
        if kinds == [.image] {
          tail.append(BarButton(symbol: "crop", title: "Crop Image", target: canvas, action: #selector(CanvasView.cropSelectedImage(_:))))
        }
        tail.append(action(BarButton(symbol: "ellipsis.circle", title: "Arrange", target: nil, action: nil)) { [weak self] sender in
          guard let self else { return }
          popUpAbove(self.arrangeMenu(), from: sender)
        })
        group(tail)
      }
    }
    bar.set(views)
    bar.isHidden = views.isEmpty
  }

  // MARK: Pieces

  private func toggle(_ button: BarButton, on: @escaping @MainActor () -> Bool, choose: @escaping @MainActor () -> Void) -> BarButton {
    controls.wire(button) { _ in choose() }
    controls.onRefresh { [weak button] in button?.isOn = on() }
    return button
  }

  private func action<Button: NSButton>(_ button: Button, _ body: @escaping @MainActor (NSButton) -> Void) -> Button {
    controls.wire(button) { sender in if let sender = sender as? NSButton { body(sender) } }
    return button
  }

  private func swatch(
    _ title: String, allowsNone: Bool, opacity: Bool = false, value: @escaping @MainActor () -> Color??,
    apply: @escaping @MainActor (Color?) -> Void
  ) -> BarSwatch {
    let swatch = BarSwatch(tip: title)
    swatch.display = controls.display
    controls.onRefresh { [weak swatch] in swatch?.color = value() ?? nil }
    return action(swatch) { [weak self] sender in
      guard let self, let canvas = self.canvas else { return }
      let popover = Controls()
      popover.canvas = canvas
      var rows: [(String, NSView)] = [(title, popover.colorGrid(allowsNone: allowsNone, value: value, apply: apply))]
      if opacity { rows.append(("Opacity", popover.opacitySlider())) }
      self.show(popover, rows, from: sender)
    }
  }

  private func showLineStyle(_ sender: NSButton) {
    guard let canvas else { return }
    let popover = Controls()
    popover.canvas = canvas
    var rows = popover.lineStyleControls()
    if !controls.kinds.isEmpty { rows.append(("Opacity", popover.opacitySlider())) }
    show(popover, rows, from: sender)
  }

  private func show(_ popoverControls: Controls, _ rows: [(String, NSView)], from sender: NSView) {
    popover?.close()
    self.popoverControls = popoverControls
    popoverControls.refresh()
    popover = popoverAbove(popoverStack(rows), from: sender)
  }

  private static func menu(_ titles: [String], chosen: Int?, choose: @escaping @MainActor (Int) -> Void) -> NSMenu {
    let menu = NSMenu(title: "")
    for (i, title) in titles.enumerated() {
      let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
      item.tag = i
      item.state = i == chosen ? .on : .off
    }
    MenuRelay { choose($0.tag) }.attach(to: menu)
    return menu
  }

  /// Layers, alignment, grouping, and the rest, as the Arrange menu has them.
  func arrangeMenu() -> NSMenu {
    let menu = NSMenu(title: "Arrange")
    guard let canvas else { return menu }
    func add(_ title: String, _ action: Selector, tag: Int = 0) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = canvas
      item.tag = tag
    }
    add("Bring to Front", #selector(CanvasView.bringToFront(_:)))
    add("Bring Forward", #selector(CanvasView.bringForward(_:)))
    add("Send Backward", #selector(CanvasView.sendBackward(_:)))
    add("Send to Back", #selector(CanvasView.sendToBack(_:)))
    if controls.elements.count > 1 {
      menu.addItem(.separator())
      for (i, title) in ["Align Left", "Align Center", "Align Right", "Align Top", "Align Middle", "Align Bottom"].enumerated() {
        add(title, #selector(CanvasView.alignObjects(_:)), tag: i)
      }
    }
    menu.addItem(.separator())
    if controls.elements.contains(where: { !$0.groups.isEmpty }) {
      add("Ungroup", #selector(CanvasView.ungroup(_:)))
    } else if controls.elements.count > 1 {
      add("Group", #selector(CanvasView.group(_:)))
    }
    add("Lock", #selector(CanvasView.lock(_:)))
    add("Duplicate", #selector(CanvasView.duplicate(_:)))
    add("Delete", #selector(CanvasView.delete(_:)))
    return menu
  }
}

/// Sends a menu's choices to a closure, kept alive as long as the menu.
@MainActor
final class MenuRelay: NSObject {
  private let body: @MainActor (NSMenuItem) -> Void
  nonisolated(unsafe) private static var key: UInt8 = 0

  init(_ body: @escaping @MainActor (NSMenuItem) -> Void) { self.body = body }

  func attach(to menu: NSMenu) {
    for item in menu.items where item.action == nil && !item.isSeparatorItem {
      item.target = self
      item.action = #selector(choose(_:))
    }
    objc_setAssociatedObject(menu, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
  }

  @objc private func choose(_ sender: NSMenuItem) { body(sender) }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
