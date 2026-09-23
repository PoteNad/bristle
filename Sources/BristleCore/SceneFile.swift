import CoreGraphics
import Foundation

/// Reads and writes the `.bristle` format: plain JSON with one element per line, so files are
/// readable and changes show up clearly in a diff. See the README for the full description.
public enum SceneFile {
  public static let formatName = "bristle"
  public static let version = 1

  public enum ReadError: Error, LocalizedError, Equatable {
    case notJSON
    case notBristle
    case newerVersion(Int)

    public var errorDescription: String? {
      switch self {
      case .notJSON: "The file isn’t valid JSON."
      case .notBristle: "The file isn’t a Bristle drawing."
      case .newerVersion(let version): "The drawing was made by a newer version of Bristle (format \(version))."
      }
    }
  }

  /// The drawing as JSON. The same scene always gives the same bytes.
  public static func data(_ scene: Scene, extra: [(String, JSON)] = []) -> Data {
    var lines = ["{"]
    var members: [(String, String)] = [
      ("type", JSON.string(formatName).text),
      ("version", JSON.number(CGFloat(version)).text),
    ]
    for (key, value) in extra { members.append((key, value.text)) }
    members.append(("canvas", paperJSON(scene.paper).text))
    let elements = scene.elements.map { "    " + elementJSON($0).text }
    members.append(("elements", elements.isEmpty ? "[]" : "[\n" + elements.joined(separator: ",\n") + "\n  ]"))
    let files = scene.files.keys.sorted().map { id -> String in
      let file = scene.files[id]!
      let body = JSON.object([("type", .string(file.type)), ("data", .string(file.data.base64EncodedString()))])
      return "    " + JSON.string(id).text + ": " + body.text
    }
    members.append(("files", files.isEmpty ? "{}" : "{\n" + files.joined(separator: ",\n") + "\n  }"))
    lines.append(members.map { "  " + JSON.string($0.0).text + ": " + $0.1 }.joined(separator: ",\n"))
    lines.append("}\n")
    return Data(lines.joined(separator: "\n").utf8)
  }

  public static func scene(from data: Data) throws -> Scene {
    try scene(fromObject: object(from: data))
  }

