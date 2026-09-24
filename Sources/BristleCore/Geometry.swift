import CoreGraphics
import Foundation

public enum Geometry {
  public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
  }

  /// Where segment `p1`–`p2` crosses segment `q1`–`q2`, as a fraction along `p1`–`p2`.
  public static func intersection(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> CGFloat? {
    let r = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y), s = CGPoint(x: q2.x - q1.x, y: q2.y - q1.y)
    let denominator = r.x * s.y - r.y * s.x
    guard abs(denominator) > 1e-12 else { return nil }
    let qp = CGPoint(x: q1.x - p1.x, y: q1.y - p1.y)
    let t = (qp.x * s.y - qp.y * s.x) / denominator
    let u = (qp.x * r.y - qp.y * r.x) / denominator
    return (0...1).contains(t) && (0...1).contains(u) ? t : nil
  }

  /// The path as straight segments, one list of points per subpath.
  public static func flatten(_ path: CGPath, tolerance: CGFloat = 1) -> [[CGPoint]] {
    var result: [[CGPoint]] = []
    var current: [CGPoint] = []
    var last = CGPoint.zero, start = CGPoint.zero
    func steps(_ length: CGFloat) -> Int { max(2, min(64, Int(length / max(tolerance, 0.1)))) }
    path.applyWithBlock { pointer in
      let element = pointer.pointee
      let p = element.points
      switch element.type {
      case .moveToPoint:
        if current.count > 1 { result.append(current) }
        current = [p[0]]
        last = p[0]
        start = p[0]
      case .addLineToPoint:
        current.append(p[0])
        last = p[0]
      case .addQuadCurveToPoint:
        let n = steps(last.distance(to: p[0]) + p[0].distance(to: p[1]))
        for i in 1...n {
          let t = CGFloat(i) / CGFloat(n), u = 1 - t
          current.append(
            CGPoint(
              x: u * u * last.x + 2 * u * t * p[0].x + t * t * p[1].x,
              y: u * u * last.y + 2 * u * t * p[0].y + t * t * p[1].y))
        }
        last = p[1]
      case .addCurveToPoint:
        let n = steps(last.distance(to: p[0]) + p[0].distance(to: p[1]) + p[1].distance(to: p[2]))
        for i in 1...n {
          let t = CGFloat(i) / CGFloat(n), u = 1 - t
          let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
          current.append(
            CGPoint(
              x: a * last.x + b * p[0].x + c * p[1].x + d * p[2].x,
              y: a * last.y + b * p[0].y + c * p[1].y + d * p[2].y))
        }
        last = p[2]
      case .closeSubpath:
        current.append(start)
        last = start
      @unknown default:
        break
      }
    }
    if current.count > 1 { result.append(current) }
    return result
  }

  /// A smooth curve through the points (a Catmull–Rom spline drawn with cubic Béziers).
  public static func smoothPath(through points: [CGPoint], closed: Bool) -> CGMutablePath {
    let path = CGMutablePath()
    // A point placed twice, as a click that adds a corner can, would kink the curve.
    var points = points.reduce(into: [CGPoint]()) { kept, p in
      if let last = kept.last, last.distance(to: p) < 0.01 { return }
      kept.append(p)
    }
    if closed, points.count > 1, let first = points.first, let last = points.last, first.distance(to: last) < 0.01 { points.removeLast() }
    guard points.count > 2 else {
      path.addLines(between: points)
      if closed { path.closeSubpath() }
      return path
    }
    let count = points.count
    func point(_ i: Int) -> CGPoint {
      if closed { return points[(i % count + count) % count] }
      return points[max(0, min(count - 1, i))]
    }
    path.move(to: points[0])
    let segments = closed ? count : count - 1
    for i in 0..<segments {
      let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
      let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
      let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
      path.addCurve(to: p2, control1: c1, control2: c2)
    }
    if closed { path.closeSubpath() }
    return path
  }
}

