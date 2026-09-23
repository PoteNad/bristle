import AppKit
import BristleCore

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

  public override func resetCursorRects() {
    addCursorRect(visibleRect, cursor: toolCursor)
  }

  public override func cursorUpdate(with event: NSEvent) {
    updateCursor(at: point(event))
  }

  func updateCursor(at p: CGPoint) {
    if spaceHeld {
      NSCursor.openHand.set()
      return
    }
    if tool == .select, let handle = handle(at: p) {
      cursor(for: handle).set()
      return
    }
    toolCursor.set()
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
    case .pencil, .pen, .highlighter, .eraser, .strokeEraser:
      return brushCursor(diameter: (style.strokeWidth) * magnification, square: tool == .highlighter)
    case .eyedropper: return symbolCursor("eyedropper", hotSpot: CGPoint(x: 1, y: 15))
    case .fill: return symbolCursor("drop", hotSpot: CGPoint(x: 8, y: 15))
    default: return .crosshair
    }
  }

  /// A circle the size of the brush, so you can see what a stroke will cover.
  func brushCursor(diameter: CGFloat, square: Bool) -> NSCursor {
    let d = min(160, max(5, diameter))
    let size = NSSize(width: ceil(d) + 4, height: ceil(d) + 4)
    let image = NSImage(size: size, flipped: false) { rect in
      let circle = NSRect(x: (rect.width - d) / 2, y: (rect.height - d) / 2, width: d, height: d)
      let path = square ? NSBezierPath(rect: circle) : NSBezierPath(ovalIn: circle)
      NSColor.white.withAlphaComponent(0.9).setStroke()
      path.lineWidth = 2.5
      path.stroke()
      NSColor.black.withAlphaComponent(0.85).setStroke()
      path.lineWidth = 1
      path.stroke()
      if d < 10 {
        NSColor.black.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.midY - 0.5, width: 1, height: 1).fill()
      }
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
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

  /// Fills the shape under the pointer with the fill tool's colour, or the paper if there's none.
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
    } else if scene.paperRect.contains(p) {
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
      Renderer.draw(scene, in: context, rect: area, images: images, paper: scene.paperRect.contains(p))
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
    styles[previous, default: previous.defaultStyle].stroke = color
    tool = previous
    delegate?.canvasView(self, didPick: color)
    delegate?.canvasViewStylesDidChange(self)
  }

  // MARK: Editing commands

  func deleteSelection(_ name: String) {
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
    let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSSegmentedControl)?.selectedTag() ?? 0
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

  // MARK: Canvas

  @objc public func cropToSelection(_ sender: Any?) {
    let box = scene.bounds(of: drawing.selection)
    guard !box.isNull else { return }
    drawing.edit("Crop to Selection") { $0.crop(to: box) }
  }

  @objc public func fitCanvasToDrawing(_ sender: Any?) {
    guard !scene.elements.isEmpty else { return }
    drawing.edit("Fit Canvas to Drawing") { $0.fitPaperToDrawing() }
  }

  @objc public func rotateCanvasLeft(_ sender: Any?) { drawing.edit("Rotate Canvas") { $0.rotatePaper(clockwise: false) } }
  @objc public func rotateCanvasRight(_ sender: Any?) { drawing.edit("Rotate Canvas") { $0.rotatePaper(clockwise: true) } }
  @objc public func flipCanvasHorizontal(_ sender: Any?) { drawing.edit("Flip Canvas") { $0.flipPaper(.horizontal) } }
  @objc public func flipCanvasVertical(_ sender: Any?) { drawing.edit("Flip Canvas") { $0.flipPaper(.vertical) } }

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
    case #selector(undo(_:)):
      item.title = undoManager?.undoMenuItemTitle ?? "Undo"
      return undoManager?.canUndo ?? false
    case #selector(redo(_:)):
      item.title = undoManager?.redoMenuItemTitle ?? "Redo"
      return undoManager?.canRedo ?? false
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
    case #selector(zoomIn(_:)): return magnification < scrollView.maxMagnification - 0.001
    case #selector(zoomOut(_:)): return magnification > scrollView.minMagnification + 0.001
    case #selector(selectAll(_:)): return !pickableElements.isEmpty
    default: return true
    }
  }
}
