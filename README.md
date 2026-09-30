# Bristle

Bristle is a small, native macOS drawing app. You draw with pencils, brushes, shapes, lines, and text on a canvas, like in MS Paint, but everything you draw can still be moved, resized, recolored, or edited later. It saves drawings as readable `.bristle` files or as PNGs that reopen with every object intact. Bristle requires macOS 13 or newer, works entirely offline, and has no third-party dependencies.

![Bristle editing a drawing of shapes, strokes, an arrow, and text in dark mode](Assets/Bristle-Screenshot.png)

## Install

Download Bristle from [GitHub Releases](https://github.com/PoteNad/bristle/releases), or install it with Homebrew:

```sh
brew install --cask PoteNad/tap/bristle
```

Homebrew includes Bristle in its normal `brew upgrade` cycle. To update only Bristle, run `brew upgrade --cask bristle`.

The Homebrew cask verifies the app bundle and removes its quarantine attribute so Bristle can open normally. Direct downloads are not Apple-notarized, so macOS may require **Open Anyway** in **System Settings → Privacy & Security** on first launch.

## How it works

- **The canvas** is a page with a fixed size, 1200 × 800 points by default. Drag the handles on its right edge, bottom edge, or corner to resize it, or use Canvas ▸ Canvas Size to set an exact size. Crop to Selection (⌘K) and Fit Canvas to Drawing trim it to what you've drawn. Anything moved off the canvas is kept and shows up again if the canvas grows.
- **The toolbar** has every tool, grouped like the ribbon in MS Paint: Select; Draw, Eraser, Fill, and Pick Color; Rectangle, Ellipse, Shapes, Line, and Arrow; then Text and Image. Each tool has a single-key shortcut, shown in its tooltip and in View ▸ Tool. Hold Space and drag to pan.
- **The style bar** at the bottom of the window shows the options for what you're doing: brush, width, and color while drawing, or stroke, fill, line style, arrowheads, and font for whatever is selected. Colors open in a picker inside the window, with swatches, a color square, and a hex field.
- **The Palette** (⇧⌘C) is a sidebar with every style option and an Arrange tab for exact position, size, rotation, alignment, and layer order. With nothing selected, it shows the canvas size and background.
- **Selections** get a dotted outline that follows each object's shape. Drag the handle in the middle of a line to bend it.
- **Opening an image** makes a canvas the size of the image, with the image locked in place so you can mark it up. Saving an image you haven't changed writes back the same bytes.
- **PNGs keep the drawing.** A PNG saved by Bristle opens as a normal image everywhere else, but Bristle stores the drawing inside it too, so reopening it in Bristle gives you every object back. If another app changes the image, Bristle opens the new pixels and offers to restore the old objects.

Bristle leaves out layers, filters, photo adjustments, blend modes, animation, collaboration, and anything that needs an account. The eraser and fill tool work on objects rather than pixels: the Pixel eraser rubs out parts of freehand strokes, the Object eraser removes whole objects, and the fill tool fills a shape or, on empty space, the canvas itself.

## Features

- Native document windows and tabs, autosave, versions, recovery of unsaved drawings, Revert, Duplicate, Rename, and Move.
- Pencil, brush, calligraphy, oil, crayon, marker, watercolor, airbrush, highlighter, and pixel brushes, with smoothing and pressure from a tablet or from how fast you draw with a mouse.
- Pixel art with a 1, 2, or 4 point pixel brush, and a pixel grid when zoomed in past 800%.
- Lines and arrows that can curve and attach to shapes, rectangles with rounded corners, ellipses, polygons, and a set of ready-made shapes like stars, arrows, and speech bubbles.
- Text typed straight onto the canvas, with fonts, sizes, alignment, and colors.
- Images from files, the clipboard, drag and drop, or an iPhone or iPad with Continuity Camera, with cropping, flipping, and Remove Background on macOS 14 or newer.
- Move, resize, rotate, duplicate, align, distribute, group, lock, and reorder, with alignment guides, an optional grid, rulers, and arrow-key nudging.
- A tap on the trackpad when something snaps into line, when an arrow attaches to a shape, and when pinching passes 100%.
- Box and free-form selection, Invert Selection, Copy Style and Paste Style, and Tab to move between objects.
- Copying puts Bristle objects, PNG, and PDF on the clipboard, so a copy pastes as objects in Bristle and as a picture anywhere else.
- Export to PNG, SVG, PDF, or JPEG at 1×, 2×, or 3×, plus Print and Share.
- Zoom from 10% to 1600% by pinching, ⌘-scrolling, the zoom control, or ⌘+, ⌘−, ⌘0, and ⌘9. ⌘-click the zoom level to fit the canvas.
- Light and dark appearances, full keyboard access, and VoiceOver descriptions of every object. The drawing itself looks the same in both appearances.

## File format

A `.bristle` file is JSON with one object per line, so it's easy to read and to diff:

```json
{
  "type": "bristle",
  "version": 1,
  "canvas": {"width":1200,"height":800,"background":"#FFFFFF"},
  "elements": [
    {"id":"4k2j9x","type":"rectangle","x":120,"y":80,"width":300,"height":180,"fill":"#DCEBFF","cornerRadius":16},
    {"id":"9sd0q1","type":"arrow","x":420,"y":170,"width":180,"height":40,"points":[[0,0],[180,40]],"startBinding":{"element":"4k2j9x","anchor":[0.5,0.5]}}
  ],
  "files": {}
}
```

- `canvas` has the canvas's `width` and `height` in points, its `background` color (`null` for transparent, white if it's missing), and an optional `resolution` in pixels per inch for exported images.
- `elements` lists objects from back to front. Each has an `id`, a `type` (`rectangle`, `ellipse`, `polygon`, `line`, `arrow`, `freehand`, `text`, or `image`), and a frame (`x`, `y`, `width`, `height`) that `rotation` (radians, clockwise) turns about its center. Values left at their defaults are omitted: `stroke` (a color, or `null` for none, default `#1D1D1F`), `strokeWidth` (3), `dash` (`solid`, `dashed`, or `dotted`), `fill`, `opacity` (1), `cornerRadius`, `locked`, and `groups`, the ids of the groups the object belongs to, innermost first.
- Polygons, lines, arrows, and freehand strokes have `points` relative to the frame's corner; strokes add `brush` (`pencil`, `pen`, `highlighter`, `calligraphy`, `airbrush`, `crayon`, `marker`, `watercolor`, `oil`, or `pixel`, whose `points` are the centers of its pixels) and optional `pressures`, and lines add `curved`, `startArrowhead` and `endArrowhead` (`none`, `arrow`, `triangle`, `circle`, or `bar`), and `startBinding` and `endBinding`, which attach an end to another object at an `anchor` given in that object's unit coordinates.
- Text has `text`, `font` (a PostScript name, or omitted for the system font), `fontSize`, `textAlign`, and `fixedWidth` when it wraps at its width.
- Images have `file`, a key into `files`, which holds each image's type and its original bytes in base64, and optionally `crop` (`[x, y, width, height]` of the image, from 0 to 1), `flipX`, and `flipY`.
- Colors are `#RRGGBB` or `#RRGGBBAA` in sRGB. Unknown members are ignored, and a file with a newer `version` is refused instead of being misread.

