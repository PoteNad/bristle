import AppKit
import BristleCore

extension Notification.Name {
  /// Posted by a `Drawing` after its scene changes. `userInfo["change"]` holds a `SceneChange`
  /// box, or nothing when the whole scene was replaced.
  public static let drawingDidChange = Notification.Name("BristleDrawingDidChange")
  /// Posted by a `Drawing` after its selection changes.
  public static let drawingSelectionDidChange = Notification.Name("BristleDrawingSelectionDidChange")
}

/// A scene being edited, with undo. The document, the canvas, and the inspector share one.
///
/// Every edit goes through `edit(_:_:)`, or a gesture for edits that follow the pointer, and
/// becomes one undo step that restores the selection with it.
@MainActor
public final class Drawing {
  public private(set) var scene: Scene
  /// The ids of the selected elements.
  public var selection: Set<String> = [] {
    didSet {
      guard selection != oldValue else { return }
      NotificationCenter.default.post(name: .drawingSelectionDidChange, object: self)
    }
  }
  public weak var undoManager: UndoManager?
  /// The scene when the current gesture began, if one is under way.
  public private(set) var gestureStart: Scene?
  private var gestureSelection: Set<String> = []
  private var coalescing: (name: String, timer: Timer)?

  /// Boxes a change for notifications.
  public final class ChangeBox: @unchecked Sendable {
    public let change: SceneChange
    init(_ change: SceneChange) { self.change = change }
  }

  public init(scene: Scene = Scene()) {
    self.scene = scene
  }

  /// Replaces the whole scene, as when a document is read or reverted. Not undoable.
  public func replace(_ scene: Scene) {
    finishCoalescing()
    gestureStart = nil
    self.scene = scene
    selection = selection.filter { scene[$0] != nil }
    NotificationCenter.default.post(name: .drawingDidChange, object: self)
  }

  /// Makes one undoable change.
  public func edit(_ actionName: String, select newSelection: Set<String>? = nil, _ body: (inout Scene) -> Void) {
    finishCoalescing()
    let before = scene, beforeSelection = selection
    var after = scene
    body(&after)
    let change = SceneChange(from: before, to: after)
    if let newSelection { selection = newSelection.filter { after[$0] != nil } }
    guard !change.isEmpty else { return }
    scene = after
    selection = selection.filter { after[$0] != nil }
    posted(change)
    register(change, actionName, beforeSelection: beforeSelection, afterSelection: selection)
  }

  // MARK: Gestures

  /// Starts a change that follows the pointer; `live(_:)` updates it and `endGesture(_:)` makes
  /// it one undo step.
  public func beginGesture() {
    finishCoalescing()
    guard gestureStart == nil else { return }
    gestureStart = scene
    gestureSelection = selection
  }

  public func live(_ body: (inout Scene) -> Void) {
    if gestureStart == nil { beginGesture() }
    let before = scene
    body(&scene)
    let change = SceneChange(from: before, to: scene)
    if !change.isEmpty { posted(change) }
  }

  public func endGesture(_ actionName: String) {
    guard let start = gestureStart else { return }
    gestureStart = nil
    let change = SceneChange(from: start, to: scene)
    guard !change.isEmpty else { return }
    selection = selection.filter { scene[$0] != nil }
    register(change, actionName, beforeSelection: gestureSelection, afterSelection: selection)
  }

  /// Puts the scene back as it was when the gesture began.
  public func cancelGesture() {
    guard let start = gestureStart else { return }
    gestureStart = nil
    let change = SceneChange(from: scene, to: start)
    scene = start
    selection = gestureSelection
    if !change.isEmpty { posted(change) }
  }

  public var isInGesture: Bool { gestureStart != nil }

  /// Applies a change right away but makes one undo step of a run of them, such as dragging
  /// in the Palette or holding a stepper, once they pause.
  public func coalesce(_ actionName: String, _ body: (inout Scene) -> Void) {
    if coalescing?.name != actionName {
      finishCoalescing()
      beginGesture()
    }
    coalescing?.timer.invalidate()
    let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.finishCoalescing() }
    }
    RunLoop.main.add(timer, forMode: .common)
    coalescing = (actionName, timer)
    live(body)
  }

  /// Ends a run of coalesced changes now.
  public func finishCoalescing() {
    guard let (name, timer) = coalescing else { return }
    timer.invalidate()
    coalescing = nil
    endGesture(name)
  }

  // MARK: Undo

  private func register(_ change: SceneChange, _ name: String, beforeSelection: Set<String>, afterSelection: Set<String>) {
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: self) { drawing in
      MainActor.assumeIsolated {
        drawing.apply(change, reversed: true, name: name, selection: beforeSelection, other: afterSelection)
      }
    }
    undoManager.setActionName(name)
  }

  private func apply(_ change: SceneChange, reversed: Bool, name: String, selection: Set<String>, other: Set<String>) {
    finishCoalescing()
    gestureStart = nil
    change.apply(to: &scene, reversed: reversed)
    self.selection = selection.filter { scene[$0] != nil }
    posted(change)
    undoManager?.registerUndo(withTarget: self) { drawing in
      MainActor.assumeIsolated {
        drawing.apply(change, reversed: !reversed, name: name, selection: other, other: selection)
      }
    }
    undoManager?.setActionName(name)
  }

  private func posted(_ change: SceneChange) {
    NotificationCenter.default.post(name: .drawingDidChange, object: self, userInfo: ["change": ChangeBox(change)])
  }

  // MARK: Reading

  public var selectedElements: [Element] { scene.elements.filter { selection.contains($0.id) } }
}
