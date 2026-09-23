import CoreGraphics

/// Smooth ink for freehand strokes. Points are eased toward the pen, each gets a radius from
/// pressure (or from speed with a mouse), and the stroke is filled as one path, so it draws,
/// prints, and exports the same.
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

  /// The pixels a drag passes over: the centres of the squares of a grid `size` wide, joined
  /// without gaps and each listed once, in the order they were reached.
  public static func pixels(_ points: [CGPoint], size: CGFloat) -> [CGPoint] {
    let size = max(1, size.rounded())
    func cell(_ p: CGPoint) -> (Int, Int) { (Int((p.x / size).rounded(.down)), Int((p.y / size).rounded(.down))) }
    var cells: [(Int, Int)] = []
    var seen = Set<Int64>()
    func add(_ c: (Int, Int)) {
      let key = Int64(c.0) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: c.1)))
      if seen.insert(key).inserted { cells.append(c) }
    }
    var last: (Int, Int)?
    for point in points {
      let c = cell(point)
      if let (x0, y0) = last {
        // A line of cells from the last one, so a quick drag leaves no gaps.
        let dx = abs(c.0 - x0), dy = -abs(c.1 - y0), sx = x0 < c.0 ? 1 : -1, sy = y0 < c.1 ? 1 : -1
        var x = x0, y = y0, error = dx + dy
        while true {
          add((x, y))
          if x == c.0 && y == c.1 { break }
          let e2 = 2 * error
          if e2 >= dy { error += dy; x += sx }
          if e2 <= dx { error += dx; y += sy }
        }
      } else {
        add(c)
      }
      last = c
    }
    return cells.map { CGPoint(x: (CGFloat($0.0) + 0.5) * size, y: (CGFloat($0.1) + 0.5) * size) }
  }

  /// The filled shape of a stroke through already smoothed points: a piece for each step
  /// between points, joined at every point and capped at the ends, all turning the same way so
  /// they fill as one shape. A single outline around the whole stroke folds over itself where
  /// the stroke turns sharply or doubles back, and leaves holes in the ink there.
  public static func outline(
    _ points: [CGPoint], pressures: [CGFloat] = [], size: CGFloat, brush: Element.Brush = .pen
  ) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    if brush == .pixel {
      let side = max(1, size.rounded())
      for p in points { path.addRect(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)) }
      return path
    }
    let size = max(size, 0.5)
    let radii = radii(points, pressures: pressures, size: size, brush: brush)
    // Points closer together than this add nothing but noise to the edges.
    let step = size * 0.02
    var p: [CGPoint] = [], r: [CGFloat] = []
    p.reserveCapacity(points.count)
    r.reserveCapacity(points.count)
    for (point, radius) in zip(points, radii) {
      if let last = p.last, last.distance(to: point) < step { continue }
      p.append(point)
      r.append(radius)
    }
    let round = brush != .highlighter
    guard p.count > 1 else {
      let radius = max(radii.max() ?? size / 2, size * 0.3)
      let dot = CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)
      if round { path.addEllipse(in: dot) } else { path.addRect(dot) }
      return path
    }

    // Every piece is added turning the same way, so where they overlap they fill as one.
    func polygon(_ corners: [CGPoint]) {
      var area: CGFloat = 0
      for i in corners.indices {
        let a = corners[i], b = corners[(i + 1) % corners.count]
        area += a.x * b.y - b.x * a.y
      }
      guard abs(area) > 1e-9 else { return }
      path.addLines(between: area > 0 ? corners : corners.reversed())
      path.closeSubpath()
    }
    func circle(_ center: CGPoint, _ radius: CGFloat) {
      path.move(to: CGPoint(x: center.x + radius, y: center.y))
      path.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
      path.closeSubpath()
    }

    var normals: [CGPoint] = []
    normals.reserveCapacity(p.count - 1)
    for i in 0..<(p.count - 1) {
      let dx = p[i + 1].x - p[i].x, dy = p[i + 1].y - p[i].y
      let length = max(hypot(dx, dy), 1e-9)
      let n = CGPoint(x: -dy / length, y: dx / length)
      normals.append(n)
      polygon([
        CGPoint(x: p[i].x + n.x * r[i], y: p[i].y + n.y * r[i]),
        CGPoint(x: p[i + 1].x + n.x * r[i + 1], y: p[i + 1].y + n.y * r[i + 1]),
        CGPoint(x: p[i + 1].x - n.x * r[i + 1], y: p[i + 1].y - n.y * r[i + 1]),
        CGPoint(x: p[i].x - n.x * r[i], y: p[i].y - n.y * r[i]),
      ])
    }
    // Joins: the gap on the outside of a gentle turn is filled with a sliver, and a sharp turn
    // gets a round join.
    for i in 1..<(p.count - 1) {
      let a = normals[i - 1], b = normals[i]
      let turn = atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
      if abs(turn) < 1e-4 { continue }
      if abs(turn) > 0.3 {
        circle(p[i], r[i])
      } else {
        let side: CGFloat = turn > 0 ? -1 : 1
        polygon([
          p[i], CGPoint(x: p[i].x + a.x * r[i] * side, y: p[i].y + a.y * r[i] * side),
          CGPoint(x: p[i].x + b.x * r[i] * side, y: p[i].y + b.y * r[i] * side),
        ])
      }
    }
    if round {
      circle(p[0], r[0])
      circle(p[p.count - 1], r[r.count - 1])
    }
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
