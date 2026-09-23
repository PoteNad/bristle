import AppKit
import BristleCore

@MainActor
public protocol CanvasViewDelegate: AnyObject {
  func canvasViewToolDidChange(_ canvas: CanvasView)
  func canvasViewZoomDidChange(_ canvas: CanvasView)
  /// The eyedropper picked a colour.
  func canvasView(_ canvas: CanvasView, didPick color: Color)
  /// The style of the current tool changed on the canvas, such as by the Palette.
  func canvasViewStylesDidChange(_ canvas: CanvasView)
  /// The pointer was released after drawing, moving, or changing something.
  func canvasViewDidFinishInteraction(_ canvas: CanvasView)
}

extension CanvasViewDelegate {
  public func canvasViewToolDidChange(_ canvas: CanvasView) {}
  public func canvasViewZoomDidChange(_ canvas: CanvasView) {}
  public func canvasView(_ canvas: CanvasView, didPick color: Color) {}
  public func canvasViewStylesDidChange(_ canvas: CanvasView) {}
  public func canvasViewDidFinishInteraction(_ canvas: CanvasView) {}
}

/// Options that change how the canvas behaves, but never the drawing.
public struct CanvasConfiguration: Equatable, Sendable {
  /// Edges and centres snap to other elements and the paper while moving and resizing.
  public var snapsToGuides = true
  public var showsGrid = false
  public var snapsToGrid = false
  public var gridSpacing: CGFloat = 20
  /// Go back to the Select tool after adding a shape, line, or text.
  public var returnsToSelect = false

  public init() {}
}

/// The drawing canvas: a view of a `Drawing` inside a scroll view that zooms, where every tool
/// makes and edits elements. Put `scrollView` in a window.
///
/// The view's coordinates are the scene's: the paper starts at the origin, and the view reaches
/// past the paper on every side so elements can be placed beyond it.
public final class CanvasView: NSView {
  public let drawing: Drawing
  public let scrollView: NSScrollView
  public weak var delegate: CanvasViewDelegate?
  public var configuration = CanvasConfiguration() {
    didSet { if configuration != oldValue { needsDisplay = true } }
  }

  /// The tool in use. The eyedropper returns to the tool before it after picking a colour.
  public var tool: Tool = .pencil {
    didSet {
      guard tool != oldValue else { return }
      if tool != .eyedropper { toolBeforeEyedropper = nil } else if toolBeforeEyedropper == nil {
        toolBeforeEyedropper = oldValue
      }
      finishInteraction()
      if tool != .select {
        endTextEditing()
        croppingID = nil
        pointEditingID = nil
      }
      window?.invalidateCursorRects(for: self)
      delegate?.canvasViewToolDidChange(self)
    }
  }
  var toolBeforeEyedropper: Tool?

