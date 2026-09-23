import CoreGraphics

/// The eraser removes whole elements, or with the stroke eraser, the parts of freehand strokes
/// it passes over. It never touches image pixels.
extension Scene {
  /// The ids of unlocked elements the eraser's path touches.
  public func elementsTouched(by path: [CGPoint], radius: CGFloat) -> Set<String> {
    guard !path.isEmpty else { return [] }
    let reach = CGRect(boundingPoints: path).insetBy(dx: -radius, dy: -radius)
    var touched: Set<String> = []
    for element in elements where !element.locked && element.bounds.intersects(reach) {
      if element.kind == .image {
        // Images are only erased by passing over their middle, so marking one up is safe.
        if path.contains(where: { element.local($0).distance(to: element.center) < min(element.width, element.height) / 4 }) {
          touched.insert(element.id)
        }
        continue
      }
      if samples(path, spacing: max(1, radius / 2)).contains(where: { element.hit($0, tolerance: radius) }) {
        touched.insert(element.id)
      }
    }
    return touched
  }

  /// Cuts freehand strokes where the eraser passed over them, returning whether anything changed.
  @discardableResult
  public mutating func erase(along path: [CGPoint], radius: CGFloat) -> Bool {
    let reach = CGRect(boundingPoints: path).insetBy(dx: -radius, dy: -radius)
    let probe = samples(path, spacing: max(1, radius / 2))
    var changed = false
    var result: [Element] = []
    result.reserveCapacity(elements.count)
    for element in elements {
      guard element.kind == .freehand, !element.locked, element.bounds.intersects(reach) else {
        result.append(element)
        continue
      }
      let world = element.worldPoints
      let reachStroke = radius + element.strokeWidth / 2
      let keep = world.map { p in !probe.contains { $0.distance(to: p) <= reachStroke } }
      guard keep.contains(false) else {
        result.append(element)
        continue
      }
      changed = true
      var runs: [[Int]] = []
      var current: [Int] = []
      for i in world.indices {
        if keep[i] {
          current.append(i)
        } else if !current.isEmpty {
          runs.append(current)
          current = []
        }
      }
      if !current.isEmpty { runs.append(current) }
      for (n, run) in runs.enumerated() where run.count >= 2 {
        var piece = element
        if n > 0 { piece.id = Element.newID() }
        piece.pressures = element.pressures.count == world.count ? run.map { element.pressures[$0] } : []
        piece.setWorldPoints(run.map { world[$0] })
        result.append(piece)
      }
    }
    if changed { elements = result }
    return changed
  }

  /// Points along a path no more than `spacing` apart.
  func samples(_ path: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard var last = path.first else { return [] }
    var result = [last]
    for p in path.dropFirst() {
      let d = last.distance(to: p)
      if d > spacing {
        let steps = Int(d / spacing)
        for s in 1...steps {
          let t = CGFloat(s) / CGFloat(steps + 1)
          result.append(CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
        }
      }
      result.append(p)
      last = p
    }
    return result
  }
}
