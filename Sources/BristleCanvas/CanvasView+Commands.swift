import AppKit
import BristleCore
import CoreImage
import Vision

extension CanvasView: NSMenuItemValidation {
  // MARK: Keys

  public override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    if event.keyCode == 49, flags.isEmpty {  // Space pans while held, as in Preview and Freeform.
      if !spaceHeld {
        spaceHeld = true
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
      }
      return
    }
    if flags.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
      let chosen = Tool.allCases.first(where: { !$0.key.isEmpty && $0.key == key })
    {
      tool = chosen
      return
    }
    let step: CGFloat = flags.contains(.shift) ? 10 : 1
    switch event.keyCode {
    case 51, 117: deleteSelection("Delete")
    case 53: cancelOperation(nil)
    case 36, 76:
      if case .polygon(let points) = interaction {
        finishPolygon(Array(points.dropLast()))
      } else if let element = drawing.selectedElements.first, drawing.selection.count == 1 {
        editContent(of: element)
      } else if drawing.selection.count > 1, let first = drawing.selectedElements.first,
        let group = scene.outermostGroup(of: first, within: enteredGroup)
      {
        enteredGroup = group
        select(pickSet(for: first))
      }
    case 48: selectNext(backwards: flags.contains(.shift))
    case 123: nudge(dx: -step, dy: 0)
    case 124: nudge(dx: step, dy: 0)
    case 125: nudge(dx: 0, dy: step)
    case 126: nudge(dx: 0, dy: -step)
    default: super.keyDown(with: event)
    }
  }

  public override func keyUp(with event: NSEvent) {
    if event.keyCode == 49, spaceHeld {
      spaceHeld = false
      window?.invalidateCursorRects(for: self)
      return
    }
    super.keyUp(with: event)
  }

  public override func flagsChanged(with event: NSEvent) {
    updateCursor(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    super.flagsChanged(with: event)
  }

  public override func cancelOperation(_ sender: Any?) {
    if case .polygon = interaction {
      interaction = .none
      needsDisplay = true
      return
    }
    if croppingID != nil || pointEditingID != nil {
      croppingID = nil
      pointEditingID = nil
      needsDisplay = true
      return
    }
    if enteredGroup != nil, let first = drawing.selectedElements.first {
      // Escape steps back out of an entered group, selecting the group again.
      enteredGroup = nil
      select(pickSet(for: first))
      return
    }
    if !drawing.selection.isEmpty {
      select([])
    } else if tool != .select {
      tool = .select
    }
  }

  func nudge(dx: CGFloat, dy: CGFloat) {
    let ids = drawing.selection.filter { scene[$0]?.locked == false }
    guard !ids.isEmpty else { return }
    let step = 1 / max(1, magnification)
    drawing.coalesce("Move") { $0.move(ids, dx: dx * step, dy: dy * step) }
  }

  /// Tab picks the next element in stacking order, so everything can be reached by keyboard.
  func selectNext(backwards: Bool) {
    let candidates = pickableElements
    guard !candidates.isEmpty else { return }
    let current = candidates.lastIndex { drawing.selection.contains($0.id) }
    let next: Int
    if let current {
      next = (current + (backwards ? -1 : 1) + candidates.count) % candidates.count
    } else {
      next = backwards ? candidates.count - 1 : 0
    }
    select(pickSet(for: candidates[next]))
    if let box = selectionBox() { scrollToVisible(CGRect(boundingPoints: box.corners).insetBy(dx: -40, dy: -40)) }
  }

  // MARK: Cursors

  /// The tool's cursor everywhere the canvas shows, except under the bars laid over it and the
  /// toolbar, where the arrow makes their buttons easy to aim at.
  public override func resetCursorRects() {
    let visible = visibleRect
    let covered = coveredRectsInCanvas().filter { $0.intersects(visible) }
    guard !covered.isEmpty else { return addCursorRect(visible, cursor: toolCursor) }
    // Cut what's visible into a grid along every covered rectangle's edges, keeping the cells
    // that nothing covers.
    let xs = Set([visible.minX, visible.maxX] + covered.flatMap { [$0.minX, $0.maxX] }).filter { $0 >= visible.minX && $0 <= visible.maxX }.sorted()
    let ys = Set([visible.minY, visible.maxY] + covered.flatMap { [$0.minY, $0.maxY] }).filter { $0 >= visible.minY && $0 <= visible.maxY }.sorted()
    for (x0, x1) in zip(xs, xs.dropFirst()) {
      for (y0, y1) in zip(ys, ys.dropFirst()) {
        let cell = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        let middle = CGPoint(x: cell.midX, y: cell.midY)
        if !covered.contains(where: { $0.contains(middle) }) { addCursorRect(cell, cursor: toolCursor) }
      }
    }
    for rect in covered { addCursorRect(rect.intersection(visible), cursor: .arrow) }
  }

  /// What lies over the canvas, in its own coordinates.
  func coveredRectsInCanvas() -> [CGRect] {
    (coveredRects?() ?? []).map { convert($0, from: nil) }
  }

  func isCovered(_ p: CGPoint) -> Bool { coveredRectsInCanvas().contains { $0.contains(p) } }

  public override func cursorUpdate(with event: NSEvent) {
    updateCursor(at: point(event))
  }

  func updateCursor(at p: CGPoint) {
    if interaction.isNone && isCovered(p) {
      NSCursor.arrow.set()
      return
    }
    if spaceHeld {
      NSCursor.openHand.set()
      return
    }
    if tool == .select, let handle = handle(at: p) {
      cursor(for: handle).set()
      return
    }
    if tool == .select, let frame = scene.frame, element(at: p) == nil, let edge = frameEdge(at: p, frame) {
      frameCursor(edge).set()
      return
    }
    toolCursor.set()
  }

  func frameCursor(_ edge: Int) -> NSCursor {
    if #available(macOS 15.0, *) {
      let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
      return NSCursor.frameResize(position: positions[edge], directions: .all)
    }
    return edge % 4 == 1 ? .resizeUpDown : edge % 4 == 3 ? .resizeLeftRight : .crosshair
  }

  func cursor(for handle: Handle) -> NSCursor {
    guard case .resize(let i) = handle else { return .arrow }
    if #available(macOS 15.0, *) {
      let angle = (selectionBox()?.rotation ?? 0) * 180 / .pi
      let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
      // Rotated boxes use the handle a quarter-turn round when that's closer to how it points.
      let turns = Int(((angle + 22.5) / 45).rounded(.down)) % 8
      return NSCursor.frameResize(position: positions[(i + turns + 8) % 8], directions: .all)
    }
    return .crosshair
  }

  var toolCursor: NSCursor {
    switch tool {
    case .select: return .arrow
    case .text: return .iBeam
    // The size of a brush or the eraser shows as a ring drawn on the canvas, under the bars, so
    // the cursor itself is small.
    case .pencil, .pen, .highlighter, .pixel, .calligraphy, .airbrush, .crayon, .marker, .watercolor, .oil: return Self.dotCursor
    case .eraser, .strokeEraser: return symbolCursor("eraser", hotSpot: CGPoint(x: 9, y: 9))
    case .eyedropper: return symbolCursor("eyedropper", hotSpot: CGPoint(x: 1, y: 15))
    case .fill: return symbolCursor("drop", hotSpot: CGPoint(x: 8, y: 15))
    default: return .crosshair
    }
  }

  /// A small dot with a light edge, which shows on any color.
  static let dotCursor: NSCursor = {
    let size = NSSize(width: 9, height: 9)
    let image = NSImage(size: size, flipped: false) { rect in
      let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
      NSColor.white.withAlphaComponent(0.9).setStroke()
      dot.lineWidth = 2
      dot.stroke()
      NSColor.black.setFill()
      dot.fill()
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 4.5, y: 4.5))
  }()

  /// Whether the pointer shows the size of what it paints or erases.
  var showsSizeRing: Bool { tool.brush != nil || tool == .eraser || tool == .strokeEraser }

  /// How wide the ring is: the brush's width, or the eraser's.
  var sizeRingWidth: CGFloat {
    [.eraser, .strokeEraser].contains(tool) ? (styles[.eraser]?.strokeWidth ?? 16) : style.strokeWidth
  }

  /// The shape the brush or eraser covers under the pointer: a circle, or a square for the
  /// highlighter and the pixel brush, whose square sits on the pixel grid.
  func sizeRing(at p: CGPoint) -> (rect: CGRect, square: Bool) {
    let width = sizeRingWidth
    if tool == .pixel {
      let side = max(1, width.rounded())
      let origin = CGPoint(x: (p.x / side).rounded(.down) * side, y: (p.y / side).rounded(.down) * side)
      return (CGRect(origin: origin, size: CGSize(width: side, height: side)), true)
    }
    return (CGRect(x: p.x - width / 2, y: p.y - width / 2, width: width, height: width), tool == .highlighter)
  }

  func invalidateSizeRing(_ p: CGPoint?) {
    guard let p else { return }
    let margin = 3 / magnification
    setNeedsDisplay(sizeRing(at: p).rect.insetBy(dx: -margin, dy: -margin))
  }

  func drawSizeRing(in context: CGContext, scale: CGFloat) {
    guard showsSizeRing, let p = hoverPoint, !spaceHeld else { return }
    let (rect, square) = sizeRing(at: p)
    guard rect.width * scale >= 4 else { return }
    let path = square ? CGPath(rect: rect, transform: nil) : CGPath(ellipseIn: rect, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
    context.setLineWidth(2.5 / scale)
    context.strokePath()
    context.addPath(path)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
    context.setLineWidth(1 / scale)
    context.strokePath()
    context.restoreGState()
  }

  func symbolCursor(_ name: String, hotSpot: CGPoint) -> NSCursor {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    else { return .crosshair }
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      let tinted = symbol.copy() as! NSImage
      tinted.isTemplate = true
      NSGraphicsContext.current?.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowColor = .white
      shadow.shadowBlurRadius = 2
      shadow.set()
      tinted.draw(in: rect.insetBy(dx: 1, dy: 1))
      NSGraphicsContext.current?.restoreGraphicsState()
      return true
    }
    return NSCursor(image: image, hotSpot: hotSpot)
  }

  // MARK: Fill and eyedropper

  /// Fills the shape under the pointer with the fill tool's colour, or the frame's background
  /// when the pointer is inside the frame, as MS Paint fills its page. The endless canvas
  /// outside a frame isn't filled.
  func fill(at p: CGPoint, clear: Bool) {
    let color = clear ? nil : (styles[.fill]?.stroke ?? .ink)
    let tolerance = 3 / magnification
    let target = pickableElements.last { element in
      if element.isClosed, element.kind != .text, element.kind != .image {
        return element.path.contains(element.local(p)) || element.hit(p, tolerance: tolerance)
      }
      return element.hit(p, tolerance: tolerance)
    }
    if let target {
      drawing.edit("Fill") { scene in
        guard var e = scene[target.id] else { return }
        switch e.kind {
        case .rectangle, .ellipse, .polygon: e.fill = color
        case .text: e.stroke = color ?? .ink
        case .freehand, .line, .arrow: if let color { e.stroke = color }
        case .image: return
        }
        scene[target.id] = e
      }
    } else if let frame = scene.frame, frame.contains(p) {
      drawing.edit(clear ? "Clear Background" : "Fill Background") { $0.paper.background = color }
    }
  }

  /// The colour drawn at a point, images included.
  public func color(at p: CGPoint) -> Color? {
    var pixel = [UInt8](repeating: 0, count: 4)
    let rendered: Bool = pixel.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.translateBy(x: 0, y: 1)
      context.scaleBy(x: 1, y: -1)
      context.translateBy(x: -p.x + 0.5, y: -p.y + 0.5)
      let area = CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)
      context.setFillColor(canvasColor)
      context.fill(area)
      Renderer.draw(scene, in: context, rect: area, images: images)
      return true
    }
    guard rendered, pixel[3] > 0 else { return nil }
    let alpha = CGFloat(pixel[3]) / 255
    return Color(
      red: CGFloat(pixel[0]) / 255 / alpha, green: CGFloat(pixel[1]) / 255 / alpha,
      blue: CGFloat(pixel[2]) / 255 / alpha, alpha: alpha)
  }

  func pickColor(at p: CGPoint) {
    guard let color = color(at: p) else {
      NSSound.beep()
      return
    }
    let previous = toolBeforeEyedropper ?? .pencil
    // The color goes to what was selected when the eyedropper was chosen, or to the tool.
    if let ids = selectionBeforeEyedropper, !ids.isEmpty {
      drawing.selection = ids
      setStyle("Pick Color") { $0.stroke = color }
    } else {
      styles[previous, default: previous.defaultStyle].stroke = color
    }
    selectionBeforeEyedropper = nil
    tool = previous
    delegate?.canvasView(self, didPick: color)
    delegate?.canvasViewStylesDidChange(self)
  }

  // MARK: Editing commands

  func deleteSelection(_ name: String) {
    if frameSelected {
      frameSelected = false
      drawing.edit("Remove Frame") { $0.frame = nil }
      return
    }
    let ids = drawing.selection.filter { scene[$0]?.locked == false }
    guard !ids.isEmpty else { return }
    drawing.edit(name, select: []) { $0.delete(ids) }
  }

  @objc public func undo(_ sender: Any?) {
    drawing.finishCoalescing()
    undoManager?.undo()
  }

  @objc public func redo(_ sender: Any?) {
    drawing.finishCoalescing()
    undoManager?.redo()
  }

  @objc public func delete(_ sender: Any?) { deleteSelection("Delete") }

  @objc public override func selectAll(_ sender: Any?) {
    if tool != .select { tool = .select }
    enteredGroup = nil
    select(Set(pickableElements.map(\.id)))
  }

  @objc public func deselectAll(_ sender: Any?) { select([]) }

  /// Edit ▸ Invert Selection, as MS Paint has: everything not selected, and nothing else.
  @objc public func invertSelection(_ sender: Any?) {
    if tool != .select { tool = .select }
    enteredGroup = nil
    let selected = drawing.selection
    select(scene.expandToGroups(Set(pickableElements.map(\.id)).subtracting(selected)).subtracting(selected))
  }

  @objc public func duplicate(_ sender: Any?) {
    let ids = drawing.selection
    guard !ids.isEmpty else { return }
    let offset = CGPoint(x: 12, y: 12)
    let copies = Scene.copies(of: scene.elements.filter { ids.contains($0.id) }, offset: offset)
    drawing.edit("Duplicate", select: Set(copies.map(\.id))) { $0.elements += copies }
  }

  // MARK: Arrange

  var selectionOrNil: Set<String>? { drawing.selection.isEmpty ? nil : drawing.selection }

  @objc public func bringToFront(_ sender: Any?) { arrange("Bring to Front") { $0.reorder($1, .front) } }
  @objc public func bringForward(_ sender: Any?) { arrange("Bring Forward") { $0.reorder($1, .forward) } }
  @objc public func sendBackward(_ sender: Any?) { arrange("Send Backward") { $0.reorder($1, .backward) } }
  @objc public func sendToBack(_ sender: Any?) { arrange("Send to Back") { $0.reorder($1, .back) } }

  /// The menu item's tag picks the alignment, in `Scene.Alignment` order.
  @objc public func alignObjects(_ sender: Any?) {
    let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSButton)?.tag ?? (sender as? NSSegmentedControl)?.selectedTag() ?? 0
    guard Scene.Alignment.allCases.indices.contains(tag) else { return }
    let alignment = Scene.Alignment.allCases[tag]
    arrange("Align") { $0.align($1, alignment) }
  }

  @objc public func distributeHorizontally(_ sender: Any?) { arrange("Distribute") { $0.distribute($1, .horizontal) } }
  @objc public func distributeVertically(_ sender: Any?) { arrange("Distribute") { $0.distribute($1, .vertical) } }

  @objc public func group(_ sender: Any?) {
    guard drawing.selection.count > 1 else { return }
    enteredGroup = nil
    arrange("Group") { $0.group($1) }
  }

  @objc public func ungroup(_ sender: Any?) { arrange("Ungroup") { $0.ungroup($1) } }

  @objc public func lock(_ sender: Any?) {
    arrange("Lock", select: []) { $0.setLocked($1, true) }
  }

  @objc public func unlockAll(_ sender: Any?) {
    let locked = Set(scene.elements.filter(\.locked).map(\.id))
    guard !locked.isEmpty else { return }
    drawing.edit("Unlock", select: locked) { $0.setLocked(locked, false) }
  }

  @objc public func flipHorizontal(_ sender: Any?) { arrange("Flip Horizontally") { $0.flip($1, .horizontal) } }
  @objc public func flipVertical(_ sender: Any?) { arrange("Flip Vertically") { $0.flip($1, .vertical) } }
  @objc public func rotateLeft(_ sender: Any?) { arrange("Rotate Left") { $0.rotate($1, by: -.pi / 2) } }
  @objc public func rotateRight(_ sender: Any?) { arrange("Rotate Right") { $0.rotate($1, by: .pi / 2) } }

  func arrange(_ name: String, select: Set<String>? = nil, _ body: (inout Scene, Set<String>) -> Void) {
    let ids = drawing.selection.filter { scene[$0]?.locked == false }
    guard !ids.isEmpty else { return }
    drawing.edit(name, select: select) { body(&$0, ids) }
  }

  /// Starts cropping the selected image, as double-clicking it does.
  /// Format ▸ Remove Background, as MS Paint offers: the subject of the selected photo is kept
  /// and the rest made transparent, worked out on this Mac by Vision. The original image stays
  /// in the drawing's history, so it can be undone.
  @objc public func removeBackground(_ sender: Any?) {
    guard #available(macOS 14.0, *) else { return NSSound.beep() }
    let targets = drawing.selectedElements.filter { $0.kind == .image && !$0.locked }
    guard !targets.isEmpty else { return }
    let files = targets.compactMap { e in scene.files[e.file].map { (e.id, $0.data) } }
    Task.detached(priority: .userInitiated) {
      var results: [(String, Data)] = []
      for (id, data) in files {
        if let cut = Self.subject(of: data) { results.append((id, cut)) }
      }
      let done = results
      await MainActor.run { [weak self] in
        guard let self else { return }
        guard !done.isEmpty else { return NSSound.beep() }
        self.drawing.edit("Remove Background") { scene in
          for (id, png) in done {
            guard var e = scene[id] else { continue }
            e.file = scene.addFile(ImageFile(type: "public.png", data: png))
            scene[id] = e
          }
          scene.removeUnusedFiles()
        }
      }
    }
  }

  /// The image with everything but its subject made transparent, as PNG data.
  @available(macOS 14.0, *)
  nonisolated static func subject(of data: Data) -> Data? {
    guard let image = ImageStore.decode(data) else { return nil }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image)
    guard (try? handler.perform([request])) != nil, let result = request.results?.first,
      let buffer = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
    else { return nil }
    let context = CIContext()
    guard let cut = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    else { return nil }
    return Renderer.png(cut)
  }

  @objc public func cropSelectedImage(_ sender: Any?) {
    guard let image = drawing.selectedElements.first(where: { $0.kind == .image && !$0.locked }) else { return }
    if tool != .select { tool = .select }
    editContent(of: image)
    window?.makeFirstResponder(self)
  }

  // MARK: Canvas

  /// Frame ▸ Frame Selection: the frame fits the selection.
  @objc public func cropToSelection(_ sender: Any?) {
    let box = scene.bounds(of: drawing.selection)
    guard !box.isNull else { return }
    drawing.edit(scene.frame == nil ? "Add Frame" : "Frame Selection") { $0.crop(to: box) }
  }

  /// Adds a frame around the drawing, or around what's in view when there's nothing yet.
  @objc public func addFrame(_ sender: Any?) {
    guard scene.frame == nil else { return }
    let visible = scrollView.documentVisibleRect
    let fallback = visible.insetBy(dx: visible.width * 0.15, dy: visible.height * 0.15)
    drawing.edit("Add Frame") { scene in
      if scene.contentBounds.isNull { scene.crop(to: fallback) } else { scene.fitFrameToDrawing() }
    }
    // Picked only with Select, so another tool's settings stay in the bar.
    if tool == .select { frameSelected = true }
  }

  @objc public func removeFrame(_ sender: Any?) {
    guard scene.frame != nil else { return }
    frameSelected = false
    drawing.edit("Remove Frame") { $0.frame = nil }
  }

  @objc public func toggleFrame(_ sender: Any?) {
    if scene.frame == nil { addFrame(sender) } else { removeFrame(sender) }
  }

  @objc public func fitCanvasToDrawing(_ sender: Any?) {
    guard !scene.elements.isEmpty else { return }
    drawing.edit(scene.frame == nil ? "Add Frame" : "Fit Frame to Drawing") { $0.fitFrameToDrawing() }
  }

  @objc public func rotateCanvasLeft(_ sender: Any?) { drawing.edit("Rotate Drawing") { $0.rotateDrawing(clockwise: false) } }
  @objc public func rotateCanvasRight(_ sender: Any?) { drawing.edit("Rotate Drawing") { $0.rotateDrawing(clockwise: true) } }
  @objc public func flipCanvasHorizontal(_ sender: Any?) { drawing.edit("Flip Drawing") { $0.flipDrawing(.horizontal) } }
  @objc public func flipCanvasVertical(_ sender: Any?) { drawing.edit("Flip Drawing") { $0.flipDrawing(.vertical) } }

  // MARK: Style

  /// The style last copied with Copy Style, shared by every window.
  nonisolated(unsafe) static var copiedStyle: Style?

  @objc public func copyStyle(_ sender: Any?) {
    guard let element = drawing.selectedElements.first else { return }
    CanvasView.copiedStyle = Style(element)
  }

  @objc public func pasteStyle(_ sender: Any?) {
    guard let style = CanvasView.copiedStyle else { return }
    arrange("Paste Style") { scene, ids in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) { style.apply(to: &scene.elements[i]) }
    }
  }

  /// Changes the selection, or the current tool's style when nothing is selected.
  public func setStyle(_ name: String, coalescing: Bool = false, _ change: @escaping (inout Style) -> Void) {
    let ids = drawing.selection.filter { scene[$0]?.locked == false }
    if ids.isEmpty {
      var style = self.style
      change(&style)
      self.style = style
      window?.invalidateCursorRects(for: self)
      delegate?.canvasViewStylesDidChange(self)
      return
    }
    let body: (inout Scene) -> Void = { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
        var style = Style(scene.elements[i])
        change(&style)
        style.apply(to: &scene.elements[i])
      }
      scene.updateBindings(changed: ids)
    }
    if coalescing { drawing.coalesce(name, body) } else { drawing.edit(name, body) }
  }

  /// Colours from the Palette go to the selection's outlines and text, or to the current tool.
  @objc public func changeColor(_ sender: Any?) {
    guard let panel = sender as? NSColorPanel, let color = Color(panel.color.cgColor) else { return }
    if tool == .fill && drawing.selection.isEmpty {
      styles[.fill, default: Tool.fill.defaultStyle].stroke = color
      delegate?.canvasViewStylesDidChange(self)
      return
    }
    setStyle("Change Color", coalescing: true) { $0.stroke = color }
  }

  /// Fonts from the font panel go to the selected text, or to the text tool.
  @objc public func changeFont(_ sender: Any?) {
    guard let manager = sender as? NSFontManager else { return }
    let convert: (inout Style) -> Void = { style in
      let current = NSFont(name: style.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
      let font = manager.convert(current)
      style.fontName = font.fontName == NSFont.systemFont(ofSize: font.pointSize).fontName ? "" : font.fontName
      style.fontSize = font.pointSize
    }
    let texts = drawing.selectedElements.filter { $0.kind == .text }
    if texts.isEmpty {
      var style = styles[.text] ?? Tool.text.defaultStyle
      convert(&style)
      styles[.text] = style
      delegate?.canvasViewStylesDidChange(self)
      return
    }
    let ids = Set(texts.map(\.id))
    drawing.coalesce("Change Font") { scene in
      for i in scene.elements.indices where ids.contains(scene.elements[i].id) {
        var style = Style(scene.elements[i])
        convert(&style)
        style.apply(to: &scene.elements[i])
      }
      scene.updateBindings(changed: ids)
    }
  }

  // MARK: Validation

  public func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let unlocked = drawing.selection.contains { scene[$0]?.locked == false }
    switch item.action {
    case #selector(removeBackground(_:)):
      guard #available(macOS 14.0, *) else { return false }
      return drawing.selectedElements.contains { $0.kind == .image && !$0.locked }
    case #selector(invertSelection(_:)): return !scene.elements.isEmpty
    case #selector(undo(_:)):
      item.title = undoManager?.undoMenuItemTitle ?? "Undo"
      return undoManager?.canUndo ?? false
    case #selector(redo(_:)):
      item.title = undoManager?.redoMenuItemTitle ?? "Redo"
      return undoManager?.canRedo ?? false
    case #selector(delete(_:)) where frameSelected: return true
    case #selector(delete(_:)), #selector(cut(_:)), #selector(bringToFront(_:)), #selector(bringForward(_:)),
      #selector(sendBackward(_:)), #selector(sendToBack(_:)), #selector(lock(_:)), #selector(flipHorizontal(_:)),
      #selector(flipVertical(_:)), #selector(rotateLeft(_:)), #selector(rotateRight(_:)), #selector(pasteStyle(_:)):
      if item.action == #selector(pasteStyle(_:)) && CanvasView.copiedStyle == nil { return false }
      return unlocked
    case #selector(copy(_:)), #selector(duplicate(_:)), #selector(copyStyle(_:)), #selector(cropToSelection(_:)),
      #selector(deselectAll(_:)):
      return !drawing.selection.isEmpty
    case #selector(alignObjects(_:)): return unlocked
    case #selector(distributeHorizontally(_:)), #selector(distributeVertically(_:)):
      return scene.unitCount(of: drawing.selection) >= 3
    case #selector(group(_:)): return drawing.selection.count > 1
    case #selector(ungroup(_:)): return drawing.selectedElements.contains { !$0.groups.isEmpty }
    case #selector(unlockAll(_:)): return scene.elements.contains(where: \.locked)
    case #selector(paste(_:)): return canPaste(NSPasteboard.general)
    case #selector(fitCanvasToDrawing(_:)): return !scene.elements.isEmpty
    case #selector(removeFrame(_:)): return scene.frame != nil
    case #selector(addFrame(_:)): return scene.frame == nil
    case #selector(toggleFrame(_:)):
      item.title = scene.frame == nil ? "Add Frame" : "Remove Frame"
      return true
    case #selector(rotateCanvasLeft(_:)), #selector(rotateCanvasRight(_:)), #selector(flipCanvasHorizontal(_:)),
      #selector(flipCanvasVertical(_:)):
      return !scene.elements.isEmpty
    case #selector(zoomIn(_:)): return magnification < scrollView.maxMagnification - 0.001
    case #selector(zoomOut(_:)): return magnification > scrollView.minMagnification + 0.001
    case #selector(selectAll(_:)): return !pickableElements.isEmpty
    default: return true
    }
  }
}
