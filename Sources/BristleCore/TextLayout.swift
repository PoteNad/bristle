import CoreGraphics
import CoreText
import Foundation

/// Lays out a text element with Core Text, the same way on the canvas and in every export.
public struct TextLayout {
  /// Space between the frame and the text on each side.
  public static let inset: CGFloat = 4

  public let element: Element
  public let font: CTFont
  public let lines: [CTLine]
  /// Each line's baseline origin, relative to the top-left of the text (inside the inset).
  public let origins: [CGPoint]
  public let size: CGSize

  public static func font(name: String, size: CGFloat) -> CTFont {
    if !name.isEmpty {
      let font = CTFontCreateWithName(name as CFString, size, nil)
      // Core Text falls back to Helvetica for unknown names; keep the system font instead.
      if (CTFontCopyPostScriptName(font) as String) == name { return font }
    }
    return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
  }

  public static func attributes(for element: Element) -> [NSAttributedString.Key: Any] {
    let font = Self.font(name: element.fontName, size: element.fontSize)
    var alignment: CTTextAlignment
    switch element.textAlign {
    case .left: alignment = .left
    case .center: alignment = .center
    case .right: alignment = .right
    }
    let style = withUnsafeBytes(of: &alignment) { bytes in
      var setting = CTParagraphStyleSetting(
        spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
      return CTParagraphStyleCreate(&setting, 1)
    }
    return [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): (element.stroke ?? .ink).cgColor,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
    ]
  }

  public init(_ element: Element) {
    self.element = element
    font = Self.font(name: element.fontName, size: element.fontSize)
    let string = element.text.isEmpty ? " " : element.text
    let attributed = NSAttributedString(string: string, attributes: Self.attributes(for: element))
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let maxWidth = element.fixedWidth ? max(1, element.width - Self.inset * 2) : 100_000
    let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
      setter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
    let layoutWidth = element.fixedWidth ? maxWidth : ceil(fitted.width) + 1
    let height = ceil(fitted.height) + 1
    let frame = CTFramesetterCreateFrame(
      setter, CFRange(location: 0, length: 0),
      CGPath(rect: CGRect(x: 0, y: 0, width: layoutWidth, height: height), transform: nil), nil)
    lines = CTFrameGetLines(frame) as? [CTLine] ?? []
    var raw = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &raw)
    // Core Text measures from the bottom; the canvas measures from the top.
    origins = raw.map { CGPoint(x: $0.x, y: height - $0.y) }
    var measured = CGSize(width: layoutWidth, height: height)
    // A trailing newline starts an empty line Core Text doesn't report.
    if element.text.hasSuffix("\n") {
      let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
      measured.height += ceil(lineHeight)
    }
    size = measured
  }

  /// The frame size that fits the text, including the inset.
  public var frameSize: CGSize {
    CGSize(
      width: element.fixedWidth ? element.width : size.width + Self.inset * 2,
      height: size.height + Self.inset * 2)
  }

  /// Draws the text into a context whose y axis points down, as the canvas's does.
  public func draw(in context: CGContext) {
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    let origin = CGPoint(x: element.x + Self.inset, y: element.y + Self.inset)
    for (line, lineOrigin) in zip(lines, origins) {
      context.textPosition = CGPoint(x: origin.x + lineOrigin.x, y: origin.y + lineOrigin.y)
      CTLineDraw(line, context)
    }
    context.restoreGState()
  }

  /// Each line's text and baseline position on the canvas, for SVG.
  public var placedLines: [(text: String, baseline: CGPoint, width: CGFloat)] {
    let string = (element.text.isEmpty ? " " : element.text) as NSString
    return zip(lines, origins).map { line, origin in
      let range = CTLineGetStringRange(line)
      let text = string.substring(with: NSRange(location: range.location, length: range.length))
        .trimmingCharacters(in: .newlines)
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
      return (text, CGPoint(x: element.x + Self.inset + origin.x, y: element.y + Self.inset + origin.y), width)
    }
  }
}

extension Element {
  /// Sets the frame to fit the text, keeping the top-left corner and a fixed width.
  public mutating func fitToText() {
    guard kind == .text else { return }
    let size = TextLayout(self).frameSize
    width = fixedWidth ? width : size.width
    height = size.height
  }
}
