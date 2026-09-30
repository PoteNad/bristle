#if BRISTLE_CHECKS
  import AppKit
  import BristleCore
  @testable import BristleCanvas

  /// Scrolling and zooming as a trackpad and a mouse do them: every step must move the view by
  /// what was asked, smoothly, promptly, and without jumps.
  extension AppChecks {
    /// A scroll event as a trackpad sends one, `phase` and `momentum` as the system numbers them.
    static func scrollEvent(
      dx: CGFloat, dy: CGFloat, at p: CGPoint, in view: NSView, phase: Int64 = 0, momentum: Int64 = 0,
      precise: Bool = true, flags: CGEventFlags = []
    ) -> NSEvent? {
      guard let window = view.window,
        let event = CGEvent(
          scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: Int32(dy.rounded()),
          wheel2: Int32(dx.rounded()), wheel3: 0)
      else { return nil }
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
      if precise {
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
      }
      event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
      event.flags = flags
      // Addressed to the window, as the system addresses events under the pointer.
      event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
      event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
      let onScreen = window.convertPoint(toScreen: view.convert(p, to: nil))
      let top = NSScreen.screens.first?.frame.maxY ?? 0
      event.location = CGPoint(x: onScreen.x, y: top - onScreen.y)
      return NSEvent(cgEvent: event)
    }

    struct Step {
      var name: String
      var milliseconds: Double
      var moved: CGPoint
      var zoom: CGFloat
    }

    /// Sends one scroll event to the canvas's scroll view, as the window would, draws, and says
    /// how long that took and how far the view moved.
    static func scroll(
      _ canvas: CanvasView, _ name: String, dx: CGFloat, dy: CGFloat, at p: CGPoint, phase: Int64 = 0,
      momentum: Int64 = 0, precise: Bool = true, flags: CGEventFlags = []
    ) -> Step {
      guard let event = scrollEvent(dx: dx, dy: dy, at: p, in: canvas, phase: phase, momentum: momentum, precise: precise, flags: flags)
      else { fail("could not make a scroll event") }
      let before = canvas.unobscuredRect.center
      let start = CACurrentMediaTime()
      canvas.scrollView.scrollWheel(with: event)
      canvas.window?.displayIfNeeded()
      let time = (CACurrentMediaTime() - start) * 1000
      // AppKit may finish the scroll on the next turn of the run loop.
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
      let after = canvas.unobscuredRect.center
      return Step(name: name, milliseconds: time, moved: CGPoint(x: after.x - before.x, y: after.y - before.y), zoom: canvas.magnification)
    }

    static func scrollCheck(_ controller: BristleDocumentController) {
      after(1.5) {
        let document = firstDocument(controller)
        let editor = document.editor!
        let canvas = editor.canvas
        // A page of handwriting, as people draw on it, with the grid and rulers showing.
        var scene = Scene()
        var seed: UInt64 = 3
        @MainActor func random() -> CGFloat {
          seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
          return CGFloat(seed >> 11) / CGFloat(1 << 53)
        }
        for i in 0..<80 {
          var e = Element(kind: .freehand)
          var p = CGPoint(x: 60 + random() * 1080, y: 60 + random() * 680)
          var points: [CGPoint] = []
          var angle = random() * .pi * 2
          for _ in 0..<40 {
            angle += (random() - 0.5) * 0.9
            p.x += cos(angle) * 2.5
            p.y += sin(angle) * 2.5
            points.append(p)
          }
          e.setWorldPoints(points)
          e.strokeWidth = i % 3 == 0 ? 8 : 4
          e.pressures = Freehand.simulatedPressures(points, size: e.strokeWidth)
          scene.elements.append(e)
        }
        canvas.drawing.replace(scene)
        var configuration = canvas.configuration
        configuration.showsGrid = true
        configuration.showsRulers = true
        canvas.configuration = configuration
        editor.window?.contentView?.needsLayout = true
        editor.window?.contentView?.layoutSubtreeIfNeeded()

        var slowest: Step?
        func note(_ step: Step) {
          if step.milliseconds > (slowest?.milliseconds ?? 0) { slowest = step }
        }

        for zoom in [0.95, 1.5, 3] as [CGFloat] {
          let tag = "at \(Int(zoom * 100))%"
          // Precise scrolling, one event at a time: each moves the view by what it asks, the
          // same way throughout, until an edge.
          for (dx, dy) in [(0, -8), (0, 8), (-8, 0), (8, 0), (-6, -6)] as [(CGFloat, CGFloat)] {
            // What's still under way from the last direction lands first.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            canvas.zoom(to: zoom)
            canvas.center(on: canvas.scene.canvas.center)
            canvas.window?.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            let c = canvas.unobscuredRect.center
            var steps: [Step] = []
            for i in 0..<30 { steps.append(scroll(canvas, "scroll \(i)", dx: dx, dy: dy, at: c)) }
            steps.forEach(note)
            var direction = CGPoint.zero
            for step in steps {
              for (moved, axis) in [(step.moved.x, 0), (step.moved.y, 1)] where abs(moved) > 0.01 {
                let sign: CGFloat = moved > 0 ? 1 : -1
                if axis == 0 && direction.x == 0 { direction.x = sign }
                if axis == 1 && direction.y == 0 { direction.y = sign }
                guard sign == (axis == 0 ? direction.x : direction.y), abs(moved) <= 8 / zoom * 2.5 + 0.5 else {
                  fail("scrolling \(tag) jumped or turned back at \(step.name): \(steps.map(\.moved))")
                }
              }
              if dx == 0 { guard abs(step.moved.x) < 0.01 else { fail("scrolling up or down \(tag) moved sideways: \(step.moved)") } }
              if dy == 0 { guard abs(step.moved.y) < 0.01 else { fail("scrolling sideways \(tag) moved up or down: \(step.moved)") } }
            }
          }
          canvas.zoom(to: zoom)
          canvas.center(on: canvas.scene.canvas.center)
          let c = canvas.unobscuredRect.center
          // Far past each edge, the view stops and stays still, with the canvas's edge in the
          // clear, beside the toolbar, rulers, and bars rather than under them.
          let page = canvas.scene.canvas
          for (dx, dy, edge) in [(0, 60, "top"), (0, -60, "bottom"), (60, 0, "left"), (-60, 0, "right")] as [(CGFloat, CGFloat, String)] {
            for _ in 0..<60 { _ = scroll(canvas, "to the \(edge)", dx: dx, dy: dy, at: c) }
            let rest = canvas.unobscuredRect
            for i in 0..<5 {
              let step = scroll(canvas, "at the \(edge) \(i)", dx: dx, dy: dy, at: c)
              guard abs(step.moved.x) < 0.01, abs(step.moved.y) < 0.01 else { fail("at the \(edge) edge \(tag), the view kept moving: \(step.moved)") }
            }
            let clear: Bool
            switch edge {
            case "top": clear = rest.minY <= page.minY
            case "bottom": clear = rest.maxY >= page.maxY
            case "left": clear = rest.minX <= page.minX
            default: clear = rest.maxX >= page.maxX
            }
            guard clear else { fail("scrolled to the \(edge) \(tag), the canvas's edge should show in the clear: \(rest) for \(page)") }
          }
        }
        pass("scrolling moves the view steadily by what's asked at every zoom, and stops cleanly at the edges with the canvas's edge in view")

        // A mouse wheel, in lines.
        canvas.zoom(to: 1.5)
        canvas.center(on: canvas.scene.canvas.center)
        let wheel = (0..<6).map { _ in scroll(canvas, "wheel", dx: 0, dy: -3, at: canvas.unobscuredRect.center, precise: false) }
        wheel.forEach(note)
        guard wheel.allSatisfy({ $0.moved.y > 0 }) else { fail("a mouse wheel should scroll down each notch: \(wheel.map(\.moved))") }
        pass("a mouse wheel scrolls a notch at a time")

        // ⌘-scrolling zooms around the pointer: the point under it stays under it.
        canvas.zoom(to: 1)
        canvas.center(on: canvas.scene.canvas.center)
        canvas.window?.displayIfNeeded()
        let spot = CGPoint(x: canvas.unobscuredRect.midX + 120, y: canvas.unobscuredRect.midY + 60)
        let onScreen = canvas.convert(spot, to: nil)
        // The events made here carry no window, so where the pointer is comes straight from the
        // spot; the event itself only has to zoom.
        let zoomBefore = canvas.magnification
        _ = scroll(canvas, "⌘-scroll", dx: 0, dy: 6, at: spot, flags: .maskCommand)
        guard canvas.magnification != zoomBefore else { fail("⌘-scrolling should zoom") }
        canvas.zoom(to: 1)
        canvas.center(on: canvas.scene.canvas.center)
        for (i, factor) in ([1.06, 1.06, 1.06, 1.06, 1.06, 0.94, 0.94, 0.94, 0.94, 0.94, 0.94, 0.94] as [CGFloat]).enumerated() {
          let start = CACurrentMediaTime()
          canvas.zoom(to: canvas.magnification * factor, around: spot)
          canvas.window?.displayIfNeeded()
          note(Step(name: "zoom \(i)", milliseconds: (CACurrentMediaTime() - start) * 1000, moved: .zero, zoom: canvas.magnification))
          let under = canvas.convert(onScreen, from: nil)
          // The canvas stays centred along an axis where it fits; along the others, the point
          // under the pointer stays there.
          let room = canvas.unobscuredRect
          if canvas.bounds.width > room.width + 1 {
            guard abs(under.x - spot.x) < 3 else { fail("zooming around the pointer drifted across: \(spot) to \(under) at \(Int(canvas.magnification * 100))%") }
          }
          if canvas.bounds.height > room.height + 1 {
            guard abs(under.y - spot.y) < 3 else { fail("zooming around the pointer drifted down: \(spot) to \(under) at \(Int(canvas.magnification * 100))%") }
          }
        }
        _ = scroll(canvas, "zoom end", dx: 0, dy: 0, at: spot, phase: 4, flags: .maskCommand)
        pass("⌘-scrolling zooms around the pointer")

        // Pinching, as the scroll view's own live zoom does it: many small steps around the
        // fingers, zooming in, out past fitting, and in again, never jumping on the way.
        canvas.zoom(to: 1)
        canvas.center(on: canvas.scene.canvas.center)
        let fingers = CGPoint(x: canvas.unobscuredRect.midX - 80, y: canvas.unobscuredRect.midY - 40)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification, object: canvas.scrollView)
        var previous = canvas.unobscuredRect.center
        let zooms = Array(stride(from: 1.0, through: 2.5, by: 0.05)) + Array(stride(from: 2.5, through: 0.3, by: -0.05)) + Array(stride(from: 0.3, through: 1.2, by: 0.05))
        for zoom in zooms {
          let start = CACurrentMediaTime()
          canvas.scrollView.setMagnification(zoom, centeredAt: fingers)
          canvas.window?.displayIfNeeded()
          note(Step(name: "pinch \(zoom)", milliseconds: (CACurrentMediaTime() - start) * 1000, moved: .zero, zoom: zoom))
          let now = canvas.unobscuredRect.center
          // A step of 5% moves the view's middle by at most a little on screen.
          let jump = now.distance(to: previous) * zoom
          guard jump < 80 else { fail("pinching jumped \(Int(jump)) points on screen at \(Int(zoom * 100))%") }
          previous = now
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: canvas.scrollView)
        pass("pinching zooms smoothly in and out, without jumps")

        if let slowest {
          print(String(format: "  slowest scroll or zoom step: %.1f ms (%@ at %d%%)", slowest.milliseconds, slowest.name, Int(slowest.zoom * 100)))
          guard slowest.milliseconds < 16 else { fail("scrolling and zooming should keep up with the screen, but \(slowest.name) took \(slowest.milliseconds) ms") }
        }
        pass("every scroll and zoom step draws within a frame")

        // Tooltips: every toolbar tool keeps AppKit's own tooltip tracking.
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        for (slot, button) in editor.toolButtons where button.window != nil {
          button.updateTrackingAreas()
          button.updateTrackingAreas()
          guard button.toolTip?.isEmpty == false, button.trackingAreas.count >= 2 else {
            fail("the \(slot) tool should keep AppKit's tooltip tracking beside its own, has \(button.trackingAreas.count)")
          }
        }
        pass("every toolbar tool keeps its tooltip")

        document.updateChangeCount(.changeCleared)
        finish()
      }
    }
  }
#endif