A PNG saved by Bristle stores the same JSON, zlib-compressed, in a private `brSC` chunk. It adds one member, `pixels`, a SHA-256 hash of the image's pixels, so Bristle can tell if another app changed the image.

## Build from source

Bristle needs Xcode or the Command Line Tools with the macOS 26 SDK or newer. The built app still runs on macOS 13 and newer.

```sh
./scripts/build.sh
open build/Bristle.app
```

The build is optimized and ad-hoc signed for the current Mac. Open `Package.swift` in Xcode to work on the source. Run `./scripts/check.sh` for the full test suite, which drives the real app to draw, scroll, zoom, save, and reopen, and compares what's on screen pixel for pixel. After editing the icon in Icon Composer, run `swift scripts/make-icon.swift` to update `Assets/Bristle-Liquid.png` and `Assets/Bristle.icns`.

## Using the canvas in another app

The canvas is the `BristleCanvas` library in this package, separate from the app. The drawing model, file format, and rendering live in `BristleCore`. `CanvasView` handles every tool, selection, text editing, the clipboard, drag and drop, zoom, and VoiceOver. The app adds documents, the toolbar, the bars, the Palette, and Settings.

```swift
import BristleCanvas
import BristleCore

let drawing = Drawing(scene: Scene())
drawing.undoManager = undoManager
let canvas = CanvasView(drawing: drawing)
canvas.tool = .pen
window.contentView = canvas.scrollView
```

Every change goes through `Drawing`, so it can be undone, and posts `drawingDidChange`. `SceneFile` reads and writes `.bristle` files, and `EmbeddedScene` reads and writes PNGs that carry a drawing.

## License

MIT. See [LICENSE](LICENSE).
