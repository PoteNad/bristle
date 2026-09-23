import AppKit
import BristleCanvas
import BristleCore

/// The inspector beside the canvas, like Keynote's and Pages' Format sidebar. It shows the
/// selection's style, text, arrangement, and image options, the current tool's style when
/// nothing is selected, and the canvas when the Select tool has nothing selected.
@MainActor
final class InspectorViewController: NSViewController {
  weak var canvas: CanvasView? {
    didSet {
      guard let canvas else { return }
      let center = NotificationCenter.default
      center.addObserver(self, selector: #selector(drawingChanged), name: .drawingDidChange, object: canvas.drawing)
      center.addObserver(
        self, selector: #selector(selectionChanged), name: .drawingSelectionDidChange, object: canvas.drawing)
    }
  }

  private let stack = NSStackView()
  private let scroll = NSScrollView()
  private var refreshers: [() -> Void] = []
  private var builtFor: String?
  private var refreshScheduled = false
  private let number = NumberFormatter()

  override func loadView() {
    let root = NSView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
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
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
    number.numberStyle = .decimal
    number.maximumFractionDigits = 1
    number.usesGroupingSeparator = false
    view = root
    view.setAccessibilityLabel("Inspector")
  }

  // MARK: What's shown

  private enum Subject: Equatable {
    case selection([String])
    case tool(Tool)
    case canvas
  }

  private var subject: Subject {
    guard let canvas else { return .canvas }
    let ids = canvas.drawing.selectedElements.map(\.id)
    if !ids.isEmpty { return .selection(ids) }
    return canvas.tool == .select || canvas.tool == .eyedropper ? .canvas : .tool(canvas.tool)
  }

  /// The elements being inspected.
  private var elements: [Element] { canvas?.drawing.selectedElements ?? [] }

  /// The kinds of element being inspected, or that the current tool makes.
  private var kinds: Set<Element.Kind> {
    switch subject {
    case .selection: return Set(elements.map(\.kind))
    case .tool(let tool):
      switch tool {
      case .pencil, .pen, .highlighter: return [.freehand]
      case .line: return [.line]
      case .arrow: return [.arrow]
      case .rectangle: return [.rectangle]
      case .ellipse: return [.ellipse]
      case .polygon: return [.polygon]
      case .text: return [.text]
      default: return []
      }
    case .canvas: return []
    }
  }

  private var style: Style {
    guard let canvas else { return Style() }
    return elements.first.map(Style.init) ?? canvas.style
  }

  @objc private func selectionChanged() { update() }

  @objc private func drawingChanged() {
    // Values follow the drawing while it changes, at most once per turn of the run loop.
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.refreshScheduled = false
        self.update()
      }
    }
  }

  /// Rebuilds the controls when what's inspected changes, and refreshes their values otherwise.
  func update() {
    guard isViewLoaded, let canvas else { return }
    let key = "\(subject)|\(kinds.map(\.rawValue).sorted())|\(elements.map(\.locked))|\(canvas.drawing.selection.count)"
    if key != builtFor {
      builtFor = key
      rebuild()
    }
    // Leave a field alone while it's being typed in.
    refreshers.forEach { $0() }
  }

