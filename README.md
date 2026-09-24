# Bristle

Bristle is a small, native macOS drawing app. It has the immediacy of a paint program — pick a pencil and draw — but everything you draw stays an editable object: shapes, lines and arrows, freehand strokes, text, and images. Nothing is flattened into pixels behind your back, so you can open a screenshot, mark it up, save an ordinary PNG, and reopen it later with every annotation still editable. Bristle requires macOS 13 or newer, works entirely offline, and has no third-party dependencies.

![Bristle drawing shapes, an arrow, ink, and text on its dotted canvas, with a shape selected and its style bar at the bottom](Assets/Bristle-Screenshot.png)

## Install

Download Bristle from [GitHub Releases](https://github.com/PoteNad/bristle/releases), or install it with Homebrew:

```sh
brew install --cask PoteNad/tap/bristle
```

Homebrew includes Bristle in its normal `brew upgrade` cycle. To update only Bristle, run `brew upgrade --cask bristle`.

The Homebrew cask verifies the app bundle and removes its quarantine attribute so Bristle can open normally. Direct downloads are not Apple-notarized, so macOS may require **Open Anyway** in **System Settings → Privacy & Security** on first launch.

## How it works

- **The canvas** is endless, as Freeform's and Excalidraw's are, with an optional dot grid, and follows the light or dark appearance. On a dark canvas, every colour, the background too, is shown with its lightness turned around, as Excalidraw does, so black ink reads as white and the Palette's swatches match what you see; the file keeps the colours you chose. View ▸ Show Rulers (⌘R) adds rulers in points from the frame's corner.
- **A frame** marks the part of the canvas that is exported and printed, like MS Paint's page: it's labelled with its size, and the canvas around it is shaded. Add one with the frame button at the bottom right or Canvas ▸ Add Frame; drag its edges to resize it, pick it by its label to move it, and press Delete to remove it. Canvas ▸ Frame Size, Frame Selection (⌘K), and Fit Frame to Drawing set it exactly. Without a frame, exports cover the whole drawing.
- **The toolbar** holds every tool, one click each, grouped as MS Paint's ribbon is: Select; Draw, Eraser, Fill, and Pick Color; Rectangle, Ellipse, Shapes, Line, and Arrow; then Text and Image. Every tool also has a key: V Select, P Pencil, B Brush, M Highlighter, C Calligraphy, S Airbrush, X Pixel, E Eraser, F Fill, R Rectangle, O Ellipse, G Polygon, L Line, A Arrow, T Text, I Eyedropper. Hold Space to pan.
- **The style bar** at the bottom centre changes with what you're doing, as Freeform's does: a menu of brushes, the width, and the colour while drawing; how the eraser erases; and for a selection, its stroke and fill colours, width, line style, arrowheads, font, size, and alignment, with a menu to arrange it. Its Style button sets any width, the opacity, and the line style. Colours, with a spectrum and a hex field for any other, and menus open above the bar, inside the window. The bar hides when there's nothing to style.
- **Like MS Paint:** the Polygon tool draws a gallery of shapes with one drag (triangles, a diamond, stars, a heart, lightning, arrows, and a speech bubble), each an editable polygon; Select draws a box or a free-form loop; Edit ▸ Invert Selection picks everything else; and Format ▸ Remove Background keeps a photo's subject and clears the rest, worked out on your Mac (macOS 14 or newer).
- **Pixel art.** The Pixel brush paints square pixels, 1, 2, or 4 wide, on the grid a PNG export has. Zoomed in past 800%, the grid shows every pixel, and images show their own pixels square.
- **Selections** get a dotted outline that follows each object's shape, as Freeform draws them. Lines have a handle in the middle of each segment: drag it to bend the line, as in Excalidraw.
- **The zoom control** at the bottom left holds the zoom level and a menu of levels, and **the canvas control** at the bottom right holds the grid, the frame, the background, and snapping.
- **The Palette** is a sidebar, shown and hidden with the brush button (⇧⌘C) like Plainst's symbols sidebar, with everything the style bar has and more, as Keynote's Format inspector has it: a Style tab with every brush, colour, width, line, corner radius, font, and size, and an Arrange tab with exact position, size, and rotation, layers, alignment, distribution, flips, and actions. With nothing selected, it shows the canvas: box or free-form selection, the frame's size, the background, the grid, and rulers. While it's open the style bar steps aside, and Settings can show the bars only when the pointer is near them. Double-click its edge to put it back to its usual width.
- **Opening an image** frames it by its own edges, with the image locked in place underneath, ready to mark up. Saving an unedited image writes back the same bytes.
- **PNGs keep the drawing.** A PNG saved by Bristle is an ordinary image everywhere else, and also carries the drawing in a private chunk, so it reopens in Bristle with every object editable. If the image is changed in another app, Bristle notices that the pixels no longer match, opens the image as it is now, and offers to restore the earlier objects.

Bristle deliberately leaves out layers panels, filters and photo adjustments, custom brush engines, blend modes, animation, collaboration, and anything that needs an account or the network. The eraser and the fill tool work on objects, not pixels: the Pixel eraser rubs out the parts of freehand strokes it passes over, and the Object eraser removes whole objects; the fill tool fills shapes, or the frame's background when you click empty space inside it.

## Features

- Native document windows and tabs, autosave, versions, recovery of unsaved drawings, Revert, Duplicate, Rename, and Move.
- Pencil, pressure-sensitive brush, calligraphy brush, oil brush, crayon, marker, watercolour, airbrush, highlighter, and pixel brush, as MS Paint has, with smoothing, tablet pressure, and speed-based thickness with a mouse.
- Lines and arrows with arrowheads, curves, and ends that attach to shapes and follow them; rectangles with rounded corners, ellipses, and polygons that can be curved.
- Text typed in place, with the font panel, sizes, alignment, and colours.
- Images placed from files, the clipboard, drag and drop, and Continuity Camera and Sketch, with cropping (double-click an image) and flipping.
- Move, resize, rotate, duplicate (⌘D, or Option-drag), align, distribute, group and enter groups, lock, and stacking order, with alignment guides, an optional grid, and nudging with the arrow keys.
- Copy Style and Paste Style, Select All, and Tab to move from object to object.
- Copying writes Bristle objects, PNG, and PDF, so a copy pastes as editable objects in Bristle and as a picture everywhere else; objects can be dragged out to other apps.
- Export as PNG (optionally editable in Bristle), SVG, PDF, or JPEG at 1×, 2×, or 3×; Print; and Share.
- Zoom from 5% to 3200% by pinching, ⌘-scrolling, the zoom control, or ⌘+, ⌘−, ⌘0, and ⌘9.
- Light and dark appearances, full keyboard access, and VoiceOver descriptions of every object on the canvas.

## File format

A `.bristle` file is JSON, written with one object per line so it reads and diffs well:

```json
{
  "type": "bristle",
  "version": 1,
  "canvas": {"background":null,"frame":[0,0,1600,1000]},
  "elements": [
    {"id":"4k2j9x","type":"rectangle","x":120,"y":80,"width":300,"height":180,"fill":"#DCEBFF","cornerRadius":16},
    {"id":"9sd0q1","type":"arrow","x":420,"y":170,"width":180,"height":40,"points":[[0,0],[180,40]],"startBinding":{"element":"4k2j9x","anchor":[0.5,0.5]}}
  ],
  "files": {}
}
```

- `canvas` gives its `background` colour, or `null` for none (the canvas follows the appearance and exports are transparent); the `frame`, `[x, y, width, height]` in points, when the drawing has one; and optionally a `resolution` in pixels per inch for exported images.
- `elements` lists objects from back to front. Each has an `id`, a `type` (`rectangle`, `ellipse`, `polygon`, `line`, `arrow`, `freehand`, `text`, or `image`), and a frame (`x`, `y`, `width`, `height`) that `rotation` (radians, clockwise) turns about its centre. Values left at their defaults are omitted: `stroke` (a colour, or `null` for none, default `#1D1D1F`), `strokeWidth` (3), `dash` (`solid`, `dashed`, or `dotted`), `fill`, `opacity` (1), `cornerRadius`, `locked`, and `groups`, the ids of the groups the object belongs to, innermost first.
- Polygons, lines, arrows, and freehand strokes have `points` relative to the frame's corner; strokes add `brush` (`pencil`, `pen`, `highlighter`, `calligraphy`, `airbrush`, `crayon`, `marker`, `watercolor`, `oil`, or `pixel`, whose `points` are the centres of its pixels) and optional `pressures`, and lines add `curved`, `startArrowhead` and `endArrowhead` (`none`, `arrow`, `triangle`, `circle`, or `bar`), and `startBinding` and `endBinding`, which attach an end to another object at an `anchor` given in that object's unit coordinates.
- Text has `text`, `font` (a PostScript name, or omitted for the system font), `fontSize`, `textAlign`, and `fixedWidth` when it wraps at its width.
- Images have `file`, a key into `files`, which holds each image's type and its original bytes in base64, and optionally `crop` (`[x, y, width, height]` of the image, from 0 to 1), `flipX`, and `flipY`.
- Colours are `#RRGGBB` or `#RRGGBBAA` in sRGB. Readers ignore members they don't know, and a newer major `version` is refused rather than misread.

In a PNG saved by Bristle, the same JSON is stored zlib-compressed in a private, unsafe-to-copy `brSC` chunk, with one more top-level member, `pixels`: a SHA-256 hash of the image's pixels, which tells Bristle whether the image was changed elsewhere.

## Build from source

Bristle needs Xcode or the Command Line Tools with the macOS 26 SDK or newer. The built app still runs on macOS 13 and newer.

```sh
./scripts/build.sh
open build/Bristle.app
```

The build is optimized and ad-hoc signed for the current Mac. Open `Package.swift` in Xcode to work on the source. Run `./scripts/check.sh` for the full test suite, which includes end-to-end checks of drawing with the pointer, saving, opening, byte-identical round trips, and restoring unsaved drawings. After editing the icon in Icon Composer, run `swift scripts/make-icon.swift` to update `Assets/Bristle-Liquid.png` and `Assets/Bristle.icns`.

## Using the canvas in another app

The canvas is the `BristleCanvas` library in this package, separate from the Bristle app, and the drawing model, file format, and rendering are in `BristleCore`. `CanvasView` provides every tool, selection, text editing, the clipboard, drag and drop, zoom, and VoiceOver support. The app adds documents, the toolbar, the bars at the bottom of the window, the Palette, and Settings around it.

```swift
import BristleCanvas
import BristleCore

let drawing = Drawing(scene: Scene())
drawing.undoManager = undoManager
let canvas = CanvasView(drawing: drawing)
canvas.tool = .pen
window.contentView = canvas.scrollView
```

Every change goes through `Drawing`, so it can be undone, and posts `drawingDidChange`. `SceneFile` reads and writes `.bristle` JSON, and `EmbeddedScene` reads and writes PNGs that carry a drawing.

## License

MIT — see [LICENSE](LICENSE).
