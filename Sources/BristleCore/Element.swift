import CoreGraphics
import Foundation

/// One object on the canvas. Everything Bristle draws is an element and stays editable: shapes,
/// lines and arrows, freehand strokes, text, and images.
///
/// An element occupies `frame` before rotation and turns by `rotation` radians around the frame's
/// centre. Point-based elements (polygons, lines, arrows, freehand strokes) keep their points
/// relative to the frame's origin, so moving an element only changes its origin.
public struct Element: Equatable, Sendable, Identifiable {
  public enum Kind: String, CaseIterable, Sendable {
    case rectangle, ellipse, polygon, line, arrow, freehand, text, image
  }

  public var id: String
  public var kind: Kind
  public var x: CGFloat = 0
  public var y: CGFloat = 0
  public var width: CGFloat = 0
  public var height: CGFloat = 0
  /// Clockwise on screen, in radians, around the centre of the frame.
  public var rotation: CGFloat = 0

  /// The outline or line colour, or text colour. `nil` draws no outline.
  public var stroke: Color? = .ink
  public var strokeWidth: CGFloat = 3
  public var dash: Dash = .solid
  /// The interior of closed shapes, or the background of text. `nil` leaves it clear.
  public var fill: Color?
  public var opacity: CGFloat = 1
  public var cornerRadius: CGFloat = 0

  public var points: [CGPoint] = []
  /// Pen pressure for each point of a freehand stroke drawn with a tablet, from 0 to 1.
  public var pressures: [CGFloat] = []
  public var brush: Brush = .pen
  /// Lines, arrows, and polygons pass smoothly through their points instead of turning corners.
  public var curved = false
  public var startArrowhead: Arrowhead = .none
  public var endArrowhead: Arrowhead = .none
  public var startBinding: Binding?
  public var endBinding: Binding?

  public var text = ""
  /// A PostScript font name, or empty for the system font.
  public var fontName = ""
  public var fontSize: CGFloat = 24
  public var textAlign: TextAlign = .left
  /// Text wraps at `width` instead of the frame growing to fit each line.
  public var fixedWidth = false

  /// The image's entry in `Scene.files`.
  public var file = ""
  /// The part of the image shown, in unit coordinates of the image; `nil` shows all of it.
  public var crop: CGRect?
  public var flipX = false
  public var flipY = false

  public var locked = false
  /// The groups the element belongs to, innermost first.
  public var groups: [String] = []

  public init(id: String = Element.newID(), kind: Kind) {
    self.id = id
    self.kind = kind
    if kind == .arrow { endArrowhead = .arrow }
    if kind == .text || kind == .image { strokeWidth = 0 }
    if kind == .image { stroke = nil }
  }

  public enum Dash: String, CaseIterable, Sendable { case solid, dashed, dotted }

  public enum Brush: String, CaseIterable, Sendable {
    /// An even line with round ends.
    case pencil
    /// Thickness follows pressure, or speed with a mouse, and the ends taper.
    case pen
    /// A broad, even, translucent line with square ends.
    case highlighter
  }

  public enum Arrowhead: String, CaseIterable, Sendable { case none, arrow, triangle, circle, bar }

  public enum TextAlign: String, CaseIterable, Sendable { case left, center, right }

  /// Where a line or arrow end is attached to another element, so it follows that element.
  public struct Binding: Equatable, Sendable {
    public var element: String
    /// The point the end aims at, in unit coordinates of the element's unrotated frame.
    public var anchor: CGPoint

    public init(element: String, anchor: CGPoint) {
      self.element = element
      self.anchor = anchor
    }
  }

  public static func newID() -> String {
    var generator = SystemRandomNumberGenerator()
    return String(generator.next() & 0x000F_FFFF_FFFF_FFFF, radix: 36)
  }

  // MARK: Geometry

  public var frame: CGRect {
    get { CGRect(x: x, y: y, width: width, height: height) }
    set {
      x = newValue.minX
      y = newValue.minY
      width = newValue.width
      height = newValue.height
    }
  }

