import AppKit
import BristleCanvas
import BristleCore

/// The bar that floats above the selection, like Freeform's: its colors, line, text, and
/// arrangement, each a swatch or a menu rather than a sidebar.
@MainActor
final class FormatBar: NSObject {
  weak var canvas: CanvasView?
  let bar = Bar(label: "Format")
  private var builtFor = ""
  private var strokeSwatch: SwatchButton?
  private var fillSwatch: SwatchButton?
  /// Keeps the targets of the open menu's buttons alive.
  private var menuTargets: [ClosureTarget] = []

  private var elements: [Element] { canvas?.drawing.selectedElements.filter { !$0.locked } ?? [] }
  private var kinds: Set<Element.Kind> { Set(elements.map(\.kind)) }
  private var style: Style { elements.first.map(Style.init) ?? Style() }

  /// Rebuilds the controls when the kinds selected change, and refreshes their colors.
  func update() {
    let kinds = self.kinds
    let key = kinds.map(\.rawValue).sorted().joined(separator: ",") + "|\(elements.contains { !$0.groups.isEmpty })"
    if key != builtFor {
      builtFor = key
      rebuild(kinds)
    }
    let style = self.style
    strokeSwatch?.color = style.stroke
    fillSwatch?.color = style.fill
  }

  private func rebuild(_ kinds: Set<Element.Kind>) {
    var views: [NSView] = []
    strokeSwatch = nil
    fillSwatch = nil
    let shapes = !kinds.isDisjoint(with: [.rectangle, .ellipse, .polygon])
    let lines = !kinds.isDisjoint(with: [.line, .arrow])
    let texts = kinds.contains(.text)
    if shapes || kinds == [.text] {
      let fill = SwatchButton(color: nil, diameter: 18)
      fill.target = self
      fill.action = #selector(chooseFill(_:))
      fill.toolTip = kinds == [.text] ? "Background" : "Fill"
      fill.setAccessibilityLabel(fill.toolTip)
      fillSwatch = fill
      views.append(fill)
    }
    if !kinds.isEmpty && kinds != [.image] {
      let stroke = SwatchButton(color: nil, diameter: 18)
      stroke.ring = shapes
      stroke.target = self
      stroke.action = #selector(chooseStroke(_:))
      stroke.toolTip = shapes ? "Border" : texts && kinds.count == 1 ? "Text Color" : "Color"
      stroke.setAccessibilityLabel(stroke.toolTip)
      strokeSwatch = stroke
      views.append(stroke)
    }
    if shapes || lines || kinds.contains(.freehand) {
      views.append(barButton("lineweight", "Line", target: self, action: #selector(showLineMenu(_:))))
    }
    if texts {
      views.append(barButton("textformat.size", "Text", target: self, action: #selector(showTextMenu(_:))))
    }
    if kinds == [.image] {
      views.append(barButton("crop", "Crop", target: self, action: #selector(crop(_:))))
    }
    views.append(barButton("ellipsis.circle", "Arrange", target: self, action: #selector(showArrangeMenu(_:))))
    bar.set(views)
  }

  // MARK: Colors

  @objc private func chooseStroke(_ sender: SwatchButton) {
    guard let canvas else { return }
    let shapes = !kinds.isDisjoint(with: [.rectangle, .ellipse, .polygon])
    let target = PaletteTarget(
      title: sender.toolTip ?? "Color", color: style.stroke, allowsNone: shapes, opacity: style.opacity,
      apply: { [weak self, weak canvas] color in
        canvas?.setStyle("Change Color") { $0.stroke = color }
        self?.update()
      },
      applyOpacity: { [weak canvas] value in canvas?.setStyle("Change Opacity", coalescing: true) { $0.opacity = value } })
    PaletteViewController.show(target, relativeTo: sender, edge: .minY)
  }

  @objc private func chooseFill(_ sender: SwatchButton) {
    guard let canvas else { return }
    let target = PaletteTarget(
      title: sender.toolTip ?? "Fill", color: style.fill, allowsNone: true, opacity: style.opacity,
      apply: { [weak self, weak canvas] color in
        canvas?.setStyle("Change Fill") { $0.fill = color }
        self?.update()
      },
      applyOpacity: { [weak canvas] value in canvas?.setStyle("Change Opacity", coalescing: true) { $0.opacity = value } })
    PaletteViewController.show(target, relativeTo: sender, edge: .minY)
  }

  // MARK: Menus

  private func pop(_ menu: NSMenu, from sender: NSView) {
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    update()
  }

  private func item(_ menu: NSMenu, _ title: String, _ on: Bool = false, _ body: @escaping @MainActor () -> Void) {
    let target = ClosureTarget { _ in body() }
    let item = menu.addItem(withTitle: title, action: #selector(ClosureTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.state = on ? .on : .off
  }

  @objc func showLineMenu(_ sender: NSButton) {
    guard let canvas else { return }
    let menu = NSMenu(title: "Line")
    menuTargets = []
    let style = self.style
    let kinds = self.kinds
    let widths: [CGFloat] = kinds == [.freehand] ? [2, 4, 8, 14, 24] : [1, 2, 3, 6, 10]
    let row = NSStackView()
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    for (i, width) in widths.enumerated() {
      let target = ClosureTarget { [weak canvas] sender in
        canvas?.setStyle("Change Line Width") { $0.strokeWidth = width }
        (sender as? NSView)?.enclosingMenuItem?.menu?.cancelTracking()
      }
      let button = NSButton(image: widthImage(CGFloat(i) * 2 + 1), target: target, action: #selector(ClosureTarget.fire(_:)))
      menuTargets.append(target)
      button.bezelStyle = .toolbar
      button.setButtonType(.pushOnPushOff)
      button.state = abs(style.strokeWidth - width) < 0.01 ? .on : .off
      button.toolTip = "\(Int(width)) point line"
      button.setAccessibilityLabel(button.toolTip)
      row.addArrangedSubview(button)
    }
    row.frame.size = row.fittingSize
    let widthItem = NSMenuItem()
    widthItem.view = row
    menu.addItem(widthItem)
    if kinds != [.freehand] {
      menu.addItem(.separator())
      for dash in Element.Dash.allCases {
        item(menu, dash.rawValue.capitalized, style.dash == dash) { [weak canvas] in canvas?.setStyle("Change Line") { $0.dash = dash } }
      }
    }
    if kinds == [.rectangle] {
      menu.addItem(.separator())
      item(menu, "Square Corners", style.cornerRadius == 0) { [weak canvas] in canvas?.setStyle("Square Corners") { $0.cornerRadius = 0 } }
      item(menu, "Rounded Corners", style.cornerRadius > 0) { [weak canvas] in canvas?.setStyle("Round Corners") { $0.cornerRadius = 16 } }
    }
    if !kinds.isDisjoint(with: [.line, .arrow]) {
      menu.addItem(.separator())
      for (title, start) in [("Start", true), ("End", false)] {
        let submenu = NSMenu(title: title)
        for head in Element.Arrowhead.allCases {
          let current = start ? style.startArrowhead : style.endArrowhead
          item(submenu, head == .none ? "None" : head.rawValue.capitalized, current == head) { [weak canvas] in
            canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
          }
        }
        let parent = menu.addItem(withTitle: "\(title) Arrowhead", action: nil, keyEquivalent: "")
        parent.submenu = submenu
      }
    }
    if !kinds.isDisjoint(with: [.line, .arrow, .polygon]) {
      menu.addItem(.separator())
      item(menu, "Curved", style.curved) { [weak canvas, style] in
        canvas?.setStyle(style.curved ? "Straighten" : "Curve") { $0.curved = !style.curved }
      }
    }
    pop(menu, from: sender)
  }

  @objc func showTextMenu(_ sender: NSButton) {
    guard let canvas else { return }
    let menu = NSMenu(title: "Text")
    let style = self.style
    let fonts = menu.addItem(withTitle: "Show Fonts", action: #selector(Editor.showFonts(_:)), keyEquivalent: "")
    fonts.target = canvas.window?.windowController
    menu.addItem(.separator())
    for size in [12, 16, 20, 24, 28, 36, 48, 64, 96] as [CGFloat] {
      item(menu, "\(Int(size)) pt", abs(style.fontSize - size) < 0.01) { [weak canvas] in
        canvas?.setStyle("Change Font Size") { $0.fontSize = size }
      }
    }
    menu.addItem(.separator())
    for (title, align) in [("Align Left", Element.TextAlign.left), ("Center", .center), ("Align Right", .right)] {
      item(menu, title, style.textAlign == align) { [weak canvas] in canvas?.setStyle("Align Text") { $0.textAlign = align } }
    }
    pop(menu, from: sender)
  }

  @objc private func crop(_ sender: Any?) {
    guard let canvas, let image = elements.first, image.kind == .image else { return }
    canvas.editContent(of: image)
    canvas.window?.makeFirstResponder(canvas)
  }

  /// Arranging, from the bar: the same commands as the Arrange menu.
  @objc func showArrangeMenu(_ sender: NSButton) {
    guard let canvas else { return }
    let menu = NSMenu(title: "Arrange")
    func add(_ title: String, _ action: Selector, tag: Int = 0) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = canvas
      item.tag = tag
    }
    add("Bring to Front", #selector(CanvasView.bringToFront(_:)))
    add("Bring Forward", #selector(CanvasView.bringForward(_:)))
    add("Send Backward", #selector(CanvasView.sendBackward(_:)))
    add("Send to Back", #selector(CanvasView.sendToBack(_:)))
    menu.addItem(.separator())
    let align = NSMenu(title: "Align")
    for (i, title) in ["Left", "Center", "Right", "Top", "Middle", "Bottom"].enumerated() {
      let item = align.addItem(withTitle: title, action: #selector(CanvasView.alignObjects(_:)), keyEquivalent: "")
      item.target = canvas
      item.tag = i
    }
    menu.addItem(withTitle: elements.count == 1 ? "Align to Canvas" : "Align", action: nil, keyEquivalent: "").submenu = align
    let distribute = NSMenu(title: "Distribute")
    for (title, action) in [("Horizontally", #selector(CanvasView.distributeHorizontally(_:))), ("Vertically", #selector(CanvasView.distributeVertically(_:)))] {
      distribute.addItem(withTitle: title, action: action, keyEquivalent: "").target = canvas
    }
    menu.addItem(withTitle: "Distribute", action: nil, keyEquivalent: "").submenu = distribute
    menu.addItem(.separator())
    add("Rotate Left", #selector(CanvasView.rotateLeft(_:)))
    add("Rotate Right", #selector(CanvasView.rotateRight(_:)))
    add("Flip Horizontally", #selector(CanvasView.flipHorizontal(_:)))
    add("Flip Vertically", #selector(CanvasView.flipVertical(_:)))
    menu.addItem(.separator())
    if elements.contains(where: { !$0.groups.isEmpty }) { add("Ungroup", #selector(CanvasView.ungroup(_:))) }
    if elements.count > 1 { add("Group", #selector(CanvasView.group(_:))) }
    add("Lock", #selector(CanvasView.lock(_:)))
    menu.addItem(.separator())
    add("Copy Style", #selector(CanvasView.copyStyle(_:)))
    add("Paste Style", #selector(CanvasView.pasteStyle(_:)))
    add("Duplicate", #selector(CanvasView.duplicate(_:)))
    add("Delete", #selector(CanvasView.delete(_:)))
    pop(menu, from: sender)
  }
}