extension Element {
  /// The middle of the curve or line from point `i` to the next, for the handle that bends it.
  public func segmentMiddle(_ i: Int) -> CGPoint {
    let p = worldPoints
    guard p.indices.contains(i), p.indices.contains(i + 1) else { return p.first ?? .zero }
    guard curved, p.count > 2 else { return CGPoint(x: (p[i].x + p[i + 1].x) / 2, y: (p[i].y + p[i + 1].y) / 2) }
    // A Catmull-Rom curve's middle, as the path draws it.
    let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
    return CGPoint(x: (-p0.x + 9 * p1.x + 9 * p2.x - p3.x) / 16, y: (-p0.y + 9 * p1.y + 9 * p2.y - p3.y) / 16)
  }

  /// Gives a straight two-point line a gentle bend, so making it curved shows at once, as a
  /// curve in MS Paint or Excalidraw starts from a bent line.
  public mutating func bendIfStraight() {
    guard isLinear, curved, points.count == 2 else { return }
    let p = worldPoints
    let dx = p[1].x - p[0].x, dy = p[1].y - p[0].y
    let length = hypot(dx, dy)
    guard length > 1 else { return }
    let mid = CGPoint(x: (p[0].x + p[1].x) / 2 + dy / length * length * 0.18, y: (p[0].y + p[1].y) / 2 - dx / length * length * 0.18)
    setWorldPoints([p[0], mid, p[1]])
  }

  /// The element's shape in unrotated canvas coordinates: the outline to fill and stroke for
  /// shapes, the line for lines and arrows, and the filled ink for freehand strokes.
  public var path: CGPath {
    switch kind {
    case .rectangle, .text, .image:
      let rect = frame
      let radius = kind == .rectangle ? min(cornerRadius, rect.width / 2, rect.height / 2) : 0
      if radius > 0 { return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }
      return CGPath(rect: rect, transform: nil)
    case .ellipse:
      return CGPath(ellipseIn: frame, transform: nil)
    case .polygon, .line, .arrow:
      let absolute = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
      let closed = kind == .polygon
      if curved { return Geometry.smoothPath(through: absolute, closed: closed) }
      let path = CGMutablePath()
      path.addLines(between: absolute)
      if closed && absolute.count > 2 { path.closeSubpath() }
      return path
    case .freehand:
      let absolute = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
      return Freehand.outline(absolute, pressures: pressures, size: strokeWidth, brush: brush)
    }
  }

  /// The arrowheads at the ends of a line or arrow, in unrotated canvas coordinates. Each is
  /// drawn filled when `filled`, and stroked otherwise.
  public var arrowheads: [(path: CGPath, filled: Bool)] {
    guard isLinear, points.count >= 2 else { return [] }
    let absolute = points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
    var result: [(CGPath, Bool)] = []
    // Aim along the drawn curve, not at the previous corner, when the line is curved.
    func direction(atEnd end: Bool) -> (tip: CGPoint, from: CGPoint) {
      if curved, absolute.count > 2 {
        let flat = Geometry.flatten(path, tolerance: 0.5).first ?? absolute
        let length = strokeWidth * 3 + 6
        let sequence = end ? Array(flat.reversed()) : flat
        let tip = sequence[0]
        for p in sequence.dropFirst() where p.distance(to: tip) >= length { return (tip, p) }
        return (tip, sequence.last!)
      }
      return end ? (absolute[absolute.count - 1], absolute[absolute.count - 2]) : (absolute[0], absolute[1])
    }
    for (head, end) in [(startArrowhead, false), (endArrowhead, true)] where head != .none {
      let (tip, from) = direction(atEnd: end)
      let angle = atan2(tip.y - from.y, tip.x - from.x)
      let size = max(10, strokeWidth * 3.5)
      let path = CGMutablePath()
      func at(_ distance: CGFloat, _ spread: CGFloat) -> CGPoint {
        CGPoint(x: tip.x - cos(angle + spread) * distance, y: tip.y - sin(angle + spread) * distance)
      }
      switch head {
      case .none: continue
      case .arrow:
        path.move(to: at(size, 0.45))
        path.addLine(to: tip)
        path.addLine(to: at(size, -0.45))
        result.append((path, false))
      case .triangle:
        path.move(to: tip)
        path.addLine(to: at(size, 0.4))
        path.addLine(to: at(size, -0.4))
        path.closeSubpath()
        result.append((path, true))
      case .circle:
        let radius = max(4, strokeWidth * 1.6)
        let c = at(radius, 0)
        path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        result.append((path, true))
      case .bar:
        let half = size * 0.5
        path.move(to: CGPoint(x: tip.x - sin(angle) * half, y: tip.y + cos(angle) * half))
        path.addLine(to: CGPoint(x: tip.x + sin(angle) * half, y: tip.y - cos(angle) * half))
        result.append((path, false))
      }
    }
    return result
  }

