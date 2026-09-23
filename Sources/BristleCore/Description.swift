import CoreGraphics
import Foundation

extension Element {
  /// What the element is, in words: "Red rectangle", "Arrow", "Text: Hello".
  public var kindName: String {
    switch kind {
    case .rectangle: "Rectangle"
    case .ellipse: "Ellipse"
    case .polygon: "Polygon"
    case .line: "Line"
    case .arrow: "Arrow"
    case .freehand: brush == .highlighter ? "Highlighter stroke" : "Drawing"
    case .text: "Text"
    case .image: "Image"
    }
  }

  /// A description for VoiceOver.
  public var summary: String {
    var parts: [String] = []
    switch kind {
    case .text:
      let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
      parts.append(text.isEmpty ? "Empty text" : "Text: " + String(text.prefix(80)))
    case .image:
      parts.append("Image")
    default:
      let colour = (kind == .freehand || isLinear ? stroke : fill ?? stroke)?.name
      let name = kindName
      parts.append(colour.map { $0.prefix(1).uppercased() + $0.dropFirst() + " " + name.lowercased() } ?? name)
    }
    parts.append("\(Int(width.rounded())) by \(Int(height.rounded()))")
    if rotation != 0 { parts.append("rotated \(Int((rotation * 180 / .pi).rounded()))°") }
    if locked { parts.append("locked") }
    if !groups.isEmpty { parts.append("grouped") }
    return parts.joined(separator: ", ")
  }
}
