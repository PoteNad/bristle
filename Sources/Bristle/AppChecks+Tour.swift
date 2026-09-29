#if BRISTLE_CHECKS
  import AppKit
  import BristleCore
  @testable import BristleCanvas

  /// A tour of everything a person does, checked the way they'd notice problems: the picture on
  /// screen after each step must be exactly what a fresh drawing of the canvas gives, so no
  /// stroke is left behind, cut off, or missing; and controls must stay where they are.
  extension AppChecks {
    // MARK: Pictures

    /// A bitmap of what the canvas shows, one pixel per point on screen.
    final class Picture {
      let rep: NSBitmapImageRep
      let visible: CGRect
      let scale: CGFloat

      init(_ canvas: CanvasView) {
        visible = canvas.visibleRect
        scale = canvas.magnification
        let width = Int((visible.width * scale).rounded()), height = Int((visible.height * scale).rounded())
        rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
      }

      /// Draws the parts of the canvas in `rects`, as AppKit would redraw them, rounded out to
      /// whole pixels; everything when `rects` is nil.
      func paint(_ canvas: CanvasView, rects: [CGRect]? = nil) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = context.cgContext
        let pixels = CGFloat(rep.pixelsHigh)
        var areas = rects ?? [visible]
        // Whole pixels, as AppKit redraws.
        areas = areas.compactMap { rect in
          let r = rect.intersection(visible)
          guard !r.isNull, !r.isEmpty else { return nil }
          let minX = ((r.minX - visible.minX) * scale).rounded(.down), maxX = ((r.maxX - visible.minX) * scale).rounded(.up)
          let minY = ((r.minY - visible.minY) * scale).rounded(.down), maxY = ((r.maxY - visible.minY) * scale).rounded(.up)
          return CGRect(x: visible.minX + minX / scale, y: visible.minY + minY / scale, width: (maxX - minX) / scale, height: (maxY - minY) / scale)
        }
        guard !areas.isEmpty else { return }
        let dirty = areas.reduce(CGRect.null) { $0.union($1) }
        cg.saveGState()
        cg.translateBy(x: 0, y: pixels)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -visible.minX, y: -visible.minY)
        cg.clip(to: areas)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        nonisolated(unsafe) let unsafeContext = cg
        canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
          MainActor.assumeIsolated { canvas.render(in: unsafeContext, dirty: dirty, rects: areas) }
        }
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
      }

      /// The colour at a point on the canvas, as 0–255 components.
      func color(at p: CGPoint) -> [Int] {
        let x = Int(((p.x - visible.minX) * scale).rounded(.down)), y = Int(((p.y - visible.minY) * scale).rounded(.down))
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let data = rep.bitmapData else { return [] }
        let i = y * rep.bytesPerRow + x * 4
        return (0..<4).map { Int(data[i + $0]) }
      }

      /// Where two pictures differ by more than a trace, and by how much.
      func differences(from other: Picture) -> (count: Int, box: CGRect, largest: Int) {
        guard let a = rep.bitmapData, let b = other.rep.bitmapData, rep.pixelsWide == other.rep.pixelsWide,
          rep.pixelsHigh == other.rep.pixelsHigh
        else { return (Int.max, .null, 255) }
        var count = 0, largest = 0
        var box = CGRect.null
        for y in 0..<rep.pixelsHigh {
          for x in 0..<rep.pixelsWide {
            let i = y * rep.bytesPerRow + x * 4
            var difference = 0
            for c in 0..<4 { difference = max(difference, abs(Int(a[i + c]) - Int(b[i + c]))) }
            guard difference > 40 else { continue }
            count += 1
            largest = max(largest, difference)
            box = box.union(CGRect(x: visible.minX + CGFloat(x) / scale, y: visible.minY + CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
          }
        }
        return (count, box, largest)
      }

      func write(_ name: String) -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("bristle-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        return path
      }
    }

    /// Runs `step` and checks that redrawing only what the canvas asked to redraw leaves the
    /// same picture as redrawing everything: nothing stale is left, and nothing is cut off.
    static func redraws(_ canvas: CanvasView, _ name: String, _ step: () -> Void) {
      canvas.displayIfNeeded()
      let screen = Picture(canvas)
      screen.paint(canvas)
      canvas.invalidated = []
      step()
      let asked = canvas.invalidated ?? []
      canvas.invalidated = nil
      // Scrolling or zooming redraws the whole view, which can't leave anything behind.
      guard canvas.visibleRect == screen.visible, canvas.magnification == screen.scale else { return }
      screen.paint(canvas, rects: asked)
      let fresh = Picture(canvas)
      fresh.paint(canvas)
      // A few faint pixels where a texture meets the edge of a redrawn part are allowed; a
      // stray mark, or a cut-off stroke, is many.
      let (count, box, largest) = screen.differences(from: fresh)
      guard count <= 8 else {
        let slug = name.replacingOccurrences(of: " ", with: "-")
        fail(
          "\(name): redrawing what changed left \(count) wrong pixels (up to \(largest) off) in \(box), pixel \(Int((box.minX - screen.visible.minX) * screen.scale)),\(Int((box.minY - screen.visible.minY) * screen.scale)); see \(screen.write(slug + "-screen")) and \(fresh.write(slug + "-fresh"))")
      }
    }

    /// Checks that drawing the view in small tiles, as AppKit does while scrolling, gives the
    /// same picture as drawing it in one go: every element is drawn wherever it shows.
    static func drawsInTiles(_ canvas: CanvasView, _ name: String) {
      canvas.displayIfNeeded()
      let whole = Picture(canvas)
      whole.paint(canvas)
      let tiles = Picture(canvas)
      let visible = tiles.visible
      let side = 61 / canvas.magnification
      var y = visible.minY
      while y < visible.maxY {
        var x = visible.minX
        while x < visible.maxX {
          tiles.paint(canvas, rects: [CGRect(x: x, y: y, width: side, height: side)])
          x += side
        }
        y += side
      }
      let (count, box, largest) = tiles.differences(from: whole)
      guard count <= 8 else {
        fail("\(name): drawn in tiles, \(count) pixels (up to \(largest) off) differ in \(box), pixel \(Int((box.minX - visible.minX) * tiles.scale)),\(Int((box.minY - visible.minY) * tiles.scale)); see \(tiles.write("tiles")) and \(whole.write("whole"))")
      }
    }

    // MARK: Events

    /// A drag made of separate events, each checked for what it leaves on screen.
    static func checkedDrag(
      _ canvas: CanvasView, _ name: String, _ points: [CGPoint], flags: NSEvent.ModifierFlags = []
    ) {
      redraws(canvas, "\(name) (press)") { send(.leftMouseDown, at: points[0], in: canvas, flags: flags) }
      for (i, p) in points.dropFirst().enumerated() {
        redraws(canvas, "\(name) (drag \(i + 1))") { send(.leftMouseDragged, at: p, in: canvas, flags: flags) }
      }
      redraws(canvas, "\(name) (release)") { send(.leftMouseUp, at: points.last!, in: canvas, flags: flags) }
    }

    static func hover(_ canvas: CanvasView, at p: CGPoint) {
      guard let window = canvas.window,
        let event = NSEvent.mouseEvent(
          with: .mouseMoved, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
      else { return }
      canvas.mouseMoved(with: event)
    }

    static func wiggle(_ a: CGPoint, _ b: CGPoint, steps: Int = 14, amplitude: CGFloat = 30) -> [CGPoint] {
      (0...steps).map { i in
        let t = CGFloat(i) / CGFloat(steps)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sin(t * .pi * 3) * amplitude)
      }
    }

    // MARK: The tour

    static func tourCheck(_ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let editor = document.editor!
        let canvas = editor.canvas
        let undo = document.undoManager!
        editor.window?.makeFirstResponder(canvas)
        canvas.window?.displayIfNeeded()

        drawingLeavesNothingBehind(editor, canvas, undo)
        tilesMatch(canvas)
        viewKeepsItsPlace(editor, canvas)
        controlsStayPut(editor, canvas)
        colorsAreTrue(editor, canvas)
        typingIsPlain(editor, canvas)
        spectrumHolds(editor, canvas)
        distributingStaysOnTheCanvas(canvas, undo)

        document.updateChangeCount(.changeCleared)
        finish()
      }
    }

    /// Every tool, at three zooms, leaves the picture on screen exactly as it should be.
    static func drawingLeavesNothingBehind(_ editor: Editor, _ canvas: CanvasView, _ undo: UndoManager) {
      for zoom in [1.0, 2.5, 0.5] as [CGFloat] {
        canvas.drawing.replace(Scene())
        canvas.zoom(to: zoom)
        canvas.center(on: canvas.scene.canvas.center)
        canvas.window?.displayIfNeeded()
        let c = canvas.unobscuredRect.center
        let reach = min(canvas.unobscuredRect.width, canvas.unobscuredRect.height) * 0.3
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * reach, y: c.y + y * reach) }
        let tag = "at \(Int(zoom * 100))%"

        // Every brush, drawn with separate events, with its ring following the pointer.
        for (i, brush) in Controls.brushes.enumerated() {
          canvas.tool = brush
          let y = -0.9 + CGFloat(i) * 0.19
          redraws(canvas, "the \(brush.title) ring \(tag)") { hover(canvas, at: at(-0.9, y)) }
          checkedDrag(canvas, "the \(brush.title) \(tag)", wiggle(at(-0.9, y), at(0.2, y + 0.05), amplitude: reach * 0.05))
          redraws(canvas, "the \(brush.title) ring moving \(tag)") { hover(canvas, at: at(0.25, y)) }
        }
        // Shapes and lines, curved lines too, and arrows.
        let shapes: [(Tool, CGPoint, CGPoint)] = [
          (.rectangle, at(0.3, -0.9), at(0.6, -0.6)), (.ellipse, at(0.65, -0.9), at(0.95, -0.6)),
          (.line, at(0.3, -0.5), at(0.6, -0.3)), (.arrow, at(0.65, -0.5), at(0.95, -0.3)),
        ]
        for (tool, a, b) in shapes {
          canvas.tool = tool
          checkedDrag(canvas, "a \(tool.title) \(tag)", line(from: a, to: b, steps: 6), flags: .command)
        }
        canvas.tool = .line
        canvas.setStyle("Curve") { $0.curved = true }
        canvas.setStyle("Width") { $0.strokeWidth = 10 }
        checkedDrag(canvas, "a curved line \(tag)", line(from: at(0.3, -0.2), to: at(0.6, 0), steps: 6), flags: .command)
        // A curved polygon placed corner by corner: the curve swings past its corners as the
        // pointer moves.
        canvas.tool = .polygon
        canvas.shapePreset = nil
        canvas.setStyle("Curve") { $0.curved = true }
        canvas.setStyle("Width") { $0.strokeWidth = 8 }
        let corners = [at(0.65, -0.2), at(0.95, -0.1), at(0.9, 0.2), at(0.7, 0.25)]
        for (i, corner) in corners.enumerated() {
          redraws(canvas, "a polygon's corner \(i + 1) \(tag)") { click(corner, in: canvas) }
          redraws(canvas, "a polygon's side \(i + 1) \(tag)") { hover(canvas, at: CGPoint(x: corner.x - reach * 0.4, y: corner.y + reach * 0.3)) }
        }
        redraws(canvas, "closing a polygon \(tag)") { click(corners[0], in: canvas) }
        canvas.shapePreset = .star
        checkedDrag(canvas, "a star \(tag)", line(from: at(0.3, 0.3), to: at(0.6, 0.6), steps: 5), flags: .command)
        canvas.shapePreset = nil

        // Text, typed and finished.
        canvas.tool = .text
        redraws(canvas, "a new text box \(tag)") { click(at(0.65, 0.4), in: canvas) }
        redraws(canvas, "typing \(tag)") { canvas.textEditor?.insertText("Hello there", replacementRange: canvas.textEditor!.selectedRange()) }
        redraws(canvas, "finishing text \(tag)") {
          grouped(undo) {
            canvas.window?.makeFirstResponder(canvas)
            canvas.endTextEditing()
          }
        }

        // Selecting, moving, resizing, turning, and bending.
        canvas.tool = .select
        guard let box = canvas.scene.elements.first(where: { $0.kind == .rectangle }),
          let bent = canvas.scene.elements.first(where: { $0.kind == .line && $0.curved }),
          let ink = canvas.scene.elements.first(where: { $0.brush == .watercolor })
        else { fail("the tour should have drawn a rectangle, a curved line, and watercolour \(tag)") }
        redraws(canvas, "picking a rectangle \(tag)") { click(CGPoint(x: box.frame.midX, y: box.frame.minY), in: canvas) }
        checkedDrag(canvas, "moving a rectangle \(tag)", line(from: CGPoint(x: box.frame.midX, y: box.frame.minY), to: at(0.2, -0.5), steps: 6), flags: .command)
        if let moved = canvas.scene[box.id] {
          let corner = CGPoint(x: moved.frame.maxX, y: moved.frame.maxY)
          checkedDrag(canvas, "resizing a rectangle \(tag)", line(from: corner, to: CGPoint(x: corner.x + reach * 0.3, y: corner.y + reach * 0.2), steps: 5), flags: .command)
        }
        if let box = canvas.selectionBox() {
          let knob = canvas.rotationHandle(box)
          checkedDrag(canvas, "turning a rectangle \(tag)", line(from: knob, to: CGPoint(x: knob.x + reach * 0.4, y: knob.y + reach * 0.1), steps: 5))
        }
        redraws(canvas, "picking a curved line \(tag)") { canvas.select([bent.id]) }
        let middle = bent.segmentMiddle(0)
        checkedDrag(canvas, "bending a line \(tag)", line(from: middle, to: CGPoint(x: middle.x, y: middle.y + reach * 0.3), steps: 5))
        redraws(canvas, "picking watercolour \(tag)") { canvas.select([ink.id]) }
        let inkPoint = ink.worldPoints[ink.worldPoints.count / 2]
        checkedDrag(canvas, "moving watercolour \(tag)", line(from: inkPoint, to: CGPoint(x: inkPoint.x + reach * 0.2, y: inkPoint.y + reach * 0.15), steps: 5), flags: .command)
        redraws(canvas, "nudging \(tag)") { grouped(undo) { canvas.nudge(dx: 10, dy: 0) } }
        grouped(undo) { canvas.drawing.finishCoalescing() }
        redraws(canvas, "colouring \(tag)") { grouped(undo) { canvas.setStyle("Colour") { $0.stroke = Color(hex: "#FF3B30") } } }
        redraws(canvas, "widening \(tag)") { grouped(undo) { canvas.setStyle("Width") { $0.strokeWidth = 40 } } }
        redraws(canvas, "undoing \(tag)") { undo.undo() }
        redraws(canvas, "redoing \(tag)") { undo.redo() }
        redraws(canvas, "Option-dragging a copy \(tag)") {
          drag(line(from: CGPoint(x: inkPoint.x + reach * 0.2 + 10, y: inkPoint.y + reach * 0.15), to: at(-0.5, 0.8), steps: 4), in: canvas, flags: [.option, .command])
        }
        // Selecting by box and by loop.
        redraws(canvas, "letting go \(tag)") { canvas.select([]) }
        checkedDrag(canvas, "a selection box \(tag)", line(from: at(-0.95, -0.95), to: at(0.1, 0.1), steps: 6))
        canvas.select([])
        canvas.lassoSelects = true
        checkedDrag(canvas, "a selection loop \(tag)", [at(-0.2, 0.3), at(0.3, 0.3), at(0.3, 0.8), at(-0.2, 0.8), at(-0.2, 0.35)])
        canvas.lassoSelects = false
        redraws(canvas, "deleting \(tag)") { grouped(undo) { canvas.delete(nil) } }
        // Both erasers, with their rings.
        for eraser in [Tool.strokeEraser, .eraser] {
          canvas.tool = eraser
          canvas.styles[.eraser, default: Tool.eraser.defaultStyle].strokeWidth = 40
          canvas.styles[.strokeEraser, default: Tool.strokeEraser.defaultStyle].strokeWidth = 40
          checkedDrag(canvas, "the \(eraser.title) \(tag)", line(from: at(-0.6, -1), to: at(-0.4, 1), steps: 12))
        }
        // The canvas's corner.
        canvas.tool = .select
        let page = canvas.scene.canvas
        canvas.center(on: CGPoint(x: page.maxX, y: page.maxY))
        canvas.window?.displayIfNeeded()
        checkedDrag(canvas, "resizing the canvas \(tag)", line(from: CGPoint(x: page.maxX, y: page.maxY), to: CGPoint(x: page.maxX - 80, y: page.maxY - 50), steps: 4))
        redraws(canvas, "undoing the canvas's size \(tag)") { undo.undo() }
      }
      pass("every tool, at 50%, 100%, and 250%, redraws exactly what changes, leaving nothing behind")
    }

    /// Drawing in tiles gives the same picture, at every zoom, for every kind of object.
    static func tilesMatch(_ canvas: CanvasView) {
      var scene = Scene()
      demo(canvas)
      scene = canvas.scene
      // Every brush, thick, near where tiles meet.
      for (i, brush) in Controls.brushes.enumerated() {
        guard let kind = brush.brush else { continue }
        var e = Element(kind: .freehand)
        e.brush = kind
        e.strokeWidth = 36
        e.stroke = Color(hex: "#5E5CE6")
        let raw = (0...40).map { CGPoint(x: 100 + CGFloat($0) * 9, y: 480 + CGFloat(i) * 30 + sin(CGFloat($0) / 4) * 12) }
        let (points, pressures) = Freehand.smoothed(raw, pressures: kind.usesPressure ? Freehand.simulatedPressures(raw, size: 36) : [])
        e.setWorldPoints(points)
        e.pressures = kind.usesPressure ? pressures : []
        scene.elements.append(e)
      }
      var curve = Element(kind: .polygon)
      curve.setWorldPoints([CGPoint(x: 600, y: 420), CGPoint(x: 700, y: 400), CGPoint(x: 680, y: 520), CGPoint(x: 610, y: 470)])
      curve.curved = true
      curve.strokeWidth = 14
      scene.elements.append(curve)
      var label = Element(kind: .text)
      label.text = "Tiles ƒ Æ gy"
      label.fontSize = 72
      label.fontName = "Noteworthy-Light"
      label.x = 700
      label.y = 560
      label.fitToText()
      scene.elements.append(label)
      canvas.drawing.replace(scene)
      // Nothing selected, one stroke, a turned shape, and several things at once.
      let ink = scene.elements.first { $0.kind == .freehand && $0.pressures.count > 0 }!.id
      let sky = scene.elements.first { $0.kind == .rectangle }!.id
      if let undo = canvas.undoManager { grouped(undo) { canvas.drawing.edit("Turn") { $0.rotate([sky], by: 0.3) } } }
      let selections: [(String, Set<String>)] = [
        ("nothing selected", []), ("a stroke selected", [ink]), ("a turned shape selected", [sky]),
        ("several selected", [ink, sky, scene.elements.last!.id, curve.id]),
      ]
      for (name, ids) in selections {
        canvas.select(ids)
        for zoom in [0.37, 1, 1.7, 4] as [CGFloat] {
          canvas.zoom(to: zoom)
          canvas.center(on: CGPoint(x: 520, y: 520))
          drawsInTiles(canvas, "\(name) at \(Int(zoom * 100))%")
        }
      }
      pass("the canvas draws the same in tiles as in one go, at every zoom")
    }

    /// Zooming keeps the middle of the view where it was, and the canvas stays in the middle
    /// when it's smaller than the view.
    static func viewKeepsItsPlace(_ editor: Editor, _ canvas: CanvasView) {
      canvas.drawing.replace(Scene(paper: Paper(size: CGSize(width: 3000, height: 2000))))
      canvas.zoom(to: 0.5)
      let spot = CGPoint(x: 1800, y: 900)
      canvas.center(on: spot)
      for percent in [100, 200, 50, 400, 100] {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = percent
        editor.zoomBar.zoomTo(item)
        let now = canvas.unobscuredRect.center
        guard abs(now.x - spot.x) <= 3, abs(now.y - spot.y) <= 3 else {
          fail("zooming to \(percent)% should keep the same place in the middle, moved from \(spot) to \(now)")
        }
      }
      canvas.zoomIn(nil)
      canvas.zoomOut(nil)
      guard canvas.unobscuredRect.center.distance(to: spot) <= 4 else { fail("zooming in and out should keep the place") }
      canvas.drawing.replace(Scene())
      canvas.zoom(to: 0.5)
      guard canvas.unobscuredRect.center.distance(to: canvas.scene.canvas.center) <= 3 else {
        fail("a canvas smaller than the view should sit in its middle, \(canvas.unobscuredRect) for \(canvas.scene.canvas)")
      }
      canvas.zoomToFit(nil)
      let shown = canvas.convert(canvas.scene.canvas, to: nil)
      let room = canvas.convert(canvas.unobscuredRect, to: nil)
      guard room.contains(shown), shown.width > room.width * 0.7 || shown.height > room.height * 0.7 else {
        fail("Zoom to Fit should show the whole canvas, large, clear of the toolbar and bars: \(shown) in \(room)")
      }
      pass("zooming keeps the view's place, and the canvas sits in the middle when it fits")
    }

    /// Choosing a brush, a shape, or a tool never moves the controls around it.
    static func controlsStayPut(_ editor: Editor, _ canvas: CanvasView) {
      canvas.drawing.replace(Scene())
      editor.togglePalette(nil)
      editor.choose(.draw)
      editor.palette.update()
      editor.window?.contentView?.layoutSubtreeIfNeeded()
      func frames() -> [NSRect] {
        allButtons(in: editor.palette.view).filter { $0 is BarButton }.map { $0.convert($0.bounds, to: nil) }
      }
      let brushes = allButtons(in: editor.palette.view).compactMap { $0 as? BarButton }.filter { button in
        Controls.brushes.contains { button.toolTip?.hasPrefix($0.title) == true }
      }
      guard brushes.count == Controls.brushes.count else { fail("the Palette should show every brush, found \(brushes.count)") }
      let before = frames()
      for button in brushes {
        click(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        guard frames() == before else { fail("choosing \(button.toolTip ?? "") moved the Palette's buttons") }
        // The same buttons stay, marked afresh, rather than being made again.
        guard button.window != nil, button.isOn, brushes.filter(\.isOn).count == 1 else {
          fail("\(button.toolTip ?? "") should show it's chosen, alone, in the same Palette")
        }
      }
      // Equal spacing: each row's buttons are the same distance apart.
      let xs = brushes.prefix(5).map { $0.convert($0.bounds, to: nil).minX }
      let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
      guard let first = gaps.first, gaps.allSatisfy({ abs($0 - first) <= 1 }) else { fail("the brushes should be evenly spaced: \(xs)") }
      editor.togglePalette(nil)
      // The toolbar shows the tool in use as its own selection.
      for slot in Editor.Slot.allCases where slot != .image {
        editor.choose(slot)
        let chosen = editor.toolButtons.filter(\.button.isOn).map(\.slot)
        guard chosen == [slot] else { fail("choosing \(slot) should mark only it in the toolbar, got \(chosen)") }
      }
      editor.choose(.select)
      // Every tool's tip names its key, as the menus name theirs.
      for (slot, button) in editor.toolButtons {
        guard let tip = button.toolTip, tip.range(of: #"\(.+\)$"#, options: .regularExpression) != nil else {
          fail("the \(slot) tool's tip should show its key, got \(button.toolTip ?? "none")")
        }
      }
      // Every tool starts at one of the widths the bar offers, so one of them shows it's chosen.
      for tool in Tool.allCases where [Tool.select, .eyedropper, .fill, .text].contains(tool) == false {
        let width = tool.defaultStyle.strokeWidth
        let offered = Controls.widths(for: Controls.brushes.contains(tool) || tool == .eraser || tool == .strokeEraser ? tool : .line)
        guard offered.contains(width) else { fail("\(tool.title) starts at \(width), which isn't among the widths offered, \(offered)") }
      }
      pass("choosing brushes and tools never moves the Palette's buttons, and the toolbar marks the tool")
    }

    /// The drawing looks the same in dark mode: black ink is black on a white canvas, and the
    /// swatches are the colours they give.
    static func colorsAreTrue(_ editor: Editor, _ canvas: CanvasView) {
      let appearance = NSApp.appearance
      defer { NSApp.appearance = appearance }
      for name in [NSAppearance.Name.darkAqua, .aqua] {
        NSApp.appearance = NSAppearance(named: name)
        var scene = Scene()
        var ink = Element(kind: .rectangle)
        ink.frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        ink.fill = Color(hex: "#1D1D1F")
        ink.stroke = nil
        scene.elements = [ink]
        canvas.drawing.replace(scene)
        canvas.zoom(to: 1)
        canvas.center(on: CGPoint(x: 400, y: 300))
        let picture = Picture(canvas)
        picture.paint(canvas)
        let paper = picture.color(at: CGPoint(x: 600, y: 500)), fill = picture.color(at: CGPoint(x: 250, y: 200))
        guard paper.prefix(3).allSatisfy({ $0 > 245 }), fill.prefix(3).allSatisfy({ $0 < 40 }) else {
          fail("in \(name.rawValue), the canvas should be white and black ink black, got \(paper) and \(fill)")
        }
      }
      pass("drawings look the same in light and dark: white canvas, black ink")
    }

    /// Typing shows the text as it will be, with none of a text document's rulers.
    static func typingIsPlain(_ editor: Editor, _ canvas: CanvasView) {
      canvas.drawing.replace(Scene())
      canvas.configuration.showsRulers = true
      defer { canvas.configuration.showsRulers = false }
      canvas.zoom(to: 1)
      canvas.center(on: canvas.scene.canvas.center)
      canvas.tool = .text
      let before = Picture(canvas)
      before.paint(canvas)
      click(CGPoint(x: 500, y: 300), in: canvas)
      guard let typing = canvas.textEditor else { fail("the text tool should start typing") }
      typing.insertText("Plain", replacementRange: typing.selectedRange())
      canvas.window?.displayIfNeeded()
      guard canvas.scrollView.horizontalRulerView?.accessoryView == nil, !typing.usesRuler, !typing.isRulerVisible else {
        fail("typing shouldn't bring up a text ruler over the canvas")
      }
      guard let color = typing.textColor?.usingColorSpace(.sRGB), color.redComponent < 0.2, color.greenComponent < 0.2 else {
        fail("the text being typed should show in its own colour")
      }
      let after = Picture(canvas)
      after.paint(canvas)
      guard after.color(at: CGPoint(x: 900, y: 600)) == before.color(at: CGPoint(x: 900, y: 600)) else {
        fail("typing shouldn't change the canvas around the text")
      }
      if let undo = canvas.undoManager {
        grouped(undo) {
          canvas.window?.makeFirstResponder(canvas)
          canvas.endTextEditing()
        }
      }
      canvas.tool = .select
      pass("typing shows plain text in its own colour, with no text ruler, and leaves the canvas as it was")
    }

    /// Dragging past the edge of the colour square or the hues holds at the edge, and greys
    /// keep the hue they were picked with.
    static func spectrumHolds(_ editor: Editor, _ canvas: CanvasView) {
      let spectrum = SpectrumView(frame: NSRect(x: 0, y: 0, width: 236, height: 152))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView?.addSubview(spectrum)
      spectrum.frame.origin = NSPoint(x: 32, y: 32)
      var picked: [Color] = []
      spectrum.pick = { color, _ in picked.append(color) }
      // The window isn't shown, so the events go straight to the view.
      func drag(_ points: [CGPoint], in view: NSView) {
        for (i, p) in points.enumerated() {
          let type: NSEvent.EventType = i == 0 ? .leftMouseDown : i == points.count - 1 ? .leftMouseUp : .leftMouseDragged
          let event = NSEvent.mouseEvent(
            with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
          switch type {
          case .leftMouseDown: view.mouseDown(with: event)
          case .leftMouseUp: view.mouseUp(with: event)
          default: view.mouseDragged(with: event)
          }
        }
      }
      // Down in the square, then far past its right and bottom: the brightest saturation, black.
      drag([CGPoint(x: 100, y: 40), CGPoint(x: 400, y: 200), CGPoint(x: 900, y: 900), CGPoint(x: 900, y: 900)], in: spectrum)
      guard spectrum.saturation == 1, spectrum.brightness == 0 else {
        fail("dragging past the square's corner should hold at it, got \(spectrum.saturation) \(spectrum.brightness)")
      }
      // Along the hues and past their right end: red at the very end, never wrapping to the start.
      let hues = spectrum.hues
      drag([CGPoint(x: hues.midX, y: hues.midY), CGPoint(x: hues.maxX + 200, y: hues.midY - 300), CGPoint(x: hues.maxX + 200, y: hues.midY - 300)], in: spectrum)
      guard spectrum.hue == 1 else { fail("dragging past the hues' end should hold at the end, got \(spectrum.hue)") }
      drag([CGPoint(x: hues.midX, y: hues.midY), CGPoint(x: hues.minX - 200, y: hues.midY + 300), CGPoint(x: hues.minX - 200, y: hues.midY + 300)], in: spectrum)
      guard spectrum.hue == 0 else { fail("dragging past the hues' start should hold at the start, got \(spectrum.hue)") }
      // A blue made grey keeps its blue hue, so the square doesn't jump.
      spectrum.color = Color(hex: "#007AFF")
      let blue = spectrum.hue
      spectrum.color = Color(hex: "#808080")
      guard spectrum.hue == blue else { fail("a grey should keep the hue before it") }
      window.close()
      pass("the colour square and hues hold at their edges, and greys keep their hue")
    }

    /// Spacing objects out never sends them off the canvas.
    static func distributingStaysOnTheCanvas(_ canvas: CanvasView, _ undo: UndoManager) {
      var scene = Scene(paper: Paper(size: CGSize(width: 800, height: 700)))
      let frames = [
        CGRect(x: -120, y: 380, width: 60, height: 40), CGRect(x: 90, y: 40, width: 460, height: 300),
        CGRect(x: 20, y: 250, width: 300, height: 200), CGRect(x: 560, y: 500, width: 120, height: 60),
        CGRect(x: 60, y: 560, width: 180, height: 120), CGRect(x: 350, y: 300, width: 40, height: 90),
      ]
      for frame in frames {
        var e = Element(kind: .ellipse)
        e.frame = frame
        scene.elements.append(e)
      }
      canvas.drawing.replace(scene)
      canvas.selectAll(nil)
      let before = canvas.scene.bounds(of: canvas.drawing.selection)
      canvas.distributeHorizontally(nil)
      canvas.distributeVertically(nil)
      let after = canvas.scene.bounds(of: canvas.drawing.selection)
      guard after.minX >= min(before.minX, 0) - 0.5, after.maxX <= before.maxX + 0.5, after.minY >= before.minY - 0.5,
        after.maxY <= before.maxY + 0.5
      else { fail("distributing should keep objects within where they were, from \(before) to \(after)") }
      let off = canvas.scene.elements.filter { !$0.bounds.intersects(canvas.scene.canvas) }
      guard off.isEmpty else { fail("distributing shouldn't move objects off the canvas") }
      canvas.select([])
      pass("distributing keeps objects within their own extent and on the canvas")
    }
  }
#endif