  public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }

  public var isPointBased: Bool { [.polygon, .line, .arrow, .freehand].contains(kind) }
  public var isLinear: Bool { kind == .line || kind == .arrow }
  public var isClosed: Bool { [.rectangle, .ellipse, .polygon, .text, .image].contains(kind) }

  /// Maps the element's unrotated coordinates to the canvas.
  public var transform: CGAffineTransform {
    guard rotation != 0 else { return .identity }
    let c = center
    return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation).translatedBy(x: -c.x, y: -c.y)
  }

  /// A canvas point in the element's unrotated coordinates.
  public func local(_ point: CGPoint) -> CGPoint {
    rotation == 0 ? point : point.applying(transform.inverted())
  }

  /// The element's points on the canvas, including rotation.
  public var worldPoints: [CGPoint] {
    let t = transform
    return points.map { CGPoint(x: $0.x + x, y: $0.y + y).applying(t) }
  }

  /// Replaces the points with canvas points, straightening any rotation into the points.
  public mutating func setWorldPoints(_ world: [CGPoint]) {
    rotation = 0
    let box = CGRect(boundingPoints: world)
    x = box.minX
    y = box.minY
    width = box.width
    height = box.height
    points = world.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
  }

  /// Fits the frame to the points, keeping them where they are on the canvas.
  public mutating func fitFrameToPoints() {
    guard !points.isEmpty else { return }
    let box = CGRect(boundingPoints: points)
    guard box.origin != .zero || box.size != frame.size else { return }
    let shifted = points.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
    // Keep a rotated element in place: its new centre is where the points' centre was drawn.
    let pointsCenter = CGPoint(x: x + box.midX, y: y + box.midY).applying(transform)
    points = shifted
    width = box.width
    height = box.height
    if rotation == 0 {
      x += box.minX
      y += box.minY
    } else {
      x = pointsCenter.x - width / 2
      y = pointsCenter.y - height / 2
    }
  }

  /// Scales the element to a new unrotated frame. Points scale with it; stroke widths don't.
  /// Text scales its font when `scalesText` is set, and otherwise wraps to the new width.
  public mutating func resize(to newFrame: CGRect, scalesText: Bool = false) {
    let sx = width > 0.0001 ? newFrame.width / width : 1
    let sy = height > 0.0001 ? newFrame.height / height : 1
    if isPointBased {
      points = points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
    }
    if kind == .text {
      if scalesText {
        fontSize = max(1, fontSize * (sy.isFinite ? sy : 1))
      } else if abs(newFrame.width - width) > 0.001 {
        fixedWidth = true
      }
    }
    frame = newFrame
  }

  /// Turns the element by `angle` around `pivot`.
  public mutating func rotate(by angle: CGFloat, around pivot: CGPoint) {
    let c = center
    let turned = CGPoint(x: c.x - pivot.x, y: c.y - pivot.y).applying(CGAffineTransform(rotationAngle: angle))
    x = pivot.x + turned.x - width / 2
    y = pivot.y + turned.y - height / 2
    rotation = Element.normalized(rotation + angle)
  }

  public static func normalized(_ angle: CGFloat) -> CGFloat {
    var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if a < 0 { a += 2 * .pi }
    if abs(a) < 1e-9 || abs(a - 2 * .pi) < 1e-9 { return 0 }
    return a
  }
}

extension CGRect {
  /// The smallest rectangle containing every point.
  public init(boundingPoints points: [CGPoint]) {
    guard let first = points.first else {
      self = .zero
      return
    }
    var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
    for p in points.dropFirst() {
      minX = Swift.min(minX, p.x)
      maxX = Swift.max(maxX, p.x)
      minY = Swift.min(minY, p.y)
      maxY = Swift.max(maxY, p.y)
    }
    self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  public var center: CGPoint { CGPoint(x: midX, y: midY) }

  public var corners: [CGPoint] {
    [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
  }
}

extension CGPoint {
  public func distance(to other: CGPoint) -> CGFloat { hypot(other.x - x, other.y - y) }
}
