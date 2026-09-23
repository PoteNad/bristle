import AppKit
import BristleCore

/// What the pointer is doing between pressing and releasing.
enum Interaction {
  case none
  case panning(last: CGPoint)
  case freehand(points: [CGPoint], pressures: [CGFloat], tablet: Bool, dirty: CGRect)
  case shape(start: CGPoint, draft: Element)
  case polygon(points: [CGPoint])
  case marquee(start: CGPoint, current: CGPoint, base: Set<String>)
  case moving(start: CGPoint, originals: [Element], moved: Bool, copies: Bool)
  case resizing(handle: Int, start: CGPoint, box: SelectionBox, originals: [Element])
  case rotating(start: CGPoint, box: SelectionBox, originals: [Element])
  case point(index: Int, original: Element)
  case cropping(handle: Int, box: SelectionBox, original: Element)
  case erasing(path: [CGPoint], strokes: Bool)
  case textBox(start: CGPoint, current: CGPoint)
}

extension CanvasView {
  func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

  /// Snapping is on unless turned off, or Command is held while dragging, as in Keynote.
  func snapping(excluding ids: Set<String>, event: NSEvent) -> Snapping? {
    let grid = configuration.snapsToGrid ? configuration.gridSpacing : nil
    guard !event.modifierFlags.contains(.command), configuration.snapsToGuides || grid != nil else { return nil }
    let near = scrollView.documentVisibleRect.insetBy(dx: -200 / magnification, dy: -200 / magnification)
    var targets = [scene.paperRect]
    for element in scene.elements where !ids.contains(element.id) {
      let box = element.rotation == 0 ? element.frame : element.bounds
      if box.intersects(near) { targets.append(box) }
      if targets.count > 400 { break }
    }
    return Snapping(targets: targets, threshold: 6 / magnification, grid: grid)
  }

  // MARK: Pressing

  public override func mouseDown(with event: NSEvent) {
    if let editor = textEditor {
      endTextEditing()
      if tool == .text || editor.elementID.isEmpty { return }
    }
    window?.makeFirstResponder(self)
    let p = point(event)
    if spaceHeld {
      interaction = .panning(last: event.locationInWindow)
      NSCursor.closedHand.set()
      return
    }
    let tool = tabletEraser ? Tool.eraser : self.tool
    switch tool {
    case .select: selectDown(p, event)
    case .pencil, .pen, .highlighter:
      let tablet = event.subtype == .tabletPoint
      interaction = .freehand(
        points: [p], pressures: [tablet ? CGFloat(event.pressure) : 1], tablet: tablet,
        dirty: CGRect(origin: p, size: .zero))
      setNeedsDisplay(CGRect(origin: p, size: .zero).insetBy(dx: -style.strokeWidth * 2, dy: -style.strokeWidth * 2))
    case .eraser, .strokeEraser:
      let strokes = tool == .strokeEraser
      if strokes { drawing.beginGesture() }
      interaction = .erasing(path: [p], strokes: strokes)
      erase(to: p)
    case .line, .arrow, .rectangle, .ellipse:
      var draft = Element(kind: kind(for: tool))
      style.apply(to: &draft)
      let start = snapped(p, event: event)
      if draft.isLinear {
        draft.setWorldPoints([start, start])
        draft.startBinding = scene.binding(at: start, excluding: "", tolerance: 4 / magnification)
      } else {
        draft.frame = CGRect(origin: start, size: .zero)
      }
      interaction = .shape(start: start, draft: draft)
    case .polygon: polygonDown(p, event)
    case .text:
      if let hit = element(at: p), hit.kind == .text {
        select([hit.id])
        beginTextEditing(hit.id)
      } else {
        interaction = .textBox(start: p, current: p)
      }
    case .fill: fill(at: p, clear: event.modifierFlags.contains(.option))
    case .eyedropper: pickColor(at: p)
    }
  }

  func kind(for tool: Tool) -> Element.Kind {
    switch tool {
    case .line: .line
    case .arrow: .arrow
    case .ellipse: .ellipse
    case .polygon: .polygon
    case .text: .text
    default: .rectangle
    }
  }

