import AppKit
import BristleCore

/// The box around the selection, with handles for resizing and turning it.
struct SelectionBox {
  /// The box before rotation, on the canvas.
  var frame: CGRect
  var rotation: CGFloat

  var center: CGPoint { frame.center }
  var transform: CGAffineTransform {
    guard rotation != 0 else { return .identity }
    let c = center
    return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rotation).translatedBy(x: -c.x, y: -c.y)
  }
  var corners: [CGPoint] { frame.corners.map { $0.applying(transform) } }

  /// Handle positions in unit coordinates, clockwise from the top left.
  static let units: [CGPoint] = [
    CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5),
    CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5),
  ]

  func point(_ unit: CGPoint) -> CGPoint {
    CGPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height).applying(transform)
  }

  func local(_ point: CGPoint) -> CGPoint { rotation == 0 ? point : point.applying(transform.inverted()) }
}

enum Handle: Equatable {
  case resize(Int)
  case rotate
  case point(Int)
}

extension CanvasView {
  /// Elements that can be picked, in the order they're drawn.
  var pickableElements: [Element] { scene.elements.filter { !$0.locked } }

  /// The box around the selection: the element's own rotated frame when one is selected.
  func selectionBox() -> SelectionBox? {
    let selected = drawing.selectedElements
    guard !selected.isEmpty else { return nil }
    if selected.count == 1, let element = selected.first {
      if element.isLinear { return SelectionBox(frame: element.bounds, rotation: 0) }
      let pad = element.kind == .freehand ? element.strokeWidth / 2 : 0
      return SelectionBox(frame: element.frame.insetBy(dx: -pad, dy: -pad), rotation: element.rotation)
    }
    return SelectionBox(frame: scene.frameBounds(of: drawing.selection), rotation: 0)
  }

  /// Where the selection is on the canvas, for placing controls beside it.
  public var selectionBounds: CGRect? { selectionBox().map { CGRect(boundingPoints: $0.corners) } }

  /// Whether the selection is one line or arrow, which is edited by its points instead of a box.
  var selectedLine: Element? {
    let selected = drawing.selectedElements
    guard selected.count == 1, let element = selected.first,
      element.isLinear || element.id == pointEditingID
    else { return nil }
    return element
  }

  var handleSize: CGFloat { 9 / magnification }

  /// The rotation handle sits above the top edge, pointing up from the box.
  func rotationHandle(_ box: SelectionBox) -> CGPoint {
    let top = box.point(CGPoint(x: 0.5, y: 0))
    let distance = 22 / magnification
    return CGPoint(x: top.x + sin(box.rotation) * distance, y: top.y - cos(box.rotation) * distance)
  }

  /// Which resize handles to offer: small boxes show only their corners.
  func visibleHandles(_ box: SelectionBox) -> [Int] {
    let tiny = 24 / magnification
    let w = box.frame.width < tiny, h = box.frame.height < tiny
    if box.frame.width < 1 { return [3, 7] }
    if box.frame.height < 1 { return [1, 5] }
    return (0..<8).filter { i in
      if i == 1 || i == 5 { return !w }
      if i == 3 || i == 7 { return !h }
      return true
    }
  }

  var selectionIsLocked: Bool { drawing.selectedElements.contains { $0.locked } }

  func handle(at point: CGPoint) -> Handle? {
    guard !selectionIsLocked, textEditor == nil else { return nil }
    let reach = handleSize / 2 + 3 / magnification
    if let line = selectedLine {
      for (i, p) in line.worldPoints.enumerated().reversed() where p.distance(to: point) <= reach + 2 / magnification {
        return .point(i)
      }
      if line.isLinear { return nil }
    }
    guard let box = selectionBox() else { return nil }
    if croppingID == nil, rotationHandle(box).distance(to: point) <= reach + 1 / magnification { return .rotate }
    for i in visibleHandles(box) {
      let p = box.point(SelectionBox.units[i])
      if abs(p.x - point.x) <= reach && abs(p.y - point.y) <= reach { return .resize(i) }
    }
    return nil
  }

  /// Which of the picked frame's handles is under a point.
  func frameHandle(at point: CGPoint, _ frame: CGRect) -> Int? {
    let reach = handleSize / 2 + 3 / magnification
    let box = SelectionBox(frame: frame, rotation: 0)
    return (0..<8).first { i in
      let p = box.point(SelectionBox.units[i])
      return abs(p.x - point.x) <= reach && abs(p.y - point.y) <= reach
    }
  }

  func drawFrameHandles(_ frame: CGRect, in context: CGContext, scale: CGFloat) {
    let box = SelectionBox(frame: frame, rotation: 0)
    for i in 0..<8 {
      drawHandle(at: box.point(SelectionBox.units[i]), round: false, in: context, scale: scale, color: NSColor.controlAccentColor.cgColor)
    }
  }

  // MARK: Drawing the selection

