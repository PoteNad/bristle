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
  /// Rulers along the top and left, in points from the canvas's corner, as MS Paint shows them.
  public var showsRulers = false

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
    didSet {
      guard configuration != oldValue else { return }
      needsDisplay = true
      if configuration.showsRulers != oldValue.showsRulers {
        updateRulers()
        // The rulers take room from the canvas.
        updateCanvasSize()
      }
    }
  }

  /// AppKit's own rulers, measuring from the canvas's corner.
  func updateRulers() {
    scrollView.hasHorizontalRuler = configuration.showsRulers
    scrollView.hasVerticalRuler = configuration.showsRulers
    scrollView.rulersVisible = configuration.showsRulers
    guard configuration.showsRulers else { return }
    for ruler in [scrollView.horizontalRulerView, scrollView.verticalRulerView] {
      if ruler?.measurementUnits != .points { ruler?.measurementUnits = .points }
    }
    scrollView.horizontalRulerView?.originOffset = -bounds.minX
    scrollView.verticalRulerView?.originOffset = -bounds.minY
    scrollView.horizontalRulerView?.needsDisplay = true
    scrollView.verticalRulerView?.needsDisplay = true
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
  /// The pieces each selected object's dotted outline goes around, kept until it changes or
  /// the zoom does.
  var haloCache: [String: (element: Element, scale: CGFloat, pieces: [CGPath])] = [:]
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
  /// While the app's checks run, every part of the view asked to be redrawn, so they can tell
  /// whether redrawing just those parts gives the same picture as redrawing everything.
  var invalidated: [CGRect]?
  /// How many taps the trackpad has been asked for, for the app's checks.
  var hapticTaps = 0
  /// Where the pointer is followed, for the size ring and the cursor.
  var pointerArea: NSTrackingArea?

  public init(drawing: Drawing) {
    self.drawing = drawing
    let scroll = CanvasScrollView()
    scrollView = scroll
    super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    // The canvas sits in the middle of the view when it's smaller than the view, as a page does
    // in Preview.
    scroll.contentView = CanvasClipView()
    scroll.documentView = self
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.1
    scroll.maxMagnification = 16
    // Beyond the view, under the toolbar and the bars, the desk continues.
    scroll.drawsBackground = true
    scroll.backgroundColor = Self.deskNSColor
    scroll.usesPredominantAxisScrolling = false
    scroll.contentView.postsBoundsChangedNotifications = true
    scroll.postsFrameChangedNotifications = true
    registerForDraggedTypes(Self.acceptedDragTypes)
    setAccessibilityRole(.layoutArea)
    setAccessibilityLabel("Canvas")
    updateCanvasSize()
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
  public override var wantsUpdateLayer: Bool { false }

  public override func setNeedsDisplay(_ invalidRect: NSRect) {
    invalidated?.append(invalidRect)
    super.setNeedsDisplay(invalidRect)
  }

  public override var needsDisplay: Bool {
    didSet { if needsDisplay { invalidated?.append(bounds) } }
  }

  public var scene: Scene { drawing.scene }
  /// Whether the pointer is drawing, moving, or changing something right now.
  public var isInteracting: Bool {
    if case .none = interaction { return false }
    return true
  }
  public var magnification: CGFloat { scrollView.magnification }

  // MARK: Size

  /// Room around the canvas, in canvas points, once it's zoomed in well past the view, so its
  /// edges and handles can be scrolled clear of the window's edges.
  static let deskMargin: CGFloat = 64
  /// Room kept around the canvas on screen for its handles and shadow, in points.
  static let handleRoom: CGFloat = 16

  /// Whether the view is being resized to suit the canvas, so the changes that makes are let be.
  private var adjusting = false

  /// Sizes the view to the canvas and the room the window leaves for it. Along a side where
  /// the whole canvas fits, the view is exactly that room, with the canvas in its middle, so
  /// there's nothing to scroll, as in Preview. Where it doesn't fit, the view reaches past the
  /// canvas by a margin that grows from nothing as it's zoomed further in, so scrolling starts
  /// gently and the edges can be brought clear of the toolbar and bars. While the canvas's edge
  /// is dragged, the view only grows, so nothing shifts under the pointer.
  public func updateCanvasSize() {
    guard !adjusting else { return }
    let page = scene.canvas
    let clip = scrollView.contentView
    let scale = magnification
    let insets = clip.contentInsets
    let room = CGSize(
      width: clip.frame.width / scale - insets.left - insets.right, height: clip.frame.height / scale - insets.top - insets.bottom)
    let pad = Self.handleRoom / scale
    // On whole pixels, so the canvas's edges stay sharp.
    func pixels(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    func span(_ low: CGFloat, _ length: CGFloat, _ room: CGFloat) -> (origin: CGFloat, length: CGFloat) {
      guard room > 1 else { return (low - Self.deskMargin, length + Self.deskMargin * 2) }
      if length + pad * 2 <= room {
        // Exactly the room, so there's nothing to scroll and the canvas is in its middle.
        return (low - pixels((room - length) / 2), room)
      }
      let margin = pixels(pad + min(Self.deskMargin, length + pad * 2 - room))
      return (low - margin, length + margin * 2)
    }
    let across = span(page.minX, page.width, room.width), down = span(page.minY, page.height, room.height)
    // Where it fits, it doesn't bounce either: there's nothing there to scroll to.
    let fitsAcross = page.width + pad * 2 <= room.width, fitsDown = page.height + pad * 2 <= room.height
    scrollView.horizontalScrollElasticity = fitsAcross ? .none : .automatic
    scrollView.verticalScrollElasticity = fitsDown ? .none : .automatic
    var rect = CGRect(x: across.origin, y: down.origin, width: across.length, height: down.length)
    if case .canvasResizing = interaction { rect = rect.union(bounds) }
    guard abs(rect.minX - bounds.minX) + abs(rect.minY - bounds.minY) + abs(rect.width - bounds.width) + abs(rect.height - bounds.height) > 0.01
    else { return }
    // What's in the middle of the view stays there.
    let middle = unobscuredRect.center
    adjusting = true
    setFrameSize(rect.size)
    setBoundsOrigin(rect.origin)
    center(on: middle)
    adjusting = false
    if configuration.showsRulers { updateRulers() }
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

  /// A tap on a Force Touch trackpad, as Keynote and Freeform give when something snaps into
  /// place. Trackpads without it, and mice, feel nothing.
  func feelAlignment() {
    hapticTaps += 1
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  @objc private func visibleDidChange() {
    guard !adjusting else { return }
    // Pinching past 100% is felt, so actual size is easy to find.
    if lastMagnification > 0, (lastMagnification - 1) * (magnification - 1) < 0 || (magnification == 1 && lastMagnification != 1) {
      feelAlignment()
    }
    // Zooming or resizing changes the room the canvas has.
    updateCanvasSize()
    let visible = unobscuredRect
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
  }

  @objc private func viewSizeDidChange() {
    updateCanvasSize()
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
    if let editor = textEditor, let element = scene[editor.elementID] { editor.refresh(element) }
    invalidateAccessibility()
  }

  @objc private func selectionDidChange() {
    needsDisplay = true
    // Everything's redrawn, so the selection box is now drawn where it is.
    lastSelectionRect = selectionRect()
    haloCache = haloCache.filter { drawing.selection.contains($0.key) }
    if let croppingID, !drawing.selection.contains(croppingID) { self.croppingID = nil }
    if let pointEditingID, !drawing.selection.contains(pointEditingID) { self.pointEditingID = nil }
    invalidateAccessibility()
  }

  func invalidate(_ element: Element) {
    // Room for the dotted outline around a selected element, too.
    let margin = 16 / magnification + 2
    setNeedsDisplay(element.drawnBounds.insetBy(dx: -margin, dy: -margin))
    if drawing.selection.contains(element.id) || !drawing.selection.isEmpty { invalidateSelectionBox() }
  }

  /// Where the selection box and its handles are drawn, with the rotation knob above them.
  func selectionRect() -> CGRect? {
    guard let box = selectionBox() else { return nil }
    let margin = 40 / magnification
    return CGRect(boundingPoints: box.corners).insetBy(dx: -margin, dy: -margin)
  }

  /// Redraws where the selection box and its handles are, and where they were last drawn.
  func invalidateSelectionBox() {
    if let last = lastSelectionRect { setNeedsDisplay(last) }
    lastSelectionRect = selectionRect()
    if let rect = lastSelectionRect { setNeedsDisplay(rect) }
  }

  // MARK: Drawing

  /// Behind the canvas, a grey the white page stands out on, as MS Paint's and Pages' pages do.
  var deskColor: CGColor {
    effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : CGColor(srgbRed: 0.886, green: 0.89, blue: 0.906, alpha: 1)
  }

  static let deskNSColor = NSColor(name: "BristleDesk") { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1) : NSColor(srgbRed: 0.886, green: 0.89, blue: 0.906, alpha: 1)
  }

  /// Whether the canvas's own colour is dark, so the grid and marks over it are drawn light.
  var canvasIsDark: Bool {
    guard let background = scene.paper.background, background.alpha > 0.5 else { return false }
    return 0.299 * background.red + 0.587 * background.green + 0.114 * background.blue < 0.5
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  public override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    var rects: UnsafePointer<NSRect>?
    var count = 0
    getRectsBeingDrawn(&rects, count: &count)
    render(in: context, dirty: dirtyRect, rects: (0..<count).map { rects![$0] })
  }

  /// Draws the part of the view in `dirty`, made of `rects`: the desk, the canvas with the
  /// drawing on it, and what's being done over it. The drawing is the same in light and dark
  /// appearances, as a page in Pages is; only the desk around it follows the appearance.
  func render(in context: CGContext, dirty dirtyRect: CGRect, rects: [CGRect]) {
    let scale = magnification
    let page = scene.canvas
    context.setFillColor(deskColor)
    context.fill(dirtyRect)
    drawPage(page, in: context, dirty: dirtyRect, scale: scale)
    // The drawing, and what's being drawn, show only on the canvas, as in MS Paint.
    context.saveGState()
    context.clip(to: page)
    drawGrid(in: context, dirty: dirtyRect, scale: scale)
    // Zoomed in far, images show their own square pixels, as paint programs show them.
    context.interpolationQuality = scale >= 3 ? .none : .high
    let dirty = rects.isEmpty ? [dirtyRect] : rects
    let tiny = 0.6 / scale
    let editing = textEditor?.elementID
    for element in scene.elements {
      let box = element.drawnBounds
      guard box.intersects(dirtyRect), dirty.contains(where: { $0.intersects(box) }), element.id != editing else {
        continue
      }
      if box.width < tiny && box.height < tiny {
        // Too small to see: a speck of its color costs far less than drawing it.
        context.setFillColor((element.stroke ?? element.fill ?? .ink).cgColor)
        context.fill(element.bounds)
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
    drawDraft(in: context, scale: scale)
    context.restoreGState()
    drawCanvasHandles(page, in: context, dirty: dirtyRect, scale: scale)
    drawInteraction(in: context, scale: scale)
    drawSelection(in: context, scale: scale)
    drawGuides(in: context, scale: scale)
    drawSizeRing(in: context, scale: scale)
  }

  /// The canvas on the desk: its colour, or a checkerboard where it's transparent, lifted by a
  /// soft shadow.
  private func drawPage(_ page: CGRect, in context: CGContext, dirty: CGRect, scale: CGFloat) {
    let reach = 16 / scale
    guard page.insetBy(dx: -reach, dy: -reach).intersects(dirty) else { return }
    let background = scene.paper.background
    context.saveGState()
    // The shadow costs a little, so it's drawn only where the page's edge is being redrawn.
    if !page.insetBy(dx: 1 / scale, dy: 1 / scale).contains(dirty) {
      context.setShadow(offset: CGSize(width: 0, height: -1), blur: 5, color: CGColor(gray: 0, alpha: 0.28))
    }
    context.setFillColor(background.map { $0.alpha >= 1 ? $0.cgColor : .white } ?? .white)
    context.fill(page)
    context.restoreGState()
    if background == nil || background!.alpha < 1 {
      context.saveGState()
      context.clip(to: page.intersection(dirty))
      let side = 16 / scale
      context.draw(Self.checkerboard, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
      if let background {
        context.setFillColor(background.cgColor)
        context.fill(page)
      }
      context.restoreGState()
    }
  }

  /// Grey and white squares, for a transparent canvas.
  nonisolated(unsafe) static let checkerboard: CGImage = {
    let context = CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    context.setFillColor(CGColor(gray: 0.87, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
    return context.makeImage()!
  }()

  /// MS Paint's three handles for resizing the canvas: the right edge, the bottom edge, and the
  /// corner between them.
  func canvasHandles(_ page: CGRect) -> [(edge: Int, point: CGPoint)] {
    [(3, CGPoint(x: page.maxX, y: page.midY)), (4, CGPoint(x: page.maxX, y: page.maxY)), (5, CGPoint(x: page.midX, y: page.maxY))]
  }

  private func drawCanvasHandles(_ page: CGRect, in context: CGContext, dirty: CGRect, scale: CGFloat) {
    let side = 7 / scale
    for (_, p) in canvasHandles(page) {
      let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
      guard rect.insetBy(dx: -2 / scale, dy: -2 / scale).intersects(dirty) else { continue }
      context.setFillColor(.white)
      context.fill(rect)
      context.setStrokeColor(CGColor(gray: 0.45, alpha: 1))
      context.setLineWidth(1 / scale)
      context.stroke(rect.insetBy(dx: 0.5 / scale, dy: 0.5 / scale))
    }
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
      // Drawn by the renderer, texture and all, from the kept outline.
      Renderer.drawInk(element, path: path, in: context)
      context.restoreGState()
      return
    }
    Renderer.draw(element, in: context, scene: scene, images: images)
  }

  /// A grid of dots, as Freeform draws.
  private func drawGrid(in context: CGContext, dirty: CGRect, scale: CGFloat) {
    // The pixel grid takes over when zoomed in far.
    guard configuration.showsGrid, scale < Self.pixelGridZoom else { return }
    // Zoomed out, every other dot goes, and so on, so they never crowd closer than a few points.
    var spacing = configuration.gridSpacing
    while spacing * scale < 7 { spacing *= 2 }
    let dot = max(1 / scale, 0.25)
    context.setFillColor(canvasIsDark ? CGColor(gray: 1, alpha: 0.25) : CGColor(gray: 0, alpha: 0.2))
    // All the dots are one path, filled at once, which is far quicker than one at a time.
    let dots = CGMutablePath()
    var y = (dirty.minY / spacing).rounded(.up) * spacing
    while y <= dirty.maxY {
      var x = (dirty.minX / spacing).rounded(.up) * spacing
      while x <= dirty.maxX {
        dots.addRect(CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
        x += spacing
      }
      y += spacing
    }
    context.addPath(dots)
    context.fillPath()
  }

  /// Zoomed in far enough to see single pixels, a line between each, as in a paint program.
  /// Exports are one pixel per point, so these are the pixels a PNG will have.
  public static let pixelGridZoom: CGFloat = 8

  private func drawPixelGrid(in context: CGContext, dirty: CGRect, scale: CGFloat) {
    guard configuration.showsGrid, scale >= Self.pixelGridZoom else { return }
    context.saveGState()
    defer { context.restoreGState() }
    let fade = min(1, (scale - Self.pixelGridZoom) / Self.pixelGridZoom + 0.5)
    context.setStrokeColor(canvasIsDark ? CGColor(gray: 1, alpha: 0.12 * fade) : CGColor(gray: 0, alpha: 0.1 * fade))
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
    lastSelectionRect = selectionRect()
    delegate?.canvasViewZoomDidChange(self)
  }

  /// Zooms to `value`, keeping the middle of the view, or `point`, where it is on screen.
  public func zoom(to value: CGFloat, around point: CGPoint? = nil) {
    let value = min(scrollView.maxMagnification, max(scrollView.minMagnification, value))
    let before = magnification
    let middle = unobscuredRect.center
    let anchor = point ?? middle
    scrollView.magnification = value
    // The anchor stays the same distance from the middle on screen.
    let factor = before / value
    center(on: CGPoint(x: anchor.x - (anchor.x - middle.x) * factor, y: anchor.y - (anchor.y - middle.y) * factor))
    zoomDidChange()
  }

  /// The zoom steps used by Zoom In and Zoom Out.
  public static let zoomSteps: [CGFloat] = [
    0.1, 0.15, 0.2, 0.25, 0.33, 0.4, 0.5, 0.6, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8, 10, 12, 16,
  ]

  @objc public func zoomIn(_ sender: Any?) {
    zoom(to: Self.zoomSteps.first { $0 > magnification + 0.001 } ?? scrollView.maxMagnification)
  }

  @objc public func zoomOut(_ sender: Any?) {
    zoom(to: Self.zoomSteps.last { $0 < magnification - 0.001 } ?? scrollView.minMagnification)
  }

  @objc public func actualSize(_ sender: Any?) { zoom(to: 1) }

  /// Room to keep clear around the canvas when fitting it, beyond what's laid over the view.
  public var fitInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

  /// Shows the whole canvas, as large as fits.
  @objc public func zoomToFit(_ sender: Any?) { zoom(toFit: scene.canvas, largest: scrollView.maxMagnification) }

  /// Shows the selection as large as fits.
  @objc public func zoomToSelection(_ sender: Any?) {
    let box = scene.bounds(of: drawing.selection)
    zoom(toFit: box.isNull ? scene.canvas : box, largest: 4)
  }

  /// The room there is for the canvas, in points on screen: the view, less what's laid over it
  /// and the margins kept around it.
  var roomToFit: CGSize {
    let clip = scrollView.contentView
    let insets = clip.contentInsets
    let scale = magnification
    return CGSize(
      width: clip.frame.width - (insets.left + insets.right) * scale - fitInsets.left - fitInsets.right,
      height: clip.frame.height - (insets.top + insets.bottom) * scale - fitInsets.top - fitInsets.bottom)
  }

  /// The zoom Zoom to Fit gives.
  public var fitMagnification: CGFloat {
    let room = roomToFit, area = scene.canvas
    let fit = min(room.width / max(area.width, 1), room.height / max(area.height, 1))
    return min(scrollView.maxMagnification, max(scrollView.minMagnification, fit))
  }

  func zoom(toFit area: CGRect, largest: CGFloat) {
    let room = roomToFit
    guard room.width > 40, room.height > 40 else { return }
    let fit = min(room.width / max(area.width, 1), room.height / max(area.height, 1), largest)
    scrollView.magnification = min(scrollView.maxMagnification, max(scrollView.minMagnification, fit))
    center(on: area.center)
    zoomDidChange()
  }

  /// Opens a drawing the way it's best seen: the canvas at actual size when it fits, and
  /// fitted otherwise, in the middle of the space the toolbar and bars leave.
  public func showDrawing() {
    let area = scene.canvas
    let room = roomToFit
    if area.width <= room.width && area.height <= room.height {
      scrollView.magnification = 1
      center(on: area.center)
      zoomDidChange()
    } else {
      zoom(toFit: area, largest: 1)
    }
  }

  /// The part of the view that nothing is laid over, such as the toolbar, in the canvas's
  /// coordinates.
  public var unobscuredRect: CGRect {
    let clip = scrollView.contentView
    // The clip view's insets are in its own coordinates, which zoom with the canvas.
    let insets = clip.contentInsets
    var rect = clip.bounds
    rect.origin.x += insets.left
    rect.origin.y += insets.top
    rect.size.width -= insets.left + insets.right
    rect.size.height -= insets.top + insets.bottom
    return convert(rect, from: clip)
  }

  /// Scrolls so `point` is in the middle of the unobscured view, as near as the canvas allows.
  public func center(on point: CGPoint) {
    viewCenter = point
    let clip = scrollView.contentView
    let now = unobscuredRect.center
    var bounds = clip.bounds
    bounds.origin.x += point.x - now.x
    bounds.origin.y += point.y - now.y
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  public override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    delegate?.canvasViewZoomDidChange(self)
  }


  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let pointerArea { removeTrackingArea(pointerArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    pointerArea = area
  }
}

extension CGColor {
  var nsColor: NSColor { NSColor(cgColor: self) ?? .black }
}

/// Keeps the canvas in the middle of the view when it's smaller than the view, and lets its
/// edges scroll clear of what's laid over the view, such as the toolbar and the bars.
final class CanvasClipView: NSClipView {
  /// AppKit keeps the clip view's insets, in its own coordinates, for everything laid over the
  /// canvas: the toolbar, the rulers, and the bars at the bottom, which the scroll view is told
  /// of. Scrolling stays AppKit's own, so it's as smooth and responsive as anywhere else; this
  /// only centres the canvas when all of it fits in the space left clear.
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var rect = super.constrainBoundsRect(proposedBounds)
    guard let document = documentView, rect.width > 0, rect.height > 0 else { return rect }
    let doc = document.frame
    let scale = frame.width / rect.width
    let insets = contentInsets
    let width = rect.width - insets.left - insets.right, height = rect.height - insets.top - insets.bottom
    // On whole pixels, so the canvas's edges stay sharp. AppKit can round the view out by a
    // fraction of a pixel, which mustn't leave anything to scroll.
    let pixel = 1 / scale
    if doc.width <= width + pixel { rect.origin.x = ((doc.midX - width / 2 - insets.left) * scale).rounded() / scale }
    if doc.height <= height + pixel { rect.origin.y = ((doc.midY - height / 2 - insets.top) * scale).rounded() / scale }
    return rect
  }
}

/// The canvas's scroll view. Command-scrolling zooms around the pointer, as in Preview. It's
/// handled here rather than by the canvas, since a document view that handles the scroll wheel
/// itself loses AppKit's responsive scrolling, which pans a large drawing smoothly.
final class CanvasScrollView: NSScrollView {
  /// Scroll bars always float over the canvas, as in Maps and Freeform, even with a mouse
  /// plugged in. Bars that take room change the room the canvas has as they come and go, which
  /// would nudge the canvas around.
  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }

  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command), let canvas = documentView as? CanvasView,
      event.phase != .ended || event.scrollingDeltaY != 0
    {
      let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
      canvas.zoom(to: canvas.magnification * factor, around: canvas.convert(event.locationInWindow, from: nil))
      return
    }
    super.scrollWheel(with: event)
  }
}
