import CoreGraphics
import Foundation

/// Lines and arrows attached to other elements, which follow those elements around.
extension Scene {
  /// Whether an element can have lines attached to it.
  public static func canBind(to element: Element) -> Bool {
    [.rectangle, .ellipse, .polygon, .text, .image, .freehand].contains(element.kind)
  }

  /// The element a line end dropped at `point` attaches to, and where, if any.
  public func binding(at point: CGPoint, excluding id: String, tolerance: CGFloat) -> Element.Binding? {
    for element in elements.reversed() where element.id != id && Scene.canBind(to: element) {
      guard !element.locked || element.kind != .image else { continue }
      let local = element.local(point)
      guard element.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(local) else { continue }
      let w = max(element.width, 0.001), h = max(element.height, 0.001)
      var anchor = CGPoint(x: (local.x - element.x) / w, y: (local.y - element.y) / h)
      anchor = CGPoint(x: min(1, max(0, anchor.x)), y: min(1, max(0, anchor.y)))
      // Near the middle, aim at the centre so the arrow meets the edge facing its other end.
      if abs(anchor.x - 0.5) < 0.2 && abs(anchor.y - 0.5) < 0.2 { anchor = CGPoint(x: 0.5, y: 0.5) }
      return Element.Binding(element: element.id, anchor: anchor)
    }
    return nil
  }

  /// Moves the ends of lines attached to changed elements, and of changed lines themselves.
  public mutating func updateBindings(changed ids: Set<String>) {
    guard !ids.isEmpty else { return }
    for i in elements.indices where elements[i].isLinear {
      let line = elements[i]
      let start = line.startBinding, end = line.endBinding
      guard start != nil || end != nil else { continue }
      let affected =
        ids.contains(line.id) || start.map { ids.contains($0.element) } == true
        || end.map { ids.contains($0.element) } == true
      guard affected, line.points.count >= 2 else { continue }
      var world = line.worldPoints
      let targetStart = start.flatMap { self[$0.element] }, targetEnd = end.flatMap { self[$0.element] }
      // Aim each end first at the other end's anchor, so both ends face each other.
      let startAim = targetStart.map { Scene.anchorPoint($0, start!.anchor) } ?? world[0]
      let endAim = targetEnd.map { Scene.anchorPoint($0, end!.anchor) } ?? world[world.count - 1]
      let gap = line.strokeWidth / 2 + 4
      if let target = targetStart {
        let toward = world.count > 2 ? world[1] : endAim
        world[0] = Scene.attachment(to: target, aim: startAim, from: toward, gap: gap)
      }
      if let target = targetEnd {
        let toward = world.count > 2 ? world[world.count - 2] : startAim
        world[world.count - 1] = Scene.attachment(to: target, aim: endAim, from: toward, gap: gap)
      }
      if start != nil && targetStart == nil { elements[i].startBinding = nil }
      if end != nil && targetEnd == nil { elements[i].endBinding = nil }
      elements[i].setWorldPoints(world)
    }
  }

  static func anchorPoint(_ element: Element, _ anchor: CGPoint) -> CGPoint {
    CGPoint(x: element.x + anchor.x * element.width, y: element.y + anchor.y * element.height)
      .applying(element.transform)
  }

  /// Where a line coming from `from` toward `aim` meets the element's outline, less a small gap.
  static func attachment(to element: Element, aim: CGPoint, from: CGPoint, gap: CGFloat) -> CGPoint {
    let outline: CGPath
    switch element.kind {
    case .freehand, .text, .image: outline = CGPath(rect: element.frame, transform: nil)
    default: outline = element.path
    }
    let world = outline.copy(using: [element.transform]) ?? outline
    let pad = element.kind == .freehand ? 0 : (element.stroke == nil ? 0 : element.strokeWidth / 2)
    var nearest: CGFloat?
    for run in Geometry.flatten(world, tolerance: 1) {
      for j in 1..<run.count {
        if let t = Geometry.intersection(from, aim, run[j - 1], run[j]) { nearest = min(nearest ?? t, t) }
      }
    }
    guard let t = nearest else { return aim }
    let hit = CGPoint(x: from.x + (aim.x - from.x) * t, y: from.y + (aim.y - from.y) * t)
    let length = from.distance(to: aim)
    guard length > 0 else { return hit }
    let back = min(gap + pad, from.distance(to: hit))
    return CGPoint(x: hit.x - (aim.x - from.x) / length * back, y: hit.y - (aim.y - from.y) / length * back)
  }
}