  /// The style each tool gives new elements.
  public var styles: [Tool: Style] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, $0.defaultStyle) })

  public var style: Style {
    get { styles[tool] ?? tool.defaultStyle }
    set { styles[tool] = newValue }
  }

  public let images = ImageStore()
  private var pathCache: [String: (Element, CGPath)] = [:]
  var interaction = Interaction.none
  /// The group whose members are picked one at a time, after double-clicking into it.
  var enteredGroup: String?
  var guides: [Snapping.Guide] = []
  /// The element a line end would attach to if released now.
  var bindingTarget: String?
  /// Elements the eraser has passed over, shown faded until it lifts.
  var erasing: Set<String> = []
  /// The image whose crop is being changed.
  var croppingID: String?
  /// The polygon whose corners are shown for dragging.
  var pointEditingID: String?
  var textEditor: TextEditor?
  var spaceHeld = false
  var tabletEraser = false
  var pasteCount = 0
  var lastPasteSource: Int?
  /// VoiceOver's view of each element, made when asked for and kept while the element exists.
  var accessibilityProxies: [String: ElementAccessibility] = [:]

  public init(drawing: Drawing) {
    self.drawing = drawing
    let scroll = NSScrollView()
    scrollView = scroll
    super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    let clip = CenteringClipView()
    clip.drawsBackground = false
    scroll.contentView = clip
    scroll.documentView = self
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.05
    scroll.maxMagnification = 32
    scroll.drawsBackground = true
    scroll.backgroundColor = .underPageBackgroundColor
    scroll.usesPredominantAxisScrolling = false
    registerForDraggedTypes(Self.acceptedDragTypes)
    setAccessibilityRole(.layoutArea)
    setAccessibilityLabel("Canvas")
    updateCanvasSize(keepingVisible: false)
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(drawingDidChange(_:)), name: .drawingDidChange, object: drawing)
    center.addObserver(
      self, selector: #selector(selectionDidChange), name: .drawingSelectionDidChange, object: drawing)
    center.addObserver(
      self, selector: #selector(zoomDidChange), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Whether a click on an inactive window draws too. Off, as in other Mac apps, so the first
  /// click only brings the window forward; the app's checks turn it on to drive the canvas.
  var acceptsFirstClick = false

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick }

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }
  public override var isOpaque: Bool { true }
  public override var wantsUpdateLayer: Bool { false }

  public var scene: Scene { drawing.scene }
  /// Whether the pointer is drawing, moving, or changing something right now.
  public var isInteracting: Bool {
    if case .none = interaction { return false }
    return true
  }
  public var magnification: CGFloat { scrollView.magnification }

  // MARK: Size

  /// Grows the view to reach well past the paper and every element.
  func updateCanvasSize(keepingVisible: Bool = true) {
    let paper = scene.paperRect
    let margin = max(800, max(paper.width, paper.height) * 0.75)
    var rect = paper.insetBy(dx: -margin, dy: -margin)
    let content = scene.contentBounds
    if !content.isNull { rect = rect.union(content.insetBy(dx: -margin / 2, dy: -margin / 2)) }
    rect = rect.integral
    guard rect != bounds else { return }
    // While a gesture is under way, only grow, so the view doesn't jump under the pointer.
    if drawing.isInGesture, bounds.contains(rect) { return }
    if drawing.isInGesture { rect = rect.union(bounds) }
    let visible = scrollView.documentVisibleRect
    setFrameSize(rect.size)
    setBoundsOrigin(rect.origin)
    if keepingVisible { scroll(visible.origin) }
  }

  // MARK: Changes

  @objc private func drawingDidChange(_ notification: Notification) {
    let change = (notification.userInfo?["change"] as? Drawing.ChangeBox)?.change
    guard let change, !change.changesPaper else {
      pathCache.removeAll()
      if change == nil { images.removeAll() }
      updateCanvasSize()
      needsDisplay = true
      NSAccessibility.post(element: self, notification: .layoutChanged)
      return
    }
    for element in change.touchedElements { invalidate(element) }
    if !drawing.isInGesture { updateCanvasSize() }
    if let editor = textEditor, let element = scene[editor.elementID] { editor.follow(element) }
    invalidateAccessibility()
  }

  @objc private func selectionDidChange() {
    needsDisplay = true
    if let croppingID, !drawing.selection.contains(croppingID) { self.croppingID = nil }
    if let pointEditingID, !drawing.selection.contains(pointEditingID) { self.pointEditingID = nil }
    invalidateAccessibility()
  }

  func invalidate(_ element: Element) {
    let margin = 16 / magnification + 2
    setNeedsDisplay(element.bounds.insetBy(dx: -margin, dy: -margin))
    if drawing.selection.contains(element.id) || !drawing.selection.isEmpty { invalidateSelectionBox() }
  }

  func invalidateSelectionBox() {
    guard let box = selectionBox() else { return }
    let margin = 40 / magnification
    setNeedsDisplay(CGRect(boundingPoints: box.corners).insetBy(dx: -margin, dy: -margin))
  }

  // MARK: Drawing

  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let scale = magnification
    NSColor.underPageBackgroundColor.setFill()
    dirtyRect.fill()
    let paper = scene.paperRect
    drawPaper(paper, in: context, dirty: dirtyRect, scale: scale)
    var rects: UnsafePointer<NSRect>?
    var count = 0
    getRectsBeingDrawn(&rects, count: &count)
    let dirty = (0..<count).map { rects![$0] }
    let tiny = 0.6 / scale
    let editing = textEditor?.elementID
    for element in scene.elements {
      let box = element.bounds
      guard box.intersects(dirtyRect), dirty.contains(where: { $0.intersects(box) }), element.id != editing else {
        continue
      }
      if box.width < tiny && box.height < tiny {
        // Too small to see: a speck of its colour costs far less than drawing it.
        (element.stroke ?? element.fill ?? .ink).cgColor.nsColor.setFill()
        box.fill()
        continue
      }
      if erasing.contains(element.id) {
        context.saveGState()
        context.setAlpha(0.25)
        draw(element, in: context)
        context.restoreGState()
      } else {
        draw(element, in: context)
      }
    }
    // Whatever lies beyond the paper is faded, since it won't be exported or printed.
    let beyond = CGMutablePath()
    beyond.addRect(dirtyRect)
    beyond.addRect(paper)
    context.saveGState()
    context.addPath(beyond)
    context.clip(using: .evenOdd)
    NSColor.underPageBackgroundColor.withAlphaComponent(0.6).setFill()
    dirtyRect.fill()
    context.restoreGState()
    drawInteraction(in: context, scale: scale)
    drawSelection(in: context, scale: scale)
    drawGuides(in: context, scale: scale)
  }

  func draw(_ element: Element, in context: CGContext) {
    // Freehand outlines take the most work to build, so each is kept until the element changes.
    if element.kind == .freehand {
      let path: CGPath
      if let cached = pathCache[element.id], cached.0 == element {
        path = cached.1
      } else {
        path = element.path
        pathCache[element.id] = (element, path)
      }
      context.saveGState()
      if element.opacity < 1 { context.setAlpha(element.opacity) }
      if element.rotation != 0 { context.concatenate(element.transform) }
      context.setFillColor((element.stroke ?? .ink).cgColor)
      context.addPath(path)
      context.fillPath(using: .winding)
      context.restoreGState()
      return
    }
    Renderer.draw(element, in: context, scene: scene, images: images)
  }

  private func drawPaper(_ paper: CGRect, in context: CGContext, dirty: CGRect, scale: CGFloat) {
    guard paper.insetBy(dx: -20 / scale, dy: -20 / scale).intersects(dirty) else { return }
    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: 1 / scale), blur: 5 / scale,
      color: NSColor.shadowColor.withAlphaComponent(0.25).cgColor)
    context.setFillColor(scene.paper.background?.cgColor ?? .white)
    context.fill(paper)
    context.restoreGState()
    let visible = paper.intersection(dirty)
    if scene.paper.background == nil {
      // A checkerboard shows the paper is transparent.
      let square = max(8 / scale, 0.5)
      context.setFillColor(CGColor(gray: 0.86, alpha: 1))
      let startX = floor((visible.minX - paper.minX) / square), startY = floor((visible.minY - paper.minY) / square)
      var y = startY
      while paper.minY + y * square < visible.maxY {
        var x = startX
        while paper.minX + x * square < visible.maxX {
          if (Int(x) + Int(y)) % 2 == 0 {
            context.fill(
              CGRect(x: paper.minX + x * square, y: paper.minY + y * square, width: square, height: square)
                .intersection(paper))
          }
          x += 1
        }
        y += 1
      }
    }
    if configuration.showsGrid {
      var spacing = configuration.gridSpacing
      while spacing * scale < 8 { spacing *= 2 }
      context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.14).cgColor)
      context.setLineWidth(1 / scale)
      var x = (visible.minX / spacing).rounded(.up) * spacing
      while x < visible.maxX {
        context.move(to: CGPoint(x: x, y: visible.minY))
        context.addLine(to: CGPoint(x: x, y: visible.maxY))
        x += spacing
      }
      var y = (visible.minY / spacing).rounded(.up) * spacing
      while y < visible.maxY {
        context.move(to: CGPoint(x: visible.minX, y: y))
        context.addLine(to: CGPoint(x: visible.maxX, y: y))
        y += spacing
      }
      context.strokePath()
    }
  }

  private func drawGuides(in context: CGContext, scale: CGFloat) {
    guard !guides.isEmpty else { return }
    context.setStrokeColor(NSColor.systemPink.cgColor)
    context.setLineWidth(1 / scale)
    for guide in guides {
      context.move(to: guide.from)
      context.addLine(to: guide.to)
    }
    context.strokePath()
  }

  // MARK: Zoom

  public var zoomPercent: Int { Int((magnification * 100).rounded()) }

  @objc func zoomDidChange() {
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
    delegate?.canvasViewZoomDidChange(self)
  }

  /// Zooms to `value`, keeping the middle of the view, or `point`, still.
  public func zoom(to value: CGFloat, around point: CGPoint? = nil) {
    let value = min(scrollView.maxMagnification, max(scrollView.minMagnification, value))
    let visible = scrollView.documentVisibleRect
    scrollView.setMagnification(value, centeredAt: point ?? CGPoint(x: visible.midX, y: visible.midY))
    zoomDidChange()
  }

  /// The zoom steps used by Zoom In and Zoom Out.
  public static let zoomSteps: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]

  @objc public func zoomIn(_ sender: Any?) {
    zoom(to: Self.zoomSteps.first { $0 > magnification + 0.001 } ?? scrollView.maxMagnification)
  }

  @objc public func zoomOut(_ sender: Any?) {
    zoom(to: Self.zoomSteps.last { $0 < magnification - 0.001 } ?? scrollView.minMagnification)
  }

  @objc public func actualSize(_ sender: Any?) { zoom(to: 1) }

  /// Room to keep clear around the paper when fitting it, such as for a palette over the view.
  public var fitInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

  /// Shows the whole paper, as large as fits.
  @objc public func zoomToFit(_ sender: Any?) {
    let paper = scene.paperRect
    let available = scrollView.contentSize
    let width = available.width - fitInsets.left - fitInsets.right
    let height = available.height - fitInsets.top - fitInsets.bottom
    guard width > 40, height > 40 else { return }
    let fit = min(width / paper.width, height / paper.height)
    scrollView.magnification = min(scrollView.maxMagnification, max(scrollView.minMagnification, fit))
    centerPaper()
    zoomDidChange()
  }

  /// Shows the paper at actual size if it fits, and fits it to the view otherwise.
  public func showPaper() {
    let paper = scene.paperRect
    let available = scrollView.contentSize
    if paper.width + fitInsets.left + fitInsets.right <= available.width
      && paper.height + fitInsets.top + fitInsets.bottom <= available.height
    {
      scrollView.magnification = 1
      centerPaper()
      zoomDidChange()
    } else {
      zoomToFit(nil)
    }
  }

  /// Centres the paper in the space the insets leave.
  private func centerPaper() {
    let shift = CGPoint(
      x: (fitInsets.left - fitInsets.right) / 2 / magnification, y: (fitInsets.top - fitInsets.bottom) / 2 / magnification)
    let paper = scene.paperRect
    center(on: CGPoint(x: paper.midX - shift.x, y: paper.midY - shift.y))
  }

  public func center(on point: CGPoint) {
    let visible = scrollView.documentVisibleRect
    scroll(CGPoint(x: point.x - visible.width / 2, y: point.y - visible.height / 2))
  }

  public override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    delegate?.canvasViewZoomDidChange(self)
  }

  public override func scrollWheel(with event: NSEvent) {
    // Command-scroll zooms around the pointer, as in Preview.
    if event.modifierFlags.contains(.command), event.phase != .ended || event.scrollingDeltaY != 0 {
      let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
      zoom(to: magnification * factor, around: convert(event.locationInWindow, from: nil))
      return
    }
    super.scrollWheel(with: event)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate, .inVisibleRect], owner: self))
  }
}

/// Keeps a document smaller than the view in the middle, as Preview does.
final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView else { return rect }
    let frame = document.frame
    if rect.width > frame.width { rect.origin.x = frame.minX - (rect.width - frame.width) / 2 }
    if rect.height > frame.height { rect.origin.y = frame.minY - (rect.height - frame.height) / 2 }
    return rect
  }
}

extension CGColor {
  var nsColor: NSColor { NSColor(cgColor: self) ?? .black }
}
