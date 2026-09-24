import CoreGraphics
import CoreText
import Foundation

/// Writes a scene as SVG: shapes and strokes as paths, text as text, and images embedded.
public enum SVG {
  public static func document(_ scene: Scene, area: CGRect? = nil, background: Color? = nil) -> Data {
    let area = area ?? scene.canvas
    var out = """
      <?xml version="1.0" encoding="UTF-8"?>
      <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
      width="\(n(area.width))" height="\(n(area.height))" \
      viewBox="\(n(area.minX)) \(n(area.minY)) \(n(area.width)) \(n(area.height))">

      """
    out += "<defs><clipPath id=\"paper\"><rect x=\"\(n(area.minX))\" y=\"\(n(area.minY))\" width=\"\(n(area.width))\" height=\"\(n(area.height))\"/></clipPath></defs>\n"
    if let background = scene.paper.background ?? background {
      out += "<rect x=\"\(n(area.minX))\" y=\"\(n(area.minY))\" width=\"\(n(area.width))\" height=\"\(n(area.height))\"\(paint("fill", background))/>\n"
    }
    out += "<g clip-path=\"url(#paper)\">\n"
    var clips = 0
    for element in scene.elements where element.drawnBounds.intersects(area) {
      out += self.element(element, scene: scene, clips: &clips)
    }
    out += "</g>\n</svg>\n"
    return Data(out.utf8)
  }

  static func element(_ e: Element, scene: Scene, clips: inout Int) -> String {
    var attributes = ""
    if e.rotation != 0 {
      attributes += " transform=\"rotate(\(n(e.rotation * 180 / .pi, 3)) \(n(e.center.x)) \(n(e.center.y)))\""
    }
    if e.opacity < 1 { attributes += " opacity=\"\(n(e.opacity, 3))\"" }
    var body = ""
    switch e.kind {
    case .freehand:
      body = "<path d=\"\(pathData(e.path))\"\(paint("fill", e.stroke ?? .ink))/>"
    case .rectangle, .ellipse, .polygon, .line, .arrow:
      let fill = e.isLinear ? " fill=\"none\"" : e.fill.map { paint("fill", $0) + " fill-rule=\"evenodd\"" } ?? " fill=\"none\""
      body = "<path d=\"\(pathData(e.path))\"\(fill)\(strokeAttributes(e))/>"
      if let stroke = e.stroke {
        for head in e.arrowheads {
          let style =
            head.filled
            ? paint("fill", stroke)
            : " fill=\"none\"" + paint("stroke", stroke, "stroke-opacity")
              + " stroke-width=\"\(n(e.strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
          body += "<path d=\"\(pathData(head.path))\"\(style)/>"
        }
      }
    case .text:
      if let fill = e.fill {
        body += "<rect x=\"\(n(e.x))\" y=\"\(n(e.y))\" width=\"\(n(e.width))\" height=\"\(n(e.height))\"\(paint("fill", fill))/>"
      }
      let layout = TextLayout(e)
      let family = e.fontName.isEmpty ? "-apple-system, system-ui, Helvetica Neue, sans-serif" : fontFamily(layout)
      body += "<text font-family=\"\(escape(family))\" font-size=\"\(n(e.fontSize))\"\(paint("fill", e.stroke ?? .ink))\(fontStyle(layout))>"
      for line in layout.placedLines where !line.text.isEmpty {
        body += "<tspan x=\"\(n(line.baseline.x))\" y=\"\(n(line.baseline.y))\" xml:space=\"preserve\">\(escape(line.text))</tspan>"
      }
      body += "</text>"
    case .image:
      guard let file = scene.files[e.file] else { break }
      clips += 1
      let crop = e.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
      let fullWidth = e.width / max(crop.width, 0.0001), fullHeight = e.height / max(crop.height, 0.0001)
      let fullX = e.x - crop.minX * fullWidth, fullY = e.y - crop.minY * fullHeight
      let mime = mimeType(file.type)
      var flip = ""
      if e.flipX || e.flipY {
        let c = e.center
        flip = " transform=\"translate(\(n(c.x)) \(n(c.y))) scale(\(e.flipX ? -1 : 1) \(e.flipY ? -1 : 1)) translate(\(n(-c.x)) \(n(-c.y)))\""
      }
      body += "<clipPath id=\"crop\(clips)\"><rect x=\"\(n(e.x))\" y=\"\(n(e.y))\" width=\"\(n(e.width))\" height=\"\(n(e.height))\"/></clipPath>"
      body += "<g clip-path=\"url(#crop\(clips))\"><image\(flip) x=\"\(n(fullX))\" y=\"\(n(fullY))\" width=\"\(n(fullWidth))\" height=\"\(n(fullHeight))\" preserveAspectRatio=\"none\" xlink:href=\"data:\(mime);base64,\(file.data.base64EncodedString())\"/></g>"
      if let stroke = e.stroke, e.strokeWidth > 0 {
        body += "<rect x=\"\(n(e.x))\" y=\"\(n(e.y))\" width=\"\(n(e.width))\" height=\"\(n(e.height))\" fill=\"none\"\(paint("stroke", stroke, "stroke-opacity")) stroke-width=\"\(n(e.strokeWidth))\"/>"
      }
    }
    guard !body.isEmpty else { return "" }
    return "<g\(attributes)>\(body)</g>\n"
  }

