import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BristleCore

/// A small drawing with one of every kind of element.
func sampleScene() -> Scene {
  var scene = Scene(paper: Paper(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
  var box = Element(id: "box", kind: .rectangle)
  box.frame = CGRect(x: 20, y: 30, width: 120, height: 80)
  box.fill = Color(hex: "#FF3B30")
  box.cornerRadius = 8
  var ring = Element(id: "ring", kind: .ellipse)
  ring.frame = CGRect(x: 240, y: 40, width: 100, height: 100)
  ring.rotation = 0.3
  ring.dash = .dashed
  var arrow = Element(id: "arrow", kind: .arrow)
  arrow.setWorldPoints([CGPoint(x: 140, y: 70), CGPoint(x: 240, y: 90)])
  arrow.startBinding = .init(element: "box", anchor: CGPoint(x: 0.5, y: 0.5))
  arrow.endBinding = .init(element: "ring", anchor: CGPoint(x: 0.5, y: 0.5))
  var ink = Element(id: "ink", kind: .freehand)
  ink.setWorldPoints((0..<30).map { CGPoint(x: 40 + CGFloat($0) * 6, y: 200 + sin(CGFloat($0) / 3) * 20) })
  ink.pressures = (0..<30).map { 0.3 + CGFloat($0 % 5) / 10 }
  var label = Element(id: "label", kind: .text)
  label.text = "Hello, \"Bristle\" — 中文 👩🏽‍💻\nSecond line"
  label.x = 200
  label.y = 200
  label.fitToText()
  var shape = Element(id: "shape", kind: .polygon)
  shape.setWorldPoints([CGPoint(x: 300, y: 200), CGPoint(x: 360, y: 220), CGPoint(x: 330, y: 280)])
  shape.curved = true
  shape.groups = ["g1"]
  label.groups = ["g1"]
  scene.elements = [box, ring, arrow, ink, label, shape]
  scene.updateBindings(changed: ["arrow"])
  return scene
}

/// A PNG of a solid colour.
func solidPNG(width: Int, height: Int, color: Color) -> Data {
  var scene = Scene(paper: Paper(frame: CGRect(x: 0, y: 0, width: width, height: height), background: color))
  scene.elements = []
  return Renderer.png(Renderer.image(scene)!)!
}

/// Core Text can stall when many threads look up fonts for the first time at once, so the
/// suites that lay out text run one at a time.
@Suite(.serialized) struct Core {
  @Suite struct Colors {
    @Test func hexRoundTrips() {
      for hex in ["#1D1D1F", "#FFFFFF", "#00000000", "#12345678", "#ABCDEF"] {
        #expect(Color(hex: hex)?.hex == hex)
      }
      #expect(Color(hex: "#abc")?.hex == "#AABBCC")
      #expect(Color(hex: "nope") == nil)
    }

    @Test func namesAreReadable() {
      #expect(Color(hex: "#FF3B30")!.name == "red")
      #expect(Color(hex: "#007AFF")!.name == "blue")
      #expect(Color.ink.name == "black")
      #expect(Color.white.name == "white")
    }
  }

  @Suite struct FileFormat {
    @Test func writingIsDeterministicAndRoundTrips() throws {
      let scene = sampleScene()
      let data = SceneFile.data(scene)
      #expect(SceneFile.data(scene) == data)
      let reopened = try SceneFile.scene(from: data)
      #expect(SceneFile.data(reopened) == data)
      #expect(reopened.elements.map(\.id) == scene.elements.map(\.id))
      #expect(reopened.elements.map(\.kind) == scene.elements.map(\.kind))
      #expect(reopened["label"]?.text == scene["label"]?.text)
      #expect(reopened["arrow"]?.endBinding == scene["arrow"]?.endBinding)
      #expect(reopened["ink"]?.pressures.count == 30)
    }

    @Test func eachElementIsOneLine() throws {
      let text = String(decoding: SceneFile.data(sampleScene()), as: UTF8.self)
      let lines = text.split(separator: "\n")
      #expect(lines.first == "{")
      #expect(lines[1] == "  \"type\": \"bristle\",")
      #expect(lines.filter { $0.hasPrefix("    {\"id\":") }.count == 6)
      #expect(text.hasSuffix("}\n"))
    }

    @Test func imagesAreStoredOnce() throws {
      var scene = Scene()
      let file = ImageFile(type: "public.png", data: solidPNG(width: 4, height: 4, color: .black))
      let a = scene.addFile(file), b = scene.addFile(file)
      #expect(a == b && scene.files.count == 1)
      var image = Element(kind: .image)
      image.file = a
      image.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
      image.crop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
      scene.elements = [image]
      let reopened = try SceneFile.scene(from: SceneFile.data(scene))
      #expect(reopened.files == scene.files)
      #expect(reopened.elements[0].crop == image.crop)
    }

    @Test func unknownValuesAreIgnoredAndNewerVersionsRefused() throws {
      let extra = #"{"type":"bristle","version":1,"future":true,"elements":[{"type":"rectangle","x":1,"y":2,"width":3,"height":4,"sparkle":9},{"type":"hologram"}]}"#
      let scene = try SceneFile.scene(from: Data(extra.utf8))
      #expect(scene.elements.count == 1)
      #expect(scene.elements[0].frame == CGRect(x: 1, y: 2, width: 3, height: 4))
      #expect(throws: SceneFile.ReadError.newerVersion(7)) {
        try SceneFile.scene(from: Data(#"{"type":"bristle","version":7}"#.utf8))
      }
      #expect(throws: SceneFile.ReadError.notBristle) { try SceneFile.scene(from: Data("{}".utf8)) }
      #expect(throws: SceneFile.ReadError.notJSON) { try SceneFile.scene(from: Data("not json".utf8)) }
    }

    @Test func numbersAreShort() {
      #expect(JSON.format(12, digits: 2) == "12")
      #expect(JSON.format(12.345678, digits: 2) == "12.35")
      #expect(JSON.format(-0.001, digits: 2) == "0")
      #expect(JSON.format(0.1 + 0.2, digits: 2) == "0.3")
    }
  }

  @Suite struct PNGFiles {
    @Test func chunksRoundTripByteForByte() throws {
      let png = solidPNG(width: 10, height: 6, color: .white)
      let chunks = try #require(PNG.chunks(png))
      #expect(chunks.first?.type == "IHDR" && chunks.last?.type == "IEND")
      #expect(PNG.write(chunks) == png)
    }

    @Test func drawingsTravelInsidePNGs() throws {
      let scene = sampleScene()
      let png = try #require(EmbeddedScene.png(scene))
      #expect(ImageStore.pixelSize(of: png) == CGSize(width: 400, height: 300))
      let embedded = try #require(EmbeddedScene(png: png))
      #expect(embedded.isCurrent)
      #expect(SceneFile.data(embedded.scene) == SceneFile.data(scene))
      let chunk = try #require(PNG.chunks(png)?.first { $0.type == PNG.sceneChunk })
      // Private, and unsafe to copy, so editors that change pixels drop it.
      #expect(chunk.type.utf8.map { $0 & 0x20 != 0 } == [true, true, false, false])
    }

    @Test func reencodingKeepsTheDrawingCurrent() throws {
      let png = try #require(EmbeddedScene.png(sampleScene()))
      // Re-encode the same pixels, as an optimiser would, and carry the chunk across.
      let image = try #require(ImageStore.decode(png))
      let data = NSMutableData()
      let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 1]] as CFDictionary)
      #expect(CGImageDestinationFinalize(destination))
      let chunk = try #require(PNG.chunks(png)?.first { $0.type == PNG.sceneChunk })
      var chunks = try #require(PNG.chunks(data as Data))
      chunks.insert(chunk, at: chunks.count - 1)
      #expect(EmbeddedScene(png: PNG.write(chunks))?.isCurrent == true)
    }

    @Test func changedPixelsMakeTheDrawingStale() throws {
      let png = try #require(EmbeddedScene.png(sampleScene()))
      let chunk = try #require(PNG.chunks(png)?.first { $0.type == PNG.sceneChunk })
      var other = try #require(PNG.chunks(solidPNG(width: 400, height: 300, color: .black)))
      other.insert(chunk, at: other.count - 1)
      let embedded = try #require(EmbeddedScene(png: PNG.write(other)))
      #expect(!embedded.isCurrent)
    }

    @Test func plainPNGsHaveNoDrawing() {
      #expect(EmbeddedScene(png: solidPNG(width: 2, height: 2, color: .white)) == nil)
      #expect(PNG.chunks(Data("GIF89a".utf8)) == nil)
    }

    @Test func zlibRoundTrips() {
      let data = Data((0..<100_000).map { UInt8($0 % 251) })
      #expect(PNG.inflate(PNG.deflate(data)) == data)
      #expect(PNG.inflate(Data([1, 2, 3])) == nil)
    }
  }

  @Suite struct Changes {
    @Test func everyKindOfEditUndoesAndRedoes() {
      let original = sampleScene()
      let edits: [(inout Scene) -> Void] = [
        { $0.elements[0].x += 10 },
        { $0.elements.append(Element(kind: .rectangle)) },
        { $0.elements.remove(at: 2) },
        { $0.reorder(["box"], .front) },
        { $0.frame = CGRect(x: 0, y: 0, width: 999, height: 300) },
        { $0.delete(["ring", "label"]); $0.elements.insert(Element(kind: .ellipse), at: 1); $0.elements[0].fill = nil },
        { $0.duplicate(["box", "shape"], offset: CGPoint(x: 10, y: 10)) },
        { $0.group(["box", "ring"]) },
      ]
      for edit in edits {
        var after = original
        edit(&after)
        let change = SceneChange(from: original, to: after)
        #expect(!change.isEmpty)
        var scene = original
        change.apply(to: &scene)
        #expect(scene == after)
        change.apply(to: &scene, reversed: true)
        #expect(scene == original)
      }
      #expect(SceneChange(from: original, to: original).isEmpty)
    }
  }

  @Suite struct Shapes {
    @Test func unfilledShapesAreTouchedAtTheirOutline() {
      var box = Element(kind: .rectangle)
      box.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
      #expect(box.hit(CGPoint(x: 0, y: 50), tolerance: 3))
      #expect(!box.hit(CGPoint(x: 50, y: 50), tolerance: 3))
      box.fill = .white
      #expect(box.hit(CGPoint(x: 50, y: 50), tolerance: 3))
      box.rotation = .pi / 4
      #expect(!box.hit(CGPoint(x: 2, y: 2), tolerance: 1))
      #expect(box.hit(CGPoint(x: 50, y: -15), tolerance: 1))
    }

    @Test func strokesAreTouchedAlongTheirInk() {
      var ink = Element(kind: .freehand)
      ink.strokeWidth = 6
      ink.setWorldPoints((0...20).map { CGPoint(x: CGFloat($0) * 10, y: 50) })
      #expect(ink.hit(CGPoint(x: 100, y: 51), tolerance: 2))
      #expect(!ink.hit(CGPoint(x: 100, y: 70), tolerance: 2))
      #expect(ink.bounds.contains(CGRect(x: 0, y: 48, width: 200, height: 4)))
      #expect(ink.intersects(CGRect(x: 90, y: 40, width: 20, height: 20)))
      #expect(!ink.intersects(CGRect(x: 90, y: 60, width: 20, height: 20)))
    }

    @Test func resizingRotatedElementsKeepsThemInPlace() {
      var line = Element(kind: .line)
      line.setWorldPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)])
      line.rotation = 0.5
      let before = line.worldPoints
      line.points[0] = CGPoint(x: -20, y: -20)
      line.fitFrameToPoints()
      let after = line.worldPoints
      #expect(after[1].distance(to: before[1]) < 0.001)
    }

    @Test func textFramesFitTheirText() {
      var text = Element(kind: .text)
      text.text = "Short"
      text.fitToText()
      let short = text.frame.size
      text.text = "A much longer line of text"
      text.fitToText()
      #expect(text.width > short.width && text.height == short.height)
      text.fixedWidth = true
      text.width = short.width
      text.fitToText()
      #expect(text.width == short.width && text.height > short.height * 2)
    }
  }

  @Suite struct Arranging {
    func row(_ count: Int) -> Scene {
      var scene = Scene()
      for i in 0..<count {
        var e = Element(id: "e\(i)", kind: .rectangle)
        e.frame = CGRect(x: CGFloat(i * i) * 20, y: CGFloat(i) * 7, width: 30, height: 20)
        e.stroke = nil
        e.fill = .black
        scene.elements.append(e)
      }
      return scene
    }

    @Test func orderMovesOneStepOrAllTheWay() {
      var scene = row(4)
      scene.reorder(["e0"], .forward)
      #expect(scene.elements.map(\.id) == ["e1", "e0", "e2", "e3"])
      scene.reorder(["e0"], .front)
      #expect(scene.elements.map(\.id) == ["e1", "e2", "e3", "e0"])
      scene.reorder(["e3", "e0"], .backward)
      #expect(scene.elements.map(\.id) == ["e1", "e3", "e0", "e2"])
      scene.reorder(["e2"], .back)
      #expect(scene.elements.map(\.id) == ["e2", "e1", "e3", "e0"])
    }

    @Test func alignAndDistribute() {
      var scene = row(4)
      let ids: Set = ["e0", "e1", "e2", "e3"]
      scene.align(ids, .top)
      #expect(Set(scene.elements.map(\.y)).count == 1)
      scene.distribute(ids, .horizontal)
      let xs = scene.elements.map(\.x).sorted()
      let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 }
      #expect(gaps.allSatisfy { abs($0 - gaps[0]) < 0.001 })
      // One object lines up with the frame, and stays put without one.
      var one = row(1)
      one.align(["e0"], .center)
      #expect(one == row(1))
      one.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
      one.align(["e0"], .center)
      #expect(one.elements[0].center.x == 200)
    }

    @Test func groupsStayTogetherAndActAsOne() {
      var scene = row(4)
      let group = scene.group(["e0", "e2"])!
      #expect(scene.elements.map(\.id) == ["e1", "e0", "e2", "e3"])
      #expect(scene.expandToGroups(["e0"]) == ["e0", "e2"])
      let inner = scene.group(["e0", "e2", "e3"])!
      #expect(scene.expandToGroups(["e0"]) == ["e0", "e2", "e3"])
      #expect(scene.expandToGroups(["e0"], within: inner) == ["e0", "e2"])
      #expect(scene.expandToGroups(["e0"], within: group) == ["e0"])
      scene.ungroup(["e0"])
      #expect(scene.expandToGroups(["e3"]) == ["e3"])
      #expect(scene.expandToGroups(["e2"]) == ["e0", "e2"])
    }

    @Test func duplicatesGetNewIDsAndKeepAttachments() {
      var scene = sampleScene()
      let copies = scene.duplicate(["box", "arrow"], offset: CGPoint(x: 10, y: 10))
      #expect(copies.count == 2 && Set(copies).isDisjoint(with: ["box", "arrow"]))
      let arrowCopy = scene[copies[1]]!
      #expect(arrowCopy.startBinding?.element == copies[0])
      #expect(arrowCopy.endBinding == nil)
      scene.delete(["ring"])
      #expect(scene["arrow"]?.endBinding == nil)
    }

    @Test func attachedArrowsFollow() throws {
      var scene = sampleScene()
      let before = try #require(scene["arrow"]).worldPoints
      scene.move(["box"], dx: 0, dy: 100)
      let after = try #require(scene["arrow"]).worldPoints
      #expect(after[0].y > before[0].y + 50)
      #expect(after[1].distance(to: before[1]) < 30)
      // The end sits just outside the box's outline.
      let box = try #require(scene["box"])
      #expect(!box.frame.contains(after[0]))
      #expect(box.frame.insetBy(dx: -12, dy: -12).contains(after[0]))
    }

    @Test func flippingTwiceRestores() {
      let original = sampleScene()
      var scene = original
      let ids = Set(scene.elements.map(\.id))
      scene.flip(ids, .horizontal)
      #expect(scene != original)
      scene.flip(ids, .horizontal)
      for (a, b) in zip(scene.elements, original.elements) {
        #expect(abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01)
      }
    }
  }

  @Suite struct Frame {
    @Test func rotatingFourTimesRestores() {
      let original = sampleScene()
      var scene = original
      scene.rotateDrawing(clockwise: true)
      let frame = scene.frame!
      #expect(frame.width == 300 && frame.height == 400)
      #expect(scene.contentBounds.minX >= frame.minX - 5 && scene.contentBounds.maxX <= frame.maxX + 5)
      for _ in 0..<3 { scene.rotateDrawing(clockwise: true) }
      #expect(scene.frame == original.frame)
      for (a, b) in zip(scene.elements, original.elements) {
        #expect(a.center.distance(to: b.center) < 0.01)
        #expect(abs(sin(a.rotation - b.rotation)) < 0.0001)
      }
    }

    @Test func resizingKeepsTheAnchorAndTheDrawing() {
      var scene = sampleScene()
      let box = scene["box"]!.frame
      scene.resizeFrame(to: CGSize(width: 600, height: 500), anchor: .center)
      #expect(scene.frame == CGRect(x: -100, y: -100, width: 600, height: 500))
      #expect(scene["box"]!.frame == box)
      scene.crop(to: CGRect(x: 100.4, y: 100, width: 50, height: 50))
      #expect(scene.frame == CGRect(x: 100, y: 100, width: 51, height: 50))
      #expect(scene["box"]!.frame == box)
    }

    @Test func withoutAFrameExportsCoverTheDrawing() {
      var scene = sampleScene()
      scene.frame = nil
      let content = scene.contentBounds
      let area = try! #require(scene.exportArea)
      #expect(area.contains(content) && area.width <= content.width + Paper.margin * 2 + 2)
      #expect(Scene().exportArea == nil)
      scene.fitFrameToDrawing()
      #expect(scene.frame == area)
      let image = Renderer.image(Scene(elements: scene.elements, files: scene.files))!
      #expect(image.width == Int(area.width) && image.height == Int(area.height))
    }

    @Test func oldFilesWithPaperOpenFramed() throws {
      let json = ##"{"type":"bristle","version":1,"paper":{"width":320,"height":200,"background":"#FFFFFF"},"elements":[]}"##
      let scene = try SceneFile.scene(from: Data(json.utf8))
      #expect(scene.frame == CGRect(x: 0, y: 0, width: 320, height: 200) && scene.paper.background == .white)
      let saved = try SceneFile.scene(from: SceneFile.data(scene))
      #expect(saved == scene)
    }
  }

  @Suite struct Tools {
    @Test func strokeEraserCutsStrokes() {
      var scene = Scene()
      var ink = Element(kind: .freehand)
      ink.strokeWidth = 4
      ink.setWorldPoints((0...40).map { CGPoint(x: CGFloat($0) * 5, y: 100) })
      scene.elements = [ink]
      let erased = scene.erase(along: [CGPoint(x: 100, y: 80), CGPoint(x: 100, y: 120)], radius: 6)
      #expect(erased)
      #expect(scene.elements.count == 2)
      #expect(scene.elements.allSatisfy { $0.kind == .freehand && $0.points.count >= 2 })
      #expect(scene.elements[0].bounds.maxX < 100 && scene.elements[1].bounds.minX > 100)
      #expect(scene.elementsTouched(by: [CGPoint(x: 20, y: 100)], radius: 4) == [scene.elements[0].id])
    }

    @Test func snappingPullsEdgesAndCentres() {
      let snapping = Snapping(targets: [CGRect(x: 100, y: 100, width: 50, height: 50)], threshold: 5)
      let result = snapping.snap(CGRect(x: 153, y: 300, width: 20, height: 20))
      #expect(result.offset == CGPoint(x: -3, y: 0))
      #expect(result.guides.count == 1)
      let centered = snapping.snap(CGRect(x: 114, y: 20, width: 20, height: 20))
      #expect(centered.offset.x == 1)
      let grid = Snapping(targets: [], threshold: 5, grid: 10).snap(CGPoint(x: 14, y: 26))
      #expect(grid.offset == CGPoint(x: -4, y: 4))
    }

    @Test func freehandSimplifiesWithoutChangingShape() {
      let points = (0...200).map { CGPoint(x: CGFloat($0), y: sin(CGFloat($0) / 20) * 30) }
      let (kept, _) = Freehand.simplify(points, pressures: [], tolerance: 0.3)
      #expect(kept.count < points.count / 3)
      #expect(kept.first == points.first && kept.last == points.last)
    }
  }

  @Suite struct Ink {
    /// Fills a stroke into a bitmap and returns whether every point along it is covered.
    func covered(_ points: [CGPoint], size: CGFloat, brush: Element.Brush) throws -> [CGPoint] {
      let pressures = Freehand.simulatedPressures(points, size: size)
      let path = Freehand.outline(points, pressures: pressures, size: size, brush: brush)
      let context = try #require(
        CGContext(
          data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.addPath(path)
      context.fillPath(using: .winding)
      let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      // Look away from the tapered ends, where the brush is thinnest.
      return points.dropFirst(8).dropLast(8).filter { p in
        let pixel = data + (299 - Int(p.y.rounded())) * context.bytesPerRow + Int(p.x.rounded()) * 4
        return pixel[3] < 250
      }
    }

    @Test func strokesThatTurnBackHaveNoHoles() throws {
      // A hairpin, then a zigzag with sharp corners, as a scribble makes.
      var points = (0...60).map { CGPoint(x: 40 + CGFloat($0) * 3, y: 60) }
      points += (0...60).map { CGPoint(x: 220 - CGFloat($0) * 3, y: 66) }
      for i in 0...12 { points.append(CGPoint(x: 40 + CGFloat(i) * 16, y: i % 2 == 0 ? 150 : 230)) }
      var dense: [CGPoint] = [points[0]]
      for p in points.dropFirst() {
        let last = dense[dense.count - 1]
        let steps = max(1, Int(last.distance(to: p) / 2))
        for k in 1...steps {
          let t = CGFloat(k) / CGFloat(steps)
          dense.append(CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
        }
      }
      // The airbrush sprays dots with space between, as it should.
      for brush in Element.Brush.allCases where brush != .airbrush {
        let gaps = try covered(dense, size: brush == .highlighter || brush == .calligraphy ? 24 : 10, brush: brush)
        #expect(gaps.isEmpty, "\(brush) left holes at \(gaps.prefix(5))")
      }
    }

    @Test func pixelsLandOnTheGridWithoutGaps() {
      let line = Freehand.pixels([CGPoint(x: 0.2, y: 0.2), CGPoint(x: 5.7, y: 0.1), CGPoint(x: 5.9, y: 3.2)], size: 1)
      #expect(line == (0...5).map { CGPoint(x: CGFloat($0) + 0.5, y: 0.5) } + (1...3).map { CGPoint(x: 5.5, y: CGFloat($0) + 0.5) })
      let big = Freehand.pixels([CGPoint(x: 3, y: 3), CGPoint(x: 3.5, y: 3.9)], size: 4)
      #expect(big == [CGPoint(x: 2, y: 2)])
      let path = Freehand.outline(line, size: 1, brush: .pixel)
      #expect(path.boundingBox == CGRect(x: 0, y: 0, width: 6, height: 4))
    }

    @Test func slowShakyStrokesHaveNoHoles() throws {
      // A slow drag, as when zoomed in: tiny steps that wobble back and forth.
      var seed: UInt64 = 3
      func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(seed >> 11) / CGFloat(1 << 53) - 0.5
      }
      var raw: [CGPoint] = []
      for i in 0..<600 {
        let t = CGFloat(i) / 600 * .pi * 1.6
        raw.append(CGPoint(x: 150 + cos(t) * 90 + random() * 3, y: 150 + sin(t) * 90 + random() * 3))
      }
      for brush in Element.Brush.allCases where brush != .airbrush {
        let size: CGFloat = brush == .highlighter || brush == .calligraphy ? 24 : 12
        let (points, _) = Freehand.smoothed(raw)
        let gaps = try covered(points, size: size, brush: brush)
        #expect(gaps.isEmpty, "\(brush) left \(gaps.count) holes, at \(gaps.prefix(3))")
      }
    }
  }

  @Suite struct Output {
    @Test func pngShowsWhatWasDrawn() throws {
      let image = try #require(Renderer.image(sampleScene()))
      #expect(image.width == 400 && image.height == 300)
      let context = try #require(
        CGContext(
          data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 300))
      let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      // The red box's middle; bitmap rows run from the top, as the canvas does.
      let row = 70, column = 80
      let pixel = data + row * context.bytesPerRow + column * 4
      #expect(pixel[0] > 240 && pixel[1] < 80 && pixel[2] < 80)
    }

    @Test func svgIsWellFormed() throws {
      let svg = SVG.document(sampleScene())
      let parser = XMLParser(data: svg)
      #expect(parser.parse())
      let text = String(decoding: svg, as: UTF8.self)
      #expect(text.contains("<tspan") && text.contains("Second line") && text.contains("&quot;Bristle&quot;"))
      #expect(text.contains("#FF3B30"))
    }

    @Test func pdfHasOnePageThePaperSize() throws {
      let data = Renderer.pdf(sampleScene())
      let provider = try #require(CGDataProvider(data: data as CFData))
      let pdf = try #require(CGPDFDocument(provider))
      #expect(pdf.numberOfPages == 1)
      #expect(pdf.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 400, height: 300))
    }

    @Test func descriptionsReadNaturally() {
      let scene = sampleScene()
      #expect(scene["box"]!.summary == "Red rectangle, 120 by 80")
      #expect(scene["label"]!.summary.hasPrefix("Text: Hello"))
    }
  }
}
