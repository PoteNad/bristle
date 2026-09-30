#if BRISTLE_CHECKS
  import AppKit
  import BristleCore
  import UniformTypeIdentifiers
  @testable import BristleCanvas

  /// End-to-end checks driven by environment variables, used by scripts/check.sh.
  @MainActor
  enum AppChecks {
    nonisolated static let environment = ProcessInfo.processInfo.environment

    static func fail(_ message: String) -> Never {
      fputs("Check failed: \(message)\n", stderr)
      exit(1)
    }

    /// Whether this launch is an automated check, which must not touch the user's drafts.
    nonisolated static var isChecking: Bool {
      [
        "BRISTLE_LAUNCH_CHECK", "BRISTLE_SAVE_CHECK", "BRISTLE_OPEN_CHECK", "BRISTLE_ROUNDTRIP_CHECK",
        "BRISTLE_STALE_CHECK", "BRISTLE_SESSION_PREPARE", "BRISTLE_SESSION_VERIFY", "BRISTLE_CLICK_CHECK",
        "BRISTLE_PERF_CHECK", "BRISTLE_SNAPSHOT", "BRISTLE_TOUR_CHECK", "BRISTLE_SCROLL_CHECK",
      ].contains { environment[$0] != nil }
    }

    /// The session check restores windows and drafts, so it runs in a copy of the app with its
    /// own bundle identifier, and keeps AppKit's restoration on.
    nonisolated static var restoresState: Bool { environment["BRISTLE_SESSION_VERIFY"] != nil }

    /// The session check runs in a copy of the app with an identifier of its own; afterwards it
    /// removes that copy's saved windows and settings, which only the app itself may delete, and
    /// any left by earlier runs.
    static func removeCheckState() {
      guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("io.github.PoteNad.bristle.checks") else { return }
      let states = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Saved Application State")
      for name in (try? FileManager.default.contentsOfDirectory(atPath: states.path)) ?? []
      where name.hasPrefix("io.github.PoteNad.bristle.checks") {
        try? FileManager.default.removeItem(at: states.appendingPathComponent(name))
      }
      UserDefaults.standard.removePersistentDomain(forName: id)
    }

    /// Discards every open document so no draft is left behind, then quits.
    static func finish() -> Never {
      for document in NSDocumentController.shared.documents {
        document.updateChangeCount(.changeCleared)
        document.autosavedContentsFileURL.map { try? FileManager.default.removeItem(at: $0) }
        document.close()
      }
      exit(0)
    }

    static func pass(_ message: String) {
      print("Check passed: \(message)")
      fflush(stdout)
    }

    /// The middle of what the canvas shows.
    static func middle(_ canvas: CanvasView) -> CGPoint {
      let visible = canvas.visibleRect
      return CGPoint(x: visible.midX.rounded(), y: visible.midY.rounded())
    }

    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(body) }
    }

    static func run(controller: BristleDocumentController) {
      if environment["BRISTLE_LAUNCH_CHECK"] == "1" { launchCheck(controller) }
      if let path = environment["BRISTLE_SAVE_CHECK"] { saveCheck(path, controller) }
      if let path = environment["BRISTLE_OPEN_CHECK"] { openCheck(path, controller) }
      if let path = environment["BRISTLE_ROUNDTRIP_CHECK"] { roundTripCheck(path, controller) }
      if let path = environment["BRISTLE_STALE_CHECK"] { staleCheck(path, controller) }
      if environment["BRISTLE_SESSION_PREPARE"] == "1" { sessionPrepare(controller) }
      if environment["BRISTLE_SESSION_VERIFY"] == "1" { sessionVerify(controller) }
      if environment["BRISTLE_CLICK_CHECK"] == "1" { clickCheck(controller) }
      if environment["BRISTLE_PERF_CHECK"] == "1" { performanceCheck(controller) }
      if environment["BRISTLE_TOUR_CHECK"] == "1" { tourCheck(controller) }
      if environment["BRISTLE_SCROLL_CHECK"] == "1" { scrollCheck(controller) }
      if let path = environment["BRISTLE_SNAPSHOT"] { snapshot(path, controller) }
    }

    static func firstDocument(_ controller: BristleDocumentController) -> BristleDocument {
      guard let document = controller.documents.first as? BristleDocument, let editor = document.editor else {
        fail("expected a document window")
      }
      // A small window, as on a small screen, when asked for.
      if let size = environment["BRISTLE_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
        !(editor.window.map { abs($0.contentLayoutRect.width - size[0]) < 1 } ?? true)
      {
        editor.window?.setContentSize(NSSize(width: size[0], height: size[1]))
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.canvas.showDrawing()
      }
      editor.window?.makeKeyAndOrderFront(nil)
      editor.window?.makeFirstResponder(editor.canvas)
      // Checks can't take focus from whatever app is in front, so the canvas takes clicks anyway.
      editor.canvas.acceptsFirstClick = true
      return document
    }

    // MARK: Events

    /// Sends a real mouse event to a point in a view, as a person's click would arrive.
    static func send(
      _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = [],
      clicks: Int = 1
    ) {
      guard let window = view.window else { fail("the view isn't in a window") }
      let location = view.convert(point, to: nil)
      guard
        let event = NSEvent.mouseEvent(
          with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
          pressure: type == .leftMouseUp ? 0 : 1)
      else { fail("could not make an event") }
      // Events sent in one turn of the run loop would share an undo group, so group each
      // gesture as separate events from a person are grouped.
      let undo = window.undoManager
      if type == .leftMouseDown, let undo {
        // Close the group AppKit opened for this turn of the run loop, then group by hand.
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
      }
      window.sendEvent(event)
      if type == .leftMouseUp, let undo { finishGroup(undo) }
    }

    /// Runs an edit made outside any event in its own undo group, as a menu command would get.
    static func grouped(_ undo: UndoManager, _ body: () -> Void) {
      undo.groupsByEvent = false
      undo.beginUndoGrouping()
      body()
      undo.endUndoGrouping()
      undo.groupsByEvent = true
    }

    static func finishGroup(_ undo: UndoManager) {
      guard !undo.groupsByEvent else { return }
      while undo.groupingLevel > 0 { undo.endUndoGrouping() }
      undo.groupsByEvent = true
    }

    static func click(_ point: CGPoint, in view: NSView, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
      guard let window = view.window else { fail("the view isn't in a window") }
      let location = view.convert(point, to: nil)
      // Buttons track the mouse until it's released, so the release waits in the queue first.
      if let up = NSEvent.mouseEvent(
        with: .leftMouseUp, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)
      {
        NSApp.postEvent(up, atStart: false)
      }
      send(.leftMouseDown, at: point, in: view, flags: flags, clicks: clicks)
      // Deliver the queued release now if nothing tracking the mouse took it.
      while let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        window.sendEvent(event)
      }
      if let undo = window.undoManager { finishGroup(undo) }
    }

    static func drag(
      _ points: [CGPoint], in view: NSView, flags: NSEvent.ModifierFlags = [], display: Bool = false
    ) {
      send(.leftMouseDown, at: points[0], in: view, flags: flags)
      for p in points.dropFirst() {
        send(.leftMouseDragged, at: p, in: view, flags: flags)
        if display { view.displayIfNeeded() }
      }
      send(.leftMouseUp, at: points.last!, in: view, flags: flags)
    }

    /// Whether two frames match to within a hundredth of a point, as pointer positions
    /// converted through the zoom rarely come out exact.
    static func same(_ a: CGRect?, _ b: CGRect) -> Bool {
      guard let a else { return false }
      return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01
        && abs(a.height - b.height) < 0.01
    }

    static func line(from a: CGPoint, to b: CGPoint, steps: Int = 12) -> [CGPoint] {
      (0...steps).map { i in
        let t = CGFloat(i) / CGFloat(steps)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
      }
    }

    // MARK: Launching

    private static func launchCheck(_ controller: BristleDocumentController) {
      after(1.5) {
        let windows = controller.documents.flatMap(\.windowControllers).compactMap(\.window)
        guard controller.documents.count == 1, windows.count == 1, windows[0].isVisible else {
          fail("expected one visible untitled window, found \(controller.documents.count) documents")
        }
        let document = firstDocument(controller)
        let editor = document.editor!
        guard windows[0].firstResponder === editor.canvas else { fail("the canvas should have keyboard focus") }
        guard !document.isDocumentEdited else { fail("a blank drawing shouldn't ask to be saved") }
        let menus = NSApp.mainMenu!.items.compactMap(\.submenu?.title)
        guard menus == ["Bristle", "File", "Edit", "Format", "Arrange", "Canvas", "View", "Window", "Help"] else {
          fail("unexpected menus \(menus)")
        }
        let toolbar = windows[0].toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let tools = editor.toolButtons.map { $0.button.accessibilityLabel() ?? "" }
        guard toolbar.filter({ !$0.hasPrefix("NSToolbar") && !$0.hasPrefix("gap") }) == ["select", "paint", "shapes", "insert", "share", "palette"],
          tools == ["Select", "Draw", "Eraser", "Fill", "Pick Color", "Rectangle", "Ellipse", "Shapes", "Line", "Arrow", "Text", "Image"],
          editor.currentSlot == .select
        else { fail("the toolbar should hold the tools and Share: \(toolbar)") }
        guard !editor.paletteVisible, !editor.zoomBar.bar.isHidden,
          document.drawing.scene.paper == Paper(), document.drawing.scene.paper.size == CGSize(width: 1200, height: 800)
        else { fail("a new window should show a white 1200 × 800 canvas with only the zoom bar") }
        // The canvas sits in the middle of the space the toolbar and the bars leave.
        let visible = editor.canvas.visibleRect
        guard visible.contains(document.drawing.scene.canvas) || editor.canvas.magnification < 1 else {
          fail("a new canvas should be shown whole, visible \(visible)")
        }
        controller.newWindowForTab(nil)
        after(1) {
          guard controller.documents.count == 2, windows[0].tabbedWindows?.count == 2 else {
            fail("New Tab should add a tab to the window")
          }
          (windows[0].tabGroup?.selectedWindow ?? NSApp.keyWindow)?.performClose(nil)
          after(0.5) {
            guard controller.documents.count == 1 else { fail("closing a tab should close only that tab") }
            pass("one window opens with the canvas focused, the menus, the tools in the toolbar, and tabs open and close")
            finish()
          }
        }
      }
    }

    // MARK: Saving and opening

    private static func saveCheck(_ folder: String, _ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let canvas = document.editor!.canvas
        canvas.tool = .rectangle
        let start = middle(canvas)
        drag(line(from: start, to: CGPoint(x: start.x + 160, y: start.y + 90)), in: canvas)
        canvas.tool = .pen
        drag(line(from: CGPoint(x: start.x - 200, y: start.y), to: CGPoint(x: start.x - 20, y: start.y + 60), steps: 30), in: canvas)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        guard canvas.scene.elements.count == 2, document.isDocumentEdited else {
          fail("drawing should add a rectangle and a stroke, not \(canvas.scene.elements.map(\.kind))")
        }
        let drawn = canvas.scene
        let bristle = URL(fileURLWithPath: folder).appendingPathComponent("Drawing.bristle")
        let png = URL(fileURLWithPath: folder).appendingPathComponent("Drawing.png")
        document.save(to: bristle, ofType: UTType.bristle.identifier, for: .saveAsOperation) { error in
          MainActor.assumeIsolated {
            if let error { fail("saving a drawing failed: \(error)") }
            guard !document.isDocumentEdited, let data = FileManager.default.contents(atPath: bristle.path),
              let reopened = try? SceneFile.scene(from: data), reopened.elements.map(\.kind) == [.rectangle, .freehand]
            else { fail("the saved drawing didn't reopen with its objects") }
            guard String(decoding: data, as: UTF8.self).hasPrefix("{\n  \"type\": \"bristle\",") else {
              fail("the file should be readable JSON")
            }
            document.save(to: png, ofType: UTType.png.identifier, for: .saveToOperation) { error in
              MainActor.assumeIsolated {
                if let error { fail("saving a PNG failed: \(error)") }
                guard let data = FileManager.default.contents(atPath: png.path), let embedded = EmbeddedScene(png: data),
                  embedded.isCurrent, embedded.scene.elements.map(\.id) == drawn.elements.map(\.id),
                  ImageStore.pixelSize(of: data) == drawn.canvas.size
                else { fail("the PNG should cover the drawing and carry it") }
                pass("drawings save as readable .bristle JSON and as PNGs that carry the drawing")
                finish()
              }
            }
          }
        }
      }
    }

    private static func openCheck(_ path: String, _ controller: BristleDocumentController) {
      // The file opens as if from Finder, during launch.
      controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, error in
        if let error { MainActor.assumeIsolated { fail("opening failed: \(error)") } }
      }
      after(2) {
        let documents = controller.documents.compactMap { $0 as? BristleDocument }
        guard documents.count == 1, documents[0].fileURL?.standardizedFileURL == URL(fileURLWithPath: path).standardizedFileURL
        else { fail("opening a file at launch should leave only that file, found \(documents.map(\.displayName))") }
        let scene = documents[0].drawing.scene
        guard scene.elements.count == 1, scene.elements[0].kind == .image, scene.elements[0].locked,
          scene.paper.background == nil, scene.canvas == scene.elements[0].frame
        else { fail("an image should open as the canvas, its own size, locked in place") }
        pass("opening an image at launch leaves no untitled window, and the image becomes the canvas")
        finish()
      }
    }

    /// Opens a file, browses it without changing it, and saves: the bytes must not change.
    private static func roundTripCheck(_ path: String, _ controller: BristleDocumentController) {
      guard let original = FileManager.default.contents(atPath: path) else { fail("missing fixture \(path)") }
      after(0.5) {
        controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, error in
          MainActor.assumeIsolated {
            guard let document = document as? BristleDocument, let canvas = document.editor?.canvas else {
              fail("could not open \(path): \(String(describing: error))")
            }
            canvas.selectAll(nil)
            canvas.zoom(to: 2)
            canvas.selectNext(backwards: false)
            canvas.select([])
            canvas.zoomToFit(nil)
            document.updateChangeCount(.changeDone)
            let type = document.fileType ?? UTType.png.identifier
            document.save(to: URL(fileURLWithPath: path), ofType: type, for: .saveOperation) { error in
              MainActor.assumeIsolated {
                if let error { fail("saving failed: \(error)") }
                guard FileManager.default.contents(atPath: path) == original else {
                  fail("saving an unedited \((path as NSString).pathExtension) file changed its bytes")
                }
                pass("opening and saving an unedited \((path as NSString).pathExtension) file kept it byte-identical")
                finish()
              }
            }
          }
        }
      }
    }

    /// A Bristle PNG whose pixels were changed elsewhere opens as the image it is now.
    private static func staleCheck(_ folder: String, _ controller: BristleDocumentController) {
      // A Bristle PNG whose drawing chunk was carried onto different pixels, as an editor that
      // ignores the PNG rules would leave it.
      var scene = Scene(paper: Paper(size: CGSize(width: 300, height: 200)))
      var box = Element(kind: .rectangle)
      box.frame = CGRect(x: 20, y: 20, width: 100, height: 60)
      var ring = Element(kind: .ellipse)
      ring.frame = CGRect(x: 150, y: 40, width: 80, height: 80)
      scene.elements = [box, ring]
      var other = scene
      other.paper.background = Color(hex: "#FF0000")
      guard let saved = EmbeddedScene.png(scene),
        let chunk = PNG.chunks(saved)?.first(where: { $0.type == PNG.sceneChunk }),
        let image = Renderer.image(other), let changed = Renderer.png(image), var chunks = PNG.chunks(changed)
      else { fail("could not make the changed PNG") }
      chunks.insert(chunk, at: chunks.count - 1)
      let path = (folder as NSString).appendingPathComponent("Changed.png")
      FileManager.default.createFile(atPath: path, contents: PNG.write(chunks))
      after(0.5) {
        controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, error in
          MainActor.assumeIsolated {
            guard let document = document as? BristleDocument else {
              fail("could not open the changed PNG: \(String(describing: error))")
            }
            let scene = document.drawing.scene
            guard scene.elements.count == 1, scene.elements[0].kind == .image else {
              fail("a changed PNG should open as its current pixels, not \(scene.elements.map(\.kind))")
            }
            after(1) {
              guard let sheet = document.windowControllers.first?.window?.attachedSheet else {
                fail("Bristle should offer to restore the earlier objects")
              }
              // Choose Restore Objects.
              let buttons = allButtons(in: sheet.contentView)
              guard let restore = buttons.first(where: { $0.title == "Restore Objects" }) else {
                fail("the sheet should offer Restore Objects: \(buttons.map(\.title))")
              }
              restore.performClick(nil)
              after(0.5) {
                guard document.drawing.scene.elements.count > 1 else { fail("restoring should bring the objects back") }
                document.undoManager?.undo()
                guard document.drawing.scene.elements.count == 1 else { fail("restoring should be undoable") }
                pass("a PNG changed elsewhere opens as it is now, and its earlier objects can be restored and undone")
                finish()
              }
            }
          }
        }
      }
    }

    static func allViews(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    static func allButtons(in view: NSView?) -> [NSButton] {
      guard let view else { return [] }
      return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(allButtons)
    }

    // MARK: Restoring

    private static func sessionPrepare(_ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let canvas = document.editor!.canvas
        canvas.tool = .ellipse
        let c = middle(canvas)
        drag(line(from: c, to: CGPoint(x: c.x + 120, y: c.y + 80)), in: canvas)
        guard canvas.scene.elements.count == 1 else {
          fail("drawing an ellipse failed: visible \(canvas.visibleRect), tool \(canvas.tool), window \(String(describing: canvas.window?.frame))")
        }
        // Quitting keeps the unsaved drawing as a draft, as AppKit does for every document app.
        NSApp.terminate(nil)
      }
    }

    private static func sessionVerify(_ controller: BristleDocumentController) {
      after(3) {
        let documents = controller.documents.compactMap { $0 as? BristleDocument }
        guard documents.count == 1, documents[0].drawing.scene.elements.map(\.kind) == [.ellipse] else {
          fail("the unsaved drawing should come back after quitting, found \(documents.map { $0.drawing.scene.elements.map(\.kind) })")
        }
        pass("an unsaved drawing is kept when quitting and comes back on the next launch")
        removeCheckState()
        finish()
      }
    }

    // MARK: Clicking

    private static func clickCheck(_ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let editor = document.editor!
        let canvas = editor.canvas
        let undo = document.undoManager!
        // The drags below reach far, so the canvas is large, and they stay inside the window at
        // this zoom.
        let big = Scene(paper: Paper(size: CGSize(width: 1800, height: 1400)))
        canvas.drawing.replace(big)
        canvas.zoom(to: 0.6)
        canvas.center(on: CGPoint(x: 900, y: 700))
        let c = middle(canvas)
        @MainActor func press(_ button: NSView) {
          button.window?.contentView?.layoutSubtreeIfNeeded()
          click(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        }
        @MainActor func barButton(_ bar: Bar, _ tip: String) -> NSButton {
          editor.window?.contentView?.layoutSubtreeIfNeeded()
          guard let button = bar.buttons.first(where: { $0.toolTip?.hasPrefix(tip) == true }) else {
            fail("the \(bar.accessibilityLabel() ?? "") bar should have \(tip): \(bar.buttons.compactMap(\.toolTip))")
          }
          return button
        }

        // Coloring the canvas is an edit like any other, however it's done.
        @MainActor func edited(_ name: String, _ body: () -> Void) {
          document.updateChangeCount(.changeCleared)
          body()
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
          guard document.isDocumentEdited else { fail("\(name) should mark the drawing edited") }
        }
        edited("filling the canvas") {
          canvas.tool = .fill
          canvas.styles[.fill, default: Tool.fill.defaultStyle].stroke = Color(hex: "#FF3B30")
          click(canvas.scene.canvas.center, in: canvas)
        }
        guard canvas.scene.paper.background == Color(hex: "#FF3B30") else { fail("the fill tool should colour the canvas") }
        edited("choosing a background") {
          let item = NSMenuItem(title: "Transparent", action: #selector(Editor.chooseBackground(_:)), keyEquivalent: "")
          item.tag = 0
          grouped(undo) { editor.chooseBackground(item) }
        }
        guard canvas.scene.paper.background == nil else { fail("Canvas ▸ Background ▸ Transparent should clear the canvas") }
        edited("a background swatch in the Palette") {
          canvas.tool = .select
          editor.togglePalette(nil)
          editor.window?.contentView?.layoutSubtreeIfNeeded()
          guard let swatch = allButtons(in: editor.palette.view).first(where: {
            $0 is SwatchButton && !["Transparent", "White", "Other Colors…"].contains($0.toolTip ?? "")
          }) else {
            fail("the Palette should offer background colours")
          }
          press(swatch)
        }
        edited("the canvas's width in the Palette") {
          guard let field = allViews(in: editor.palette.view).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Canvas width" })
          else { fail("the Palette should have the canvas's width") }
          field.doubleValue = 900
          grouped(undo) { _ = field.sendAction(field.action, to: field.target) }
          guard canvas.scene.paper.size == CGSize(width: 900, height: 1400) else {
            fail("setting the width should resize the canvas, got \(canvas.scene.paper.size)")
          }
        }
        editor.togglePalette(nil)
        grouped(undo) { canvas.drawing.edit("Reset") { $0 = big } }
        canvas.tool = .select
        document.updateChangeCount(.changeCleared)
        pass("colouring and resizing the canvas mark the drawing edited, however it's done")

        // Every tool in the toolbar acts when clicked: the toolbar sends each tool's own action.
        for (slot, button) in editor.toolButtons where slot != .image {
          // On a small screen some groups are in the toolbar's overflow menu, not in the window.
          if button.window != nil {
            click(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
          } else if let action = button.action {
            NSApp.sendAction(action, to: button.target, from: button)
          }
          guard editor.currentSlot == slot, button.isOn else {
            fail("clicking \(button.accessibilityLabel() ?? "") chose \(canvas.tool) instead")
          }
        }
        // Draw shows the brushes, widths, and color in the bar at the bottom, and they respond to clicks.
        editor.choose(.draw)
        guard Controls.brushes.contains(canvas.tool), !editor.styleBar.bar.isHidden else {
          fail("Draw should choose a brush and show the style bar")
        }
        // The bar's brush menu lists every brush and chooses one.
        @MainActor func chooseBrush(_ title: String) {
          let menu = editor.styleBar.brushMenu()
          guard let index = menu.items.firstIndex(where: { $0.title.components(separatedBy: "\t")[0] == title }) else {
            fail("the brush menu should offer \(title): \(menu.items.map(\.title))")
          }
          menu.performActionForItem(at: index)
          editor.window?.contentView?.layoutSubtreeIfNeeded()
        }
        guard editor.styleBar.brushMenu().items.map({ $0.title.components(separatedBy: "\t")[0] }) == Controls.brushes.map(\.title) else {
          fail("the brush menu should list every brush")
        }
        chooseBrush("Pencil")
        guard canvas.tool == .pencil, barButton(editor.styleBar.bar, "Brush: Pencil").toolTip == "Brush: Pencil" else {
          fail("choosing Pencil from the bar should choose the pencil and show it")
        }
        chooseBrush("Brush")
        press(barButton(editor.styleBar.bar, "Bold"))
        guard canvas.tool == .pen, canvas.style.strokeWidth == Controls.widths(for: .pen)[2] else {
          fail("clicking Brush and Bold in the bar should choose the brush at its boldest, got \(canvas.tool) \(canvas.style.strokeWidth)")
        }
        press(barButton(editor.styleBar.bar, "Medium"))
        editor.choose(.select)
        editor.styleBar.update()
        guard !editor.styleBar.bar.isHidden, (barButton(editor.styleBar.bar, "Box Selection") as? BarButton)?.isOn == true else {
          fail("Select with nothing selected should offer box and free-form selection")
        }
        // The brush button slides the Palette in and away. Zoomed in, the view keeps its place;
        // zoomed out, the canvas stays in the middle.
        canvas.zoom(to: 1)
        guard let brush = editor.window?.toolbar?.items.first(where: { $0.itemIdentifier == Editor.paletteToolbarItem }),
          let action = brush.action
        else { fail("the toolbar should have the Palette button") }
        NSApp.sendAction(action, to: brush.target, from: brush)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        guard editor.paletteVisible, editor.palette.sectionTitles.first == "Canvas" else {
          fail("the brush button should show the Palette with the canvas's settings: \(editor.palette.sectionTitles)")
        }
        let before = middle(canvas)
        NSApp.sendAction(action, to: brush.target, from: brush)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        guard !editor.paletteVisible else { fail("the brush button should hide the Palette again") }
        guard abs(middle(canvas).x - before.x) <= 3, abs(middle(canvas).y - before.y) <= 3 else {
          fail("the view should stay centred on the same place when the Palette comes and goes: \(before) → \(middle(canvas))")
        }
        canvas.zoom(to: 0.4)
        for _ in 0..<2 {
          NSApp.sendAction(action, to: brush.target, from: brush)
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
          // Along each side where the canvas fits, it stays in the middle.
          let room = canvas.unobscuredRect, page = canvas.scene.canvas
          let pad = 2 * CanvasView.handleRoom / canvas.magnification
          guard page.width + pad > room.width || abs(room.midX - page.midX) < 4, page.height + pad > room.height || abs(room.midY - page.midY) < 4 else {
            fail("a canvas that fits should stay in the middle as the Palette comes and goes: \(room)")
          }
        }
        // After the view resizes, moving it elsewhere sticks, when the canvas is bigger than the view.
        let restore = canvas.unobscuredRect.center
        canvas.zoom(to: 2)
        let zoomed = canvas.unobscuredRect.center
        canvas.center(on: CGPoint(x: zoomed.x + 50, y: zoomed.y + 30))
        let recentred = canvas.unobscuredRect.center
        guard abs(recentred.x - zoomed.x - 50) <= 1, abs(recentred.y - zoomed.y - 30) <= 1 else {
          fail("centring the view after it resized should stick, got \(recentred) from \(zoomed)")
        }
        canvas.zoom(to: 0.6)
        canvas.center(on: restore)
        guard canvas.unobscuredRect.center.distance(to: restore) <= 2 else {
          fail("zooming out and back should return to the same place, got \(canvas.unobscuredRect.center) from \(restore)")
        }
        editor.choose(.draw)
        pass("every toolbar tool and the drawing bar respond to clicks, and the Palette comes and goes without moving the view")

        // Draw, undo, redo.
        let points = (0...40).map { CGPoint(x: c.x - 200 + CGFloat($0) * 8, y: c.y + sin(CGFloat($0) / 5) * 40) }
        drag(points, in: canvas)
        guard canvas.scene.elements.count == 1, let stroke = canvas.scene.elements.first, stroke.kind == .freehand,
          stroke.brush == .pen, stroke.pressures.count == stroke.points.count
        else { fail("dragging with the brush should draw one stroke") }
        undo.undo()
        guard canvas.scene.elements.isEmpty else { fail("undo should remove the stroke") }
        undo.redo()
        guard canvas.scene.elements.first?.id == stroke.id else { fail("redo should restore the same stroke") }

        // Keys choose tools; a rectangle is drawn, clicked, moved, and resized.
        canvas.window?.makeFirstResponder(canvas)
        @MainActor func key(_ character: String, code: UInt16) {
          let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: canvas.window!.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
          NSApp.sendEvent(event)
        }
        key("r", code: 15)
        guard canvas.tool == .rectangle else { fail("R should choose the rectangle tool") }
        let box = CGRect(x: c.x - 100, y: c.y + 120, width: 200, height: 100)
        drag(line(from: box.origin, to: CGPoint(x: box.maxX, y: box.maxY)), in: canvas)
        guard let rect = canvas.scene.elements.last, rect.kind == .rectangle, same(rect.frame, box) else {
          fail("dragging should draw a rectangle at \(box), got \(String(describing: canvas.scene.elements.last?.frame))")
        }
        key("v", code: 9)
        guard canvas.tool == .select else { fail("V should choose Select") }
        // An unfilled rectangle is picked at its outline, not its middle.
        click(box.center, in: canvas)
        guard canvas.drawing.selection.isEmpty else { fail("clicking inside an unfilled rectangle shouldn't select it") }
        click(CGPoint(x: box.minX + 40, y: box.minY), in: canvas)
        guard canvas.drawing.selection == [rect.id] else { fail("clicking a rectangle's edge should select it") }
        editor.styleBar.update()
        guard !editor.styleBar.bar.isHidden else { fail("selecting a rectangle should show the style bar") }
        // A real click on the stroke swatch opens the colors above it; a click on red colors the selection.
        press(barButton(editor.styleBar.bar, "Stroke Color"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let popover = editor.styleBar.popover, popover.isShown, let colors = popover.contentViewController?.view,
          let red = allButtons(in: colors).first(where: { $0.toolTip == "Red" })
        else { fail("clicking the stroke swatch should show the colors") }
        let swatchTop = barButton(editor.styleBar.bar, "Stroke Color").window!.convertToScreen(
          barButton(editor.styleBar.bar, "Stroke Color").convert(barButton(editor.styleBar.bar, "Stroke Color").bounds, to: nil)).maxY
        guard let popoverWindow = colors.window, popoverWindow.frame.minY >= swatchTop - 1,
          let editorWindow = editor.window, editorWindow.frame.contains(popoverWindow.frame)
        else { fail("the colors should open above the bar, inside the window") }
        press(red)
        guard canvas.scene[rect.id]?.stroke == Color(hex: "#FF3B30") else {
          fail("clicking red should color the rectangle, got \(String(describing: canvas.scene[rect.id]?.stroke))")
        }
        popover.close()
        undo.undo()
        press(barButton(editor.styleBar.bar, "Bold"))
        guard canvas.scene[rect.id]?.strokeWidth == Controls.widths(for: .line)[2] else { fail("clicking Bold should thicken the rectangle") }
        undo.undo()
        pass("the style bar changes a selection's color and width with real clicks, its colors opening above it")
        drag(line(from: CGPoint(x: box.minX + 40, y: box.minY), to: CGPoint(x: box.minX + 77, y: box.minY + 23)), in: canvas, flags: .command)
        guard same(canvas.scene[rect.id]?.frame, box.offsetBy(dx: 37, dy: 23)) else {
          fail("dragging should move the rectangle, got \(String(describing: canvas.scene[rect.id]?.frame))")
        }
        let moved = canvas.scene[rect.id]!.frame
        let corner = CGPoint(x: moved.maxX, y: moved.maxY)
        drag(line(from: corner, to: CGPoint(x: corner.x + 100, y: corner.y + 50)), in: canvas, flags: .command)
        guard let resized = canvas.scene[rect.id]?.frame, abs(resized.width - 300) < 0.5, abs(resized.height - 150) < 0.5,
          same(CGRect(origin: resized.origin, size: moved.size), moved)
        else { fail("dragging the corner handle should resize, got \(String(describing: canvas.scene[rect.id]?.frame))") }
        undo.undo()
        guard same(canvas.scene[rect.id]?.frame, moved) else { fail("undo should undo the resize") }
        undo.undo()
        guard same(canvas.scene[rect.id]?.frame, box) else { fail("undo should undo the move") }
        pass("drawing, undo, tool keys, picking at outlines, moving and resizing work with the pointer")

        // Dragging across empty canvas selects what it touches; Shift-clicking removes one.
        let far = CGPoint(x: c.x - 320, y: c.y - 200)
        drag(line(from: far, to: CGPoint(x: c.x + 300, y: c.y + 300)), in: canvas)
        guard canvas.drawing.selection == [stroke.id, rect.id] else { fail("the marquee should select both objects") }
        click(CGPoint(x: box.minX + 40, y: box.minY), in: canvas, flags: .shift)
        guard canvas.drawing.selection == [stroke.id] else { fail("Shift-click should remove the rectangle from the selection") }

        // Group, then Option-drag copies the group.
        canvas.selectAll(nil)
        grouped(undo) { canvas.group(nil) }
        click(CGPoint(x: box.minX + 40, y: box.minY), in: canvas)
        guard canvas.drawing.selection == [stroke.id, rect.id] else { fail("clicking one member should select the group") }
        drag(line(from: CGPoint(x: box.minX + 40, y: box.minY), to: CGPoint(x: box.minX, y: box.midY + 300)), in: canvas, flags: [.option, .command])
        guard canvas.scene.elements.count == 4, same(canvas.scene[rect.id]?.frame, box) else {
          fail("Option-dragging should leave the group and move a copy")
        }
        // Double-clicking into the group picks just the one element.
        click(CGPoint(x: box.minX + 40, y: box.minY), in: canvas)
        click(CGPoint(x: box.minX + 40, y: box.minY), in: canvas, clicks: 2)
        guard canvas.drawing.selection == [rect.id] else { fail("double-clicking should enter the group") }
        pass("marquee, Shift-click, grouping, Option-drag copies, and entering groups work")

        // An arrow drawn from the rectangle to a new ellipse stays attached when the ellipse moves.
        canvas.tool = .ellipse
        let ring = CGRect(x: c.x + 250, y: c.y + 140, width: 120, height: 80)
        drag(line(from: ring.origin, to: CGPoint(x: ring.maxX, y: ring.maxY)), in: canvas)
        let ellipseID = canvas.scene.elements.last!.id
        canvas.tool = .arrow
        drag(line(from: CGPoint(x: box.midX, y: box.midY), to: ring.center, steps: 20), in: canvas)
        guard let arrow = canvas.scene.elements.last, arrow.kind == .arrow, arrow.startBinding?.element == rect.id,
          arrow.endBinding?.element == ellipseID
        else { fail("the arrow should attach to both shapes") }
        grouped(undo) { canvas.drawing.edit("Move") { $0.move([ellipseID], dx: 0, dy: 150) } }
        guard let followed = canvas.scene[arrow.id]?.worldPoints.last, followed.y > arrow.worldPoints.last!.y + 100 else {
          fail("the arrow should follow the ellipse")
        }
        pass("arrows attach to shapes and follow them")

        // Text: click to type, then the text is an element.
        canvas.tool = .text
        click(CGPoint(x: c.x - 300, y: c.y - 150), in: canvas)
        guard let typing = canvas.textEditor else { fail("clicking with the text tool should start typing") }
        typing.insertText("Hello, Bristle", replacementRange: typing.selectedRange())
        grouped(undo) {
          canvas.window?.makeFirstResponder(canvas)
          canvas.endTextEditing()
        }
        guard let text = canvas.scene.elements.last, text.kind == .text, text.text == "Hello, Bristle", text.width > 60 else {
          fail("typing should make a text element that fits its text")
        }
        undo.undo()
        guard !canvas.scene.elements.contains(where: { $0.kind == .text }) else { fail("undo should remove the new text") }
        pass("text is typed in place and undone in one step")

        // Fill and eyedropper.
        canvas.tool = .fill
        click(ring.center.applying(CGAffineTransform(translationX: 0, y: 150)), in: canvas)
        guard canvas.scene[ellipseID]?.fill != nil else { fail("the fill tool should fill the ellipse") }
        canvas.tool = .eyedropper
        click(ring.center.applying(CGAffineTransform(translationX: 0, y: 150)), in: canvas)
        guard canvas.tool == .fill, canvas.styles[.fill]?.stroke == canvas.scene[ellipseID]?.fill else {
          fail("the eyedropper should pick the fill color and return to the fill tool")
        }
        pass("the fill tool fills shapes and the eyedropper picks colors")

        // The pixel brush paints squares on the pixel grid, and the style popover sets any width.
        editor.choose(.draw)
        chooseBrush("Pixel")
        guard canvas.tool == .pixel else { fail("choosing Pixel should choose the pixel brush") }
        let dot = CGPoint(x: c.x - 250.3, y: c.y + 260.6)
        drag(line(from: dot, to: CGPoint(x: dot.x + 40, y: dot.y + 10)), in: canvas)
        guard let pixels = canvas.scene.elements.last, pixels.brush == .pixel, pixels.points.count == 41,
          pixels.worldPoints.allSatisfy({ $0.x - $0.x.rounded(.down) == 0.5 && $0.y - $0.y.rounded(.down) == 0.5 })
        else { fail("the pixel brush should paint a gapless run of pixels, got \(String(describing: canvas.scene.elements.last?.points.count))") }
        press(barButton(editor.styleBar.bar, "Style"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let style = editor.styleBar.popover, style.isShown,
          let slider = style.contentViewController?.view.subviews.first.flatMap({ allViews(in: $0) })?.compactMap({ $0 as? NSSlider }).first
        else { fail("the Style button should show a width slider") }
        slider.doubleValue = 5
        slider.sendAction(slider.action, to: slider.target)
        guard canvas.style.strokeWidth == 5 else { fail("the width slider should set the pixel size, got \(canvas.style.strokeWidth)") }
        style.close()
        canvas.setStyle("Width") { $0.strokeWidth = 1 }
        pass("the pixel brush paints on the pixel grid, and the style popover sets any width")

        // Calligraphy is thick across its nib and thin along it; the airbrush sprays dots.
        chooseBrush("Calligraphy")
        let nib = CGPoint(x: c.x - 250, y: c.y + 320)
        drag(line(from: nib, to: CGPoint(x: nib.x + 120, y: nib.y), steps: 20), in: canvas)
        guard let pen = canvas.scene.elements.last, pen.brush == .calligraphy else { fail("the calligraphy brush should draw") }
        chooseBrush("Airbrush")
        drag(line(from: CGPoint(x: nib.x, y: nib.y + 60), to: CGPoint(x: nib.x + 120, y: nib.y + 60), steps: 20), in: canvas)
        guard let spray = canvas.scene.elements.last, spray.brush == .airbrush else { fail("the airbrush should spray") }
        pass("the calligraphy brush and the airbrush draw from the brush menu")

        // A shape from the gallery is drawn with one drag and stays an editable polygon.
        canvas.tool = .polygon
        let shapes = editor.styleBar.shapeMenu()
        guard let star = shapes.items.firstIndex(where: { $0.title == "Star" }) else { fail("the shape menu should offer a star") }
        shapes.performActionForItem(at: star)
        let starBox = CGRect(x: c.x + 150, y: c.y + 300, width: 100, height: 90)
        drag(line(from: starBox.origin, to: CGPoint(x: starBox.maxX, y: starBox.maxY)), in: canvas, flags: .command)
        guard let drawn = canvas.scene.elements.last, drawn.kind == .polygon, drawn.points.count == 10, same(drawn.frame, starBox) else {
          fail("dragging with the star should draw a ten-cornered polygon filling the box, got \(String(describing: canvas.scene.elements.last?.frame))")
        }
        canvas.shapePreset = nil

        // A free-form loop selects what's inside it.
        canvas.tool = .select
        canvas.select([])
        editor.styleBar.update()
        press(barButton(editor.styleBar.bar, "Free-Form Selection"))
        guard canvas.lassoSelects else { fail("clicking Free-Form Selection should draw loops") }
        let loop = [
          CGPoint(x: starBox.minX - 20, y: starBox.minY - 20), CGPoint(x: starBox.maxX + 20, y: starBox.minY - 20),
          CGPoint(x: starBox.maxX + 20, y: starBox.maxY + 20), CGPoint(x: starBox.minX - 20, y: starBox.maxY + 20), CGPoint(x: starBox.minX - 20, y: starBox.minY - 10),
        ]
        drag(loop, in: canvas)
        guard canvas.drawing.selection == [drawn.id] else { fail("the loop should select the star alone, got \(canvas.drawing.selection)") }
        canvas.lassoSelects = false
        canvas.invertSelection(nil)
        guard !canvas.drawing.selection.contains(drawn.id), !canvas.drawing.selection.isEmpty else {
          fail("Invert Selection should select everything but the star")
        }
        canvas.select([])
        pass("shapes from the gallery, free-form selection, and Invert Selection work")

        // Every textured brush draws, from where the checks started, back in the middle.
        canvas.center(on: c)
        for (i, name) in ["Crayon", "Marker", "Watercolor", "Oil Brush"].enumerated() {
          chooseBrush(name)
          let y = c.y - 330 + CGFloat(i) * 30
          drag(line(from: CGPoint(x: c.x + 60, y: y), to: CGPoint(x: c.x + 200, y: y + 10), steps: 12), in: canvas)
          guard canvas.scene.elements.last?.brush.rawValue == Tool.allCases.first(where: { $0.title == name })?.brush?.rawValue else {
            fail("the \(name) should draw")
          }
        }
        canvas.displayIfNeeded()

        // A line is bent by dragging the middle of it.
        canvas.center(on: c)
        canvas.tool = .line
        let from = CGPoint(x: c.x - 340, y: c.y - 280), to = CGPoint(x: c.x - 200, y: c.y - 280)
        drag(line(from: from, to: to), in: canvas, flags: .command)
        guard let bent = canvas.scene.elements.last, bent.kind == .line, bent.points.count == 2 else { fail("the line tool should draw a line") }
        canvas.tool = .select
        canvas.select([bent.id])
        let middle = bent.segmentMiddle(0)
        drag(line(from: middle, to: CGPoint(x: middle.x, y: middle.y - 40)), in: canvas, flags: .command)
        guard let curved = canvas.scene[bent.id], curved.points.count == 3, abs(curved.worldPoints[1].y - (middle.y - 40)) < 1 else {
          fail("dragging a line's middle should bend it, got \(String(describing: canvas.scene[bent.id]?.worldPoints))")
        }

        // The Palette's Arrange tab places things exactly.
        editor.togglePalette(nil)
        editor.palette.tab = .arrange
        editor.palette.update()
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        guard let xField = allViews(in: editor.palette.view).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "X" }) else {
          fail("the Arrange tab should have a field for X")
        }
        let placed = canvas.scene.frameBounds(of: [bent.id])
        let origin: CGFloat = 0
        xField.doubleValue = Double((placed.minX - origin + 25).rounded())
        grouped(undo) { _ = xField.sendAction(xField.action, to: xField.target) }
        guard abs(canvas.scene.frameBounds(of: [bent.id]).minX - origin - (placed.minX - origin + 25).rounded()) < 0.5 else {
          fail("setting X should move the line, from \(placed.minX) to \(canvas.scene.frameBounds(of: [bent.id]).minX)")
        }
        editor.palette.tab = .style
        editor.togglePalette(nil)

        // The spectrum picks any colour in the window, one undo step for a drag.
        canvas.select([bent.id])
        editor.styleBar.update()
        press(barButton(editor.styleBar.bar, "Stroke Color"))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        guard let colors = editor.styleBar.popover?.contentViewController?.view,
          let spectrum = allViews(in: colors).compactMap({ $0 as? SpectrumView }).first
        else { fail("the colour popover should show the spectrum") }
        let strokeBefore = canvas.scene[bent.id]?.stroke
        drag(line(from: CGPoint(x: 30, y: 30), to: CGPoint(x: 150, y: 40), steps: 6), in: spectrum)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        guard let picked = canvas.scene[bent.id]?.stroke, picked != strokeBefore else { fail("dragging in the spectrum should colour the line") }
        editor.styleBar.popover?.close()
        undo.undo()
        guard canvas.scene[bent.id]?.stroke == strokeBefore else {
          let after1 = canvas.scene[bent.id]?.stroke
          undo.undo()
          fail("one undo should take back a spectrum drag: before \(String(describing: strokeBefore?.hex)), picked \(picked.hex), after one undo \(String(describing: after1?.hex)), after two \(String(describing: canvas.scene[bent.id]?.stroke?.hex)), names \(undo.undoActionName)")
        }
        canvas.select([])
        pass("textured brushes draw, lines bend by their middles, the Arrange tab places things, and the spectrum picks colours")

        // The canvas: its handles drag it bigger with any tool, and its edges with Select, as
        // MS Paint's do; undo puts it back.
        canvas.select([])
        canvas.tool = .pen
        let page = canvas.scene.canvas
        let corner2 = CGPoint(x: page.maxX, y: page.maxY)
        canvas.center(on: corner2)
        let strokes = canvas.scene.elements.count
        drag(line(from: corner2, to: CGPoint(x: corner2.x + 40, y: corner2.y + 30)), in: canvas)
        guard canvas.scene.paper.size == CGSize(width: page.width + 40, height: page.height + 30), canvas.scene.elements.count == strokes else {
          fail("dragging the canvas's corner handle should resize it, not draw, got \(canvas.scene.paper.size)")
        }
        undo.undo()
        guard canvas.scene.paper.size == page.size else { fail("undo should put the canvas's size back") }
        canvas.tool = .select
        let edge = CGPoint(x: page.maxX, y: page.maxY - 60)
        drag(line(from: edge, to: CGPoint(x: edge.x - 100, y: edge.y)), in: canvas)
        guard canvas.scene.paper.size == CGSize(width: page.width - 100, height: page.height) else {
          fail("dragging the canvas's right edge with Select should narrow it, got \(canvas.scene.paper.size)")
        }
        undo.undo()
        pass("the canvas resizes by its handles and edges, and undoes")

        document.updateChangeCount(.changeCleared)
        finish()
      }
    }

    // MARK: Performance

    private static func performanceCheck(_ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let canvas = document.editor!.canvas
        var scene = Scene(paper: Paper(size: CGSize(width: 8000, height: 6000)))
        var seed: UInt64 = 7
        @MainActor func random() -> CGFloat {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          return CGFloat(seed >> 11) / CGFloat(1 << 53)
        }
        for i in 0..<10_000 {
          var p = CGPoint(x: 100 + random() * 7800, y: 100 + random() * 5800)
          var angle = random() * .pi * 2
          var points: [CGPoint] = []
          for _ in 0..<(40 + Int(random() * 80)) {
            angle += (random() - 0.5) * 0.7
            p.x += cos(angle) * 3
            p.y += sin(angle) * 3
            points.append(p)
          }
          var e = Element(kind: i % 25 == 0 ? .rectangle : .freehand)
          if e.kind == .rectangle { e.frame = CGRect(origin: p, size: CGSize(width: 120, height: 80)) } else { e.setWorldPoints(points) }
          scene.elements.append(e)
        }
        canvas.drawing.replace(scene)
        canvas.zoom(to: 1)
        canvas.center(on: CGPoint(x: 4000, y: 3000))
        @MainActor func redraw() -> Double {
          let start = CACurrentMediaTime()
          canvas.setNeedsDisplay(canvas.visibleRect)
          canvas.displayIfNeeded()
          return (CACurrentMediaTime() - start) * 1000
        }
        _ = redraw()
        let actual = (0..<5).map { _ in redraw() }.sorted()[2]
        // Panning: each step shows a new strip of the drawing.
        @MainActor func pan() -> Double {
          let visible = canvas.visibleRect
          let start = CACurrentMediaTime()
          canvas.scroll(CGPoint(x: visible.minX + 37, y: visible.minY + 23))
          canvas.displayIfNeeded()
          return (CACurrentMediaTime() - start) * 1000
        }
        let panning = (0..<9).map { _ in pan() }.sorted()[4]
        canvas.tool = .pen
        // Choosing the tool shows the style bar, which redraws the window once; the stroke is timed after.
        canvas.window?.displayIfNeeded()
        let c = CGPoint(x: 4000, y: 3000)
        var slowest = 0.0
        send(.leftMouseDown, at: c, in: canvas)
        for i in 1...200 {
          send(.leftMouseDragged, at: CGPoint(x: c.x + CGFloat(i) * 2, y: c.y + sin(CGFloat(i) / 10) * 50), in: canvas)
          let start = CACurrentMediaTime()
          canvas.displayIfNeeded()
          slowest = max(slowest, (CACurrentMediaTime() - start) * 1000)
        }
        send(.leftMouseUp, at: CGPoint(x: c.x + 400, y: c.y), in: canvas)
        let undo = CACurrentMediaTime()
        document.undoManager?.undo()
        let undoTime = (CACurrentMediaTime() - undo) * 1000
        canvas.zoomToFit(nil)
        _ = redraw()
        let fit = (0..<3).map { _ in redraw() }.sorted()[1]
        print(String(format: "  10,000 objects: redraw at 100%% %.1f ms, panning %.1f ms, whole canvas %.1f ms, slowest frame drawing %.1f ms, undo %.1f ms", actual, panning, fit, slowest, undoTime))
        guard slowest < 16, actual < 50, panning < 16, undoTime < 100 else { fail("drawing on a large drawing is too slow") }
        pass("a drawing of 10,000 objects draws, strokes, and undoes quickly")
        document.updateChangeCount(.changeCleared)
        finish()
      }
    }

    // MARK: Snapshots

    /// Writes an image of the first window, for reviewing the interface without screen access.
    private static func snapshot(_ path: String, _ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let editor = document.editor!
        let canvas = editor.canvas
        if let open = environment["BRISTLE_OPEN"] {
          controller.openDocument(withContentsOf: URL(fileURLWithPath: open), display: true) { _, _, _ in }
        }
        if let width = environment["BRISTLE_WIDTH"].flatMap(Double.init) {
          editor.window?.setContentSize(NSSize(width: width, height: environment["BRISTLE_HEIGHT"].flatMap(Double.init) ?? 800))
        }
        after(1) {
          let target = (controller.documents.last as? BristleDocument)?.editor ?? editor
          if environment["BRISTLE_DEMO"] == "1" { demo(target.canvas) }
          if let tool = environment["BRISTLE_TOOL"].flatMap(Tool.init(rawValue:)) { target.canvas.tool = tool }
          if environment["BRISTLE_SCENARIO"] == "edit" {
            // A turned shape selected beside text being typed and an image being cropped.
            let c = target.canvas
            let shape = c.scene.elements.first { $0.kind == .rectangle }!
            c.drawing.edit("Rotate") { $0.rotate([shape.id], by: 0.35) }
            c.select([shape.id])
            let text = c.scene.elements.first { $0.kind == .text }!
            c.beginTextEditing(text.id)
          }
          if let size = environment["BRISTLE_CANVAS"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            target.canvas.drawing.edit("Canvas Size") { $0.paper.size = CGSize(width: size[0], height: size[1]) }
            target.canvas.showDrawing()
          }
          if environment["BRISTLE_SELECT"] == "all" { target.canvas.selectAll(nil) }
          if environment["BRISTLE_BRUSHES"] == "1" {
            // A stroke of every brush, one under another.
            let c = target.canvas
            var scene = Scene()
            let colors = ["#1D1D1F", "#FF3B30", "#FF9500", "#34C759", "#007AFF", "#AF52DE", "#FF2D55", "#5AC8FA", "#FFD60A", "#1D1D1F"]
            for (i, tool) in Controls.brushes.enumerated() {
              guard let brush = tool.brush else { continue }
              let raw = (0...80).map { k -> CGPoint in
                let t = CGFloat(k) / 80
                return CGPoint(x: 80 + t * 520, y: 60 + CGFloat(i) * 56 + sin(t * .pi * 2.5) * 16)
              }
              var e = Element(kind: .freehand)
              tool.defaultStyle.apply(to: &e)
              e.brush = brush
              e.stroke = Color(hex: colors[i])
              if brush == .pixel {
                e.strokeWidth = 4
                e.setWorldPoints(Freehand.pixels(raw, size: 4))
              } else {
                let pressures = brush.usesPressure ? Freehand.simulatedPressures(raw, size: e.strokeWidth) : []
                let (points, smooth) = Freehand.smoothed(raw, pressures: pressures)
                e.setWorldPoints(points)
                e.pressures = brush.usesPressure ? smooth : []
              }
              scene.elements.append(e)
              var label = Element(kind: .text)
              label.text = tool.title
              label.fontSize = 16
              label.stroke = Color(hex: "#6E6E73")
              label.x = 640
              label.y = 48 + CGFloat(i) * 56
              label.fitToText()
              scene.elements.append(label)
            }
            c.drawing.replace(scene)
            c.showDrawing()
          }
          if environment["BRISTLE_PIXELS"] == "1" {
            // A small pixel drawing, zoomed in far enough to show the pixel grid.
            let c = target.canvas
            var art = Element(kind: .freehand)
            art.brush = .pixel
            art.strokeWidth = 1
            art.stroke = Color(hex: "#FF3B30")
            let heart = ["01100110", "11111111", "11111111", "01111110", "00111100", "00011000"]
            var cells: [CGPoint] = []
            for (y, row) in heart.enumerated() {
              for (x, bit) in row.enumerated() where bit == "1" { cells.append(CGPoint(x: 1000.5 + CGFloat(x), y: 1000.5 + CGFloat(y))) }
            }
            art.setWorldPoints(cells)
            c.drawing.edit("Pixels") { $0.elements.append(art) }
            c.zoom(to: 16)
            c.center(on: CGPoint(x: 1004, y: 1003))
            c.tool = .pixel
          }
          if environment["BRISTLE_PALETTE"] == "1" { target.togglePalette(nil) }
          if environment["BRISTLE_TAB"] == "arrange" { target.palette.tab = .arrange }
          if let slot = environment["BRISTLE_SLOT"].flatMap(Int.init).flatMap(Editor.Slot.init(rawValue:)) { target.choose(slot) }
          if environment["BRISTLE_DRAW"] == "1" { target.choose(.draw) }
          if environment["BRISTLE_TYPE"] == "1" {
            target.canvas.tool = .text
            target.canvas.acceptsFirstClick = true
            click(middle(target.canvas), in: target.canvas)
            if let typing = target.canvas.textEditor {
              typing.insertText("Hello", replacementRange: typing.selectedRange())
            }
            if let zoom = environment["BRISTLE_ZOOM"].flatMap(Double.init) { target.canvas.zoom(to: zoom) }
          }
          if environment["BRISTLE_SELECT"] == "nothing" { target.canvas.select([]) }
          if let kind = environment["BRISTLE_SELECT"].flatMap(Element.Kind.init(rawValue:)),
            let element = target.canvas.scene.elements.first(where: { $0.kind == kind })
          {
            target.canvas.select([element.id])
          }
          if environment["BRISTLE_HOVER"] == "bar", let bar = target.window?.contentView {
            // The pointer just above the style bar, so its ring shows passing behind it.
            let point = NSPoint(x: bar.bounds.midX - 40, y: 64)
            target.canvas.styles[.eraser, default: Tool.eraser.defaultStyle].strokeWidth = 48
            target.canvas.hoverPoint = target.canvas.convert(point, from: nil)
          }
          if let preset = environment["BRISTLE_SHAPE"].flatMap(ShapePreset.init(rawValue:)) {
            target.canvas.tool = .polygon
            target.canvas.shapePreset = preset
          }
          target.styleBar.update()
          target.palette.update()
          if let tip = environment["BRISTLE_PRESS"] {
            target.window?.contentView?.layoutSubtreeIfNeeded()
            if let button = target.styleBar.bar.buttons.first(where: { $0.toolTip?.hasPrefix(tip) == true }) {
              click(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
            }
          }
          _ = canvas
          after(environment["BRISTLE_WAIT"].flatMap(Double.init) ?? 1) {
            var captured = target.window
            if environment["BRISTLE_SETTINGS"] == "1", let delegate = NSApp.delegate as? AppDelegate {
              delegate.settingsController.show()
              captured = delegate.settingsController.window
              RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            }
            guard let window = captured else { fail("no window to capture") }
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            // A popover is drawn from its own view, since it's a window of its own.
            if let popover = target.styleBar.popover, popover.isShown, let view = popover.contentViewController?.view,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
              view.cacheDisplay(in: view.bounds, to: rep)
              try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".popover.png"))
            }
            try? capture.run()
            capture.waitUntilExit()
            pass("wrote \(path)")
            finish()
          }
        }
      }
    }

    /// A small drawing of each kind of object, for screenshots.
    static func demo(_ canvas: CanvasView) {
      var scene = Scene()
      @MainActor func add(_ e: Element) { scene.elements.append(e) }
      var sky = Element(kind: .rectangle)
      sky.frame = CGRect(x: 120, y: 120, width: 420, height: 280)
      sky.fill = Color(hex: "#DCEBFF")
      sky.stroke = Color(hex: "#0A84FF")
      sky.cornerRadius = 22
      add(sky)
      var sun = Element(kind: .ellipse)
      sun.frame = CGRect(x: 400, y: 150, width: 90, height: 90)
      sun.fill = Color(hex: "#FFD60A")
      sun.stroke = Color(hex: "#FF9F0A")
      add(sun)
      var hill = Element(kind: .polygon)
      hill.setWorldPoints([CGPoint(x: 140, y: 380), CGPoint(x: 260, y: 240), CGPoint(x: 360, y: 330), CGPoint(x: 520, y: 380)])
      hill.curved = true
      hill.fill = Color(hex: "#34C759")
      hill.stroke = Color(hex: "#248A3D")
      add(hill)
      var note = Element(kind: .text)
      note.text = "Everything stays editable"
      note.fontSize = 40
      note.fontName = ""
      note.x = 640
      note.y = 150
      note.fitToText()
      add(note)
      var arrow = Element(kind: .arrow)
      arrow.setWorldPoints([CGPoint(x: 820, y: 230), CGPoint(x: 700, y: 330), CGPoint(x: 555, y: 300)])
      arrow.curved = true
      arrow.stroke = Color(hex: "#FF3B30")
      arrow.strokeWidth = 5
      arrow.endBinding = .init(element: sky.id, anchor: CGPoint(x: 0.5, y: 0.5))
      add(arrow)
      var ink = Element(kind: .freehand)
      let raw = (0...90).map { i -> CGPoint in
        let t = CGFloat(i) / 90
        return CGPoint(x: 640 + t * 480, y: 560 + sin(t * .pi * 3) * 70 + t * 30)
      }
      let pressures = Freehand.simulatedPressures(raw, size: 10)
      let (points, smooth) = Freehand.smoothed(raw, pressures: pressures)
      ink.setWorldPoints(points)
      ink.pressures = smooth
      ink.strokeWidth = 10
      ink.stroke = Color(hex: "#5E5CE6")
      add(ink)
      var mark = Element(kind: .freehand)
      mark.brush = .highlighter
      mark.setWorldPoints([CGPoint(x: 640, y: 240), CGPoint(x: 1100, y: 236)])
      mark.stroke = Color(hex: "#FFD60A")
      mark.strokeWidth = 30
      mark.opacity = 0.45
      scene.elements.insert(mark, at: 0)
      var label = Element(kind: .text)
      label.text = "Shapes, arrows, ink, and text"
      label.fontSize = 22
      label.stroke = Color(hex: "#6E6E73")
      label.x = 120
      label.y = 440
      label.fitToText()
      add(label)
      scene.updateBindings(changed: [arrow.id])
      canvas.drawing.replace(scene)
      canvas.tool = .select
      canvas.drawing.selection = [ink.id]
      canvas.showDrawing()
    }
  }
#endif
