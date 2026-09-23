import AppKit
import BristleCanvas
import BristleCore

/// The floating column of tools over the canvas. Tools come in groups; each group's button
/// shows the last tool used from it. Clicking the chosen tool again (or pressing and holding,
/// or Control-clicking) opens the group in place with its variants and a few quick settings,
/// and choosing one closes it again.
@MainActor
final class ToolsPalette: NSView {
  struct Group {
    var name: String
    var tools: [Tool]
  }

  static let groups: [Group] = [
    Group(name: "Select", tools: [.select]),
    Group(name: "Draw", tools: [.pencil, .pen, .highlighter]),
    Group(name: "Erase", tools: [.eraser, .strokeEraser]),
    Group(name: "Lines", tools: [.line, .arrow]),
    Group(name: "Shapes", tools: [.rectangle, .ellipse, .polygon]),
    Group(name: "Text", tools: [.text]),
    Group(name: "Fill", tools: [.fill]),
    Group(name: "Eyedropper", tools: [.eyedropper]),
  ]

  /// Stroke widths offered in the quick settings, by tool.
  static func widths(for tool: Tool) -> [CGFloat] {
    switch tool {
    case .pencil: [1, 2, 3, 6]
    case .pen: [4, 8, 14, 24]
    case .highlighter: [12, 20, 32, 48]
    case .eraser, .strokeEraser: [8, 16, 32, 64]
    case .text: [16, 24, 36, 56]
    default: [1, 3, 6, 10]
    }
  }

  weak var canvas: CanvasView?
  private let column = NSStackView()
  private var buttons: [ToolButton] = []
  private let imageButton = ToolButton()
  private var expansion: NSView?
  private var expandedGroup: Int?
  private var widthControl: NSSegmentedControl?
  private var colorWell: NSColorWell?
  private var monitor: Any?
  /// The tool shown for each group.
  private var variants: [String: Tool] = [:]