  private func rebuild() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    refreshers = []
    let kinds = self.kinds
    stack.addArrangedSubview(header())
    let locked = elements.contains(where: \.locked)
    if locked {
      let note = label("Locked objects can't be changed. Choose Arrange ▸ Unlock All to change them.")
      note.textColor = .secondaryLabelColor
      stack.addArrangedSubview(note)
    }
    if !kinds.isEmpty && !locked { stack.addArrangedSubview(styleSection(kinds)) }
    if kinds.contains(.text) && !locked { stack.addArrangedSubview(textSection()) }
    if case .selection = subject, !locked {
      if kinds == [.image] { stack.addArrangedSubview(imageSection()) }
      stack.addArrangedSubview(arrangeSection())
    }
    if subject == .canvas { stack.addArrangedSubview(canvasSection()) }
    for view in stack.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
    }
  }

  private func header() -> NSView {
    let title: String
    switch subject {
    case .selection(let ids):
      if ids.count == 1, let element = elements.first {
        title = element.kindName
      } else if Set(elements.map(\.kind)).count == 1, let first = elements.first {
        title = "\(ids.count) \(first.kindName)s".replacingOccurrences(of: "Texts", with: "Text Boxes")
      } else {
        title = "\(ids.count) Objects"
      }
    case .tool(let tool): title = tool.title
    case .canvas: title = "Canvas"
    }
    let field = NSTextField(labelWithString: title)
    field.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold)
    field.setAccessibilityRole(.staticText)
    return field
  }

  // MARK: Sections

  private func section(_ title: String, _ rows: [[NSView]]) -> NSView {
    let heading = NSTextField(labelWithString: title)
    heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
    heading.textColor = .secondaryLabelColor
    let grid = NSGridView(views: rows)
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    for row in 0..<grid.numberOfRows where rows[row].count == 1 {
      grid.row(at: row).mergeCells(in: NSRange(location: 0, length: grid.numberOfColumns))
    }
    let stack = NSStackView(views: [heading, grid])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    return stack
  }

  private func label(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    return field
  }

  private func rowLabel(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

  private func styleSection(_ kinds: Set<Element.Kind>) -> NSView {
    var rows: [[NSView]] = []
    let shapes = !kinds.isDisjoint(with: [.rectangle, .ellipse, .polygon])
    let lines = !kinds.isDisjoint(with: [.line, .arrow])
    let freehand = kinds.contains(.freehand)
    if kinds != [.text] {
      // Outline: none, solid, dashed or dotted, and its colour.
      let popup = NSPopUpButton()
      let dashes = Element.Dash.allCases
      if !freehand && kinds != [.image] || kinds == [.image] { popup.addItem(withTitle: kinds == [.image] ? "No Border" : "None") }
      for dash in dashes where !freehand && kinds != [.image] {
        popup.addItem(withTitle: dash.rawValue.capitalized)
      }
      if kinds == [.image] { popup.addItem(withTitle: "Border") }
      let well = colorWell { [weak self] color in self?.canvas?.setStyle("Change Color", coalescing: true) { $0.stroke = color } }
      popup.target = self
      popup.action = #selector(strokeKindChanged(_:))
      popup.setAccessibilityLabel("Line")
      let line = NSStackView(views: freehand ? [well] : [popup, well])
      line.spacing = 6
      rows.append([rowLabel(freehand ? "Color:" : lines ? "Line:" : "Border:"), line])
      refreshers.append { [weak self] in
        guard let self else { return }
        let style = self.style
        if kinds == [.image] {
          popup.selectItem(at: style.stroke == nil ? 0 : 1)
        } else if !freehand {
          popup.selectItem(at: style.stroke == nil ? 0 : 1 + (dashes.firstIndex(of: style.dash) ?? 0))
        }
        well.isEnabled = style.stroke != nil || freehand
        if let stroke = style.stroke { well.color = NSColor(cgColor: stroke.cgColor) ?? .black }
      }
      let (slider, field) = numberControl(range: 0.5...64, logarithmic: true, name: "Width") { [weak self] value in
        self?.canvas?.setStyle("Change Line Width", coalescing: true) { $0.strokeWidth = value }
      }
      rows.append([rowLabel("Width:"), row(slider, field, unit: "pt")])
      refreshers.append { [weak self] in
        guard let self else { return }
        self.set(slider, field, self.style.strokeWidth, logarithmic: true)
      }
    }
    if shapes || kinds == [.text] {
      let popup = NSPopUpButton()
      popup.addItems(withTitles: ["None", "Color"])
      popup.target = self
      popup.action = #selector(fillKindChanged(_:))
      popup.setAccessibilityLabel(kinds == [.text] ? "Background" : "Fill")
      let well = colorWell { [weak self] color in self?.canvas?.setStyle("Change Fill", coalescing: true) { $0.fill = color } }
      let fill = NSStackView(views: [popup, well])
      fill.spacing = 6
      rows.append([rowLabel(kinds == [.text] ? "Background:" : "Fill:"), fill])
      refreshers.append { [weak self] in
        guard let self else { return }
        let style = self.style
        popup.selectItem(at: style.fill == nil ? 0 : 1)
        well.isEnabled = style.fill != nil
        if let fill = style.fill { well.color = NSColor(cgColor: fill.cgColor) ?? .white }
      }
    }
    if kinds == [.rectangle] {
      let (slider, field) = numberControl(range: 0...200, logarithmic: false, name: "Corner radius") { [weak self] value in
        self?.canvas?.setStyle("Change Corners", coalescing: true) { $0.cornerRadius = value }
      }
      rows.append([rowLabel("Corners:"), row(slider, field, unit: "pt")])
      refreshers.append { [weak self] in
        guard let self else { return }
        self.set(slider, field, self.style.cornerRadius, logarithmic: false)
      }
    }
    if lines {
      for end in ["Start", "End"] {
        let popup = NSPopUpButton()
        for head in Element.Arrowhead.allCases {
          popup.addItem(withTitle: head == .none ? "None" : head.rawValue.capitalized)
        }
        popup.setAccessibilityLabel("\(end) arrowhead")
        popup.identifier = NSUserInterfaceItemIdentifier(end)
        popup.target = self
        popup.action = #selector(arrowheadChanged(_:))
        rows.append([rowLabel("\(end):"), popup])
        refreshers.append { [weak self] in
          guard let self else { return }
          let head = end == "Start" ? self.style.startArrowhead : self.style.endArrowhead
          popup.selectItem(at: Element.Arrowhead.allCases.firstIndex(of: head) ?? 0)
        }
      }
    }
    if lines || kinds == [.polygon] {
      let curved = NSButton(checkboxWithTitle: "Curved", target: self, action: #selector(curvedChanged(_:)))
      rows.append([NSGridCell.emptyContentView, curved])
      refreshers.append { [weak self] in curved.state = self?.style.curved == true ? .on : .off }
    }
    let (slider, field) = numberControl(range: 5...100, logarithmic: false, name: "Opacity") { [weak self] value in
      self?.canvas?.setStyle("Change Opacity", coalescing: true) { $0.opacity = value / 100 }
    }
    rows.append([rowLabel("Opacity:"), row(slider, field, unit: "%")])
    refreshers.append { [weak self] in
      guard let self else { return }
      self.set(slider, field, (self.style.opacity * 100).rounded(), logarithmic: false)
    }
    return section("Style", rows)
  }

  private func textSection() -> NSView {
    var rows: [[NSView]] = []
    let font = NSTextField(labelWithString: "")
    font.lineBreakMode = .byTruncatingTail
    let fonts = NSButton(title: "Fonts…", target: nil, action: #selector(Editor.showFonts(_:)))
    fonts.controlSize = .small
    fonts.setAccessibilityLabel("Show Fonts")
    let fontRow = NSStackView(views: [font, fonts])
    fontRow.spacing = 6
    rows.append([rowLabel("Font:"), fontRow])
    let well = colorWell { [weak self] color in
      self?.canvas?.setStyle("Change Text Color", coalescing: true) { $0.stroke = color }
    }
    rows.append([rowLabel("Color:"), well])
    let size = NSTextField()
    size.formatter = number
    size.widthAnchor.constraint(equalToConstant: 52).isActive = true
    size.setAccessibilityLabel("Text size")
    let stepper = NSStepper()
    stepper.minValue = 4
    stepper.maxValue = 512
    stepper.increment = 1
    stepper.valueWraps = false
    let sizeAction = ClosureTarget { [weak self, weak size, weak stepper] sender in
      guard let self, let size, let stepper else { return }
      let value = (sender as AnyObject?) === stepper ? stepper.doubleValue : (self.number.number(from: size.stringValue)?.doubleValue ?? stepper.doubleValue)
      let points = min(512, max(4, value))
      self.canvas?.setStyle("Change Font Size", coalescing: true) { $0.fontSize = points }
    }
    size.target = sizeAction
    size.action = #selector(ClosureTarget.fire(_:))
    stepper.target = sizeAction
    stepper.action = #selector(ClosureTarget.fire(_:))
    targets.append(sizeAction)
    let sizeRow = NSStackView(views: [size, stepper, NSTextField(labelWithString: "pt")])
    sizeRow.spacing = 4
    rows.append([rowLabel("Size:"), sizeRow])
    let align = NSSegmentedControl(
      images: ["text.alignleft", "text.aligncenter", "text.alignright"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)!
      }, trackingMode: .selectOne, target: self, action: #selector(alignmentChanged(_:)))
    for (i, name) in ["Align Left", "Center", "Align Right"].enumerated() {
      align.setToolTip(name, forSegment: i)
      align.setLabel("", forSegment: i)
    }
    align.setAccessibilityLabel("Alignment")
    rows.append([rowLabel("Align:"), align])
    refreshers.append { [weak self, weak size, weak stepper] in
      guard let self, let size, let stepper else { return }
      let style = self.style
      let current = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
      font.stringValue = style.fontName.isEmpty ? "System" : (current.displayName ?? current.fontName)
      if let color = style.stroke { well.color = NSColor(cgColor: color.cgColor) ?? .black }
      if size.currentEditor() == nil { size.stringValue = self.number.string(from: NSNumber(value: Double(style.fontSize))) ?? "" }
      stepper.doubleValue = style.fontSize
      align.selectedSegment = Element.TextAlign.allCases.firstIndex(of: style.textAlign) ?? 0
    }
    return section("Text", rows)
  }

  private func imageSection() -> NSView {
    let crop = NSButton(title: "Crop", target: self, action: #selector(cropImage(_:)))
    crop.toolTip = "Drag the handles to crop the image; double-clicking an image does the same"
    let reset = NSButton(title: "Reset Crop", target: self, action: #selector(resetCrop(_:)))
    let original = NSButton(title: "Original Size", target: self, action: #selector(originalSize(_:)))
    let buttons = NSStackView(views: [crop, reset])
    buttons.spacing = 6
    refreshers.append { [weak self] in reset.isEnabled = self?.elements.contains { $0.crop != nil } == true }
    return section("Image", [[buttons], [original]])
  }

  private func arrangeSection() -> NSView {
    var rows: [[NSView]] = []
    // Position and size of the selection as a whole, as in Keynote's Arrange inspector.
    let fields = ["X", "Y", "W", "H"].map { name -> NSTextField in
      let field = NSTextField()
      field.formatter = number
      field.placeholderString = name
      field.setAccessibilityLabel(["X": "X position", "Y": "Y position", "W": "Width", "H": "Height"][name])
      field.widthAnchor.constraint(equalToConstant: 64).isActive = true
      field.target = self
      field.action = #selector(geometryChanged(_:))
      field.identifier = NSUserInterfaceItemIdentifier(name)
      return field
    }
    rows.append([rowLabel("Position:"), pair(fields[0], "X", fields[1], "Y")])
    rows.append([rowLabel("Size:"), pair(fields[2], "W", fields[3], "H")])
    let rotation = NSTextField()
    rotation.formatter = number
    rotation.widthAnchor.constraint(equalToConstant: 64).isActive = true
    rotation.identifier = NSUserInterfaceItemIdentifier("R")
    rotation.target = self
    rotation.action = #selector(geometryChanged(_:))
    rotation.setAccessibilityLabel("Rotation")
    let flipH = symbolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip Horizontally", #selector(CanvasView.flipHorizontal(_:)))
    let flipV = symbolButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip Vertically", #selector(CanvasView.flipVertical(_:)))
    let rotate = NSStackView(views: [rotation, NSTextField(labelWithString: "°"), flipH, flipV])
    rotate.spacing = 4
    rows.append([rowLabel("Rotate:"), rotate])
    refreshers.append { [weak self] in
      guard let self, let canvas = self.canvas else { return }
      let ids = canvas.drawing.selection
      let box = canvas.scene.frameBounds(of: ids)
      guard !box.isNull else { return }
      let values = [box.minX, box.minY, box.width, box.height]
      for (field, value) in zip(fields, values) where field.currentEditor() == nil {
        field.stringValue = self.number.string(from: NSNumber(value: Double(value))) ?? ""
      }
      let single = self.elements.count == 1 ? self.elements[0] : nil
      rotation.isEnabled = single != nil
      if rotation.currentEditor() == nil {
        let degrees = single.map { ($0.rotation * 180 / .pi).rounded() } ?? 0
        rotation.stringValue = self.number.string(from: NSNumber(value: Double(degrees > 180 ? degrees - 360 : degrees))) ?? ""
      }
    }
    let order = NSSegmentedControl(
      images: ["square.3.layers.3d.bottom.filled", "square.2.layers.3d.bottom.filled", "square.2.layers.3d.top.filled", "square.3.layers.3d.top.filled"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
      }, trackingMode: .momentary, target: self, action: #selector(orderChanged(_:)))
    for (i, name) in ["Send to Back", "Send Backward", "Bring Forward", "Bring to Front"].enumerated() {
      order.setToolTip(name, forSegment: i)
    }
    order.setAccessibilityLabel("Stacking order")
    rows.append([rowLabel("Order:"), order])
    let align = NSSegmentedControl(
      images: ["align.horizontal.left", "align.horizontal.center", "align.horizontal.right", "align.vertical.top", "align.vertical.center", "align.vertical.bottom"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
      }, trackingMode: .momentary, target: self, action: #selector(alignChanged(_:)))
    let alignNames = ["Left", "Center", "Right", "Top", "Middle", "Bottom"]
    for (i, name) in alignNames.enumerated() {
      align.setToolTip(elements.count == 1 ? "Align \(name) of Canvas" : "Align \(name)", forSegment: i)
    }
    align.setAccessibilityLabel("Align")
    rows.append([rowLabel("Align:"), align])
    let distribute = NSPopUpButton(frame: .zero, pullsDown: true)
    distribute.addItem(withTitle: "Distribute")
    distribute.addItem(withTitle: "Horizontally")
    distribute.lastItem?.action = #selector(CanvasView.distributeHorizontally(_:))
    distribute.lastItem?.target = canvas
    distribute.addItem(withTitle: "Vertically")
    distribute.lastItem?.action = #selector(CanvasView.distributeVertically(_:))
    distribute.lastItem?.target = canvas
    distribute.isEnabled = (canvas?.scene.unitCount(of: canvas?.drawing.selection ?? []) ?? 0) >= 3
    let group = NSButton(title: elements.contains { !$0.groups.isEmpty } ? "Ungroup" : "Group", target: canvas, action: nil)
    group.action = elements.contains { !$0.groups.isEmpty } ? #selector(CanvasView.ungroup(_:)) : #selector(CanvasView.group(_:))
    group.isEnabled = elements.count > 1 || elements.contains { !$0.groups.isEmpty }
    let lock = NSButton(title: "Lock", target: canvas, action: #selector(CanvasView.lock(_:)))
    lock.toolTip = "Keep the selection from being moved or changed (⌘L)"
    let more = NSStackView(views: [distribute, group, lock])
    more.spacing = 6
    rows.append([more])
    return section("Arrange", rows)
  }

  private func canvasSection() -> NSView {
    var rows: [[NSView]] = []
    let width = NSTextField(), height = NSTextField()
    for (field, name) in [(width, "W"), (height, "H")] {
      field.formatter = number
      field.widthAnchor.constraint(equalToConstant: 64).isActive = true
      field.identifier = NSUserInterfaceItemIdentifier(name)
      field.target = self
      field.action = #selector(paperSizeChanged(_:))
      field.setAccessibilityLabel(name == "W" ? "Canvas width" : "Canvas height")
    }
    rows.append([rowLabel("Size:"), pair(width, "W", height, "H")])
    let size = NSButton(title: "Canvas Size…", target: nil, action: #selector(Editor.showCanvasSize(_:)))
    let fit = NSButton(title: "Fit to Drawing", target: canvas, action: #selector(CanvasView.fitCanvasToDrawing(_:)))
    let buttons = NSStackView(views: [size, fit])
    buttons.spacing = 6
    rows.append([buttons])
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["Transparent", "Color"])
    popup.target = self
    popup.action = #selector(backgroundKindChanged(_:))
    popup.setAccessibilityLabel("Background")
    let well = colorWell { [weak self] color in
      self?.canvas?.drawing.coalesce("Change Background") { $0.paper.background = color }
    }
    let background = NSStackView(views: [popup, well])
    background.spacing = 6
    rows.append([rowLabel("Background:"), background])
    refreshers.append { [weak self] in
      guard let self, let paper = self.canvas?.scene.paper else { return }
      if width.currentEditor() == nil { width.stringValue = self.number.string(from: NSNumber(value: Double(paper.width))) ?? "" }
      if height.currentEditor() == nil { height.stringValue = self.number.string(from: NSNumber(value: Double(paper.height))) ?? "" }
      popup.selectItem(at: paper.background == nil ? 0 : 1)
      well.isEnabled = paper.background != nil
      if let color = paper.background { well.color = NSColor(cgColor: color.cgColor) ?? .white }
      fit.isEnabled = self.canvas?.scene.elements.isEmpty == false
    }
    let hint = label("Objects outside the canvas are kept but left out of exports and printing.")
    hint.textColor = .secondaryLabelColor
    rows.append([hint])
    return section("Canvas", rows)
  }

  // MARK: Controls

  private var targets: [ClosureTarget] = []

  /// A colour well that opens the Palette.
  private func colorWell(_ change: @escaping (Color) -> Void) -> NSColorWell {
    let well = NSColorWell(style: .default)
    well.widthAnchor.constraint(equalToConstant: 44).isActive = true
    let target = ClosureTarget { sender in
      if let well = sender as? NSColorWell, let color = Color(well.color.cgColor) { change(color) }
    }
    targets.append(target)
    well.target = target
    well.action = #selector(ClosureTarget.fire(_:))
    well.setAccessibilityLabel("Color")
    return well
  }

  private func numberControl(
    range: ClosedRange<CGFloat>, logarithmic: Bool, name: String, _ change: @escaping (CGFloat) -> Void
  ) -> (NSSlider, NSTextField) {
    let slider = NSSlider()
    slider.minValue = logarithmic ? log(range.lowerBound) : range.lowerBound
    slider.maxValue = logarithmic ? log(range.upperBound) : range.upperBound
    slider.isContinuous = true
    slider.controlSize = .small
    slider.setAccessibilityLabel(name)
    let field = NSTextField()
    field.formatter = number
    field.widthAnchor.constraint(equalToConstant: 46).isActive = true
    field.setAccessibilityLabel(name)
    let target = ClosureTarget { [weak slider, weak field, weak self] sender in
      guard let slider, let field, let self else { return }
      var value: CGFloat
      if (sender as AnyObject?) === slider {
        value = logarithmic ? exp(slider.doubleValue) : slider.doubleValue
        value = value < 10 ? (value * 2).rounded() / 2 : value.rounded()
        field.stringValue = self.number.string(from: NSNumber(value: Double(value))) ?? ""
      } else {
        guard let typed = self.number.number(from: field.stringValue)?.doubleValue else { return }
        value = min(range.upperBound, max(range.lowerBound, typed))
      }
      change(value)
    }
    targets.append(target)
    for control in [slider, field] as [NSControl] {
      control.target = target
      control.action = #selector(ClosureTarget.fire(_:))
    }
    return (slider, field)
  }

  private func set(_ slider: NSSlider, _ field: NSTextField, _ value: CGFloat, logarithmic: Bool) {
    slider.doubleValue = logarithmic ? log(max(value, 0.01)) : value
    if field.currentEditor() == nil { field.stringValue = number.string(from: NSNumber(value: Double(value))) ?? "" }
  }

  private func row(_ slider: NSSlider, _ field: NSTextField, unit: String) -> NSView {
    let stack = NSStackView(views: [slider, field, NSTextField(labelWithString: unit)])
    stack.spacing = 4
    slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
    return stack
  }

  private func pair(_ a: NSTextField, _ aLabel: String, _ b: NSTextField, _ bLabel: String) -> NSView {
    func small(_ text: String) -> NSTextField {
      let field = NSTextField(labelWithString: text)
      field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      field.textColor = .secondaryLabelColor
      return field
    }
    let stack = NSStackView(views: [a, small(aLabel), b, small(bLabel)])
    stack.spacing = 4
    return stack
  }

  private func symbolButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
    let button = NSButton(image: image, target: canvas, action: action)
    button.bezelStyle = .toolbar
    button.toolTip = title
    button.setAccessibilityLabel(title)
    return button
  }

  // MARK: Actions

  @objc private func strokeKindChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    let kinds = self.kinds
    let fallback = style.stroke ?? .ink
    canvas?.setStyle("Change Line") { style in
      if index == 0 {
        style.stroke = nil
      } else {
        if style.stroke == nil { style.stroke = fallback }
        if kinds == [.image] {
          if style.strokeWidth == 0 { style.strokeWidth = 3 }
        } else {
          style.dash = Element.Dash.allCases[index - 1]
        }
      }
    }
  }

  @objc private func fillKindChanged(_ sender: NSPopUpButton) {
    let on = sender.indexOfSelectedItem == 1
    canvas?.setStyle("Change Fill") { $0.fill = on ? ($0.fill ?? Color(hex: "#FFFFFF")) : nil }
  }

  @objc private func arrowheadChanged(_ sender: NSPopUpButton) {
    let head = Element.Arrowhead.allCases[max(0, sender.indexOfSelectedItem)]
    let start = sender.identifier?.rawValue == "Start"
    canvas?.setStyle("Change Arrowhead") { if start { $0.startArrowhead = head } else { $0.endArrowhead = head } }
  }

  @objc private func curvedChanged(_ sender: NSButton) {
    let on = sender.state == .on
    canvas?.setStyle(on ? "Curve Line" : "Straighten Line") { $0.curved = on }
  }

  @objc private func alignmentChanged(_ sender: NSSegmentedControl) {
    let align = Element.TextAlign.allCases[max(0, sender.selectedSegment)]
    canvas?.setStyle("Align Text") { $0.textAlign = align }
  }

  @objc private func orderChanged(_ sender: NSSegmentedControl) {
    guard let canvas else { return }
    switch sender.selectedSegment {
    case 0: canvas.sendToBack(sender)
    case 1: canvas.sendBackward(sender)
    case 2: canvas.bringForward(sender)
    default: canvas.bringToFront(sender)
    }
  }

  @objc private func alignChanged(_ sender: NSSegmentedControl) {
    let item = NSMenuItem()
    item.tag = sender.selectedSegment
    canvas?.alignObjects(item)
  }

  @objc private func geometryChanged(_ sender: NSTextField) {
    guard let canvas, let value = number.number(from: sender.stringValue).map({ CGFloat($0.doubleValue) }) else {
      return update()
    }
    let ids = canvas.drawing.selection.filter { canvas.scene[$0]?.locked == false }
    let box = canvas.scene.frameBounds(of: ids)
    guard !ids.isEmpty, !box.isNull else { return }
    switch sender.identifier?.rawValue {
    case "X": canvas.drawing.edit("Move") { $0.move(ids, dx: value - box.minX, dy: 0) }
    case "Y": canvas.drawing.edit("Move") { $0.move(ids, dx: 0, dy: value - box.minY) }
    case "W", "H":
      let width = sender.identifier?.rawValue == "W"
      guard value >= 1 else { return update() }
      let sx = width ? value / max(box.width, 0.001) : 1, sy = width ? 1 : value / max(box.height, 0.001)
      canvas.drawing.edit("Resize") { scene in
        for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
          var e = scene.elements[i]
          let c = e.center
          let center = CGPoint(x: box.minX + (c.x - box.minX) * sx, y: box.minY + (c.y - box.minY) * sy)
          let size = CGSize(width: e.width * sx, height: e.height * sy)
          e.resize(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
          if e.kind == .text { e.fitToText() }
          if e.isPointBased { e.fitFrameToPoints() }
          scene.elements[i] = e
        }
        scene.updateBindings(changed: ids)
      }
    case "R":
      guard let element = elements.first, elements.count == 1 else { return }
      let angle = value * .pi / 180 - element.rotation
      canvas.drawing.edit("Rotate") { $0.rotate(ids, by: angle, around: element.center) }
    default: break
    }
  }

  @objc private func paperSizeChanged(_ sender: NSTextField) {
    guard let canvas, let value = number.number(from: sender.stringValue).map({ CGFloat($0.doubleValue) }), value >= 1
    else { return update() }
    var size = CGSize(width: canvas.scene.paper.width, height: canvas.scene.paper.height)
    if sender.identifier?.rawValue == "W" { size.width = value } else { size.height = value }
    canvas.drawing.edit("Canvas Size") { $0.resizePaper(to: size) }
  }

  @objc private func backgroundKindChanged(_ sender: NSPopUpButton) {
    let transparent = sender.indexOfSelectedItem == 0
    canvas?.drawing.edit(transparent ? "Clear Background" : "Fill Background") { scene in
      scene.paper.background = transparent ? nil : (scene.paper.background ?? .white)
    }
  }

  @objc private func cropImage(_ sender: Any?) {
    guard let canvas, let image = elements.first, image.kind == .image else { return }
    canvas.editContent(of: image)
    view.window?.makeFirstResponder(canvas)
  }

  @objc private func resetCrop(_ sender: Any?) {
    guard let canvas else { return }
    let ids = Set(elements.filter { $0.kind == .image }.map(\.id))
    canvas.drawing.edit("Reset Crop") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
        guard let crop = scene.elements[i].crop else { continue }
        var e = scene.elements[i]
        let full = CGSize(width: e.width / crop.width, height: e.height / crop.height)
        let center = CGPoint(
          x: e.x - crop.minX * full.width + full.width / 2, y: e.y - crop.minY * full.height + full.height / 2
        ).applying(e.transform)
        e.frame = CGRect(x: center.x - full.width / 2, y: center.y - full.height / 2, width: full.width, height: full.height)
        e.crop = nil
        scene.elements[i] = e
      }
    }
  }

  @objc private func originalSize(_ sender: Any?) {
    guard let canvas else { return }
    let ids = Set(elements.filter { $0.kind == .image }.map(\.id))
    canvas.drawing.edit("Original Size") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
        var e = scene.elements[i]
        guard let data = scene.files[e.file]?.data, var size = ImageStore.pixelSize(of: data) else { continue }
        if let dpi = ImageStore.resolution(of: data), abs(dpi - scene.paper.resolution) > 1 {
          size = CGSize(width: size.width * scene.paper.resolution / dpi, height: size.height * scene.paper.resolution / dpi)
        }
        let crop = e.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let c = e.center
        let target = CGSize(width: size.width * crop.width, height: size.height * crop.height)
        e.frame = CGRect(x: c.x - target.width / 2, y: c.y - target.height / 2, width: target.width, height: target.height)
        scene.elements[i] = e
      }
    }
  }
}

/// Sends a control's action to a closure.
final class ClosureTarget: NSObject {
  let body: @MainActor (Any?) -> Void

  init(_ body: @escaping @MainActor (Any?) -> Void) { self.body = body }

  @MainActor @objc func fire(_ sender: Any?) { body(sender) }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
