import CoreGraphics
import Foundation

/// The frame: the part of the endless canvas that's exported and printed. Cropping, resizing,
/// rotating, and flipping move the frame or the elements, never pixels, so everything stays
/// editable.
extension Scene {
  public enum Anchor: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var unit: CGPoint { CGPoint(x: CGFloat(rawValue % 3) / 2, y: CGFloat(rawValue / 3) / 2) }
  }

  /// Makes `rect` the frame.
  public mutating func crop(to rect: CGRect) {
    let rect = rect.integral
    guard rect.width >= 1, rect.height >= 1 else { return }
    frame = rect
  }

  /// Changes the frame's size, keeping the anchor where it is. With no frame, one is made around
  /// the drawing first.
  public mutating func resizeFrame(to size: CGSize, anchor: Anchor = .topLeft) {
    let size = CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    let current = frame ?? exportArea ?? CGRect(origin: .zero, size: size)
    let dx = (size.width - current.width) * anchor.unit.x, dy = (size.height - current.height) * anchor.unit.y
    frame = CGRect(x: current.minX - dx.rounded(), y: current.minY - dy.rounded(), width: size.width, height: size.height)
  }

  /// Fits the frame around the drawing, with `margin` to spare.
  public mutating func fitFrameToDrawing(margin: CGFloat = Paper.margin) {
    let content = contentBounds
    guard !content.isNull else { return }
    crop(to: content.insetBy(dx: -margin, dy: -margin))
  }

  /// The middle that rotating and flipping the whole drawing turn around.
  var drawingCenter: CGPoint { (frame ?? contentBounds).center }

  /// Turns the whole drawing a quarter turn, with its frame.
  public mutating func rotateDrawing(clockwise: Bool) {
    let pivot = drawingCenter
    let all = Set(elements.map(\.id))
    rotate(all, by: clockwise ? .pi / 2 : -.pi / 2, around: pivot)
    if let old = frame {
      frame = CGRect(x: pivot.x - old.height / 2, y: pivot.y - old.width / 2, width: old.height, height: old.width)
    }
  }

  /// Mirrors the whole drawing within its frame.
  public mutating func flipDrawing(_ axis: Axis) {
    guard !elements.isEmpty else { return }
    mirror(Set(elements.map(\.id)), axis, around: drawingCenter)
  }
}
