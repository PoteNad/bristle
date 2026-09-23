import CoreGraphics
import Foundation

/// Ready-made shapes, as MS Paint's shape gallery offers, drawn with one drag into a box. Each
/// becomes an ordinary polygon, so its points can be edited afterwards.
public enum ShapePreset: String, CaseIterable, Sendable {
  case triangle, rightTriangle, diamond, pentagon, hexagon, octagon
  case star, star4, star6, heart, lightning, cross
  case arrowRight, arrowLeft, arrowUp, arrowDown, speech

  public var title: String {
    switch self {
    case .triangle: "Triangle"
    case .rightTriangle: "Right Triangle"
    case .diamond: "Diamond"
    case .pentagon: "Pentagon"
    case .hexagon: "Hexagon"
    case .octagon: "Octagon"
    case .star: "Star"
    case .star4: "4-Point Star"
    case .star6: "6-Point Star"
    case .heart: "Heart"
    case .lightning: "Lightning"
    case .cross: "Cross"
    case .arrowRight: "Right Arrow"
    case .arrowLeft: "Left Arrow"
    case .arrowUp: "Up Arrow"
    case .arrowDown: "Down Arrow"
    case .speech: "Speech Bubble"
    }
  }

  /// Whether the outline is drawn as a smooth curve through the points.
  public var curved: Bool { self == .heart }

  /// The corners in a unit box, y pointing down, touching all four sides.
  public var unitPoints: [CGPoint] {
    func regular(_ count: Int, rotation: CGFloat = -.pi / 2) -> [CGPoint] {
      (0..<count).map { i in
        let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(count)
        return CGPoint(x: 0.5 + cos(a) * 0.5, y: 0.5 + sin(a) * 0.5)
      }
    }
    func star(_ count: Int, inner: CGFloat) -> [CGPoint] {
      (0..<(count * 2)).map { i in
        let a = -.pi / 2 + CGFloat(i) * .pi / CGFloat(count)
        let r = i % 2 == 0 ? 0.5 : 0.5 * inner
        return CGPoint(x: 0.5 + cos(a) * r, y: 0.5 + sin(a) * r)
      }
    }
    let points: [CGPoint]
    switch self {
    case .triangle: points = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    case .rightTriangle: points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    case .diamond: points = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
    case .pentagon: points = regular(5)
    case .hexagon: points = regular(6, rotation: 0)
    case .octagon: points = regular(8, rotation: .pi / 8)
    case .star: points = star(5, inner: 0.45)
    case .star4: points = star(4, inner: 0.38)
    case .star6: points = star(6, inner: 0.55)
    case .heart:
      points = [
        CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.75, y: 0), CGPoint(x: 1, y: 0.28), CGPoint(x: 0.82, y: 0.62),
        CGPoint(x: 0.5, y: 1), CGPoint(x: 0.18, y: 0.62), CGPoint(x: 0, y: 0.28), CGPoint(x: 0.25, y: 0),
      ]
    case .lightning:
      points = [
        CGPoint(x: 0.55, y: 0), CGPoint(x: 0.1, y: 0.58), CGPoint(x: 0.45, y: 0.58), CGPoint(x: 0.3, y: 1),
        CGPoint(x: 0.9, y: 0.36), CGPoint(x: 0.55, y: 0.36), CGPoint(x: 0.8, y: 0),
      ]
    case .cross:
      let a: CGFloat = 0.32, b: CGFloat = 0.68
      points = [
        CGPoint(x: a, y: 0), CGPoint(x: b, y: 0), CGPoint(x: b, y: a), CGPoint(x: 1, y: a), CGPoint(x: 1, y: b),
        CGPoint(x: b, y: b), CGPoint(x: b, y: 1), CGPoint(x: a, y: 1), CGPoint(x: a, y: b), CGPoint(x: 0, y: b),
        CGPoint(x: 0, y: a), CGPoint(x: a, y: a),
      ]
    case .arrowRight:
      points = [
        CGPoint(x: 0, y: 0.3), CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.6, y: 0), CGPoint(x: 1, y: 0.5),
        CGPoint(x: 0.6, y: 1), CGPoint(x: 0.6, y: 0.7), CGPoint(x: 0, y: 0.7),
      ]
    case .arrowLeft: points = ShapePreset.arrowRight.unitPoints.map { CGPoint(x: 1 - $0.x, y: $0.y) }
    case .arrowDown: points = ShapePreset.arrowRight.unitPoints.map { CGPoint(x: $0.y, y: $0.x) }
    case .arrowUp: points = ShapePreset.arrowDown.unitPoints.map { CGPoint(x: $0.x, y: 1 - $0.y) }
    case .speech:
      points = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.72), CGPoint(x: 0.42, y: 0.72),
        CGPoint(x: 0.18, y: 1), CGPoint(x: 0.22, y: 0.72), CGPoint(x: 0, y: 0.72),
      ]
    }
    // Stretch to fill the box, so the shape fills what's dragged.
    let box = CGRect(boundingPoints: points)
    return points.map {
      CGPoint(x: ($0.x - box.minX) / max(box.width, 0.0001), y: ($0.y - box.minY) / max(box.height, 0.0001))
    }
  }

  /// The corners filling `rect`.
  public func points(in rect: CGRect) -> [CGPoint] {
    unitPoints.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
  }

  /// The shape as a small picture's outline, for menus and buttons.
  public func path(in rect: CGRect) -> CGPath {
    let corners = points(in: rect)
    if curved { return Geometry.smoothPath(through: corners, closed: true) }
    let path = CGMutablePath()
    path.addLines(between: corners)
    path.closeSubpath()
    return path
  }
}
