import CoreGraphics
import CryptoKit
import Foundation

/// A drawing: the canvas settings, the elements from back to front, and the images they show.
public struct Scene: Equatable, Sendable {
  public var paper: Paper
  /// Back to front: later elements draw over earlier ones.
  public var elements: [Element]
  /// Image data by id, for image elements.
  public var files: [String: ImageFile]

  public init(paper: Paper = Paper(), elements: [Element] = [], files: [String: ImageFile] = [:]) {
    self.paper = paper
    self.elements = elements
    self.files = files
  }

  public func index(of id: String) -> Int? { elements.firstIndex { $0.id == id } }

  public subscript(id: String) -> Element? {
    get { index(of: id).map { elements[$0] } }
    set {
      guard let index = index(of: id) else { return }
      if let newValue { elements[index] = newValue } else { elements.remove(at: index) }
    }
  }

  /// Adds image data, reusing an entry with the same bytes, and returns its id.
  @discardableResult
  public mutating func addFile(_ file: ImageFile) -> String {
    let id = file.id
    if files[id] == nil { files[id] = file }
    return id
  }

  /// Drops image data no element shows any more.
  public mutating func removeUnusedFiles() {
    let used = Set(elements.lazy.filter { $0.kind == .image }.map(\.file))
    files = files.filter { used.contains($0.key) }
  }

  /// The canvas: the page that's drawn on, exported, and printed, as MS Paint's is. It starts at
  /// the origin; anything beyond it is kept but not shown.
  public var canvas: CGRect { CGRect(origin: .zero, size: paper.size) }
}

/// The canvas a drawing is made on: a page of a fixed size, which grows or shrinks when asked,
/// as MS Paint's does.
public struct Paper: Equatable, Sendable {
  /// The canvas's size, in points, which are pixels in exported images.
  public var size: CGSize {
    didSet { size = Paper.clamped(size) }
  }
  /// The canvas's color, or `nil` for a transparent canvas, shown as a checkerboard.
  public var background: Color?
  /// Pixels per inch recorded in exported images, so a Retina screenshot keeps its size.
  public var resolution: CGFloat

  /// A new drawing's canvas.
  public static let standardSize = CGSize(width: 1200, height: 800)
  /// The space kept around the drawing when the canvas is fitted to it.
  public static let margin: CGFloat = 24
  /// The largest side a canvas can have.
  public static let maximumSide: CGFloat = 20_000

  public init(size: CGSize = Paper.standardSize, background: Color? = .white, resolution: CGFloat = 72) {
    self.size = Paper.clamped(size)
    self.background = background
    self.resolution = resolution
  }

  /// Whole points, at least one and at most the largest side.
  public static func clamped(_ size: CGSize) -> CGSize {
    func side(_ value: CGFloat) -> CGFloat { value.isFinite ? min(maximumSide, max(1, value.rounded())) : 1 }
    return CGSize(width: side(size.width), height: side(size.height))
  }
}

/// Image bytes exactly as they were placed or opened, so nothing is re-encoded.
public struct ImageFile: Equatable, Sendable {
  /// A uniform type identifier, such as `public.png` or `public.jpeg`.
  public var type: String
  public var data: Data

  public init(type: String, data: Data) {
    self.type = type
    self.data = data
  }

  /// The first 16 hex digits of the SHA-256 of the data, so identical images share one entry.
  public var id: String {
    SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
  }
}
