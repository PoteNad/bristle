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

  /// The frame, if the drawing has one.
  public var frame: CGRect? {
    get { paper.frame }
    set { paper.frame = newValue.map { $0.standardized.integral } }
  }

  /// What exports, prints, and copies cover: the frame, or else the drawing with a small margin.
  public var exportArea: CGRect? {
    if let frame = paper.frame { return frame }
    let content = contentBounds
    return content.isNull ? nil : content.insetBy(dx: -Paper.margin, dy: -Paper.margin).integral
  }
}

/// The canvas a drawing is made on. It's endless; an optional frame marks the part that is
/// exported and printed, as an opened image's own edges do.
public struct Paper: Equatable, Sendable {
  /// The part exported and printed, or `nil` for the whole drawing.
  public var frame: CGRect?
  /// The canvas color, or `nil` for none: the canvas follows the appearance on screen and is
  /// transparent in exports unless they add one.
  public var background: Color?
  /// Pixels per inch recorded in exported images, so a Retina screenshot keeps its size.
  public var resolution: CGFloat

  /// The space kept around the drawing when there's no frame.
  public static let margin: CGFloat = 24

  public init(frame: CGRect? = nil, background: Color? = nil, resolution: CGFloat = 72) {
    self.frame = frame
    self.background = background
    self.resolution = resolution
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
