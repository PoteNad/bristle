import CoreGraphics
import CryptoKit
import Foundation
import zlib

/// PNG chunks, and the Bristle drawing that a PNG saved by Bristle carries with it.
///
/// A Bristle PNG is an ordinary image with one extra chunk, `brSC`, holding the drawing as
/// zlib-compressed `.bristle` JSON. The chunk is private and marked unsafe to copy, so image
/// editors that follow the PNG specification drop it when they change the pixels. For editors
/// that don't, the JSON records a hash of the pixels it was saved with; if the pixels no longer
/// match, the drawing is stale and the image is opened as it is now.
public enum PNG {
  public static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  public static let sceneChunk = "brSC"

  public struct Chunk: Equatable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
      self.type = type
      self.data = data
    }
  }

  public static func isPNG(_ data: Data) -> Bool { data.starts(with: signature) }

  /// The chunks of a PNG in order, or `nil` if the data isn't a well-formed PNG.
  public static func chunks(_ data: Data) -> [Chunk]? {
    guard isPNG(data) else { return nil }
    var chunks: [Chunk] = []
    var offset = data.startIndex + signature.count
    while offset + 12 <= data.endIndex {
      let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
      let typeStart = offset + 4
      guard length >= 0, typeStart + 4 + length + 4 <= data.endIndex,
        let type = String(data: data[typeStart..<typeStart + 4], encoding: .ascii)
      else { return nil }
      chunks.append(Chunk(type: type, data: Data(data[typeStart + 4..<typeStart + 4 + length])))
      offset = typeStart + 4 + length + 4
      if type == "IEND" { return chunks }
    }
    return nil
  }

  public static func write(_ chunks: [Chunk]) -> Data {
    var out = signature
    for chunk in chunks {
      let type = Data(chunk.type.utf8)
      out.append(bigEndian(UInt32(chunk.data.count)))
      out.append(type)
      out.append(chunk.data)
      out.append(bigEndian(crc(type + chunk.data)))
    }
    return out
  }

  static func bigEndian(_ value: UInt32) -> Data {
    Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
  }

  public static func crc(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { bytes in
      UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
    }
  }

  // MARK: zlib

  public static func deflate(_ data: Data) -> Data {
    var length = compressBound(uLong(data.count))
    var out = Data(count: Int(length))
    let status = out.withUnsafeMutableBytes { output in
      data.withUnsafeBytes { input in
        compress2(
          output.bindMemory(to: Bytef.self).baseAddress, &length, input.bindMemory(to: Bytef.self).baseAddress,
          uLong(data.count), Z_BEST_COMPRESSION)
      }
    }
    precondition(status == Z_OK, "zlib could not compress")
    return out.prefix(Int(length))
  }

  public static func inflate(_ data: Data, limit: Int = 1 << 31) -> Data? {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    let input = [UInt8](data)
    return input.withUnsafeBufferPointer { inputPointer -> Data? in
      stream.next_in = UnsafeMutablePointer(mutating: inputPointer.baseAddress)
      stream.avail_in = uInt(input.count)
      while true {
        let status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
          stream.next_out = output.baseAddress
          stream.avail_out = uInt(output.count)
          let status = zlib.inflate(&stream, Z_NO_FLUSH)
          out.append(output.baseAddress!, count: output.count - Int(stream.avail_out))
          return status
        }
        if status == Z_STREAM_END { return out }
        guard status == Z_OK, out.count <= limit else { return nil }
      }
    }
  }

  // MARK: Drawings in PNGs

  /// A PNG with the drawing's JSON in a `brSC` chunk, replacing any earlier one.
  public static func embedding(_ json: Data, in png: Data) -> Data? {
    guard var chunks = chunks(png) else { return nil }
    chunks.removeAll { $0.type == sceneChunk }
    guard let end = chunks.lastIndex(where: { $0.type == "IEND" }) else { return nil }
    chunks.insert(Chunk(type: sceneChunk, data: deflate(json)), at: end)
    return write(chunks)
  }

  /// The drawing JSON a PNG carries, if any.
  public static func embeddedJSON(in png: Data) -> Data? {
    guard let chunk = chunks(png)?.first(where: { $0.type == sceneChunk }) else { return nil }
    return inflate(chunk.data)
  }

  /// A hash of an image's pixels as 8-bit sRGB, which survives lossless re-encoding.
  public static func pixelHash(_ image: CGImage) -> String {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var hasher = SHA256()
    hasher.update(data: Data("\(width)x\(height):".utf8))
    hasher.update(data: pixels)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func pixelHash(ofPNG data: Data) -> String? { ImageStore.decode(data).map(pixelHash) }
}

/// A drawing read from a PNG saved by Bristle.
public struct EmbeddedScene {
  public var scene: Scene
  /// Whether the pixels still match the drawing, or the image was changed in another app.
  public var isCurrent: Bool

  /// Reads the drawing a PNG carries, if it has one.
  public init?(png: Data) {
    guard let json = PNG.embeddedJSON(in: png), let object = try? SceneFile.object(from: json),
      let scene = try? SceneFile.scene(fromObject: object)
    else { return nil }
    self.scene = scene
    isCurrent = (object["pixels"] as? String) == PNG.pixelHash(ofPNG: png)
  }

  /// The scene as a PNG that reopens as the same drawing in Bristle.
  public static func png(_ scene: Scene, images: ImageStore = ImageStore()) -> Data? {
    guard let image = Renderer.image(scene, images: images),
      let png = Renderer.png(image, resolution: scene.paper.resolution),
      let hash = PNG.pixelHash(ofPNG: png)
    else { return nil }
    return PNG.embedding(SceneFile.data(scene, extra: [("pixels", .string(hash))]), in: png)
  }
}
