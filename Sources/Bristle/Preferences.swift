import AppKit
import BristleCanvas
import BristleCore

enum PreferenceKey {
  static let appearance = "appearance"
  static let paperSize = "paperSize"
  static let transparentBackground = "transparentBackground"
  static let snapsToGuides = "snapsToGuides"
  static let showsGrid = "showsGrid"
  static let snapsToGrid = "snapsToGrid"
  static let gridSpacing = "gridSpacing"
  static let returnsToSelect = "returnsToSelect"
  static let inspectorVisible = "inspectorVisible"
  static let toolsVisible = "toolsVisible"
  /// Each tool's style, as JSON by tool name.
  static let toolStyles = "toolStyles"
  /// The last tool chosen in each group of the Tools column.
  static let toolVariants = "toolVariants"
  /// The content size of the window the user last resized, which new windows open at.
  static let windowSize = "windowSize"
}

enum AppAppearance: String, CaseIterable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var value: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// Sizes for new drawings, in points.
enum PaperSize: String, CaseIterable {
  case standard, widescreen, laptop, square, letter, a4

  var title: String {
    switch self {
    case .standard: "1600 × 1000"
    case .widescreen: "1920 × 1080 (HD)"
    case .laptop: "1280 × 800"
    case .square: "1080 × 1080"
    case .letter: "US Letter"
    case .a4: "A4"
    }
  }

  var size: CGSize {
    switch self {
    case .standard: CGSize(width: 1600, height: 1000)
    case .widescreen: CGSize(width: 1920, height: 1080)
    case .laptop: CGSize(width: 1280, height: 800)
    case .square: CGSize(width: 1080, height: 1080)
    case .letter: CGSize(width: 612, height: 792)
    case .a4: CGSize(width: 595, height: 842)
    }
  }
}

extension Notification.Name {
  static let canvasDefaultsDidChange = Notification.Name("BristleCanvasDefaultsDidChange")
}