  init() {
    super.init(frame: .zero)
    let stored = UserDefaults.standard.dictionary(forKey: PreferenceKey.toolVariants) as? [String: String] ?? [:]
    for group in Self.groups {
      variants[group.name] = stored[group.name].flatMap(Tool.init(rawValue:)).flatMap { group.tools.contains($0) ? $0 : nil }
        ?? group.tools[0]
    }
    column.orientation = .vertical
    column.spacing = 2
    column.edgeInsets = NSEdgeInsets(top: 6, left: 5, bottom: 6, right: 5)
    for (i, group) in Self.groups.enumerated() {
      let button = ToolButton()
      button.tag = i
      button.target = self
      button.action = #selector(pressGroup(_:))
      button.hasVariants = group.tools.count > 1 || Self.hasQuickSettings(group.tools[0])
      button.onHold = { [weak self] in self?.expand(i) }
      buttons.append(button)
      column.addArrangedSubview(button)
      if i == 0 || i == 4 || i == 7 {
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 4).isActive = true
        column.addArrangedSubview(gap)
      }
    }
    imageButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Insert Image")
    imageButton.toolTip = "Insert Image"
    imageButton.setAccessibilityLabel("Insert Image")
    imageButton.target = nil
    imageButton.action = #selector(Editor.insertImage(_:))
    column.addArrangedSubview(imageButton)
    let glass = Self.glass(around: column, cornerRadius: 20)
    addSubview(glass)
    glass.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthAnchor.constraint(greaterThanOrEqualTo: glass.widthAnchor),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.toolbar)
    setAccessibilityLabel("Tools")
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Liquid Glass on macOS 26 and later, and a toolbar material before it.
  static func glass(around content: NSView, cornerRadius: CGFloat) -> NSView {
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
    material.layer?.cornerRadius = cornerRadius / 1.6
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

  static func hasQuickSettings(_ tool: Tool) -> Bool { ![.select, .eyedropper].contains(tool) }

  /// Clicks go through to the canvas except over the column and an open group.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }

  func update() {
    guard let canvas else { return }
    for (i, group) in Self.groups.enumerated() {
      if group.tools.contains(canvas.tool) { variants[group.name] = canvas.tool }
      let tool = variants[group.name] ?? group.tools[0]
      let button = buttons[i]
      button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
      button.state = group.tools.contains(canvas.tool) ? .on : .off
      let key = tool.key.isEmpty ? "" : " (\(tool.key.uppercased()))"
      button.toolTip = tool.title + key
      button.setAccessibilityLabel(tool.title)
      button.setAccessibilityHelp(
        group.tools.count > 1 ? "Click again to choose another \(group.name.lowercased()) tool." : nil)
    }
    if !AppPreferences.isAutomatedCheck {
      UserDefaults.standard.set(variants.mapValues(\.rawValue), forKey: PreferenceKey.toolVariants)
    }
    if let expandedGroup { refreshQuickSettings(Self.groups[expandedGroup]) }
  }

  @objc private func pressGroup(_ sender: ToolButton) {
    guard let canvas else { return }
    // Pressing and holding already opened the group.
    if sender.didHold {
      sender.didHold = false
      return
    }
    let group = Self.groups[sender.tag]
    let tool = variants[group.name] ?? group.tools[0]
    if expandedGroup == sender.tag {
      collapse()
    } else if canvas.tool == tool, sender.hasVariants {
      expand(sender.tag)
    } else {
      collapse()
      canvas.tool = tool
    }
    window?.makeFirstResponder(canvas)
    update()
  }

  // MARK: Expanding a group

  func expand(_ index: Int) {
    collapse()
    guard let canvas, let window else { return }
    let group = Self.groups[index]
    if let tool = variants[group.name], canvas.tool != tool, !group.tools.contains(canvas.tool) { canvas.tool = tool }
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 2
    row.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 8)
    if group.tools.count > 1 {
      for tool in group.tools {
        let button = ToolButton()
        button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
        button.state = canvas.tool == tool ? .on : .off
        button.toolTip = tool.title + (tool.key.isEmpty ? "" : " (\(tool.key.uppercased()))")
        button.setAccessibilityLabel(tool.title)
        button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
        button.target = self
        button.action = #selector(chooseVariant(_:))
        row.addArrangedSubview(button)
      }
    }
    if Self.hasQuickSettings(canvas.tool) {
      if group.tools.count > 1 {
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.addArrangedSubview(divider)
      }
      let widths = Self.widths(for: canvas.tool)
      let control = NSSegmentedControl(images: widths.map { Self.dot($0, text: canvas.tool == .text) }, trackingMode: .selectOne, target: self, action: #selector(chooseWidth(_:)))
      control.segmentStyle = .separated
      for (i, width) in widths.enumerated() {
        control.setToolTip(canvas.tool == .text ? "\(Int(width)) point text" : "\(Int(width)) point line", forSegment: i)
      }
      control.setAccessibilityLabel(canvas.tool == .text ? "Text size" : "Line width")
      widthControl = control
      row.addArrangedSubview(control)
      if canvas.tool != .eraser && canvas.tool != .strokeEraser {
        let well = NSColorWell(style: .minimal)
        well.target = self
        well.action = #selector(chooseColor(_:))
        well.toolTip = canvas.tool == .fill ? "Fill color" : "Color"
        well.setAccessibilityLabel(well.toolTip)
        well.widthAnchor.constraint(equalToConstant: 38).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        colorWell = well
        row.addArrangedSubview(well)
      }
    }
    guard !row.arrangedSubviews.isEmpty else { return }
    let glass = Self.glass(around: row, cornerRadius: 18)
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    let button = buttons[index]
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: column.trailingAnchor, constant: 12),
      glass.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      trailingAnchor.constraint(greaterThanOrEqualTo: glass.trailingAnchor),
    ])
    expansion = glass
    expandedGroup = index
    refreshQuickSettings(group)
    NSAccessibility.post(element: glass, notification: .created)
    // A click anywhere else, or Escape, closes the group.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
      let type = event.type, keyCode = event.type == .keyDown ? event.keyCode : 0
      let location = event.locationInWindow, sameWindow = event.window === window
      let consumed = MainActor.assumeIsolated { () -> Bool in
        guard let self, let expansion = self.expansion, sameWindow else { return false }
        if type == .keyDown {
          guard keyCode == 53 else { return false }
          self.collapse()
          return true
        }
        let inside = expansion.bounds.contains(expansion.convert(location, from: nil))
        let inColumn = self.column.bounds.contains(self.column.convert(location, from: nil))
        if !inside && !inColumn && !NSColorPanel.shared.isVisible { self.collapse() }
        return false
      }
      return consumed ? nil : event
    }
  }

  func collapse() {
    expansion?.removeFromSuperview()
    expansion = nil
    expandedGroup = nil
    widthControl = nil
    colorWell = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  var isExpanded: Bool { expansion != nil }

  private func refreshQuickSettings(_ group: Group) {
    guard let canvas else { return }
    let style = canvas.style
    let widths = Self.widths(for: canvas.tool)
    let current = canvas.tool == .text ? style.fontSize : style.strokeWidth
    if let widthControl {
      let nearest = widths.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 0
      widthControl.selectedSegment = widths.contains(current) ? nearest : -1
    }
    if let colorWell, let color = style.stroke {
      colorWell.color = NSColor(cgColor: color.cgColor) ?? .black
    }
  }

  @objc private func chooseVariant(_ sender: NSButton) {
    guard let name = sender.identifier?.rawValue, let tool = Tool(rawValue: name), let canvas else { return }
    canvas.tool = tool
    collapse()
    update()
    window?.makeFirstResponder(canvas)
  }

  @objc private func chooseWidth(_ sender: NSSegmentedControl) {
    guard let canvas, sender.selectedSegment >= 0 else { return }
    let widths = Self.widths(for: canvas.tool)
    let value = widths[sender.selectedSegment]
    if canvas.tool == .text {
      canvas.setStyle("Change Font Size") { $0.fontSize = value }
    } else {
      canvas.setStyle("Change Line Width") { $0.strokeWidth = value }
    }
    if canvas.drawing.selection.isEmpty { canvas.delegate?.canvasViewStylesDidChange(canvas) }
    collapse()
  }

  @objc private func chooseColor(_ sender: NSColorWell) {
    guard let canvas, let color = Color(sender.color.cgColor) else { return }
    canvas.setStyle("Change Color", coalescing: true) { $0.stroke = color }
  }

  /// A dot as wide as the line it stands for, or a letter for text sizes.
  static func dot(_ width: CGFloat, text: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
      NSColor.labelColor.setFill()
      if text {
        let size = 7 + width / 5
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor]
        let string = NSAttributedString(string: "A", attributes: attributes)
        let s = string.size()
        string.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
      } else {
        let d = min(14, max(2, sqrt(width) * 2.4))
        NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}

/// A tool button. Groups with more tools show a small corner mark, and pressing and holding
/// opens the group.
final class ToolButton: NSButton {
  var hasVariants = false { didSet { needsDisplay = true } }
  var onHold: (() -> Void)?
  /// Set when pressing and holding opened the group, so the release doesn't also act.
  var didHold = false
  private var holdTimer: Timer?

  init() {
    super.init(frame: .zero)
    setButtonType(.pushOnPushOff)
    bezelStyle = .toolbar
    isBordered = true
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    widthAnchor.constraint(equalToConstant: 34).isActive = true
    heightAnchor.constraint(equalToConstant: 30).isActive = true
    setContentHuggingPriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard hasVariants else { return }
    let r = bounds
    let edge = isFlipped ? r.maxY - 3 : r.minY + 3
    let inward: CGFloat = isFlipped ? -5 : 5
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: r.maxX - 3, y: edge))
    mark.line(to: NSPoint(x: r.maxX - 3, y: edge + inward))
    mark.line(to: NSPoint(x: r.maxX - 8, y: edge))
    mark.close()
    NSColor.secondaryLabelColor.setFill()
    mark.fill()
  }

  override func mouseDown(with event: NSEvent) {
    guard onHold != nil else { return super.mouseDown(with: event) }
    didHold = false
    let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.holdTimer = nil
        self.didHold = true
        self.onHold?()
      }
    }
    // The button tracks the mouse in the event-tracking run loop mode, so the timer runs there too.
    RunLoop.main.add(timer, forMode: .common)
    holdTimer = timer
    super.mouseDown(with: event)
    holdTimer?.invalidate()
    holdTimer = nil
  }

  override func rightMouseDown(with event: NSEvent) {
    if let onHold { onHold() } else { super.rightMouseDown(with: event) }
  }
}
