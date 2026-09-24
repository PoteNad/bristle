import AppKit
import Testing

@testable import BristleCanvas
@testable import BristleCore

@MainActor
func rectangle(_ frame: CGRect, id: String = Element.newID()) -> Element {
  var e = Element(id: id, kind: .rectangle)
  e.frame = frame
  return e
}

@MainActor @Suite(.serialized) struct Canvas {
  @Test func editsUndoAndRestoreTheSelection() {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let drawing = Drawing()
    drawing.undoManager = undo
    let box = rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), id: "box")
    undo.beginUndoGrouping()
    drawing.edit("Add", select: ["box"]) { $0.elements.append(box) }
    undo.endUndoGrouping()
    #expect(undo.undoActionName == "Add")
    undo.beginUndoGrouping()
    drawing.edit("Move") { $0.move(["box"], dx: 5, dy: 0) }
    undo.endUndoGrouping()
    drawing.selection = []
    undo.undo()
    #expect(drawing.scene["box"]?.x == 0 && drawing.selection == ["box"])
    undo.undo()
    #expect(drawing.scene.elements.isEmpty && drawing.selection.isEmpty)
    undo.redo()
    undo.redo()
    #expect(drawing.scene["box"]?.x == 5)
  }

  @Test func gesturesBecomeOneUndoStep() {
    let undo = UndoManager()
    undo.groupsByEvent = false
    let drawing = Drawing(scene: Scene(elements: [rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), id: "box")]))
    drawing.undoManager = undo
    undo.beginUndoGrouping()
    drawing.beginGesture()
    for _ in 0..<20 { drawing.live { $0.move(["box"], dx: 1, dy: 1) } }
    drawing.endGesture("Move")
    undo.endUndoGrouping()
    #expect(drawing.scene["box"]?.frame.origin == CGPoint(x: 20, y: 20))
    undo.undo()
    #expect(drawing.scene["box"]?.frame.origin == .zero)
    #expect(!undo.canUndo)
    drawing.beginGesture()
    drawing.live { $0.elements.removeAll() }
    drawing.cancelGesture()
    #expect(drawing.scene.elements.count == 1)
  }

  @Test func copiedElementsPasteAsNewObjects() {
    let drawing = Drawing(scene: Scene(elements: [rectangle(CGRect(x: 10, y: 10, width: 50, height: 30), id: "box")]))
    let canvas = CanvasView(drawing: drawing)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    canvas.write(["box"], to: pasteboard)
    #expect(pasteboard.data(forType: .png) != nil && pasteboard.data(forType: .pdf) != nil)
    #expect(canvas.insert(from: pasteboard, at: CGPoint(x: 200, y: 200), name: "Paste"))
    #expect(drawing.scene.elements.count == 2)
    let pasted = drawing.scene.elements[1]
    #expect(pasted.id != "box" && pasted.frame.size == CGSize(width: 50, height: 30))
    #expect(pasted.frame.center == CGPoint(x: 200, y: 200))
    #expect(drawing.selection == [pasted.id])
  }

  @Test func textAndImagesPasteFromOtherApps() throws {
    let drawing = Drawing()
    let canvas = CanvasView(drawing: drawing)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("Hello from elsewhere", forType: .string)
    #expect(canvas.insert(from: pasteboard, at: .zero, name: "Paste"))
    #expect(drawing.scene.elements.last?.text == "Hello from elsewhere")
    var scene = Scene(paper: Paper(size: CGSize(width: 40, height: 20), background: .black))
    scene.elements = []
    let png = try #require(Renderer.image(scene).flatMap { Renderer.png($0) })
    pasteboard.clearContents()
    pasteboard.setData(png, forType: .png)
    #expect(canvas.insert(from: pasteboard, at: CGPoint(x: 100, y: 100), name: "Paste"))
    let image = try #require(drawing.scene.elements.last)
    #expect(image.kind == .image && image.frame.size == CGSize(width: 40, height: 20))
    #expect(drawing.scene.files[image.file]?.data == png)
  }

  @Test func stylesApplyToTheSelectionOrTheTool() {
    let drawing = Drawing(scene: Scene(elements: [rectangle(CGRect(x: 0, y: 0, width: 10, height: 10), id: "box")]))
    let canvas = CanvasView(drawing: drawing)
    canvas.tool = .rectangle
    canvas.setStyle("Width") { $0.strokeWidth = 9 }
    #expect(canvas.styles[.rectangle]?.strokeWidth == 9 && drawing.scene["box"]?.strokeWidth == 3)
    drawing.selection = ["box"]
    canvas.setStyle("Fill") { $0.fill = .black }
    #expect(drawing.scene["box"]?.fill == .black)
    canvas.copyStyle(nil)
    drawing.edit("Add") { $0.elements.append(rectangle(CGRect(x: 20, y: 0, width: 10, height: 10), id: "other")) }
    drawing.selection = ["other"]
    canvas.pasteStyle(nil)
    #expect(drawing.scene["other"]?.fill == .black)
  }

  @Test func toolsHaveDistinctKeys() {
    let keys = Tool.allCases.map(\.key).filter { !$0.isEmpty }
    #expect(Set(keys).count == keys.count)
    #expect(Tool.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
  }
}

@MainActor @Suite struct Photos {
  @Test func removingTheBackgroundKeepsTheSubject() throws {
    guard #available(macOS 14.0, *) else { return }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Assets/Bristle-Screenshot.png")
    let data = try Data(contentsOf: url)
    let original = try #require(ImageStore.decode(data))
    let cut = try #require(CanvasView.subject(of: data))
    let image = try #require(ImageStore.decode(cut))
    #expect(image.width == original.width && image.height == original.height)
    let w = image.width, h = image.height
    let context = try #require(
      CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    var clear = 0, kept = 0
    for y in stride(from: 0, to: h, by: 16) {
      for x in stride(from: 0, to: w, by: 16) {
        if pixels[y * context.bytesPerRow + x * 4 + 3] < 20 { clear += 1 } else { kept += 1 }
      }
    }
    // Something is kept and something made clear.
    #expect(clear > 0 && kept > 0)
  }
}
