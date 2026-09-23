import AppKit
import BristleCore

/// Text is edited in place with a standard text view laid over the element, so typing, the
/// font panel, spelling, and input methods all work as they do everywhere else.
final class TextEditor: NSTextView, NSTextViewDelegate {
  let elementID: String
  let isNew: Bool
  weak var canvas: CanvasView?
  private let ownUndo = UndoManager()

  init(element: Element, canvas: CanvasView, isNew: Bool) {
    elementID = element.id
    self.isNew = isNew
    self.canvas = canvas
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: CGSize(width: 100_000, height: 100_000))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    super.init(frame: element.frame, textContainer: container)
    isRichText = false
    importsGraphics = false
    allowsUndo = true
    usesFontPanel = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    textContainerInset = NSSize(width: TextLayout.inset, height: TextLayout.inset)
    isVerticallyResizable = false
    isHorizontallyResizable = false
    focusRingType = .none
    delegate = self
    string = element.text
    apply(element)
    setAccessibilityLabel("Text")
  }

  required init?(coder: NSCoder) { fatalError() }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    fatalError()
  }

  func apply(_ element: Element) {
    let font = NSFont(name: element.fontName, size: element.fontSize) ?? .systemFont(ofSize: element.fontSize)
    self.font = font
    textColor = (element.stroke ?? .ink).cgColor.nsColor
    alignment = [.left: .left, .center: .center, .right: .right][element.textAlign] ?? .left
    typingAttributes[.font] = font
    typingAttributes[.foregroundColor] = textColor
    if let fill = element.fill {
      drawsBackground = true
      backgroundColor = fill.cgColor.nsColor
    } else {
      drawsBackground = false
    }
    insertionPointColor = textColor ?? .labelColor
    follow(element)
  }

  /// Keeps the view over the element as its frame changes.
  func follow(_ element: Element) {
    textContainer?.size = CGSize(
      width: element.fixedWidth ? max(1, element.width - TextLayout.inset * 2) : 100_000, height: 100_000)
    frame = element.frame
    frameCenterRotation = -element.rotation * 180 / .pi
    needsDisplay = true
  }

  func undoManager(for view: NSTextView) -> UndoManager? { ownUndo }

  func textDidChange(_ notification: Notification) {
    guard let canvas else { return }
    let text = string
    let font = self.font ?? .systemFont(ofSize: 24)
    let color = textColor.flatMap { Color($0.cgColor) }
    let systemName = NSFont.systemFont(ofSize: font.pointSize).fontName
    canvas.drawing.live { scene in
      guard var e = scene[self.elementID] else { return }
      e.text = text
      e.fontName = font.fontName == systemName ? "" : font.fontName
      e.fontSize = font.pointSize
      if let color { e.stroke = color }
      e.fitToText()
      scene[self.elementID] = e
      scene.updateBindings(changed: [self.elementID])
    }
  }

  override func cancelOperation(_ sender: Any?) { canvas?.endTextEditing() }

  override func doCommand(by selector: Selector) {
    // Command-Return finishes, like Keynote; Return starts a new line.
    if selector == #selector(insertNewlineIgnoringFieldEditor(_:)) {
      insertNewline(nil)
      return
    }
    super.doCommand(by: selector)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36, event.modifierFlags.contains(.command) {
      canvas?.endTextEditing()
      return
    }
    super.keyDown(with: event)
  }

  override func changeColor(_ sender: Any?) {
    super.changeColor(sender)
    textDidChange(Notification(name: NSText.didChangeNotification))
  }

  override func changeFont(_ sender: Any?) {
    super.changeFont(sender)
    textDidChange(Notification(name: NSText.didChangeNotification))
  }
}

extension CanvasView {
  public var isEditingText: Bool { textEditor != nil }

  /// Adds a text element at a point and starts typing into it.
  func addText(at point: CGPoint, width: CGFloat?) {
    var element = Element(kind: .text)
    (styles[.text] ?? Tool.text.defaultStyle).apply(to: &element)
    element.x = point.x.rounded()
    element.y = point.y.rounded()
    if let width {
      element.fixedWidth = true
      element.width = width
    }
    element.fitToText()
    if width == nil {
      // A click marks where the first line's text starts, not the frame's corner.
      element.x -= TextLayout.inset
      element.y -= element.height / 2
    }
    drawing.beginGesture()
    drawing.live { $0.elements.append(element) }
    drawing.selection = [element.id]
    beginTextEditing(element.id, isNew: true)
  }

  public func beginTextEditing(_ id: String) { beginTextEditing(id, isNew: false) }

  func beginTextEditing(_ id: String, isNew: Bool) {
    guard let element = scene[id], element.kind == .text, !element.locked else { return }
    endTextEditing()
    if !drawing.isInGesture { drawing.beginGesture() }
    let editor = TextEditor(element: element, canvas: self, isNew: isNew)
    textEditor = editor
    addSubview(editor)
    window?.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    invalidate(element)
  }

  /// Finishes typing, removing the text if it was left empty.
  public func endTextEditing() {
    guard let editor = textEditor else { return }
    textEditor = nil
    let id = editor.elementID
    let firstResponder = window?.firstResponder === editor
    editor.removeFromSuperview()
    if let element = scene[id] {
      invalidate(element)
      if element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        drawing.live { $0.delete([id]) }
      }
    }
    drawing.endGesture(editor.isNew ? "Add Text" : "Typing")
    if firstResponder { window?.makeFirstResponder(self) }
    if editor.isNew && configuration.returnsToSelect, scene[id] != nil { tool = .select }
  }
}
