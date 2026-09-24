import AppKit
import BristleCore

/// What dragging on the canvas does.
public enum Tool: String, CaseIterable, Sendable {
  case select
  case pencil, pen, highlighter, pixel, calligraphy, airbrush, crayon, marker, watercolor, oil
  case eraser, strokeEraser
  case line, arrow
  case rectangle, ellipse, polygon
  case text
  case fill
  case eyedropper

  public var title: String {
    switch self {
    case .select: "Select"
    case .pencil: "Pencil"
    case .pen: "Brush"
    case .highlighter: "Highlighter"
    case .pixel: "Pixel"
    case .calligraphy: "Calligraphy"
    case .airbrush: "Airbrush"
    case .crayon: "Crayon"
    case .marker: "Marker"
    case .watercolor: "Watercolor"
    case .oil: "Oil Brush"
    case .eraser: "Object Eraser"
    case .strokeEraser: "Pixel Eraser"
    case .line: "Line"
    case .arrow: "Arrow"
    case .rectangle: "Rectangle"
    case .ellipse: "Ellipse"
    case .polygon: "Polygon"
    case .text: "Text"
    case .fill: "Fill"
    case .eyedropper: "Eyedropper"
    }
  }

  /// The key that chooses the tool while the canvas has focus.
  public var key: String {
    switch self {
    case .select: "v"
    case .pencil: "p"
    case .pen: "b"
    case .highlighter: "m"
    case .pixel: "x"
    case .calligraphy: "c"
    case .airbrush: "s"
    case .crayon, .marker, .watercolor, .oil: ""
    case .eraser: ""
    case .strokeEraser: "e"
    case .line: "l"
    case .arrow: "a"
    case .rectangle: "r"
    case .ellipse: "o"
    case .polygon: "g"
    case .text: "t"
    case .fill: "f"
    case .eyedropper: "i"
    }
  }

  public var symbol: String {
    switch self {
    case .select: "cursorarrow"
    case .pencil: "pencil"
    case .pen: "paintbrush.pointed"
    case .highlighter: "highlighter"
    case .pixel: "squareshape.split.3x3"
    case .calligraphy: "signature"
    case .airbrush: "aqi.medium"
    case .crayon: "scribble"
    case .marker: "pencil.line"
    case .watercolor: "drop.halffull"
    case .oil: "paintbrush.fill"
    case .eraser: "eraser"
    case .strokeEraser: "eraser.line.dashed"
    case .line: "line.diagonal"
    case .arrow: "arrow.up.right"
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .polygon: "pentagon"
    case .text: "textformat"
    case .fill: "drop"
    case .eyedropper: "eyedropper"
    }
  }

  /// What the tool draws with.
  public var brush: Element.Brush? {
    switch self {
    case .pencil: .pencil
    case .pen: .pen
    case .highlighter: .highlighter
    case .pixel: .pixel
    case .calligraphy: .calligraphy
    case .airbrush: .airbrush
    case .crayon: .crayon
    case .marker: .marker
    case .watercolor: .watercolor
    case .oil: .oil
    default: nil
    }
  }

  /// The style each tool starts with.
  public var defaultStyle: Style {
    switch self {
    case .pencil: Style(strokeWidth: 3)
    case .pen: Style(strokeWidth: 8)
    case .highlighter: Style(stroke: Color(hex: "#FFD60A"), strokeWidth: 24, opacity: 0.45)
    case .pixel: Style(strokeWidth: 1)
    case .calligraphy: Style(strokeWidth: 10)
    case .airbrush: Style(strokeWidth: 28)
    case .crayon: Style(strokeWidth: 8)
    case .marker: Style(strokeWidth: 10)
    case .watercolor: Style(stroke: Color(hex: "#007AFF"), strokeWidth: 20)
    case .oil: Style(stroke: Color(hex: "#FF9500"), strokeWidth: 16)
    case .line: Style(strokeWidth: 3)
    case .arrow: Style(strokeWidth: 3, endArrowhead: .arrow)
    case .rectangle, .ellipse, .polygon: Style(strokeWidth: 3)
    case .text: Style(fontSize: 28)
    case .fill: Style(stroke: Color(hex: "#0A84FF"))
    case .eraser, .strokeEraser: Style(strokeWidth: 24)
    default: Style()
    }
  }

  /// Whether the tool makes elements that use its style.
  public var hasStyle: Bool { ![.select, .eyedropper].contains(self) }

  /// Tools that make an element with a single drag.
  var makesShape: Bool { [.line, .arrow, .rectangle, .ellipse].contains(self) }
}