  private func selectDown(_ p: CGPoint, _ event: NSEvent) {
    let shift = event.modifierFlags.contains(.shift)
    if !shift, let handle = handle(at: p) {
      drawing.beginGesture()
      let originals = drawing.selectedElements
      switch handle {
      case .resize(let i):
        if let croppingID, let image = scene[croppingID], let box = selectionBox() {
          interaction = .cropping(handle: i, box: box, original: image)
        } else if let box = selectionBox() {
          interaction = .resizing(handle: i, start: p, box: box, originals: originals)
        }
      case .rotate:
        if let box = selectionBox() { interaction = .rotating(start: p, box: box, originals: originals) }
      case .point(let i):
        if let line = originals.first { interaction = .point(index: i, original: line) }
      }
      return
    }
    if event.clickCount == 2 {
      doubleClick(at: p)
      return
    }
    if let croppingID, scene[croppingID].map({ !$0.hit(p, tolerance: 2 / magnification) }) ?? true {
      self.croppingID = nil
      needsDisplay = true
    }
    if let hit = element(at: p) {
      // Picking something outside the entered group leaves the group.
      if let group = enteredGroup, !hit.groups.contains(group) { enteredGroup = nil }
      let set = pickSet(for: hit)
      if shift {
        drawing.selection = drawing.selection.isSuperset(of: set)
          ? drawing.selection.subtracting(set) : drawing.selection.union(set)
        guard drawing.selection.isSuperset(of: set) else { return }
      } else if !drawing.selection.contains(hit.id) {
        select(set)
      }
      interaction = .moving(
        start: p, originals: drawing.selectedElements, moved: false, copies: event.modifierFlags.contains(.option))
    } else {
      if !shift {
        select([])
        enteredGroup = nil
      }
      interaction = .marquee(start: p, current: p, base: shift ? drawing.selection : [])
    }
  }

  private func doubleClick(at p: CGPoint) {
    guard let hit = element(at: p) else {
      enteredGroup = nil
      return
    }
    // Double-clicking a group enters it, picking what's inside one level at a time.
    if let group = scene.outermostGroup(of: hit, within: enteredGroup) {
      enteredGroup = group
      select(pickSet(for: hit))
      return
    }
    select([hit.id])
    editContent(of: hit)
  }

  /// What double-clicking an element does: edit text, crop an image, or move a polygon's corners.
  public func editContent(of element: Element) {
    switch element.kind {
    case .text: beginTextEditing(element.id)
    case .image:
      croppingID = element.id
      needsDisplay = true
    case .polygon:
      pointEditingID = pointEditingID == element.id ? nil : element.id
      needsDisplay = true
    default: break
    }
  }

  // MARK: Dragging

  public override func mouseDragged(with event: NSEvent) {
    let p = point(event)
    switch interaction {
    case .none: break
    case .panning(let last):
      let now = event.locationInWindow
      pan(by: CGPoint(x: now.x - last.x, y: now.y - last.y))
      interaction = .panning(last: now)
      return
    case .freehand(var points, var pressures, let tablet, let dirty):
      guard let last = points.last, last.distance(to: p) >= 0.4 / magnification else { return }
      points.append(p)
      pressures.append(tablet ? CGFloat(event.pressure) : 1)
      // Only the end of the stroke changes, so only the end is redrawn.
      let width = style.strokeWidth
      let tail = CGRect(boundingPoints: Array(points.suffix(12))).insetBy(dx: -width - 3, dy: -width - 3)
      setNeedsDisplay(tail.union(dirty))
      interaction = .freehand(points: points, pressures: pressures, tablet: tablet, dirty: tail)
    case .shape(let start, var draft):
      invalidate(draft)
      shape(&draft, from: start, to: snapped(p, event: event), event: event)
      interaction = .shape(start: start, draft: draft)
      invalidate(draft)
      if draft.isLinear {
        let previous = bindingTarget
        bindingTarget = scene.binding(at: p, excluding: draft.id, tolerance: 4 / magnification)?.element
        if previous != bindingTarget { needsDisplay = true }
      }
    case .polygon(var points):
      points[points.count - 1] = constrained(p, from: points[points.count - 2], event: event)
      interaction = .polygon(points: points)
      needsDisplay = true
    case .marquee(let start, let current, let base):
      setNeedsDisplay(CGRect(boundingPoints: [start, current]).insetBy(dx: -2, dy: -2))
      interaction = .marquee(start: start, current: p, base: base)
      let rect = CGRect(boundingPoints: [start, p])
      var touched = Set(pickableElements.filter { $0.intersects(rect) }.map(\.id))
      touched = scene.expandToGroups(touched, within: enteredGroup).filter { scene[$0]?.locked == false }
      drawing.selection = base.union(touched)
      setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    case .moving(let start, var originals, let moved, let copies):
      if !moved {
        guard start.distance(to: p) > 3 / magnification else { return }
        drawing.beginGesture()
        if copies {
          // Option-dragging leaves the originals behind and moves copies, as in Keynote.
          let duplicates = Scene.copies(of: originals, offset: .zero)
          drawing.live { $0.elements += duplicates }
          drawing.selection = Set(duplicates.map(\.id))
          originals = duplicates
        }
      }
      move(originals, from: start, to: p, event: event)
      interaction = .moving(start: start, originals: originals, moved: true, copies: copies)
      if !dragsOut(event) { autoscroll(with: event) }
      return
    case .resizing(let handle, _, let box, let originals):
      resize(originals, box: box, handle: handle, to: p, event: event)
    case .rotating(let start, let box, let originals):
      rotate(originals, box: box, from: start, to: p, event: event)
    case .point(let index, let original):
      movePoint(index, of: original, to: p, event: event)
    case .cropping(let handle, let box, let original):
      crop(original, box: box, handle: handle, to: p, event: event)
    case .erasing(var path, let strokes):
      path.append(p)
      interaction = .erasing(path: path, strokes: strokes)
      erase(to: p)
    case .textBox(let start, let current):
      setNeedsDisplay(CGRect(boundingPoints: [start, current]).insetBy(dx: -2, dy: -2))
      interaction = .textBox(start: start, current: p)
      setNeedsDisplay(CGRect(boundingPoints: [start, p]).insetBy(dx: -2, dy: -2))
    }
    autoscroll(with: event)
  }

