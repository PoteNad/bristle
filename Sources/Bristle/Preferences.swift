import AppKit
import BristleCanvas
import BristleCore

enum PreferenceKey {
  static let appearance = "appearance"
  static let snapsToGuides = "snapsToGuides"
  static let showsGrid = "showsGrid"
  static let showsRulers = "showsRulers"
  static let snapsToGrid = "snapsToGrid"
  static let gridSpacing = "gridSpacing"
  static let returnsToSelect = "returnsToSelect"
  static let paletteVisible = "paletteVisible"
  /// Whether the style bar steps aside while the Palette, which has all it has, is open.
  static let barHidesWithPalette = "barHidesWithPalette"
  /// Whether the bars over the canvas show only when the pointer comes near them.
  static let barsAutoHide = "barsAutoHide"
  /// Each tool's style, as JSON by tool name.
  static let toolStyles = "toolStyles"
  /// The content size of the window the user last resized, which new windows open at.
  static let windowSize = "windowSize"
  /// The canvas a new drawing starts with: its width and height, and whether it's transparent.
  static let newCanvasWidth = "newCanvasWidth"
  static let newCanvasHeight = "newCanvasHeight"
  static let newCanvasTransparent = "newCanvasTransparent"
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

/// Common canvas sizes, in points, offered by Canvas ▸ Canvas Size and the Palette.
enum CanvasSize: String, CaseIterable {
  case standard, hd, laptop, square, story, letter, a4

  var title: String {
    switch self {
    case .standard: "1200 × 800"
    case .hd: "1920 × 1080 (HD)"
    case .laptop: "1440 × 900"
    case .square: "1080 × 1080 (Square)"
    case .story: "1080 × 1920 (Portrait)"
    case .letter: "612 × 792 (US Letter)"
    case .a4: "595 × 842 (A4)"
    }
  }

  var size: CGSize {
    switch self {
    case .standard: Paper.standardSize
    case .hd: CGSize(width: 1920, height: 1080)
    case .laptop: CGSize(width: 1440, height: 900)
    case .square: CGSize(width: 1080, height: 1080)
    case .story: CGSize(width: 1080, height: 1920)
    case .letter: CGSize(width: 612, height: 792)
    case .a4: CGSize(width: 595, height: 842)
    }
  }
}

extension Notification.Name {
  static let canvasDefaultsDidChange = Notification.Name("BristleCanvasDefaultsDidChange")
}

enum AppPreferences {
  /// Automated checks must leave the user's settings, windows, and tool styles alone.
  static var isAutomatedCheck: Bool {
    #if BRISTLE_CHECKS
      AppChecks.isChecking
    #else
      false
    #endif
  }

  static let settingKeys = [
    PreferenceKey.appearance, PreferenceKey.snapsToGuides, PreferenceKey.showsGrid, PreferenceKey.snapsToGrid,
    PreferenceKey.showsRulers, PreferenceKey.gridSpacing, PreferenceKey.returnsToSelect, PreferenceKey.barHidesWithPalette,
    PreferenceKey.barsAutoHide, PreferenceKey.newCanvasWidth, PreferenceKey.newCanvasHeight, PreferenceKey.newCanvasTransparent,
  ]

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      PreferenceKey.appearance: AppAppearance.system.rawValue,
      PreferenceKey.snapsToGuides: true,
      PreferenceKey.showsGrid: false,
      PreferenceKey.snapsToGrid: false,
      PreferenceKey.gridSpacing: 20,
      PreferenceKey.returnsToSelect: false,
      PreferenceKey.paletteVisible: false,
      PreferenceKey.barHidesWithPalette: true,
      PreferenceKey.barsAutoHide: false,
      PreferenceKey.newCanvasWidth: Double(Paper.standardSize.width),
      PreferenceKey.newCanvasHeight: Double(Paper.standardSize.height),
      PreferenceKey.newCanvasTransparent: false,
    ])
  }

  /// A new drawing: a blank canvas of the size and colour Settings give.
  static var newScene: Scene {
    guard !isAutomatedCheck else { return Scene() }
    let defaults = UserDefaults.standard
    let size = CGSize(width: defaults.double(forKey: PreferenceKey.newCanvasWidth), height: defaults.double(forKey: PreferenceKey.newCanvasHeight))
    return Scene(paper: Paper(size: size, background: defaults.bool(forKey: PreferenceKey.newCanvasTransparent) ? nil : .white))
  }

  static var appearance: AppAppearance {
    AppAppearance(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.appearance) ?? "") ?? .system
  }

  @MainActor static func applyAppearance() { NSApp.appearance = appearance.value }

  static var gridSpacing: CGFloat {
    let value = UserDefaults.standard.double(forKey: PreferenceKey.gridSpacing)
    return [8, 10, 16, 20, 25, 32, 50].contains(value) ? value : 20
  }

  static var canvasConfiguration: CanvasConfiguration {
    let defaults = UserDefaults.standard
    var configuration = CanvasConfiguration()
    configuration.snapsToGuides = defaults.bool(forKey: PreferenceKey.snapsToGuides)
    configuration.showsGrid = defaults.bool(forKey: PreferenceKey.showsGrid)
    configuration.showsRulers = defaults.bool(forKey: PreferenceKey.showsRulers)
    configuration.snapsToGrid = defaults.bool(forKey: PreferenceKey.snapsToGrid)
    configuration.gridSpacing = gridSpacing
    configuration.returnsToSelect = defaults.bool(forKey: PreferenceKey.returnsToSelect)
    return configuration
  }

  /// The styles each tool had when last used, shared by every window.
  static var toolStyles: [Tool: Style] {
    get {
      var styles = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, $0.defaultStyle) })
      guard !isAutomatedCheck else { return styles }
      let stored = UserDefaults.standard.dictionary(forKey: PreferenceKey.toolStyles) as? [String: String] ?? [:]
      for (name, json) in stored {
        if let tool = Tool(rawValue: name), let style = Style(json: json) { styles[tool] = style }
      }
      return styles
    }
    set {
      guard !isAutomatedCheck else { return }
      let stored = Dictionary(uniqueKeysWithValues: newValue.filter { $0.value != $0.key.defaultStyle }.map { ($0.key.rawValue, $0.value.json) })
      UserDefaults.standard.set(stored, forKey: PreferenceKey.toolStyles)
    }
  }
}

