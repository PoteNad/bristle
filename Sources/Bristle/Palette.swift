import AppKit
import BristleCanvas
import BristleCore

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

  weak var canvas: CanvasView? {
    didSet { controls.canvas = canvas }
  }
  weak var editor: Editor?
  private let controls = Controls()
  private let stack = NSStackView()
  private let scroll = NSScrollView()
  private var builtFor = ""
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

  private var elements: [Element] { controls.elements }
  private var kinds: Set<Element.Kind> { controls.kinds }
  private var style: Style { controls.style }

  func update() {
    guard isViewLoaded, canvas != nil else { return }
    let key = controls.key
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
    let c = controls
    let kinds = self.kinds
    title(heading)
    if canvas.drawing.selectedElements.contains(where: \.locked) && elements.isEmpty {
      note("Locked. Arrange ▸ Unlock All (⌥⌘L) unlocks it.")
      return
    }
    if kinds.isEmpty && ![Tool.eraser, .strokeEraser, .fill].contains(canvas.tool) {
      canvasSection()
      return
    }
    let selecting = c.selecting
    let tool = canvas.tool
    let shapes = c.hasShapes, lines = c.hasLines
    let freehand = kinds.contains(.freehand)

    if !selecting && Controls.brushes.contains(tool) {
      add("Brush", c.segmented(
        symbols: Controls.brushes.map { ($0.symbol, $0.title) },
        selected: { Controls.brushes.firstIndex(of: canvas.tool) }
      ) { [weak canvas] i in canvas?.tool = Controls.brushes[i] })
    }
    if selecting && kinds == [.freehand] {
      let brushes = Element.Brush.allCases
      add("Brush", c.segmented(
        symbols: Controls.brushes.map { ($0.symbol, $0.title) },
        selected: { [weak c] in c?.elements.first.map { brushes.firstIndex(of: $0.brush) ?? 0 } }
      ) { [weak c] i in c?.setBrush(brushes[i]) })
    }
    if tool == .eraser || tool == .strokeEraser, !selecting {
      add("Erase", c.segmented(labels: ["Objects", "Parts"], selected: { canvas.tool == .strokeEraser ? 1 : 0 }) {
        [weak canvas] i in canvas?.tool = i == 0 ? .eraser : .strokeEraser
      })
      add("Size", widthControl())
    }
    if tool == .fill && !selecting {
      add("Fill with", c.colorRow(Controls.strokes + Controls.fills.dropFirst(), allowsNone: false, value: { [weak c] in
        c?.fillColor
      }) { [weak c] color in c?.setFillColor(color) })
    }
    if !kinds.isEmpty && kinds != [.image] {
      add(kinds == [.text] ? "Text color" : "Stroke", c.colorRow(Controls.strokes, allowsNone: shapes && !freehand && !lines, value: {
        [weak c] in c?.style.stroke
      }) { [weak canvas] color in canvas?.setStyle("Change Color") { $0.stroke = color } })
    }
    if shapes || kinds == [.text] {
      add(kinds == [.text] ? "Background" : "Fill", c.colorRow(Controls.fills, allowsNone: true, value: { [weak c] in
        c?.style.fill
      }) { [weak canvas] color in canvas?.setStyle("Change Fill") { $0.fill = color } })
    }
    if shapes || lines || freehand { add("Width", widthControl()) }
    for (title, control) in c.lineStyleControls() { add(title, control) }
    if lines {
      let heads = Element.Arrowhead.allCases
      let row = NSStackView(views: [arrowPopUp(heads, start: true), arrowPopUp(heads, start: false)])
      row.spacing = 6
      row.distribution = .fillEqually
      add("Arrowheads", row)
    }
    if kinds.contains(.text) {
      add("Font", c.segmented(images: Controls.fonts.map { (Controls.fontImage($0.name), $0.title) }, selected: { [weak c] in
        guard let name = c?.style.fontName else { return nil }
        return Controls.fonts.firstIndex { $0.name == name }
      }) { [weak canvas] i in canvas?.setStyle("Change Font") { $0.fontName = Controls.fonts[i].name } })
      add("Size", c.segmented(labels: Controls.sizes.map(\.0), selected: { [weak c] in
        guard let size = c?.style.fontSize else { return nil }
        return Controls.sizes.firstIndex { abs($0.1 - size) < 0.01 }
      }) { [weak canvas] i in canvas?.setStyle("Change Font Size") { $0.fontSize = Controls.sizes[i].1 } })
      add("Align", c.segmented(
        symbols: [("text.alignleft", "Align Left"), ("text.aligncenter", "Center"), ("text.alignright", "Align Right")],
        selected: { [weak c] in c.flatMap { Element.TextAlign.allCases.firstIndex(of: $0.style.textAlign) } }
      ) { [weak canvas] i in canvas?.setStyle("Align Text") { $0.textAlign = Element.TextAlign.allCases[i] } })
    }
    if !kinds.isEmpty { add("Opacity", c.opacitySlider()) }
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
    if Controls.brushes.contains(canvas.tool) { return "Draw" }
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
  /// When nothing is selected: the frame and the canvas's background.
  private func canvasSection() {
    guard let canvas else { return }
    let size = NSTextField(labelWithString: "")
    size.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    controls.onRefresh { [weak canvas] in
      guard let canvas else { return }
      size.stringValue = canvas.scene.frame.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "None"
    }
    let change = NSButton(title: "Frame Size…", target: editor, action: #selector(Editor.showFrameSize(_:)))
    let fit = NSButton(title: "Fit to Drawing", target: canvas, action: #selector(CanvasView.fitCanvasToDrawing(_:)))
    for button in [change, fit] { button.controlSize = .small }
    let buttons = NSStackView(views: [change, fit])
    buttons.spacing = 6
    let column = NSStackView(views: [size, buttons])
    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = 8
    add("Frame", column, fill: false)
    add("Background", controls.colorRow(Controls.fills, allowsNone: true, value: { [weak canvas] in canvas?.scene.paper.background }) {
      [weak canvas] color in canvas?.drawing.edit(color == nil ? "Clear Background" : "Background") { $0.paper.background = color }
    })
  }

  /// Three widths, as Excalidraw offers, suited to the tool, and a slider for any other.
  private func widthControl() -> NSView {
    let images = (0..<3).map { i in (Controls.lineImage(CGFloat(i) * 2.5 + 1.5), Controls.widthNames[i]) }
    let presets = controls.segmented(images: images, selected: { [weak controls] in controls?.widthIndex }) { [weak controls] i in
      controls?.setWidth(i)
    }
    let slider = controls.widthSlider()
    let column = NSStackView(views: [presets, slider])
    column.orientation = .vertical
    column.spacing = 8
    presets.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    slider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    return column
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

  private func arrowPopUp(_ heads: [Element.Arrowhead], start: Bool) -> NSPopUpButton {
    let popup = NSPopUpButton()
    popup.controlSize = .small
    for head in heads {
      popup.addItem(withTitle: head == .none ? "None" : head.rawValue.capitalized)
      popup.lastItem?.image = Controls.arrowImage(head, start: start)
    }
    // The button shows the arrowhead; its menu names them.
    (popup.cell as? NSPopUpButtonCell)?.imagePosition = .imageOnly
    popup.setAccessibilityLabel(start ? "Start arrowhead" : "End arrowhead")
    popup.toolTip = start ? "Start" : "End"
    controls.wire(popup) { [weak canvas] sender in
      guard let popup = sender as? NSPopUpButton else { return }
      let head = heads[max(0, popup.indexOfSelectedItem)]
      canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
    }
    controls.onRefresh { [weak self, weak popup] in
      guard let self else { return }
      popup?.selectItem(at: heads.firstIndex(of: start ? self.style.startArrowhead : self.style.endArrowhead) ?? 0)
    }
    return popup
  }
}
