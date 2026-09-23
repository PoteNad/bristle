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
        selectionBeforeEyedropper = drawing.selection
      }
      finishInteraction()
      // Choosing a tool lets go of the frame, so the bar shows the tool's settings.
      if tool != .select { frameSelected = false }
      if tool != .select {
        endTextEditing()
        croppingID = nil
        pointEditingID = nil
      }
      // Drawing tools start fresh, as in Freeform and Excalidraw: the selection is let go.
      if tool != .select && tool != .eyedropper && oldValue != .eyedropper {
        drawing.selection = []
      }
      window?.invalidateCursorRects(for: self)
      if hoverPoint != nil { needsDisplay = true }
      delegate?.canvasViewToolDidChange(self)
    }
  }
  var toolBeforeEyedropper: Tool?
  var selectionBeforeEyedropper: Set<String>?

  /// The style each tool gives new elements.
  public var styles: [Tool: Style] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, $0.defaultStyle) }) {
    // The size ring follows a new width.
    didSet { if showsSizeRing, hoverPoint != nil { needsDisplay = true } }
  }

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
  /// Where the pointer is over the canvas, for the ring showing the brush's size.
  var hoverPoint: CGPoint? {
    didSet {
      guard hoverPoint != oldValue else { return }
      invalidateSizeRing(oldValue)
      invalidateSizeRing(hoverPoint)
    }
  }
  /// What the window lays over the canvas, in window coordinates: bars, and the toolbar. The
  /// pointer is an arrow there.
  public var coveredRects: (() -> [NSRect])?
  /// The ready-made shape the polygon tool draws with one drag, or `nil` to place corners one
  /// click at a time.
  public var shapePreset: ShapePreset? { didSet { delegate?.canvasViewToolDidChange(self) } }
  /// Whether dragging across empty canvas with Select draws a free-form loop, as MS Paint's
  /// Free-form selection does, instead of a box.
  public var lassoSelects = false { didSet { delegate?.canvasViewToolDidChange(self) } }
  var spaceHeld = false
  var tabletEraser = false
  var pasteCount = 0
  var lastPasteSource: Int?
  /// VoiceOver's view of each element, made when asked for and kept while the element exists.
  var accessibilityProxies: [String: ElementAccessibility] = [:]
  /// Where the selection box was last drawn, so moving it clears the old place.
  var lastSelectionRect: CGRect?
  /// Whether the frame is picked, to move or resize it.
  public internal(set) var frameSelected = false { didSet { if frameSelected != oldValue { needsDisplay = true } } }

  public init(drawing: Drawing) {
    self.drawing = drawing
    let scroll = NSScrollView()
    scrollView = scroll
    super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    scroll.documentView = self
    // An endless canvas, as in Freeform: no scroll bars, just the drawing.
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.1
    scroll.maxMagnification = 16
    scroll.drawsBackground = false
    scroll.usesPredominantAxisScrolling = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.postsFrameChangedNotifications = true
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
    center.addObserver(
      self, selector: #selector(visibleDidChange), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    center.addObserver(self, selector: #selector(viewSizeDidChange), name: NSView.frameDidChangeNotification, object: scroll)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Whether a click on an inactive window draws too. Off, as in other Mac apps, so the first
  /// click only brings the window forward; the app's checks turn it on to drive the canvas.
  var acceptsFirstClick = false

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstClick }

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }
  public override var isOpaque: Bool { true }
  var frameIsLocked: Bool { false }
  public override var wantsUpdateLayer: Bool { false }

  public var scene: Scene { drawing.scene }
  /// Whether the pointer is drawing, moving, or changing something right now.
  public var isInteracting: Bool {
    if case .none = interaction { return false }
    return true
  }
  public var magnification: CGFloat { scrollView.magnification }

  // MARK: Size

  /// How far the canvas reaches around the drawing; panning near an edge reaches further.
  static let reach: CGFloat = 20_000

  /// Grows the view to reach well past the drawing and what's in view, so the canvas never ends.
  func updateCanvasSize(keepingVisible: Bool = true) {
    var rect = CGRect(x: -Self.reach, y: -Self.reach, width: Self.reach * 2, height: Self.reach * 2)
    let content = scene.contentBounds
    if !content.isNull { rect = rect.union(content.insetBy(dx: -Self.reach, dy: -Self.reach)) }
    if let frame = scene.frame { rect = rect.union(frame.insetBy(dx: -Self.reach, dy: -Self.reach)) }
    if keepingVisible {
      let visible = scrollView.documentVisibleRect
      if !visible.isEmpty { rect = rect.union(visible.insetBy(dx: -Self.reach / 2, dy: -Self.reach / 2)) }
    }
    rect = rect.integral
    // The canvas only grows, so nothing jumps under the pointer.
    if !bounds.isEmpty && bounds.width > 2000 { rect = rect.union(bounds) }
    guard rect != bounds else { return }
    let visible = scrollView.documentVisibleRect
    setFrameSize(rect.size)
    setBoundsOrigin(rect.origin)
    if keepingVisible { scroll(visible.origin) }
    // AppKit leaves a subview's layer where it was when the bounds origin moves, so the text
    // being typed is put back over its element.
    if let editor = textEditor {
      let frame = editor.frame
      editor.frame = .zero
      editor.frame = frame
    }
  }

  /// The middle of what's in view, kept while the window or the sidebar beside it changes size.
  private var viewCenter: CGPoint?
  private var resizing = false
  private var lastVisibleSize = CGSize.zero
  private var lastMagnification: CGFloat = 0

  @objc private func visibleDidChange() {
    let visible = scrollView.documentVisibleRect
    // AppKit resizes the clip view before saying the scroll view changed size, so a change of
    // size at the same zoom is the view resizing: it stays centred where it was, rather than
    // keeping its left edge.
    let resized = lastMagnification == magnification && lastVisibleSize != .zero
      && abs(visible.width - lastVisibleSize.width) + abs(visible.height - lastVisibleSize.height) > 0.5
    lastVisibleSize = visible.size
    lastMagnification = magnification
    guard !resizing else { return }
    if resized, let viewCenter {
      resizing = true
      center(on: viewCenter)
      resizing = false
      return
    }
    viewCenter = visible.center
    // Panning near the canvas's edge makes more room beyond it.
    if visible.minX - bounds.minX < Self.reach / 4 || bounds.maxX - visible.maxX < Self.reach / 4
      || visible.minY - bounds.minY < Self.reach / 4 || bounds.maxY - visible.maxY < Self.reach / 4
    {
      updateCanvasSize()
    }
  }

  @objc private func viewSizeDidChange() {
    guard let viewCenter else { return }
    resizing = true
    center(on: viewCenter)
    resizing = false
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

  /// Redraws where the selection box and its handles are, and where they were last drawn.
  func invalidateSelectionBox() {
    let margin = 40 / magnification
    if let last = lastSelectionRect { setNeedsDisplay(last) }
    guard let box = selectionBox() else {
      lastSelectionRect = nil
      return
    }
    let rect = CGRect(boundingPoints: box.corners).insetBy(dx: -margin, dy: -margin)
    setNeedsDisplay(rect)
    lastSelectionRect = rect
  }

  // MARK: Drawing

  /// The canvas behind the drawing: its own color, or else one that follows the appearance, near
  /// white in light and near black in dark, as Freeform's board does.
  var canvasColor: CGColor {
    if let background = scene.paper.background, scene.frame == nil { return background.cgColor }
    return appearanceIsDark ? CGColor(srgbRed: 0.118, green: 0.118, blue: 0.122, alpha: 1) : .white
  }

  private var appearanceIsDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

  /// Whether the drawing is shown for a dark canvas, with its lightness turned around.
  var isDarkCanvas: Bool {
    scene.paper.background == nil && appearanceIsDark
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let scale = magnification
    context.setFillColor(canvasColor)
    context.fill(dirtyRect)
    // A background colors only the frame, the part that's exported, when there is one.
    if let background = scene.paper.background, let frame = scene.frame {
      context.setFillColor(background.cgColor)
      context.fill(frame.intersection(dirtyRect))
    }
    drawGrid(in: context, dirty: dirtyRect, scale: scale)
    // Zoomed in far, images show their own square pixels, as paint programs show them.
    context.interpolationQuality = scale >= 3 ? .none : .high
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
        // Too small to see: a speck of its color costs far less than drawing it.
        shown(element.stroke ?? element.fill ?? .ink).cgColor.nsColor.setFill()
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
    drawPixelGrid(in: context, dirty: dirtyRect, scale: scale)
    drawFrame(in: context, dirty: dirtyRect, scale: scale)
    drawInteraction(in: context, scale: scale)
    drawSelection(in: context, scale: scale)
    drawGuides(in: context, scale: scale)
    drawSizeRing(in: context, scale: scale)
  }

  /// A color as it's shown on this canvas.
  /// How a color looks on the canvas now: turned around on a dark canvas.
  public func shown(_ color: Color) -> Color { isDarkCanvas ? color.onDarkCanvas : color }

  func shown(_ element: Element) -> Element {
    guard isDarkCanvas else { return element }
    var e = element
    e.stroke = e.stroke?.onDarkCanvas
    e.fill = e.fill?.onDarkCanvas
    return e
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
      context.setFillColor(shown(element.stroke ?? .ink).cgColor)
      context.addPath(path)
      context.fillPath(using: .winding)
      context.restoreGState()
      return
    }
    Renderer.draw(shown(element), in: context, scene: scene, images: images)
  }

  /// A grid of dots, as Freeform draws.
  private func drawGrid(in context: CGContext, dirty: CGRect, scale: CGFloat) {
    // The pixel grid takes over when zoomed in far.
    guard configuration.showsGrid, scale < Self.pixelGridZoom else { return }
    var spacing = configuration.gridSpacing
    while spacing * scale < 14 { spacing *= 2 }
    let dot = max(1 / scale, 0.25)
    context.setFillColor(isDarkCanvas ? CGColor(gray: 1, alpha: 0.2) : CGColor(gray: 0, alpha: 0.2))
    var y = (dirty.minY / spacing).rounded(.up) * spacing
    while y <= dirty.maxY {
      var x = (dirty.minX / spacing).rounded(.up) * spacing
      while x <= dirty.maxX {
        context.fillEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
        x += spacing
      }
      y += spacing
    }
  }

  /// Zoomed in far enough to see single pixels, a line between each, as in a paint program.
  /// Exports are one pixel per point, so these are the pixels a PNG will have.
  public static let pixelGridZoom: CGFloat = 8

  private func drawPixelGrid(in context: CGContext, dirty: CGRect, scale: CGFloat) {
    guard configuration.showsGrid, scale >= Self.pixelGridZoom else { return }
    context.saveGState()
    defer { context.restoreGState() }
    let fade = min(1, (scale - Self.pixelGridZoom) / Self.pixelGridZoom + 0.5)
    context.setStrokeColor(appearanceIsDark ? CGColor(gray: 1, alpha: 0.12 * fade) : CGColor(gray: 0, alpha: 0.1 * fade))
    context.setLineWidth(1 / scale)
    var x = dirty.minX.rounded(.down)
    while x <= dirty.maxX {
      context.move(to: CGPoint(x: x, y: dirty.minY))
      context.addLine(to: CGPoint(x: x, y: dirty.maxY))
      x += 1
    }
    var y = dirty.minY.rounded(.down)
    while y <= dirty.maxY {
      context.move(to: CGPoint(x: dirty.minX, y: y))
      context.addLine(to: CGPoint(x: dirty.maxX, y: y))
      y += 1
    }
    context.strokePath()
  }

  /// The frame's outline, with its size above its top-left corner, as Excalidraw labels frames.
  private func drawFrame(in context: CGContext, dirty: CGRect, scale: CGFloat) {
    guard let frame = scene.frame, frame.insetBy(dx: -40 / scale, dy: -40 / scale).intersects(dirty) else { return }
    let selected = frameSelected
    context.saveGState()
    context.setStrokeColor(selected ? NSColor.controlAccentColor.cgColor : (isDarkCanvas ? CGColor(gray: 1, alpha: 0.35) : CGColor(gray: 0, alpha: 0.3)))
    context.setLineWidth((selected ? 2 : 1) / scale)
    context.stroke(frame)
    context.restoreGState()
    let label = frameLabel(frame)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11 / scale, weight: .medium),
      .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
    ]
    // Clear of the corner handle, so the label reads whole when the frame is picked.
    NSAttributedString(string: label, attributes: attributes).draw(at: CGPoint(x: frame.minX, y: frame.minY - 21 / scale))
    if selected, !frameIsLocked { drawFrameHandles(frame, in: context, scale: scale) }
  }

  func frameLabel(_ frame: CGRect) -> String { "Frame  \(Int(frame.width)) × \(Int(frame.height))" }

  /// The frame's label, which is clicked to pick the frame.
  func frameLabelRect(_ frame: CGRect) -> CGRect {
    let width = (CGFloat(frameLabel(frame).count) * 6.5 + 8) / magnification
    return CGRect(x: frame.minX, y: frame.minY - 23 / magnification, width: width, height: 17 / magnification)
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

  /// Room to keep clear around the drawing when fitting it, such as for bars over the view.
  public var fitInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

  /// What Zoom to Fit shows: the frame, or all of the drawing.
  var fitArea: CGRect? {
    if let frame = scene.frame { return frame }
    let content = scene.contentBounds
    return content.isNull ? nil : content
  }

  /// Shows the whole drawing, or its frame, as large as fits.
  @objc public func zoomToFit(_ sender: Any?) { zoom(toFit: fitArea, largest: scrollView.maxMagnification) }

  /// Shows the selection as large as fits.
  @objc public func zoomToSelection(_ sender: Any?) {
    let box = scene.bounds(of: drawing.selection)
    zoom(toFit: box.isNull ? fitArea : box, largest: 4)
  }

  func zoom(toFit area: CGRect?, largest: CGFloat) {
    guard let area else {
      scrollView.magnification = 1
      center(on: .zero)
      zoomDidChange()
      return
    }
    let available = scrollView.contentSize
    let width = available.width - fitInsets.left - fitInsets.right
    let height = available.height - fitInsets.top - fitInsets.bottom
    guard width > 40, height > 40 else { return }
    let fit = min(width / max(area.width, 1), height / max(area.height, 1), largest)
    scrollView.magnification = min(scrollView.maxMagnification, max(scrollView.minMagnification, fit))
    centerInView(area)
    zoomDidChange()
  }

  /// Opens a drawing the way it's best seen: at actual size when it fits, and fitted otherwise,
  /// centred in the space the bars leave.
  public func showDrawing() {
    guard let area = fitArea else {
      scrollView.magnification = 1
      center(on: .zero)
      zoomDidChange()
      return
    }
    let available = scrollView.contentSize
    if area.width + fitInsets.left + fitInsets.right <= available.width
      && area.height + fitInsets.top + fitInsets.bottom <= available.height
    {
      scrollView.magnification = 1
      centerInView(area)
      zoomDidChange()
    } else {
      zoom(toFit: area, largest: 1)
    }
  }

  private func centerInView(_ area: CGRect) {
    let shift = CGPoint(
      x: (fitInsets.left - fitInsets.right) / 2 / magnification, y: (fitInsets.top - fitInsets.bottom) / 2 / magnification)
    center(on: CGPoint(x: area.midX - shift.x, y: area.midY - shift.y))
  }

  public func center(on point: CGPoint) {
    viewCenter = point
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
        rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
        owner: self))
  }
}

extension CGColor {
  var nsColor: NSColor { NSColor(cgColor: self) ?? .black }
}
