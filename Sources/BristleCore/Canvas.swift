import CoreGraphics
import Foundation

/// Changes to the paper itself: cropping, resizing, rotating, and flipping the whole drawing.
/// Elements are moved, never redrawn, so everything stays editable.
extension Scene {
  public enum Anchor: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var unit: CGPoint { CGPoint(x: CGFloat(rawValue % 3) / 2, y: CGFloat(rawValue / 3) / 2) }
  }

  /// Makes `rect` the paper, keeping every element where it is relative to the drawing.
  public mutating func crop(to rect: CGRect) {
    let rect = rect.integral
    guard rect.width >= 1, rect.height >= 1 else { return }
    let all = Set(elements.map(\.id))
    translateAll(dx: -rect.minX, dy: -rect.minY, ids: all)
    paper.width = rect.width
    paper.height = rect.height
  }

  /// Changes the paper's size, keeping the drawing at the anchor.
  public mutating func resizePaper(to size: CGSize, anchor: Anchor = .topLeft) {
    let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    let dx = (size.width - paper.width) * anchor.unit.x, dy = (size.height - paper.height) * anchor.unit.y
    crop(to: CGRect(x: -dx.rounded(), y: -dy.rounded(), width: size.width, height: size.height))
  }

  /// Fits the paper around the drawing, with `margin` to spare.
  public mutating func fitPaperToDrawing(margin: CGFloat = 0) {
    let content = contentBounds
    guard !content.isNull else { return }
    crop(to: content.insetBy(dx: -margin, dy: -margin))
  }

  /// Turns the whole drawing a quarter turn, swapping the paper's width and height.
  public mutating func rotatePaper(clockwise: Bool) {
    let old = paperRect
    let all = Set(elements.map(\.id))
    rotate(all, by: clockwise ? .pi / 2 : -.pi / 2, around: old.center)
    swap(&paper.width, &paper.height)
    // The rotated paper has the same centre; move everything so it starts at the origin again.
    translateAll(dx: (old.height - old.width) / 2, dy: (old.width - old.height) / 2, ids: all)
  }

  /// Mirrors the whole drawing within the paper.
  public mutating func flipPaper(_ axis: Axis) {
    mirror(Set(elements.map(\.id)), axis, around: paperRect.center)
  }

  mutating func translateAll(dx: CGFloat, dy: CGFloat, ids: Set<String>) {
    guard dx != 0 || dy != 0 else { return }
    for i in elements.indices where ids.contains(elements[i].id) {
      elements[i].x += dx
      elements[i].y += dy
    }
  }
}