enum AppPreferences {
  static let settingKeys = [
    PreferenceKey.appearance, PreferenceKey.paperSize, PreferenceKey.transparentBackground,
    PreferenceKey.snapsToGuides, PreferenceKey.gridSpacing, PreferenceKey.returnsToSelect,
  ]

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      PreferenceKey.appearance: AppAppearance.system.rawValue,
      PreferenceKey.paperSize: PaperSize.standard.rawValue,
      PreferenceKey.transparentBackground: false,
      PreferenceKey.snapsToGuides: true,
      PreferenceKey.showsGrid: false,
      PreferenceKey.snapsToGrid: false,
      PreferenceKey.gridSpacing: 20,
      PreferenceKey.returnsToSelect: false,
      PreferenceKey.inspectorVisible: true,
      PreferenceKey.toolsVisible: true,
    ])
  }

  static var appearance: AppAppearance {
    AppAppearance(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.appearance) ?? "") ?? .system
  }

  @MainActor static func applyAppearance() { NSApp.appearance = appearance.value }

  static var paperSize: PaperSize {
    PaperSize(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.paperSize) ?? "") ?? .standard
  }

  /// The paper new drawings start with.
  static var newPaper: Paper {
    let size = paperSize.size
    let transparent = UserDefaults.standard.bool(forKey: PreferenceKey.transparentBackground)
    return Paper(width: size.width, height: size.height, background: transparent ? nil : .white)
  }

  static var gridSpacing: CGFloat {
    let value = UserDefaults.standard.double(forKey: PreferenceKey.gridSpacing)
    return [8, 10, 16, 20, 25, 32, 50].contains(value) ? value : 20
  }

  static var canvasConfiguration: CanvasConfiguration {
    let defaults = UserDefaults.standard
    var configuration = CanvasConfiguration()
    configuration.snapsToGuides = defaults.bool(forKey: PreferenceKey.snapsToGuides)
    configuration.showsGrid = defaults.bool(forKey: PreferenceKey.showsGrid)
    configuration.snapsToGrid = defaults.bool(forKey: PreferenceKey.snapsToGrid)
    configuration.gridSpacing = gridSpacing
    configuration.returnsToSelect = defaults.bool(forKey: PreferenceKey.returnsToSelect)
    return configuration
  }

  /// The styles each tool had when last used, shared by every window.
  static var toolStyles: [Tool: Style] {
    get {
      var styles = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, $0.defaultStyle) })
      let stored = UserDefaults.standard.dictionary(forKey: PreferenceKey.toolStyles) as? [String: String] ?? [:]
      for (name, json) in stored {
        if let tool = Tool(rawValue: name), let style = Style(json: json) { styles[tool] = style }
      }
      return styles
    }
    set {
      let stored = Dictionary(uniqueKeysWithValues: newValue.filter { $0.value != $0.key.defaultStyle }.map { ($0.key.rawValue, $0.value.json) })
      UserDefaults.standard.set(stored, forKey: PreferenceKey.toolStyles)
    }
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  private let appearanceControl = NSSegmentedControl(
    labels: AppAppearance.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let paperSize = NSPopUpButton()
  private let background = NSPopUpButton()
  private let gridSpacing = NSPopUpButton()
  private let guides = NSButton(checkboxWithTitle: "Snap to alignment guides", target: nil, action: nil)
  private let returnsToSelect = NSButton(
    checkboxWithTitle: "Return to Select after adding a shape, line, or text", target: nil, action: nil)

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled, .closable], backing: .buffered,
      defer: false)
    window.title = "Bristle Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false

    for size in PaperSize.allCases {
      paperSize.addItem(withTitle: size.title)
      paperSize.lastItem?.representedObject = size.rawValue
    }
    background.addItems(withTitles: ["White", "Transparent"])
    for spacing in [8, 10, 16, 20, 25, 32, 50] {
      gridSpacing.addItem(withTitle: "\(spacing) points")
      gridSpacing.lastItem?.tag = spacing
    }
    for control in [appearanceControl, paperSize, background, gridSpacing, guides, returnsToSelect] as [NSControl] {
      control.target = self
      control.action = #selector(changeOption)
    }

    func describe(_ control: NSView, _ text: String) {
      control.toolTip = text
      control.setAccessibilityHelp(text)
    }
    describe(appearanceControl, "Follow the system appearance or always use Light or Dark. Drawings keep their own colors.")
    describe(paperSize, "Choose the canvas size for new drawings. Canvas ▸ Canvas Size changes it for a drawing.")
    describe(background, "Choose whether new drawings start on white or on a transparent canvas.")
    describe(gridSpacing, "Set the spacing of the grid shown with View ▸ Show Grid.")
    describe(guides, "While moving and resizing, line up edges and centers with other objects and the canvas. Hold ⌘ to place freely.")
    describe(returnsToSelect, "After adding one shape, line, or text box, switch back to the Select tool instead of keeping the tool.")

    let generalGrid = NSGridView(views: [
      [NSTextField(labelWithString: "Appearance:"), appearanceControl],
      [NSTextField(labelWithString: "New canvas size:"), paperSize],
      [NSTextField(labelWithString: "New canvas background:"), background],
    ])
    let canvasGrid = NSGridView(views: [[NSTextField(labelWithString: "Grid spacing:"), gridSpacing]])
    for grid in [generalGrid, canvasGrid] {
      grid.rowSpacing = 8
      grid.columnSpacing = 12
      grid.column(at: 0).xPlacement = .trailing
      grid.column(at: 1).width = 240
      grid.rowAlignment = .firstBaseline
    }
    let options = NSStackView(views: [guides, returnsToSelect])
    options.orientation = .vertical
    options.alignment = .leading
    options.spacing = 6
    let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
    describe(restore, "Reset every setting to its original value.")
    let buttons = NSStackView(views: [NSView(), restore])
    buttons.orientation = .horizontal

    func group(_ title: String, _ body: [NSView]) -> NSStackView {
      let heading = NSTextField(labelWithString: title)
      heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      let stack = NSStackView(views: [heading] + body)
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 8
      return stack
    }

    let content = NSStackView(views: [
      group("General", [generalGrid]), group("Canvas", [canvasGrid, options]), buttons,
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
    window.contentView = content
    canvasGrid.widthAnchor.constraint(equalTo: generalGrid.widthAnchor).isActive = true
    buttons.widthAnchor.constraint(equalTo: generalGrid.widthAnchor).isActive = true
    content.layoutSubtreeIfNeeded()
    window.setContentSize(content.fittingSize)
    sync()
  }

  required init?(coder: NSCoder) { fatalError() }

  func show() {
    sync()
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeFirstResponder(nil)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    appearanceControl.selectedSegment = AppAppearance.allCases.firstIndex(of: AppPreferences.appearance) ?? 0
    paperSize.selectItem(withTitle: AppPreferences.paperSize.title)
    background.selectItem(at: defaults.bool(forKey: PreferenceKey.transparentBackground) ? 1 : 0)
    gridSpacing.selectItem(withTag: Int(AppPreferences.gridSpacing))
    guides.state = defaults.bool(forKey: PreferenceKey.snapsToGuides) ? .on : .off
    returnsToSelect.state = defaults.bool(forKey: PreferenceKey.returnsToSelect) ? .on : .off
  }

  @objc private func changeOption() {
    let defaults = UserDefaults.standard
    if AppAppearance.allCases.indices.contains(appearanceControl.selectedSegment) {
      defaults.set(AppAppearance.allCases[appearanceControl.selectedSegment].rawValue, forKey: PreferenceKey.appearance)
    }
    if let size = paperSize.selectedItem?.representedObject as? String {
      defaults.set(size, forKey: PreferenceKey.paperSize)
    }
    defaults.set(background.indexOfSelectedItem == 1, forKey: PreferenceKey.transparentBackground)
    if let spacing = gridSpacing.selectedItem?.tag, spacing > 0 { defaults.set(spacing, forKey: PreferenceKey.gridSpacing) }
    defaults.set(guides.state == .on, forKey: PreferenceKey.snapsToGuides)
    defaults.set(returnsToSelect.state == .on, forKey: PreferenceKey.returnsToSelect)
    AppPreferences.applyAppearance()
    NotificationCenter.default.post(name: .canvasDefaultsDidChange, object: nil)
  }

  @objc private func restoreDefaults() {
    AppPreferences.settingKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    AppPreferences.applyAppearance()
    sync()
    NotificationCenter.default.post(name: .canvasDefaultsDidChange, object: nil)
  }
}
