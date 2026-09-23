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
      // Pixels keep hard edges, as they would in a paint program.
      if element.brush == .pixel { context.setShouldAntialias(false) }
      context.setFillColor((element.stroke ?? .ink).cgColor)
      context.addPath(element.path)
      context.fillPath(using: .winding)
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

  /// Draws the background, if any, and the elements that touch `rect`.
  public static func draw(
    _ scene: Scene, in context: CGContext, rect: CGRect? = nil, images: ImageStore, background: Color? = nil
  ) {
    let area = rect ?? scene.exportArea ?? .zero
    if let background = scene.paper.background ?? background {
      context.setFillColor(background.cgColor)
      context.fill(area)
    }
    for element in scene.elements where element.bounds.intersects(area) {
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

  /// The drawing as an image, `scale` pixels per canvas unit: its frame, or all of it. A
  /// `background` fills the image when the drawing has no background of its own.
  public static func image(
    _ scene: Scene, scale: CGFloat = 1, area: CGRect? = nil, images: ImageStore = ImageStore(), background: Color? = nil
  ) -> CGImage? {
    let area = area ?? scene.exportArea ?? CGRect(x: 0, y: 0, width: 1, height: 1)
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

  /// The drawing as a vector PDF, one page the size of its frame, or of all of it.
  public static func pdf(
    _ scene: Scene, area: CGRect? = nil, images: ImageStore = ImageStore(), title: String? = nil,
    background: Color? = nil
  ) -> Data {
    let area = area ?? scene.exportArea ?? CGRect(x: 0, y: 0, width: 1, height: 1)
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
