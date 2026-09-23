import AppKit
import BristleCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
  /// Bristle elements, as the JSON of a drawing holding just them and their images.
  public static let bristleElements = NSPasteboard.PasteboardType("io.github.PoteNad.bristle.elements")
}

/// The clipboard, drag and drop, and Continuity Camera. Copied elements go out as Bristle
/// elements, PNG, and PDF, so they paste as editable objects here and as pictures elsewhere.
extension CanvasView: @preconcurrency NSServicesMenuRequestor, NSDraggingSource {
  static var acceptedDragTypes: [NSPasteboard.PasteboardType] {
    [.bristleElements, .fileURL, .png, .tiff, .pdf, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .string]
  }

  static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP]

  /// A scene holding only the given elements, their images, and the same paper.
  func clipping(_ ids: Set<String>) -> Scene {
    var clip = Scene(paper: scene.paper, elements: scene.elements.filter { ids.contains($0.id) })
    for element in clip.elements where element.kind == .image {
      if let file = scene.files[element.file] { clip.files[element.file] = file }
    }
    return clip
  }

  /// Writes the elements to a pasteboard as Bristle elements, PNG, PDF, and their text.
  public func write(_ ids: Set<String>, to pasteboard: NSPasteboard) {
    let clip = clipping(ids)
    let area = clip.contentBounds.integral
    guard !area.isNull else { return }
    var transparent = clip
    transparent.paper.background = nil
    let text = clip.elements.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
    pasteboard.clearContents()
    pasteboard.declareTypes([.bristleElements, .png, .pdf] + (text.isEmpty ? [] : [.string]), owner: nil)
    pasteboard.setData(SceneFile.data(clip), forType: .bristleElements)
    // Twice the resolution, so a copy pasted into a document stays sharp on Retina displays.
    if let image = Renderer.image(transparent, scale: 2, area: area, images: images),
      let png = Renderer.png(image, resolution: 144)
    {
      pasteboard.setData(png, forType: .png)
    }
    pasteboard.setData(Renderer.pdf(transparent, area: area, images: images), forType: .pdf)
    if !text.isEmpty { pasteboard.setString(text, forType: .string) }
  }

  @objc public func copy(_ sender: Any?) {
    guard !drawing.selection.isEmpty else { return }
    write(drawing.selection, to: .general)
    pasteCount = 0
    lastPasteSource = NSPasteboard.general.changeCount
  }

  @objc public func cut(_ sender: Any?) {
    copy(sender)
    deleteSelection("Cut")
  }

  @objc public func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if lastPasteSource == pasteboard.changeCount { pasteCount += 1 } else {
      pasteCount = 0
      lastPasteSource = pasteboard.changeCount
    }
    insert(from: pasteboard, at: nil, name: "Paste")
  }

  func canPaste(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.availableType(from: Self.acceptedDragTypes) != nil
      || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: Self.imageTypes.map(\.identifier)])
  }

  /// Adds whatever a pasteboard holds: Bristle elements, images, image files, or text. With no
  /// point, pasted elements land where they came from, stepping on with each paste, or in the
  /// middle of the view when that place is out of sight.
  @discardableResult
  func insert(from pasteboard: NSPasteboard, at point: CGPoint?, name: String) -> Bool {
    if let data = pasteboard.data(forType: .bristleElements), let clip = try? SceneFile.scene(from: data),
      !clip.elements.isEmpty
    {
      let box = clip.contentBounds
      let visible = scrollView.documentVisibleRect
      var offset: CGPoint
      if let point {
        offset = CGPoint(x: point.x - box.midX, y: point.y - box.midY)
      } else if visible.intersects(box) {
        offset = CGPoint(x: CGFloat(pasteCount) * 12, y: CGFloat(pasteCount) * 12)
      } else {
        offset = CGPoint(x: visible.midX - box.midX, y: visible.midY - box.midY)
      }
      offset = CGPoint(x: offset.x.rounded(), y: offset.y.rounded())
      let copies = Scene.copies(of: clip.elements, offset: offset)
      if tool != .select { tool = .select }
      drawing.edit(name, select: Set(copies.map(\.id))) { scene in
        for (id, file) in clip.files where scene.files[id] == nil { scene.files[id] = file }
        scene.elements += copies
      }
      return true
    }
    var images: [ImageFile] = []
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: Self.imageTypes.map(\.identifier)])
      as? [URL]
    {
      for url in urls {
        guard let data = try? Data(contentsOf: url) else { continue }
        let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
        images.append(ImageFile(type: type, data: data))
      }
    }
    if images.isEmpty {
      for type in [NSPasteboard.PasteboardType.png, NSPasteboard.PasteboardType(UTType.jpeg.identifier)] {
        if let data = pasteboard.data(forType: type) {
          images.append(ImageFile(type: type == .png ? UTType.png.identifier : UTType.jpeg.identifier, data: data))
          break
        }
      }
    }
    if images.isEmpty, let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .pdf),
      let image = NSImage(data: data), let png = Self.png(from: image)
    {
      images.append(ImageFile(type: UTType.png.identifier, data: png))
    }
    if !images.isEmpty {
      insertImages(images, at: point, name: name)
      return true
    }
    if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .newlines), !text.isEmpty {
      var element = Element(kind: .text)
      (styles[.text] ?? Tool.text.defaultStyle).apply(to: &element)
      element.text = text
      element.fitToText()
      let where_ = point ?? scrollView.documentVisibleRect.center
      element.x = (where_.x - element.width / 2).rounded()
      element.y = (where_.y - element.height / 2).rounded()
      if tool != .select { tool = .select }
      drawing.edit(name, select: [element.id]) { $0.elements.append(element) }
      return true
    }
    return false
  }

  /// Places images, each at its own size unless that won't fit in view, centred on `point`.
  public func insertImages(_ files: [ImageFile], at point: CGPoint?, name: String = "Insert Image") {
    let visible = scrollView.documentVisibleRect
    var center = point ?? visible.center
    var elements: [Element] = []
    var added: [ImageFile] = []
    for file in files {
      guard var size = ImageStore.pixelSize(of: file.data), size.width > 0, size.height > 0 else { continue }
      // Images keep their printed size: a Retina screenshot placed in an ordinary drawing is
      // shown at the size it appeared on screen.
      if let dpi = ImageStore.resolution(of: file.data), abs(dpi - scene.paper.resolution) > 1 {
        let factor = scene.paper.resolution / dpi
        size = CGSize(width: size.width * factor, height: size.height * factor)
      }
      // Large images are scaled down to fit in view; with no view yet, they keep their size.
      let limit = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
      let fit = visible.width < 1 || visible.height < 1 ? 1 : min(1, limit.width / size.width, limit.height / size.height)
      size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
      var element = Element(kind: .image)
      element.file = file.id
      element.frame = CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(), width: size.width, height: size.height)
      elements.append(element)
      added.append(file)
      center.x += 20
      center.y += 20
    }
    guard !elements.isEmpty else {
      NSSound.beep()
      return
    }
    if tool != .select { tool = .select }
    drawing.edit(name, select: Set(elements.map(\.id))) { scene in
      for file in added { scene.addFile(file) }
      scene.elements += elements
    }
  }

  static func png(from image: NSImage) -> Data? {
    var rect = CGRect(origin: .zero, size: image.size)
    let scale: CGFloat = image.representations.contains { $0 is NSPDFImageRep } ? 2 : 1
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    if scale == 1 { return Renderer.png(cgImage) }
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    guard let context = Renderer.bitmap(size: size, scale: 1) else { return nil }
    let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage().flatMap { Renderer.png($0, resolution: 144) }
  }

  // MARK: Drag and drop

  public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    canPaste(sender.draggingPasteboard) ? .copy : []
  }

  public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    canPaste(sender.draggingPasteboard) ? .copy : []
  }

  public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let p = convert(sender.draggingLocation, from: nil)
    return insert(from: sender.draggingPasteboard, at: p, name: "Drop")
  }

  /// Dragging the selection out of the window hands it to other apps, as PNG and PDF.
  func dragsOut(_ event: NSEvent) -> Bool {
    guard let window, let content = window.contentView else { return false }
    let inWindow = content.convert(event.locationInWindow, from: nil)
    guard !content.bounds.insetBy(dx: -2, dy: -2).contains(inWindow), !drawing.selection.isEmpty else { return false }
    let ids = drawing.selection
    drawing.cancelGesture()
    interaction = .none
    updateGuides([])
    let item = NSPasteboardItem()
    let clip = clipping(ids)
    let area = clip.contentBounds.integral
    var transparent = clip
    transparent.paper.background = nil
    item.setData(SceneFile.data(clip), forType: .bristleElements)
    if let image = Renderer.image(transparent, scale: 2, area: area, images: images), let png = Renderer.png(image, resolution: 144) {
      item.setData(png, forType: .png)
    }
    item.setData(Renderer.pdf(transparent, area: area, images: images), forType: .pdf)
    let draggingItem = NSDraggingItem(pasteboardWriter: item)
    let preview = Renderer.image(transparent, scale: magnification, area: area, images: images)
    let frame = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height)
    draggingItem.setDraggingFrame(frame, contents: preview.map { NSImage(cgImage: $0, size: frame.size) })
    beginDraggingSession(with: [draggingItem], event: event, source: self)
    return true
  }

  public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation
  {
    context == .outsideApplication ? .copy : [.copy, .generic]
  }

  // MARK: Continuity Camera and Sketch

  public override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?)
    -> Any?
  {
    if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) || returnType == .pdf {
      return self
    }
    return super.validRequestor(forSendType: sendType, returnType: returnType)
  }

  public func readSelection(from pasteboard: NSPasteboard) -> Bool {
    insert(from: pasteboard, at: nil, name: "Insert from iPhone")
  }

  public func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}