  /// How far the drawing reaches beyond the frame, for strokes and arrowheads.
  public var outset: CGFloat {
    switch kind {
    case .freehand: return strokeWidth / 2 + 1
    case .line, .arrow:
      let heads = startArrowhead != .none || endArrowhead != .none
      return (heads ? max(10, strokeWidth * 3.5) : 0) + strokeWidth / 2 + 1
    case .text, .image: return stroke == nil ? 0 : strokeWidth / 2
    default: return stroke == nil ? 0 : strokeWidth / 2 + 1
    }
  }

  /// The area the element draws in on the canvas, including rotation, strokes, and arrowheads.
  public var bounds: CGRect {
    // A stroke's ink never reaches further from its points than half its width, so its frame
    // gives its bounds without building the outline. Curves can swing past their points.
    var box: CGRect
    if curved && (isLinear || kind == .polygon) {
      box = path.boundingBoxOfPath
    } else {
      box = frame
    }
    box = box.insetBy(dx: -outset, dy: -outset)
    guard rotation != 0 else { return box }
    return CGRect(boundingPoints: box.corners.map { $0.applying(transform) })
  }

  /// The frame's corners on the canvas, for selection outlines of rotated elements.
  public var worldCorners: [CGPoint] { frame.corners.map { $0.applying(transform) } }

  /// Whether a point on the canvas touches the element. Shapes without a fill are touched only
  /// near their outline, so things behind them stay easy to reach.
  public func hit(_ point: CGPoint, tolerance: CGFloat) -> Bool {
    guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
    let p = local(point)
    switch kind {
    case .text, .image:
      return frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
    case .freehand:
      let outline = path
      if outline.contains(p, using: .winding) { return true }
      return outline.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        .contains(p)
    case .line, .arrow:
      let width = strokeWidth + tolerance * 2
      if path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(p) {
        return true
      }
      return arrowheads.contains { $0.path.boundingBoxOfPath.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    case .rectangle, .ellipse, .polygon:
      let shape = path
      if fill != nil, shape.contains(p) { return true }
      let width = (stroke == nil ? 0 : strokeWidth) + tolerance * 2
      return shape.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }
  }

  /// Whether the element crosses a rectangle on the canvas, for selecting by dragging.
  public func intersects(_ rect: CGRect) -> Bool {
    let box = bounds
    guard box.intersects(rect) else { return false }
    if rect.contains(box) { return true }
    // A rotated or thin element's box can cross the rectangle while the element doesn't.
    let outline: [[CGPoint]]
    switch kind {
    case .rectangle, .text, .image, .ellipse: outline = [worldCorners + [worldCorners[0]]]
    default: outline = Geometry.flatten(path.copy(using: [transform]) ?? path, tolerance: 2)
    }
    let edges = rect.corners + [rect.corners[0]]
    for run in outline {
      if run.contains(where: rect.contains) { return true }
      for i in 1..<max(1, run.count) {
        for j in 1..<edges.count where Geometry.intersection(run[i - 1], run[i], edges[j - 1], edges[j]) != nil {
          return true
        }
      }
    }
    // The rectangle may sit wholly inside a shape.
    let shape = path.copy(using: [transform]) ?? path
    return isClosed && shape.contains(rect.center)
  }
}

extension CGPath {
  func copy(using transforms: [CGAffineTransform]) -> CGPath? {
    var t = transforms.reduce(CGAffineTransform.identity) { $0.concatenating($1) }
    return copy(using: &t)
  }
}
