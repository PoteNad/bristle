import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoded images for a scene's files, kept so each is decoded once.
public final class ImageStore {
  private var images: [String: CGImage] = [:]

  public init() {}

  public func image(for id: String, in scene: Scene) -> CGImage? {
    if let image = images[id] { return image }
    guard let file = scene.files[id], let image = ImageStore.decode(file.data) else { return nil }
    images[id] = image
    return image
  }

  public func removeAll() { images.removeAll() }

  /// Decodes image data upright, applying any orientation a camera recorded.
  public static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      return nil
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if orientation == 1 { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// The upright size of image data in pixels.
  public static func pixelSize(of data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
    else { return nil }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }

  /// Pixels per inch recorded in image data, if any.
  public static func resolution(of data: Data) -> CGFloat? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 0
    else { return nil }
    return dpi
  }
}

/// Draws elements with Core Graphics. The canvas, PNG, PDF, printing, and the clipboard all draw
/// through here, so every output matches what's on screen.
public enum Renderer {
  /// Draws one element into a context whose y axis points down.
  public static func draw(_ element: Element, in context: CGContext, scene: Scene, images: ImageStore) {
    context.saveGState()
    defer { context.restoreGState() }
    if element.opacity < 1 {
      context.setAlpha(element.opacity)
      // Overlapping parts of a translucent element shouldn't darken each other.
      context.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    defer { if element.opacity < 1 { context.endTransparencyLayer() } }
    if element.rotation != 0 { context.concatenate(element.transform) }
    switch element.kind {
    case .freehand:
      drawInk(element, in: context)
    case .text:
      if let fill = element.fill {
        context.setFillColor(fill.cgColor)
        context.fill(element.frame)
      }
      TextLayout(element).draw(in: context)
    case .image:
      drawImage(element, in: context, scene: scene, images: images)
      strokeOutline(element, in: context)
    case .rectangle, .ellipse, .polygon:
      if let fill = element.fill {
        context.setFillColor(fill.cgColor)
        context.addPath(element.path)
        context.fillPath(using: .evenOdd)
      }
      strokeOutline(element, in: context)
    case .line, .arrow:
      strokeOutline(element, in: context)
      guard let stroke = element.stroke else { break }
      context.setLineDash(phase: 0, lengths: [])
      for head in element.arrowheads {
        context.addPath(head.path)
        if head.filled {
          context.setFillColor(stroke.cgColor)
          context.fillPath()
        } else {
          context.setStrokeColor(stroke.cgColor)
          context.setLineWidth(element.strokeWidth)
          context.setLineCap(.round)
          context.setLineJoin(.round)
          context.strokePath()
        }
      }
    }
  }

  /// A freehand stroke, with the texture of its brush.
  public static func drawInk(_ element: Element, path known: CGPath? = nil, in context: CGContext) {
    let color = (element.stroke ?? .ink).cgColor
    let path = known ?? element.path
    context.setFillColor(color)
    switch element.brush {
    case .pixel:
      // Pixels keep hard edges, as they would in a paint program.
      context.setShouldAntialias(false)
      context.addPath(path)
      context.fillPath()
    case .crayon:
      // The colour, with a grain rubbed out of it, as wax skips over paper.
      context.beginTransparencyLayer(auxiliaryInfo: nil)
      context.addPath(path)
      context.fillPath()
      context.addPath(path)
      context.clip()
      context.setBlendMode(.destinationOut)
      // Tile by tile, each always in the same place, so a stroke redrawn in parts, as the
      // canvas does, matches one drawn whole.
      let side: CGFloat = 48
      let area = path.boundingBoxOfPath.intersection(context.boundingBoxOfClipPath)
      if !area.isNull {
        var y = (area.minY / side).rounded(.down) * side
        while y < area.maxY {
          var x = (area.minX / side).rounded(.down) * side
          while x < area.maxX {
            context.draw(grain, in: CGRect(x: x, y: y, width: side, height: side))
            x += side
          }
          y += side
        }
      }
      context.endTransparencyLayer()
    case .marker:
      // One flat layer, so the stroke doesn't darken where it crosses itself.
      context.setAlpha(0.85)
      context.beginTransparencyLayer(auxiliaryInfo: nil)
      context.addPath(path)
      context.fillPath()
      context.endTransparencyLayer()
    case .watercolor:
      // A thin wash, one layer so it doesn't darken where it crosses itself, that bleeds softly
      // at its edges.
      context.setShadow(offset: .zero, blur: max(1, element.strokeWidth * 0.3), color: color.copy(alpha: 0.6))
      context.setAlpha(0.5)
      context.beginTransparencyLayer(auxiliaryInfo: nil)
      context.addPath(path)
      context.fillPath()
      context.endTransparencyLayer()
    case .oil:
      // Thick paint, with light and dark streaks along the stroke where the bristles pull.
      context.addPath(path)
      context.fillPath()
      let centre = element.points.map { CGPoint(x: $0.x + element.x, y: $0.y + element.y) }
      guard centre.count > 1 else { break }
      context.saveGState()
      context.addPath(path)
      context.clip()
      let r = element.strokeWidth / 2
      for (offset, light) in [(-0.55, true), (-0.15, false), (0.3, true), (0.65, false)] as [(CGFloat, Bool)] {
        let streak = CGMutablePath()
        for (i, p) in centre.enumerated() {
          let a = centre[max(0, i - 1)], b = centre[min(centre.count - 1, i + 1)]
          let length = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
          let q = CGPoint(x: p.x - (b.y - a.y) / length * r * offset, y: p.y + (b.x - a.x) / length * r * offset)
          if i == 0 { streak.move(to: q) } else { streak.addLine(to: q) }
        }
        context.addPath(streak)
        context.setStrokeColor(light ? CGColor(gray: 1, alpha: 0.22) : CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(max(0.5, r * 0.18))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
      }
      context.restoreGState()
    default:
      context.addPath(path)
      context.fillPath(using: .winding)
    }
  }

  /// Speckles of paper for crayon, the same every time.
  nonisolated(unsafe) static let grain: CGImage = {
    let side = 48
    let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var seed: UInt64 = 11
    for y in 0..<side {
      for x in 0..<side {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let v = CGFloat(seed >> 11) / CGFloat(1 << 53)
        // Mostly solid colour, with a scatter of gaps.
        guard v > 0.72 else { continue }
        context.setFillColor(CGColor(gray: 0, alpha: 0.45 + (v - 0.72) / 0.28 * 0.55))
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
      }
    }
    return context.makeImage()!
  }()

  static func strokeOutline(_ element: Element, in context: CGContext) {
    guard let stroke = element.stroke, element.strokeWidth > 0 else { return }
    context.setStrokeColor(stroke.cgColor)
    context.setLineWidth(element.strokeWidth)
    context.setLineCap(element.dash == .dotted ? .round : element.isLinear ? .round : .butt)
    context.setLineJoin(.round)
    context.setLineDash(phase: 0, lengths: dashLengths(element))
    context.addPath(element.path)
    context.strokePath()
  }

  public static func dashLengths(_ element: Element) -> [CGFloat] {
    let w = max(element.strokeWidth, 0.5)
    switch element.dash {
    case .solid: return []
    case .dashed: return [w * 3 + 4, w * 2 + 4]
    case .dotted: return [0.01, w * 2 + 2]
    }
  }

  static func drawImage(_ element: Element, in context: CGContext, scene: Scene, images: ImageStore) {
    let frame = element.frame
    guard let image = images.image(for: element.file, in: scene) else {
      // Missing image data shows a placeholder rather than nothing.
      context.setFillColor(CGColor(gray: 0.5, alpha: 0.2))
      context.fill(frame)
      return
    }
    context.saveGState()
    context.clip(to: frame)
    let crop = element.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    // The whole image, placed so the cropped part fills the frame.
    let fullWidth = frame.width / max(crop.width, 0.0001), fullHeight = frame.height / max(crop.height, 0.0001)
    var full = CGRect(
      x: frame.minX - crop.minX * fullWidth, y: frame.minY - crop.minY * fullHeight, width: fullWidth,
      height: fullHeight)
    context.translateBy(x: frame.midX, y: frame.midY)
    context.scaleBy(x: element.flipX ? -1 : 1, y: element.flipY ? 1 : -1)
    full = full.offsetBy(dx: -frame.midX, dy: -frame.midY)
    // The context is flipped, so draw the image upside down in local space to show it upright.
    full.origin.y = -full.maxY
    // A canvas zoomed in far asks for the image's own pixels, drawn square.
    if context.interpolationQuality != .none { context.interpolationQuality = .high }
    context.draw(image, in: full)
    context.restoreGState()
  }

  /// Draws the background, if any, and the elements that touch `rect`, within the canvas.
  public static func draw(
    _ scene: Scene, in context: CGContext, rect: CGRect? = nil, images: ImageStore, background: Color? = nil
  ) {
    let area = rect ?? scene.canvas
    if let background = scene.paper.background ?? background {
      context.setFillColor(background.cgColor)
      context.fill(area.intersection(scene.canvas))
    }
    // Nothing shows beyond the canvas.
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: scene.canvas)
    for element in scene.elements where element.drawnBounds.intersects(area) {
      draw(element, in: context, scene: scene, images: images)
    }
  }

  /// A bitmap context whose y axis points down, `scale` pixels per canvas unit.
  public static func bitmap(size: CGSize, scale: CGFloat) -> CGContext? {
    let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    return context
  }

  /// The drawing as an image, `scale` pixels per canvas unit: its canvas, or `area` of it. A
  /// `background` fills the image when the canvas is transparent.
  public static func image(
    _ scene: Scene, scale: CGFloat = 1, area: CGRect? = nil, images: ImageStore = ImageStore(), background: Color? = nil
  ) -> CGImage? {
    let area = area ?? scene.canvas
    guard let context = bitmap(size: area.size, scale: scale) else { return nil }
    context.translateBy(x: -area.minX, y: -area.minY)
    draw(scene, in: context, rect: area, images: images, background: background)
    return context.makeImage()
  }

  /// Encodes an image as PNG, recording `resolution` pixels per inch.
  public static func png(_ image: CGImage, resolution: CGFloat = 72) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: resolution, kCGImagePropertyDPIHeight: resolution]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// The drawing as a vector PDF, one page the size of its canvas.
  public static func pdf(
    _ scene: Scene, area: CGRect? = nil, images: ImageStore = ImageStore(), title: String? = nil,
    background: Color? = nil
  ) -> Data {
    let area = area ?? scene.canvas
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: area.size)
    var info: [CFString: Any] = [kCGPDFContextCreator: "Bristle"]
    if let title { info[kCGPDFContextTitle] = title }
    guard let consumer = CGDataConsumer(data: data),
      let context = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary)
    else { return Data() }
    context.beginPDFPage(nil)
    context.translateBy(x: 0, y: area.height)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -area.minX, y: -area.minY)
    context.clip(to: area)
    draw(scene, in: context, rect: area, images: images, background: background)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }
}
