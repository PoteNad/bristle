import CoreGraphics

/// Smooth ink for freehand strokes. Points are eased toward the pen, each gets a radius from
/// pressure (or from speed with a mouse), and both sides are joined with round ends into a single
/// filled shape, so a stroke draws, prints, and exports as one path.
public enum Freehand {
  /// Pressures for a stroke drawn with a mouse, from its speed: moving quickly thins the line, as
  /// it would with a real pen. They are stored with the stroke so it keeps its shape when resized.
  public static func simulatedPressures(_ points: [CGPoint], size: CGFloat) -> [CGFloat] {
    var result: [CGFloat] = []
    result.reserveCapacity(points.count)
    var pressure: CGFloat = 0.6
    for i in points.indices {
      let speed = i == 0 ? 0 : points[i].distance(to: points[i - 1])
      let target = 1 - min(1, speed / (max(size, 0.5) * 3)) * 0.65
      pressure += (target - pressure) * 0.3
      result.append(pressure)
    }
    return result
  }

  /// The radius of the stroke at each point.
  static func radii(_ points: [CGPoint], pressures: [CGFloat], size: CGFloat, brush: Element.Brush) -> [CGFloat] {
    guard brush == .pen else { return Array(repeating: size / 2, count: points.count) }
    let pressures = pressures.count == points.count ? pressures : simulatedPressures(points, size: size)
    var result = pressures.map { size / 2 * (0.3 + 0.7 * $0) }
    // Taper the first and last few points.
    let taper = min(6, points.count / 3)
    for i in 0..<taper {
      let f = 0.35 + 0.65 * CGFloat(i + 1) / CGFloat(taper + 1)
      result[i] *= f
      result[points.count - 1 - i] *= f
    }
    return result
  }

  /// Eases each point toward the pen for a steady line, keeping the first and last points, and
  /// keeps the pressures in step. Strokes are stored smoothed, so they draw the same afterwards.
  public static func smoothed(_ raw: [CGPoint], pressures: [CGFloat] = []) -> ([CGPoint], [CGFloat]) {
    guard raw.count > 2, let first = raw.first, let last = raw.last else { return (raw, pressures) }
    var points = [first]
    points.reserveCapacity(raw.count + 1)
    for p in raw.dropFirst() {
      let previous = points[points.count - 1]
      points.append(CGPoint(x: previous.x + (p.x - previous.x) * 0.55, y: previous.y + (p.y - previous.y) * 0.55))
    }
    points.append(last)
    var smoothedPressures = pressures
    if pressures.count == raw.count, let final = pressures.last { smoothedPressures.append(final) }
    return (points, smoothedPressures)
  }

  /// The filled outline of a stroke through already smoothed points.
  public static func outline(
    _ points: [CGPoint], pressures: [CGFloat] = [], size: CGFloat, brush: Element.Brush = .pen
  ) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    let size = max(size, 0.5)
    let r = radii(points, pressures: pressures, size: size, brush: brush)
    let extent = CGRect(boundingPoints: points)
    if points.count < 2 || extent.width + extent.height < 0.5 {
      let radius = max(r.max() ?? size / 2, size * 0.3)
      if brush == .highlighter {
        path.addRect(CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
      } else {
        path.addEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
      }
      return path
    }
    var left: [CGPoint] = [], right: [CGPoint] = [], normals: [CGPoint] = []
    left.reserveCapacity(points.count)
    right.reserveCapacity(points.count)
    for i in points.indices {
      let a = points[max(0, i - 1)], b = points[min(points.count - 1, i + 1)]
      var tx = b.x - a.x, ty = b.y - a.y
      let length = hypot(tx, ty)
      if length < 0.0001 {
        let previous = normals.last ?? CGPoint(x: 0, y: 1)
        tx = previous.y
        ty = -previous.x
      } else {
        tx /= length
        ty /= length
      }
      let n = CGPoint(x: -ty, y: tx)
      normals.append(n)
      left.append(CGPoint(x: points[i].x + n.x * r[i], y: points[i].y + n.y * r[i]))
      right.append(CGPoint(x: points[i].x - n.x * r[i], y: points[i].y - n.y * r[i]))
    }
    func side(_ side: [CGPoint]) {
      for i in 1..<side.count - 1 {
        let mid = CGPoint(x: (side[i].x + side[i + 1].x) / 2, y: (side[i].y + side[i + 1].y) / 2)
        path.addQuadCurve(to: mid, control: side[i])
      }
      path.addLine(to: side[side.count - 1])
    }
    let end = points.count - 1
    path.move(to: left[0])
    side(left)
    if brush == .highlighter {
      path.addLine(to: right[end])
    } else {
      let angle = atan2(normals[end].y, normals[end].x)
      path.addArc(center: points[end], radius: r[end], startAngle: angle, endAngle: angle + .pi, clockwise: true)
    }
    side(right.reversed())
    if brush == .highlighter {
      path.addLine(to: left[0])
    } else {
      let angle = atan2(normals[0].y, normals[0].x)
      path.addArc(center: points[0], radius: r[0], startAngle: angle + .pi, endAngle: angle, clockwise: true)
    }
    path.closeSubpath()
    return path
  }

  /// Drops points that add nothing visible: those within `tolerance` of the line through their
  /// neighbours (Ramer–Douglas–Peucker), keeping pressure alongside.
  public static func simplify(_ points: [CGPoint], pressures: [CGFloat], tolerance: CGFloat) -> (
    [CGPoint], [CGFloat]
  ) {
    guard points.count > 2 else { return (points, pressures) }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack = [(0, points.count - 1)]
    while let (start, end) = stack.popLast() {
      guard end > start + 1 else { continue }
      var farthest = 0.0 as CGFloat, index = start
      for i in (start + 1)..<end {
        let d = Geometry.distance(from: points[i], toSegment: points[start], points[end])
        if d > farthest {
          farthest = d
          index = i
        }
      }
      if farthest > tolerance {
        keep[index] = true
        stack.append((start, index))
        stack.append((index, end))
      }
    }
    let kept = points.indices.filter { keep[$0] }
    return (kept.map { points[$0] }, pressures.count == points.count ? kept.map { pressures[$0] } : [])
  }
}