  func pan(by delta: CGPoint) {
    let clip = scrollView.contentView
    var origin = clip.bounds.origin
    origin.x -= delta.x / magnification
    origin.y += delta.y / magnification
    clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  /// Keeps a dragged point on a 15° step from `anchor` while Shift is held.
  func constrained(_ p: CGPoint, from anchor: CGPoint, event: NSEvent) -> CGPoint {
    guard event.modifierFlags.contains(.shift) else { return p }
    let angle = atan2(p.y - anchor.y, p.x - anchor.x)
    let step = CGFloat.pi / 12
    let snappedAngle = (angle / step).rounded() * step
    let length = anchor.distance(to: p)
    return CGPoint(x: anchor.x + cos(snappedAngle) * length, y: anchor.y + sin(snappedAngle) * length)
  }

  func snapped(_ p: CGPoint, event: NSEvent) -> CGPoint {
    guard let snapping = snapping(excluding: [], event: event) else {
      guides = []
      return p
    }
    let result = snapping.snap(p)
    updateGuides(result.guides)
    return CGPoint(x: p.x + result.offset.x, y: p.y + result.offset.y)
  }

  func updateGuides(_ new: [Snapping.Guide]) {
    guard new != guides else { return }
    for guide in guides + new {
      setNeedsDisplay(CGRect(boundingPoints: [guide.from, guide.to]).insetBy(dx: -2, dy: -2))
    }
    guides = new
  }

  /// Shapes the draft of a line or shape between the press and the pointer.
  func shape(_ draft: inout Element, from start: CGPoint, to p: CGPoint, event: NSEvent) {
    if draft.isLinear {
      draft.setWorldPoints([start, constrained(p, from: start, event: event)])
      return
    }
    var dx = p.x - start.x, dy = p.y - start.y
    if event.modifierFlags.contains(.shift) {
      let side = max(abs(dx), abs(dy))
      dx = dx < 0 ? -side : side
      dy = dy < 0 ? -side : side
    }
    if event.modifierFlags.contains(.option) {
      draft.frame = CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
    } else {
      draft.frame = CGRect(boundingPoints: [start, CGPoint(x: start.x + dx, y: start.y + dy)])
    }
  }

  // MARK: Moving, resizing, rotating

  func move(_ originals: [Element], from start: CGPoint, to p: CGPoint, event: NSEvent) {
    var dx = p.x - start.x, dy = p.y - start.y
    if event.modifierFlags.contains(.shift) {
      if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
    }
    let ids = Set(originals.map(\.id))
    let box = originals.map { $0.rotation == 0 ? $0.frame : $0.bounds }.reduce(CGRect.null) { $0.union($1) }
    if let snapping = snapping(excluding: ids, event: event), !box.isNull {
      let result = snapping.snap(box.offsetBy(dx: dx, dy: dy))
      dx += result.offset.x
      dy += result.offset.y
      updateGuides(result.guides)
    } else {
      updateGuides([])
    }
    let byID = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    drawing.live { scene in
      for i in scene.elements.indices {
        guard let original = byID[scene.elements[i].id] else { continue }
        scene.elements[i].x = original.x + dx
        scene.elements[i].y = original.y + dy
      }
      scene.updateBindings(changed: ids)
    }
  }

  /// The new unrotated frame of a box whose handle has been dragged to `p`.
  func resizedFrame(_ box: SelectionBox, handle: Int, to p: CGPoint, keepAspect: Bool, fromCenter: Bool) -> CGRect {
    let unit = SelectionBox.units[handle]
    let f = box.frame
    let local = box.local(p)
    let minimum = 1 / magnification
    var minX = f.minX, maxX = f.maxX, minY = f.minY, maxY = f.maxY
    if fromCenter {
      if unit.x != 0.5 { let half = max(abs(local.x - f.midX), minimum / 2); minX = f.midX - half; maxX = f.midX + half }
      if unit.y != 0.5 { let half = max(abs(local.y - f.midY), minimum / 2); minY = f.midY - half; maxY = f.midY + half }
    } else {
      if unit.x == 0 { minX = min(local.x, maxX - minimum) }
      if unit.x == 1 { maxX = max(local.x, minX + minimum) }
      if unit.y == 0 { minY = min(local.y, maxY - minimum) }
      if unit.y == 1 { maxY = max(local.y, minY + minimum) }
    }
    var result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    if keepAspect, f.width > 0, f.height > 0 {
      let corner = unit.x != 0.5 && unit.y != 0.5
      let scale = corner
        ? max(result.width / f.width, result.height / f.height)
        : unit.x != 0.5 ? result.width / f.width : result.height / f.height
      let size = CGSize(width: f.width * scale, height: f.height * scale)
      // The opposite side or corner stays put; edges grow evenly across.
      let anchorX = fromCenter ? f.midX : unit.x == 0 ? f.maxX : unit.x == 1 ? f.minX : f.midX
      let anchorY = fromCenter ? f.midY : unit.y == 0 ? f.maxY : unit.y == 1 ? f.minY : f.midY
      let x = fromCenter || unit.x == 0.5 ? anchorX - size.width / 2 : unit.x == 0 ? anchorX - size.width : anchorX
      let y = fromCenter || unit.y == 0.5 ? anchorY - size.height / 2 : unit.y == 0 ? anchorY - size.height : anchorY
      result = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
    return result
  }

  func resize(_ originals: [Element], box: SelectionBox, handle: Int, to p: CGPoint, event: NSEvent) {
    var target = p
    if box.rotation == 0, let snapping = snapping(excluding: Set(originals.map(\.id)), event: event) {
      let result = snapping.snap(p)
      target = CGPoint(x: p.x + result.offset.x, y: p.y + result.offset.y)
      updateGuides(result.guides)
    }
    let single = originals.count == 1 ? originals[0] : nil
    let corner = SelectionBox.units[handle].x != 0.5 && SelectionBox.units[handle].y != 0.5
    // Images and text keep their proportions from a corner unless Shift is held; shapes the other way round.
    let proportional = single.map { $0.kind == .image || $0.kind == .text } ?? false
    let shift = event.modifierFlags.contains(.shift)
    let keepAspect = corner && proportional ? !shift : shift
    let newFrame = resizedFrame(
      box, handle: handle, to: target, keepAspect: keepAspect, fromCenter: event.modifierFlags.contains(.option))
    let sx = box.frame.width > 0 ? newFrame.width / box.frame.width : 1
    let sy = box.frame.height > 0 ? newFrame.height / box.frame.height : 1
    let byID = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    drawing.live { scene in
      for i in scene.elements.indices {
        guard var e = byID[scene.elements[i].id] else { continue }
        // Where the element's centre goes, in the box's unrotated space, then on the canvas.
        let c = box.local(e.center)
        let local = CGPoint(
          x: newFrame.minX + (c.x - box.frame.minX) * sx, y: newFrame.minY + (c.y - box.frame.minY) * sy)
        let center = local.applying(box.transform)
        var scaleX = sx, scaleY = sy
        let relative = e.rotation - box.rotation
        if abs(sin(relative)) > 0.7 { swap(&scaleX, &scaleY) }
        let size = CGSize(width: max(0, e.width * scaleX), height: max(0, e.height * scaleY))
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        if e.kind == .text {
          let scales = single == nil || keepAspect
          e.resize(to: frame, scalesText: scales)
          if !scales {
            e.fitToText()
            e.y = frame.minY - (e.height - frame.height) / 2
          }
        } else {
          e.resize(to: frame)
          if e.isPointBased { e.fitFrameToPoints() }
        }
        scene.elements[i] = e
      }
      scene.updateBindings(changed: Set(byID.keys))
    }
  }

  func rotate(_ originals: [Element], box: SelectionBox, from start: CGPoint, to p: CGPoint, event: NSEvent) {
    let c = box.center.applying(box.transform)
    var delta = atan2(p.y - c.y, p.x - c.x) - atan2(start.y - c.y, start.x - c.x)
    if event.modifierFlags.contains(.shift) {
      let step = CGFloat.pi / 12
      let total = ((box.rotation + delta) / step).rounded() * step
      delta = total - box.rotation
    }
    let byID = Dictionary(originals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    drawing.live { scene in
      for i in scene.elements.indices {
        guard var e = byID[scene.elements[i].id] else { continue }
        e.rotate(by: delta, around: c)
        scene.elements[i] = e
      }
      scene.updateBindings(changed: Set(byID.keys))
    }
  }

  func movePoint(_ index: Int, of original: Element, to p: CGPoint, event: NSEvent) {
    var world = original.worldPoints
    guard world.indices.contains(index) else { return }
    let neighbour = index > 0 ? world[index - 1] : world.count > 1 ? world[1] : p
    world[index] = constrained(snapped(p, event: event), from: neighbour, event: event)
    let isEnd = original.isLinear && (index == 0 || index == world.count - 1)
    let target = isEnd ? scene.binding(at: p, excluding: original.id, tolerance: 4 / magnification) : nil
    if bindingTarget != target?.element {
      bindingTarget = target?.element
      needsDisplay = true
    }
    drawing.live { scene in
      guard var e = scene[original.id] else { return }
      if original.isLinear {
        e.setWorldPoints(world)
      } else {
        // A polygon keeps its rotation; its corners move in its own space.
        e.points[index] = CGPoint(x: original.local(world[index]).x - original.x, y: original.local(world[index]).y - original.y)
        e.fitFrameToPoints()
      }
      scene[original.id] = e
    }
  }

  /// Changes an image's crop: the kept part's edge moves while the picture stays put.
  func crop(_ original: Element, box: SelectionBox, handle: Int, to p: CGPoint, event: NSEvent) {
    guard let full = fullImageFrame(original) else { return }
    var frame = resizedFrame(box, handle: handle, to: p, keepAspect: event.modifierFlags.contains(.shift), fromCenter: false)
    frame = frame.intersection(full)
    guard frame.width >= 1, frame.height >= 1 else { return }
    drawing.live { scene in
      guard var image = scene[original.id] else { return }
      // Keep the picture in place on the canvas while its frame changes.
      let center = frame.center.applying(original.transform)
      image.frame = CGRect(x: center.x - frame.width / 2, y: center.y - frame.height / 2, width: frame.width, height: frame.height)
      image.crop = CGRect(
        x: (frame.minX - full.minX) / full.width, y: (frame.minY - full.minY) / full.height,
        width: frame.width / full.width, height: frame.height / full.height)
      if let crop = image.crop, abs(crop.width - 1) < 0.0005, abs(crop.height - 1) < 0.0005 { image.crop = nil }
      scene[original.id] = image
    }
  }

  func erase(to p: CGPoint) {
    guard case .erasing(let path, let strokes) = interaction else { return }
    let radius = max(2, (styles[.eraser]?.strokeWidth ?? 16) / 2)
    let recent = Array(path.suffix(2))
    if strokes {
      drawing.live { $0.erase(along: recent, radius: radius) }
    } else {
      let touched = scene.elementsTouched(by: recent, radius: radius).subtracting(erasing)
      guard !touched.isEmpty else { return }
      erasing.formUnion(touched)
      for id in touched { if let element = scene[id] { invalidate(element) } }
    }
  }

  // MARK: Releasing

  public override func mouseUp(with event: NSEvent) {
    let p = point(event)
    let current = interaction
    interaction = .none
    updateGuides([])
    defer { delegate?.canvasViewDidFinishInteraction(self) }
    switch current {
    case .none: break
    case .panning:
      NSCursor.openHand.set()
    case .freehand(let points, let pressures, let tablet, _):
      finishStroke(points, pressures: pressures, tablet: tablet)
    case .shape(_, var draft):
      invalidate(draft)
      bindingTarget = nil
      let size = draft.isLinear ? draft.worldPoints[0].distance(to: draft.worldPoints[1]) : max(draft.width, draft.height)
      guard size >= 3 / magnification else {
        needsDisplay = true
        return
      }
      if draft.isLinear {
        draft.endBinding = scene.binding(at: p, excluding: draft.id, tolerance: 4 / magnification)
      }
      add(draft, name: "Add \(draft.kindName)")
    case .polygon(var points):
      // Dragging out the first side finishes that side; clicking later adds corners.
      if points.count == 2, points[0].distance(to: points[1]) >= 3 / magnification {
        points.append(points[1])
      }
      interaction = .polygon(points: points)
    case .marquee(let start, let current, _):
      setNeedsDisplay(CGRect(boundingPoints: [start, current]).insetBy(dx: -2, dy: -2))
    case .moving(_, let originals, let moved, _):
      if moved {
        drawing.endGesture(originals.count == 1 ? "Move \(originals[0].kindName)" : "Move")
      }
    case .resizing:
      drawing.endGesture("Resize")
    case .rotating:
      drawing.endGesture("Rotate")
    case .point(let index, let original):
      if original.isLinear, index == 0 || index == original.points.count - 1 {
        let binding = scene.binding(at: p, excluding: original.id, tolerance: 4 / magnification)
        drawing.live { scene in
          if index == 0 { scene[original.id]?.startBinding = binding } else { scene[original.id]?.endBinding = binding }
          scene.updateBindings(changed: [original.id])
        }
      }
      bindingTarget = nil
      needsDisplay = true
      drawing.endGesture("Move Point")
    case .cropping:
      drawing.endGesture("Crop Image")
    case .erasing(_, let strokes):
      if strokes {
        drawing.endGesture("Erase")
      } else if !erasing.isEmpty {
        let ids = erasing
        erasing = []
        drawing.edit("Erase") { $0.delete(ids) }
      }
    case .textBox(let start, let end):
      setNeedsDisplay(CGRect(boundingPoints: [start, end]).insetBy(dx: -2, dy: -2))
      let wide = abs(end.x - start.x) >= 20 / magnification
      addText(at: wide ? CGPoint(x: min(start.x, end.x), y: min(start.y, end.y)) : start, width: wide ? abs(end.x - start.x) : nil)
    }
  }

  /// Adds a new element, selecting it or keeping the tool, as Settings choose.
  func add(_ element: Element, name: String) {
    drawing.edit(name, select: configuration.returnsToSelect ? [element.id] : drawing.selection) { scene in
      scene.elements.append(element)
      scene.updateBindings(changed: [element.id])
    }
    if configuration.returnsToSelect { tool = .select }
  }

  func finishStroke(_ raw: [CGPoint], pressures rawPressures: [CGFloat], tablet: Bool) {
    guard let brush = tool.brush ?? (tabletEraser ? nil : .pen), !raw.isEmpty else { return }
    let width = style.strokeWidth
    var pressures = tablet ? rawPressures : []
    if brush == .pen && !tablet { pressures = Freehand.simulatedPressures(raw, size: width) }
    let (smooth, smoothPressures) = Freehand.smoothed(raw, pressures: pressures)
    let (points, kept) = Freehand.simplify(smooth, pressures: smoothPressures, tolerance: 0.2 / magnification)
    var stroke = Element(kind: .freehand)
    style.apply(to: &stroke)
    stroke.brush = brush
    stroke.setWorldPoints(points)
    stroke.pressures = brush == .pen ? kept : []
    setNeedsDisplay(stroke.bounds.insetBy(dx: -width * 2, dy: -width * 2))
    drawing.edit("Draw") { $0.elements.append(stroke) }
  }

  // MARK: Polygons

  private func polygonDown(_ p: CGPoint, _ event: NSEvent) {
    guard case .polygon(var points) = interaction else {
      interaction = .polygon(points: [snapped(p, event: event), snapped(p, event: event)])
      return
    }
    let first = points[0]
    let closing = points.count > 3 && first.distance(to: p) <= 8 / magnification
    if event.clickCount >= 2 || closing {
      if !closing, points.count > 1 { points.removeLast() }
      finishPolygon(points)
      return
    }
    points[points.count - 1] = constrained(snapped(p, event: event), from: points[points.count - 2], event: event)
    points.append(points[points.count - 1])
    interaction = .polygon(points: points)
  }

  func finishPolygon(_ points: [CGPoint]) {
    interaction = .none
    var corners = points
    // Drop the corner following the pointer and any doubled up by a double-click.
    while corners.count > 1, corners[corners.count - 1].distance(to: corners[corners.count - 2]) < 1 / magnification {
      corners.removeLast()
    }
    needsDisplay = true
    guard corners.count >= 3 else { return }
    var polygon = Element(kind: .polygon)
    styles[.polygon, default: Tool.polygon.defaultStyle].apply(to: &polygon)
    polygon.setWorldPoints(corners)
    add(polygon, name: "Add Polygon")
  }

  public override func mouseMoved(with event: NSEvent) {
    let p = point(event)
    if case .polygon(var points) = interaction {
      let previous = CGRect(boundingPoints: Array(points.suffix(2)))
      points[points.count - 1] = constrained(p, from: points[points.count - 2], event: event)
      interaction = .polygon(points: points)
      let margin = style.strokeWidth + 4
      setNeedsDisplay(previous.union(CGRect(boundingPoints: Array(points.suffix(2)))).insetBy(dx: -margin, dy: -margin))
    }
    updateCursor(at: p)
  }

  public override func otherMouseDown(with event: NSEvent) {
    interaction = .panning(last: event.locationInWindow)
    NSCursor.closedHand.set()
  }

  public override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }

  public override func otherMouseUp(with event: NSEvent) {
    interaction = .none
    window?.invalidateCursorRects(for: self)
  }

  public override func tabletProximity(with event: NSEvent) {
    tabletEraser = event.isEnteringProximity && event.pointingDeviceType == .eraser
    super.tabletProximity(with: event)
  }

  /// Cancels whatever the pointer was doing, finishing a polygon in progress.
  func finishInteraction() {
    switch interaction {
    case .polygon(let points): finishPolygon(points)
    case .moving(_, _, let moved, _) where moved: drawing.cancelGesture()
    case .resizing, .rotating, .point, .cropping: drawing.cancelGesture()
    case .erasing(_, let strokes):
      if strokes { drawing.endGesture("Erase") }
      erasing = []
    default: break
    }
    interaction = .none
    bindingTarget = nil
    updateGuides([])
    needsDisplay = true
  }

  // MARK: Drawing what's under way

  func drawInteraction(in context: CGContext, scale: CGFloat) {
    let accent = NSColor.controlAccentColor
    switch interaction {
    case .freehand(let raw, let rawPressures, let tablet, _):
      guard let brush = tool.brush else { return }
      let width = style.strokeWidth
      var pressures = tablet ? rawPressures : []
      if brush == .pen && !tablet { pressures = Freehand.simulatedPressures(raw, size: width) }
      let (points, smoothPressures) = Freehand.smoothed(raw, pressures: pressures)
      context.saveGState()
      context.setAlpha(style.opacity)
      context.setFillColor((style.stroke ?? .ink).cgColor)
      context.addPath(Freehand.outline(points, pressures: smoothPressures, size: width, brush: brush))
      context.fillPath(using: .winding)
      context.restoreGState()
    case .shape(_, let draft):
      Renderer.draw(draft, in: context, scene: scene, images: images)
    case .polygon(let points):
      var draft = Element(kind: .polygon)
      (styles[.polygon] ?? Tool.polygon.defaultStyle).apply(to: &draft)
      draft.fill = nil
      draft.kind = .line
      draft.setWorldPoints(points)
      Renderer.draw(draft, in: context, scene: scene, images: images)
      if let first = points.first {
        drawHandle(at: first, round: true, in: context, scale: scale, color: accent.cgColor)
      }
    case .marquee(let start, let current, _):
      let rect = CGRect(boundingPoints: [start, current])
      context.setFillColor(accent.withAlphaComponent(0.12).cgColor)
      context.fill(rect)
      context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
      context.setLineWidth(1 / scale)
      context.stroke(rect)
    case .textBox(let start, let current):
      let rect = CGRect(boundingPoints: [start, current])
      context.setStrokeColor(accent.cgColor)
      context.setLineWidth(1 / scale)
      context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
      context.stroke(rect)
    default: break
    }
  }
}
