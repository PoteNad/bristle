import CoreGraphics
import Foundation

/// Changing the canvas, as MS Paint's Resize, Crop, Rotate, and Flip do. They move the canvas's
/// edges or the elements, never pixels, so everything stays editable.
extension Scene {
  public enum Anchor: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var unit: CGPoint { CGPoint(x: CGFloat(rawValue % 3) / 2, y: CGFloat(rawValue / 3) / 2) }
  }

  /// Moves every element, as the canvas's corner moves when it grows or shrinks from the left
  /// or the top.
  mutating func shiftAll(dx: CGFloat, dy: CGFloat) {
    move(Set(elements.map(\.id)), dx: dx, dy: dy)
  }

  /// Makes `rect` the canvas: what's in it stays where it is on the page.
  public mutating func crop(to rect: CGRect) {
    let rect = rect.standardized.integral
    guard rect.width >= 1, rect.height >= 1 else { return }
    shiftAll(dx: -rect.minX, dy: -rect.minY)
    paper.size = rect.size
  }

  /// Changes the canvas's size, keeping the drawing at the anchor: at the top left, it grows
  /// and shrinks at the right and bottom, as dragging MS Paint's canvas does.
  public mutating func resizeCanvas(to size: CGSize, anchor: Anchor = .topLeft) {
    let size = Paper.clamped(size)
    let old = paper.size
    guard size != old else { return }
    let dx = ((size.width - old.width) * anchor.unit.x).rounded(), dy = ((size.height - old.height) * anchor.unit.y).rounded()
    shiftAll(dx: dx, dy: dy)
    paper.size = size
  }

  /// Fits the canvas around the drawing, with `margin` to spare.
  public mutating func fitCanvasToDrawing(margin: CGFloat = Paper.margin) {
    let content = contentBounds
    guard !content.isNull else { return }
    crop(to: content.insetBy(dx: -margin, dy: -margin))
  }

  /// Turns the whole drawing a quarter turn, canvas and all.
  public mutating func rotateDrawing(clockwise: Bool) {
    let old = paper.size
    let pivot = canvas.center
    rotate(Set(elements.map(\.id)), by: clockwise ? .pi / 2 : -.pi / 2, around: pivot)
    // The turned canvas's corner goes back to the origin.
    shiftAll(dx: old.height / 2 - pivot.x, dy: old.width / 2 - pivot.y)
    paper.size = CGSize(width: old.height, height: old.width)
  }

  /// Mirrors the whole drawing within its canvas.
  public mutating func flipDrawing(_ axis: Axis) {
    guard !elements.isEmpty else { return }
    mirror(Set(elements.map(\.id)), axis, around: canvas.center)
  }
}
