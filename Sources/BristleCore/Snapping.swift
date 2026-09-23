import CoreGraphics

/// Alignment guides: while moving or resizing, edges and centres pull toward the edges and
/// centres of other elements and of the paper, and a guide line shows what lined up.
public struct Snapping: Sendable {
  public struct Guide: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
  }

  public struct Result: Sendable {
    public var offset: CGPoint
    public var guides: [Guide]
  }

  /// The rectangles to line up with.
  public var targets: [CGRect]
  /// How close, in canvas units, an edge must come before it snaps.
  public var threshold: CGFloat
  /// Snap to this grid spacing instead of to other elements, if set.
  public var grid: CGFloat?

  public init(targets: [CGRect], threshold: CGFloat, grid: CGFloat? = nil) {
    self.targets = targets
    self.threshold = threshold
    self.grid = grid
  }

  /// How far to move `box` so its edges or centre line up, and the guides to show.
  public func snap(_ box: CGRect) -> Result {
    if let grid, grid > 0 {
      let dx = (box.minX / grid).rounded() * grid - box.minX
      let dy = (box.minY / grid).rounded() * grid - box.minY
      return Result(offset: CGPoint(x: dx, y: dy), guides: [])
    }
    let xs = [box.minX, box.midX, box.maxX], ys = [box.minY, box.midY, box.maxY]
    let dx = best(xs, targets.flatMap { [$0.minX, $0.midX, $0.maxX] })
    let dy = best(ys, targets.flatMap { [$0.minY, $0.midY, $0.maxY] })
    let moved = box.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
    return Result(offset: CGPoint(x: dx ?? 0, y: dy ?? 0), guides: guides(for: moved, x: dx != nil, y: dy != nil))
  }

  /// Snaps a single point, such as the corner being dragged while resizing or drawing.
  public func snap(_ point: CGPoint) -> Result {
    if let grid, grid > 0 {
      return Result(
        offset: CGPoint(x: (point.x / grid).rounded() * grid - point.x, y: (point.y / grid).rounded() * grid - point.y),
        guides: [])
    }
    let dx = best([point.x], targets.flatMap { [$0.minX, $0.midX, $0.maxX] })
    let dy = best([point.y], targets.flatMap { [$0.minY, $0.midY, $0.maxY] })
    let moved = CGRect(x: point.x + (dx ?? 0), y: point.y + (dy ?? 0), width: 0, height: 0)
    return Result(offset: CGPoint(x: dx ?? 0, y: dy ?? 0), guides: guides(for: moved, x: dx != nil, y: dy != nil))
  }

  private func best(_ values: [CGFloat], _ candidates: [CGFloat]) -> CGFloat? {
    var result: CGFloat?
    for value in values {
      for candidate in candidates {
        let delta = candidate - value
        if abs(delta) <= threshold, abs(delta) < abs(result ?? .infinity) { result = delta }
      }
    }
    return result
  }

  private func guides(for box: CGRect, x: Bool, y: Bool) -> [Guide] {
    var guides: [Guide] = []
    let epsilon: CGFloat = 0.01
    if x {
      for value in [box.minX, box.midX, box.maxX] {
        let matches = targets.filter { t in [t.minX, t.midX, t.maxX].contains { abs($0 - value) < epsilon } }
        guard !matches.isEmpty else { continue }
        let top = matches.map(\.minY).min()!, bottom = matches.map(\.maxY).max()!
        guides.append(Guide(from: CGPoint(x: value, y: min(top, box.minY)), to: CGPoint(x: value, y: max(bottom, box.maxY))))
      }
    }
    if y {
      for value in [box.minY, box.midY, box.maxY] {
        let matches = targets.filter { t in [t.minY, t.midY, t.maxY].contains { abs($0 - value) < epsilon } }
        guard !matches.isEmpty else { continue }
        let left = matches.map(\.minX).min()!, right = matches.map(\.maxX).max()!
        guides.append(Guide(from: CGPoint(x: min(left, box.minX), y: value), to: CGPoint(x: max(right, box.maxX), y: value)))
      }
    }
    return guides
  }
}