  func drawSelection(in context: CGContext, scale: CGFloat) {
    let accent = NSColor.controlAccentColor.cgColor
    let line = 1 / scale
    if let target = bindingTarget.flatMap({ scene[$0] }) {
      context.saveGState()
      context.setStrokeColor(accent)
      context.setLineWidth(3 / scale)
      context.addPath(target.path.copy(using: [target.transform]) ?? target.path)
      context.strokePath()
      context.restoreGState()
    }
    let selected = drawing.selectedElements
    guard !selected.isEmpty, textEditor == nil || selected.count > 1 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    let locked = selectionIsLocked
    let color = locked ? NSColor.secondaryLabelColor.cgColor : accent
    context.setStrokeColor(color)
    context.setLineWidth(line)
    // Each element of a larger selection gets a faint outline of its own.
    if selected.count > 1 {
      context.saveGState()
      context.setAlpha(0.5)
      for element in selected {
        let corners = element.rotation == 0 ? element.frame.corners : element.worldCorners
        context.addLines(between: corners + [corners[0]])
      }
      context.strokePath()
      context.restoreGState()
    }
    if let croppingID, let image = scene[croppingID] {
      drawCrop(image, in: context, scale: scale)
    }
    if let line = selectedLine {
      let points = line.worldPoints
      if line.isLinear {
        context.saveGState()
        context.setAlpha(0.35)
        context.setLineWidth(max(line.strokeWidth + 4 / scale, 4 / scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(line.path.copy(using: [line.transform]) ?? line.path)
        context.strokePath()
        context.restoreGState()
      }
      for p in points { drawHandle(at: p, round: true, in: context, scale: scale, color: color) }
      if line.isLinear { return }
    }
    guard let box = selectionBox() else { return }
    let corners = box.corners
    context.addLines(between: corners + [corners[0]])
    context.strokePath()
    guard !locked else { return }
    if croppingID == nil {
      let top = box.point(CGPoint(x: 0.5, y: 0)), knob = rotationHandle(box)
      context.move(to: top)
      context.addLine(to: knob)
      context.strokePath()
      drawHandle(at: knob, round: true, in: context, scale: scale, color: color)
    }
    for i in visibleHandles(box) {
      drawHandle(at: box.point(SelectionBox.units[i]), round: false, in: context, scale: scale, color: color, rotation: box.rotation)
    }
  }

  func drawHandle(
    at point: CGPoint, round: Bool, in context: CGContext, scale: CGFloat, color: CGColor, rotation: CGFloat = 0
  ) {
    let size = handleSize
    let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    context.saveGState()
    if rotation != 0 {
      context.translateBy(x: point.x, y: point.y)
      context.rotate(by: rotation)
      context.translateBy(x: -point.x, y: -point.y)
    }
    context.setShadow(offset: CGSize(width: 0, height: 0.5 / scale), blur: 1.5 / scale, color: CGColor(gray: 0, alpha: 0.3))
    context.setFillColor(.white)
    if round { context.fillEllipse(in: rect) } else { context.fill(rect) }
    context.restoreGState()
    context.saveGState()
    if rotation != 0 {
      context.translateBy(x: point.x, y: point.y)
      context.rotate(by: rotation)
      context.translateBy(x: -point.x, y: -point.y)
    }
    context.setStrokeColor(color)
    context.setLineWidth(1.25 / scale)
    if round { context.strokeEllipse(in: rect) } else { context.stroke(rect) }
    context.restoreGState()
  }

  /// While cropping, the rest of the image shows faintly around the part that's kept.
  func drawCrop(_ image: Element, in context: CGContext, scale: CGFloat) {
    guard let full = fullImageFrame(image) else { return }
    context.saveGState()
    context.concatenate(image.transform)
    context.setAlpha(0.3)
    var whole = image
    whole.crop = nil
    whole.frame = full
    whole.rotation = 0
    Renderer.draw(whole, in: context, scene: scene, images: images)
    context.setAlpha(1)
    context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
    context.setLineWidth(1 / scale)
    context.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
    context.stroke(full)
    context.restoreGState()
  }

  /// Where the whole of a cropped image lies, before rotation.
  func fullImageFrame(_ image: Element) -> CGRect? {
    guard image.kind == .image else { return nil }
    let crop = image.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    let width = image.width / max(crop.width, 0.0001), height = image.height / max(crop.height, 0.0001)
    return CGRect(x: image.x - crop.minX * width, y: image.y - crop.minY * height, width: width, height: height)
  }

  // MARK: Picking

  /// The topmost element under a point, with the group it acts with.
  func element(at point: CGPoint) -> Element? {
    let tolerance = 5 / magnification
    return pickableElements.last { $0.hit(point, tolerance: tolerance) }
  }

  /// What picking an element selects: its whole group, unless the group has been entered.
  func pickSet(for element: Element) -> Set<String> {
    let group = scene.outermostGroup(of: element, within: enteredGroup)
    guard let group else { return [element.id] }
    return Set(scene.elements.filter { $0.groups.contains(group) && !$0.locked }.map(\.id))
  }

  public func select(_ ids: Set<String>) {
    drawing.selection = ids
  }
}
