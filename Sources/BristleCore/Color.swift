import CoreGraphics
import Foundation

/// An sRGB colour, kept to 8 bits per channel so it is saved as `#RRGGBB` or `#RRGGBBAA` and read
/// back exactly.
public struct Color: Equatable, Hashable, Sendable {
  public private(set) var red: CGFloat
  public private(set) var green: CGFloat
  public private(set) var blue: CGFloat
  public private(set) var alpha: CGFloat

  public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
    func channel(_ value: CGFloat) -> CGFloat { (min(1, max(0, value.isFinite ? value : 0)) * 255).rounded() / 255 }
    self.red = channel(red)
    self.green = channel(green)
    self.blue = channel(blue)
    self.alpha = channel(alpha)
  }

  /// Reads `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
  public init?(hex: String) {
    var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
    if digits.hasPrefix("#") { digits = digits.dropFirst() }
    if digits.count == 3 { digits = Substring(digits.map { "\($0)\($0)" }.joined()) }
    guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
    let full = digits.count == 6 ? value << 8 | 0xFF : value
    self.init(
      red: CGFloat(full >> 24 & 0xFF) / 255, green: CGFloat(full >> 16 & 0xFF) / 255,
      blue: CGFloat(full >> 8 & 0xFF) / 255, alpha: CGFloat(full & 0xFF) / 255)
  }

  /// Converts any Core Graphics colour to sRGB.
  public init?(_ color: CGColor) {
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
      let parts = converted.components, parts.count >= 4
    else { return nil }
    self.init(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
  }

  public var hex: String {
    let bytes = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
    let rgb = bytes.prefix(3).map { String(format: "%02X", $0) }.joined()
    return "#" + rgb + (bytes[3] == 255 ? "" : String(format: "%02X", bytes[3]))
  }

  public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

  public func withAlpha(_ alpha: CGFloat) -> Color { Color(red: red, green: green, blue: blue, alpha: alpha) }

  /// The near-black Apple uses for text, the default ink.
  public static let ink = Color(hex: "#1D1D1F")!
  public static let white = Color(red: 1, green: 1, blue: 1)
  public static let black = Color(red: 0, green: 0, blue: 0)
  public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)

  /// A plain name for the colour, for VoiceOver: "red", "light blue", "dark gray".
  public var name: String {
    let high = max(red, green, blue), low = min(red, green, blue)
    let lightness = (high + low) / 2
    let chroma = high - low
    if alpha < 0.05 { return "clear" }
    if chroma < 0.08 {
      if lightness < 0.12 { return "black" }
      if lightness > 0.94 { return "white" }
      return lightness < 0.4 ? "dark gray" : lightness > 0.7 ? "light gray" : "gray"
    }
    var hue: CGFloat
    if high == red {
      hue = (green - blue) / chroma
    } else if high == green {
      hue = (blue - red) / chroma + 2
    } else {
      hue = (red - green) / chroma + 4
    }
    hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
    let base: String
    switch hue {
    case ..<15, 345...: base = lightness > 0.75 ? "pink" : "red"
    case ..<40: base = lightness < 0.35 ? "brown" : "orange"
    case ..<65: base = lightness < 0.3 ? "olive" : "yellow"
    case ..<160: base = "green"
    case ..<195: base = "teal"
    case ..<255: base = "blue"
    case ..<290: base = "purple"
    default: base = "pink"
    }
    if base == "brown" || base == "olive" { return base }
    if lightness < 0.25 { return "dark " + base }
    if lightness > 0.8 { return "light " + base }
    return base
  }
}