/// Bristle's settings, in one window, as a Mac app keeps them: how the app looks, what a new
/// drawing starts with, how the canvas helps while drawing, and how the bars behave. The same
/// grid, snapping, and ruler options are in the View menu.
@MainActor
final class SettingsWindowController: NSWindowController {
  private let appearanceControl = NSSegmentedControl(
    labels: AppAppearance.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let width = NSTextField()
  private let height = NSTextField()
  private let background = NSPopUpButton()
  private let showsGrid = NSButton(checkboxWithTitle: "Show grid", target: nil, action: nil)
  private let gridSpacing = NSPopUpButton()
  private let snapsToGrid = NSButton(checkboxWithTitle: "Snap to grid", target: nil, action: nil)
  private let guides = NSButton(checkboxWithTitle: "Snap to other objects and the canvas", target: nil, action: nil)
  private let rulers = NSButton(checkboxWithTitle: "Show rulers", target: nil, action: nil)
  private let afterAdding = NSPopUpButton()
  private let barHides = NSButton(checkboxWithTitle: "Hide the style bar while the Palette is open", target: nil, action: nil)
  private let barsAutoHide = NSButton(checkboxWithTitle: "Show bars only when the pointer is near the bottom", target: nil, action: nil)

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable], backing: .buffered,
      defer: false)
    window.title = "Bristle Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false

    let number = NumberFormatter()
    number.numberStyle = .decimal
    number.minimum = 1
    number.maximum = NSNumber(value: Double(Paper.maximumSide))
    number.maximumFractionDigits = 0
    for field in [width, height] {
      field.formatter = number
      field.alignment = .right
      field.widthAnchor.constraint(equalToConstant: 64).isActive = true
    }
    width.setAccessibilityLabel("New canvas width")
    height.setAccessibilityLabel("New canvas height")
    background.addItems(withTitles: ["White", "Transparent"])
    for spacing in [8, 10, 16, 20, 25, 32, 50] {
      gridSpacing.addItem(withTitle: "\(spacing) points")
      gridSpacing.lastItem?.tag = spacing
    }
    afterAdding.addItems(withTitles: ["Keep the tool", "Switch to Select"])
    let controls: [NSControl] = [
      appearanceControl, width, height, background, showsGrid, gridSpacing, snapsToGrid, guides, rulers, afterAdding,
      barHides, barsAutoHide,
    ]
    for control in controls {
      control.target = self
      control.action = #selector(changeOption)
    }

    func describe(_ control: NSView, _ text: String) {
      control.toolTip = text
      control.setAccessibilityHelp(text)
    }
    describe(appearanceControl, "Light or dark windows. Drawings keep their own colours either way.")
    describe(background, "Transparent canvases export as PNGs you can place over anything.")
    describe(guides, "While moving and resizing, line up edges and middles with other objects and the canvas. Hold ⌘ to place freely.")
    describe(afterAdding, "What happens after you add one shape, line, or text box.")
    describe(barsAutoHide, "Keeps the canvas clear until you move the pointer to the bottom of the window.")

    func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    func note(_ text: String) -> NSTextField {
      let field = NSTextField(wrappingLabelWithString: text)
      field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      field.textColor = .secondaryLabelColor
      field.preferredMaxLayoutWidth = 300
      return field
    }
    let size = NSStackView(views: [width, label("×"), height, label("points")])
    size.spacing = 6
    let grid = NSStackView(views: [showsGrid, gridSpacing])
    grid.spacing = 12
    let empty = NSGridCell.emptyContentView
    let form = NSGridView(views: [
      [label("Appearance:"), appearanceControl],
      [empty, note("The window follows it; drawings keep their own colours.")],
      [label("New canvas:"), size],
      [label("Background:"), background],
      [label("Canvas:"), grid],
      [empty, snapsToGrid],
      [empty, guides],
      [empty, rulers],
      [label("After adding a shape:"), afterAdding],
      [label("Bars:"), barHides],
      [empty, barsAutoHide],
    ])
    form.rowSpacing = 8
    form.columnSpacing = 10
    form.column(at: 0).xPlacement = .trailing
    form.rowAlignment = .firstBaseline
    // A little room above each group.
    for row in [2, 4, 8, 9] { form.row(at: row).topPadding = 10 }
    let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
    describe(restore, "Put every setting back as it was when Bristle was new.")
    let content = NSView()
    for view in [form, restore] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
      form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      form.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
      restore.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 22),
      restore.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
      restore.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
    ])
    window.contentView = content
    content.layoutSubtreeIfNeeded()
    window.setContentSize(content.fittingSize)
    sync()
    NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: .canvasDefaultsDidChange, object: nil)
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

  /// The View menu changes the same options.
  @objc private func defaultsChanged() { sync() }

  private func sync() {
    let defaults = UserDefaults.standard
    appearanceControl.selectedSegment = AppAppearance.allCases.firstIndex(of: AppPreferences.appearance) ?? 0
    if width.currentEditor() == nil { width.doubleValue = defaults.double(forKey: PreferenceKey.newCanvasWidth) }
    if height.currentEditor() == nil { height.doubleValue = defaults.double(forKey: PreferenceKey.newCanvasHeight) }
    background.selectItem(at: defaults.bool(forKey: PreferenceKey.newCanvasTransparent) ? 1 : 0)
    showsGrid.state = defaults.bool(forKey: PreferenceKey.showsGrid) ? .on : .off
    gridSpacing.selectItem(withTag: Int(AppPreferences.gridSpacing))
    snapsToGrid.state = defaults.bool(forKey: PreferenceKey.snapsToGrid) ? .on : .off
    guides.state = defaults.bool(forKey: PreferenceKey.snapsToGuides) ? .on : .off
    rulers.state = defaults.bool(forKey: PreferenceKey.showsRulers) ? .on : .off
    afterAdding.selectItem(at: defaults.bool(forKey: PreferenceKey.returnsToSelect) ? 1 : 0)
    barHides.state = defaults.bool(forKey: PreferenceKey.barHidesWithPalette) ? .on : .off
    barsAutoHide.state = defaults.bool(forKey: PreferenceKey.barsAutoHide) ? .on : .off
  }

  @objc private func changeOption() {
    // Automated checks leave the user's settings alone.
    guard !AppPreferences.isAutomatedCheck else { return }
    let defaults = UserDefaults.standard
    if AppAppearance.allCases.indices.contains(appearanceControl.selectedSegment) {
      defaults.set(AppAppearance.allCases[appearanceControl.selectedSegment].rawValue, forKey: PreferenceKey.appearance)
    }
    let size = Paper.clamped(CGSize(width: width.doubleValue, height: height.doubleValue))
    defaults.set(Double(size.width), forKey: PreferenceKey.newCanvasWidth)
    defaults.set(Double(size.height), forKey: PreferenceKey.newCanvasHeight)
    defaults.set(background.indexOfSelectedItem == 1, forKey: PreferenceKey.newCanvasTransparent)
    defaults.set(showsGrid.state == .on, forKey: PreferenceKey.showsGrid)
    if let spacing = gridSpacing.selectedItem?.tag, spacing > 0 { defaults.set(spacing, forKey: PreferenceKey.gridSpacing) }
    defaults.set(snapsToGrid.state == .on, forKey: PreferenceKey.snapsToGrid)
    defaults.set(guides.state == .on, forKey: PreferenceKey.snapsToGuides)
    defaults.set(rulers.state == .on, forKey: PreferenceKey.showsRulers)
    defaults.set(afterAdding.indexOfSelectedItem == 1, forKey: PreferenceKey.returnsToSelect)
    defaults.set(barHides.state == .on, forKey: PreferenceKey.barHidesWithPalette)
    defaults.set(barsAutoHide.state == .on, forKey: PreferenceKey.barsAutoHide)
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