  /// The top-level JSON object of a drawing.
  public static func object(from data: Data) throws -> [String: Any] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { throw ReadError.notJSON }
    guard let object = root as? [String: Any] else { throw ReadError.notBristle }
    return object
  }

  public static func scene(fromObject object: [String: Any]) throws -> Scene {
    guard object["type"] as? String == formatName else { throw ReadError.notBristle }
    let version = (object["version"] as? NSNumber)?.intValue ?? 1
    guard version <= Self.version else { throw ReadError.newerVersion(version) }
    var scene = Scene()
    if let canvas = object["canvas"] as? [String: Any] ?? object["paper"] as? [String: Any] {
      scene.paper = readPaper(canvas)
    }
    scene.elements = (object["elements"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(readElement) }
    for (id, value) in object["files"] as? [String: Any] ?? [:] {
      guard let entry = value as? [String: Any], let type = entry["type"] as? String,
        let base64 = entry["data"] as? String, let data = Data(base64Encoded: base64)
      else { continue }
      scene.files[id] = ImageFile(type: type, data: data)
    }
    return scene
  }

  // MARK: Writing

  static func paperJSON(_ paper: Paper) -> JSON {
    var members: [(String, JSON)] = []
    members.append(("background", paper.background.map { .string($0.hex) } ?? .null))
    if let frame = paper.frame {
      members.append(("frame", .array([frame.minX, frame.minY, frame.width, frame.height].map { .number($0) })))
    }
    if paper.resolution != 72 { members.append(("resolution", .number(paper.resolution))) }
    return .object(members)
  }

  /// Only values that differ from an element's defaults are written.
  static func elementJSON(_ e: Element) -> JSON {
    let base = Element(id: e.id, kind: e.kind)
    var m: [(String, JSON)] = [("id", .string(e.id)), ("type", .string(e.kind.rawValue))]
    m.append(("x", .number(e.x)))
    m.append(("y", .number(e.y)))
    m.append(("width", .number(e.width)))
    m.append(("height", .number(e.height)))
    if e.rotation != 0 { m.append(("rotation", .number(e.rotation, digits: 4))) }
    if e.stroke != base.stroke { m.append(("stroke", e.stroke.map { .string($0.hex) } ?? .null)) }
    if e.strokeWidth != base.strokeWidth { m.append(("strokeWidth", .number(e.strokeWidth))) }
    if e.dash != base.dash { m.append(("dash", .string(e.dash.rawValue))) }
    if let fill = e.fill { m.append(("fill", .string(fill.hex))) }
    if e.opacity != 1 { m.append(("opacity", .number(e.opacity, digits: 3))) }
    if e.cornerRadius != 0 { m.append(("cornerRadius", .number(e.cornerRadius))) }
    if e.isPointBased {
      m.append(("points", .array(e.points.map { .array([.number($0.x), .number($0.y)]) })))
    }
    if !e.pressures.isEmpty { m.append(("pressures", .array(e.pressures.map { .number($0, digits: 3) }))) }
    if e.kind == .freehand { m.append(("brush", .string(e.brush.rawValue))) }
    if e.curved { m.append(("curved", .bool(true))) }
    if e.startArrowhead != base.startArrowhead { m.append(("startArrowhead", .string(e.startArrowhead.rawValue))) }
    if e.endArrowhead != base.endArrowhead { m.append(("endArrowhead", .string(e.endArrowhead.rawValue))) }
    for (key, binding) in [("startBinding", e.startBinding), ("endBinding", e.endBinding)] {
      guard let binding else { continue }
      m.append(
        (key, .object([
          ("element", .string(binding.element)),
          ("anchor", .array([.number(binding.anchor.x, digits: 4), .number(binding.anchor.y, digits: 4)])),
        ])))
    }
    if e.kind == .text {
      m.append(("text", .string(e.text)))
      if !e.fontName.isEmpty { m.append(("font", .string(e.fontName))) }
      m.append(("fontSize", .number(e.fontSize)))
      if e.textAlign != .left { m.append(("textAlign", .string(e.textAlign.rawValue))) }
      if e.fixedWidth { m.append(("fixedWidth", .bool(true))) }
    }
    if e.kind == .image {
      m.append(("file", .string(e.file)))
      if let crop = e.crop {
        m.append(
          ("crop", .array([crop.minX, crop.minY, crop.width, crop.height].map { .number($0, digits: 5) })))
      }
      if e.flipX { m.append(("flipX", .bool(true))) }
      if e.flipY { m.append(("flipY", .bool(true))) }
    }
    if e.locked { m.append(("locked", .bool(true))) }
    if !e.groups.isEmpty { m.append(("groups", .array(e.groups.map { .string($0) }))) }
    return .object(m)
  }

  // MARK: Reading

  static func number(_ value: Any?) -> CGFloat? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    return double.isFinite ? CGFloat(double) : nil
  }

  static func point(_ value: Any?) -> CGPoint? {
    guard let pair = value as? [Any], pair.count >= 2, let x = number(pair[0]), let y = number(pair[1]) else {
      return nil
    }
    return CGPoint(x: x, y: y)
  }

  static func readPaper(_ object: [String: Any]) -> Paper {
    var paper = Paper()
    if let hex = object["background"] as? String { paper.background = Color(hex: hex) }
    if let values = (object["frame"] as? [Any])?.compactMap(number), values.count == 4, values[2] >= 1, values[3] >= 1 {
      paper.frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    } else if let width = number(object["width"]), let height = number(object["height"]), width >= 1, height >= 1 {
      // Early drawings had a page at the origin.
      paper.frame = CGRect(x: 0, y: 0, width: width, height: height)
    }
    if let resolution = number(object["resolution"]), resolution > 0 { paper.resolution = resolution }
    return paper
  }

  static func readElement(_ o: [String: Any]) -> Element? {
    guard let kind = (o["type"] as? String).flatMap(Element.Kind.init(rawValue:)) else { return nil }
    let id = (o["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Element.newID()
    var e = Element(id: id, kind: kind)
    e.x = number(o["x"]) ?? 0
    e.y = number(o["y"]) ?? 0
    e.width = max(0, number(o["width"]) ?? 0)
    e.height = max(0, number(o["height"]) ?? 0)
    e.rotation = number(o["rotation"]) ?? 0
    if o["stroke"] is NSNull {
      e.stroke = nil
    } else if let hex = o["stroke"] as? String, let color = Color(hex: hex) {
      e.stroke = color
    }
    if let width = number(o["strokeWidth"]) { e.strokeWidth = max(0, width) }
    if let dash = (o["dash"] as? String).flatMap(Element.Dash.init(rawValue:)) { e.dash = dash }
    e.fill = (o["fill"] as? String).flatMap(Color.init(hex:))
    if let opacity = number(o["opacity"]) { e.opacity = min(1, max(0, opacity)) }
    if let radius = number(o["cornerRadius"]) { e.cornerRadius = max(0, radius) }
    e.points = (o["points"] as? [Any] ?? []).compactMap(point)
    e.pressures = (o["pressures"] as? [Any] ?? []).compactMap(number).map { min(1, max(0, $0)) }
    if e.pressures.count != e.points.count { e.pressures = [] }
    if let brush = (o["brush"] as? String).flatMap(Element.Brush.init(rawValue:)) { e.brush = brush }
    e.curved = o["curved"] as? Bool ?? false
    if let head = (o["startArrowhead"] as? String).flatMap(Element.Arrowhead.init(rawValue:)) {
      e.startArrowhead = head
    }
    if let head = (o["endArrowhead"] as? String).flatMap(Element.Arrowhead.init(rawValue:)) {
      e.endArrowhead = head
    }
    func binding(_ value: Any?) -> Element.Binding? {
      guard let b = value as? [String: Any], let target = b["element"] as? String else { return nil }
      return Element.Binding(element: target, anchor: point(b["anchor"]) ?? CGPoint(x: 0.5, y: 0.5))
    }
    e.startBinding = binding(o["startBinding"])
    e.endBinding = binding(o["endBinding"])
    e.text = o["text"] as? String ?? ""
    e.fontName = o["font"] as? String ?? ""
    if let size = number(o["fontSize"]), size > 0 { e.fontSize = size }
    if let align = (o["textAlign"] as? String).flatMap(Element.TextAlign.init(rawValue:)) { e.textAlign = align }
    e.fixedWidth = o["fixedWidth"] as? Bool ?? false
    e.file = o["file"] as? String ?? ""
    if let crop = o["crop"] as? [Any], crop.count == 4 {
      let values = crop.compactMap(number)
      if values.count == 4 { e.crop = CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
    }
    e.flipX = o["flipX"] as? Bool ?? false
    e.flipY = o["flipY"] as? Bool ?? false
    e.locked = o["locked"] as? Bool ?? false
    e.groups = (o["groups"] as? [Any] ?? []).compactMap { $0 as? String }
    return e
  }
}

/// A JSON value that keeps the order of object members, so files are written deterministically.
public indirect enum JSON: Sendable {
  case null
  case bool(Bool)
  case number(CGFloat, digits: Int = 2)
  case string(String)
  case array([JSON])
  case object([(String, JSON)])

  public var text: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value, let digits): return JSON.format(value, digits: digits)
    case .string(let value): return JSON.quote(value)
    case .array(let values): return "[" + values.map(\.text).joined(separator: ",") + "]"
    case .object(let members):
      return "{" + members.map { JSON.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
    }
  }

  /// Rounds to `digits` decimal places and drops trailing zeros: 12, 12.5, 0.25.
  static func format(_ value: CGFloat, digits: Int) -> String {
    guard value.isFinite else { return "0" }
    let scale = pow(10, CGFloat(digits))
    let rounded = (value * scale).rounded() / scale
    if rounded == rounded.rounded(), abs(rounded) < 1e15 {
      let integer = Int(rounded)
      return String(integer == 0 ? 0 : integer)
    }
    var text = String(format: "%.\(digits)f", Double(rounded))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
  }

  static func quote(_ string: String) -> String {
    var out = "\""
    out.reserveCapacity(string.utf8.count + 2)
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case let s where s.value < 0x20 || s.value == 0x2028 || s.value == 0x2029:
        out += String(format: "\\u%04x", s.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}
