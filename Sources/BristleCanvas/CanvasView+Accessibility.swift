import AppKit
import BristleCore

/// Each element is a layout item VoiceOver can find, read, and select, as Pages and Keynote
/// expose the objects on their pages.
final class ElementAccessibility: NSAccessibilityElement {
  let id: String
  weak var canvas: CanvasView?

  init(id: String, canvas: CanvasView) {
    self.id = id
    self.canvas = canvas
    super.init()
    setAccessibilityRole(.layoutItem)
    setAccessibilityParent(canvas)
  }

  /// Runs on the main thread with the canvas, which is where VoiceOver's requests arrive.
  private func withCanvas<T: Sendable>(_ fallback: T, _ body: @MainActor (CanvasView, String) -> T) -> T {
    let canvas = self.canvas, id = self.id
    return MainActor.assumeIsolated {
      guard let canvas else { return fallback }
      return body(canvas, id)
    }
  }

  override func accessibilityLabel() -> String? { withCanvas(nil) { $0.scene[$1]?.summary } }

  override func accessibilityRoleDescription() -> String? {
    withCanvas(nil) { $0.scene[$1]?.kindName.lowercased() }
  }

  override func accessibilityValue() -> Any? {
    withCanvas(nil as String?) { canvas, id in canvas.scene[id].flatMap { $0.kind == .text ? $0.text : nil } }
  }

  override func accessibilityFrame() -> NSRect {
    withCanvas(.zero) { canvas, id in
      guard let element = canvas.scene[id], let window = canvas.window else { return .zero }
      return window.convertToScreen(canvas.convert(element.bounds, to: nil))
    }
  }

  override func isAccessibilitySelected() -> Bool { withCanvas(false) { $0.drawing.selection.contains($1) } }

  override func setAccessibilitySelected(_ selected: Bool) {
    withCanvas(()) { canvas, id in
      let selection = canvas.drawing.selection
      canvas.select(selected ? selection.union([id]) : selection.subtracting([id]))
    }
  }

  override func accessibilityPerformPress() -> Bool {
    withCanvas(false) { canvas, id in
      canvas.select([id])
      return true
    }
  }

  override func isAccessibilityFocused() -> Bool { isAccessibilitySelected() }
}

extension CanvasView {
  func invalidateAccessibility() {
    guard NSWorkspace.shared.isVoiceOverEnabled || !accessibilityProxies.isEmpty else { return }
    NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
  }

  public override func accessibilityChildren() -> [Any]? {
    var proxies = accessibilityProxies
    var children: [Any] = []
    let ids = Set(scene.elements.map(\.id))
    proxies = proxies.filter { ids.contains($0.key) }
    for element in scene.elements.reversed() {
      let proxy = proxies[element.id] ?? ElementAccessibility(id: element.id, canvas: self)
      proxies[element.id] = proxy
      children.append(proxy)
    }
    accessibilityProxies = proxies
    if let textEditor { children.insert(textEditor, at: 0) }
    return children
  }

  public override func accessibilitySelectedChildren() -> [Any]? {
    let proxies = accessibilityProxies
    return drawing.selection.compactMap { proxies[$0] }
  }

  public override func accessibilityValue() -> Any? {
    let count = scene.elements.count
    let selected = drawing.selection.count
    var value = "\(count) \(count == 1 ? "object" : "objects")"
    if selected > 0 { value += ", \(selected) selected" }
    return value
  }

  public override func accessibilityHelp() -> String? {
    "\(tool.title) tool. Tab moves between objects; arrow keys move the selection."
  }
}
