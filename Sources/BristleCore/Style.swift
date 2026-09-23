import CoreGraphics
import Foundation

/// How an element looks, apart from its geometry and content: what Copy Style copies, and what
/// each tool gives the elements it makes.
public struct Style: Equatable, Sendable {
  public var stroke: Color?
  public var strokeWidth: CGFloat
  public var dash: Element.Dash
  public var fill: Color?
  public var opacity: CGFloat
  public var cornerRadius: CGFloat
  public var startArrowhead: Element.Arrowhead
  public var endArrowhead: Element.Arrowhead
  public var curved: Bool
  public var fontName: String
  public var fontSize: CGFloat
  public var textAlign: Element.TextAlign

  public init(
    stroke: Color? = .ink, strokeWidth: CGFloat = 3, dash: Element.Dash = .solid, fill: Color? = nil,
    opacity: CGFloat = 1, cornerRadius: CGFloat = 0, startArrowhead: Element.Arrowhead = .none,
    endArrowhead: Element.Arrowhead = .none, curved: Bool = false, fontName: String = "", fontSize: CGFloat = 24,
    textAlign: Element.TextAlign = .left
  ) {
    self.stroke = stroke
    self.strokeWidth = strokeWidth
    self.dash = dash
    self.fill = fill
    self.opacity = opacity
    self.cornerRadius = cornerRadius
    self.startArrowhead = startArrowhead
    self.endArrowhead = endArrowhead
    self.curved = curved
    self.fontName = fontName
    self.fontSize = fontSize
    self.textAlign = textAlign
  }

  /// The style of an existing element.
  public init(_ e: Element) {
    self.init(
      stroke: e.stroke, strokeWidth: e.strokeWidth, dash: e.dash, fill: e.fill, opacity: e.opacity,
      cornerRadius: e.cornerRadius, startArrowhead: e.startArrowhead, endArrowhead: e.endArrowhead, curved: e.curved,
      fontName: e.fontName, fontSize: e.fontSize, textAlign: e.textAlign)
  }

  /// Gives an element this style, as far as it applies to that kind of element.
  public func apply(to e: inout Element) {
    e.stroke = stroke
    e.opacity = opacity
    switch e.kind {
    case .text:
      e.fill = fill
      e.fontName = fontName
      e.fontSize = fontSize
      e.textAlign = textAlign
      e.fitToText()
    case .image:
      e.strokeWidth = strokeWidth
    case .freehand:
      e.strokeWidth = strokeWidth
    case .line, .arrow:
      e.strokeWidth = strokeWidth
      e.dash = dash
      e.startArrowhead = startArrowhead
      e.endArrowhead = endArrowhead
      e.curved = curved
    case .rectangle, .ellipse, .polygon:
      e.strokeWidth = strokeWidth
      e.dash = dash
      e.fill = fill
      e.cornerRadius = cornerRadius
      if e.kind == .polygon { e.curved = curved }
    }
  }

  // MARK: Storing

  /// The style as JSON, for keeping each tool's settings between launches.
  public var json: String {
    var members: [(String, JSON)] = [
      ("stroke", stroke.map { .string($0.hex) } ?? .null), ("strokeWidth", .number(strokeWidth)),
      ("dash", .string(dash.rawValue)), ("fill", fill.map { .string($0.hex) } ?? .null),
      ("opacity", .number(opacity, digits: 3)), ("cornerRadius", .number(cornerRadius)),
      ("startArrowhead", .string(startArrowhead.rawValue)), ("endArrowhead", .string(endArrowhead.rawValue)),
      ("curved", .bool(curved)), ("fontSize", .number(fontSize)), ("textAlign", .string(textAlign.rawValue)),
    ]
    if !fontName.isEmpty { members.append(("font", .string(fontName))) }
    return JSON.object(members).text
  }

  public init?(json: String) {
    guard let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
    self.init()
    if o["stroke"] is NSNull { stroke = nil } else if let hex = o["stroke"] as? String { stroke = Color(hex: hex) }
    fill = (o["fill"] as? String).flatMap(Color.init(hex:))
    if let value = SceneFile.number(o["strokeWidth"]) { strokeWidth = max(0, value) }
    if let value = (o["dash"] as? String).flatMap(Element.Dash.init(rawValue:)) { dash = value }
    if let value = SceneFile.number(o["opacity"]) { opacity = min(1, max(0.05, value)) }
    if let value = SceneFile.number(o["cornerRadius"]) { cornerRadius = max(0, value) }
    if let value = (o["startArrowhead"] as? String).flatMap(Element.Arrowhead.init(rawValue:)) { startArrowhead = value }
    if let value = (o["endArrowhead"] as? String).flatMap(Element.Arrowhead.init(rawValue:)) { endArrowhead = value }
    curved = o["curved"] as? Bool ?? false
    fontName = o["font"] as? String ?? ""
    if let value = SceneFile.number(o["fontSize"]), value > 0 { fontSize = value }
    if let value = (o["textAlign"] as? String).flatMap(Element.TextAlign.init(rawValue:)) { textAlign = value }
  }
}