  static func strokeAttributes(_ e: Element) -> String {
    guard let stroke = e.stroke, e.strokeWidth > 0 else { return "" }
    var result = paint("stroke", stroke, "stroke-opacity") + " stroke-width=\"\(n(e.strokeWidth))\" stroke-linejoin=\"round\""
    let cap = e.dash == .dotted || e.isLinear ? "round" : "butt"
    result += " stroke-linecap=\"\(cap)\""
    let dashes = Renderer.dashLengths(e)
    if !dashes.isEmpty { result += " stroke-dasharray=\"\(dashes.map { n($0) }.joined(separator: " "))\"" }
    return result
  }

  static func paint(_ attribute: String, _ color: Color, _ opacityAttribute: String? = nil) -> String {
    let hex = String(color.hex.prefix(7))
    var result = " \(attribute)=\"\(hex)\""
    if color.alpha < 1 { result += " \(opacityAttribute ?? attribute + "-opacity")=\"\(n(color.alpha, 3))\"" }
    return result
  }

  static func fontFamily(_ layout: TextLayout) -> String {
    CTFontCopyFamilyName(layout.font) as String
  }

  static func fontStyle(_ layout: TextLayout) -> String {
    let traits = CTFontGetSymbolicTraits(layout.font)
    var result = ""
    if traits.contains(.traitBold) { result += " font-weight=\"bold\"" }
    if traits.contains(.traitItalic) { result += " font-style=\"italic\"" }
    return result
  }

  static func mimeType(_ type: String) -> String {
    switch type {
    case "public.png": "image/png"
    case "public.jpeg": "image/jpeg"
    case "com.compuserve.gif": "image/gif"
    case "public.heic": "image/heic"
    case "public.tiff": "image/tiff"
    case "org.webmproject.webp": "image/webp"
    default: "application/octet-stream"
    }
  }

  static func pathData(_ path: CGPath) -> String {
    var parts: [String] = []
    path.applyWithBlock { pointer in
      let element = pointer.pointee
      let p = element.points
      switch element.type {
      case .moveToPoint: parts.append("M\(n(p[0].x)) \(n(p[0].y))")
      case .addLineToPoint: parts.append("L\(n(p[0].x)) \(n(p[0].y))")
      case .addQuadCurveToPoint: parts.append("Q\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y))")
      case .addCurveToPoint:
        parts.append("C\(n(p[0].x)) \(n(p[0].y)) \(n(p[1].x)) \(n(p[1].y)) \(n(p[2].x)) \(n(p[2].y))")
      case .closeSubpath: parts.append("Z")
      @unknown default: break
      }
    }
    return parts.joined(separator: " ")
  }

  static func n(_ value: CGFloat, _ digits: Int = 2) -> String { JSON.format(value, digits: digits) }

  static func escape(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case let s where s.value < 0x20 && s != "\t": continue
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }
}
