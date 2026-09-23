import Foundation

/// The difference between two versions of a scene, small enough to keep one for every undo step.
///
/// Most edits add, remove, or change a few elements while the rest keep their order; those are
/// recorded element by element. Edits that reorder elements record the whole element list.
public struct SceneChange: Sendable {
  enum Elements: Sendable {
    case none
    /// Removed elements at their old indices, inserted ones at their new indices, and changed
    /// ones at their new indices with both versions.
    case patch(removed: [(Int, Element)], inserted: [(Int, Element)], changed: [(Int, Element, Element)])
    case whole(before: [Element], after: [Element])
  }

  var elements: Elements
  var paper: (Paper, Paper)?
  var files: ([String: ImageFile], [String: ImageFile])?

  public init(from before: Scene, to after: Scene) {
    paper = before.paper == after.paper ? nil : (before.paper, after.paper)
    files = before.files == after.files ? nil : (before.files, after.files)
    elements = Self.diff(before.elements, after.elements)
  }

  public var isEmpty: Bool {
    if paper != nil || files != nil { return false }
    if case .none = elements { return true }
    return false
  }

  static func diff(_ old: [Element], _ new: [Element]) -> Elements {
    if old == new { return .none }
    if old.count == new.count, zip(old, new).allSatisfy({ $0.id == $1.id }) {
      let changed = old.indices.compactMap { i in old[i] == new[i] ? nil : (i, old[i], new[i]) }
      return .patch(removed: [], inserted: [], changed: changed)
    }
    let oldIDs = Set(old.map(\.id)), newIDs = Set(new.map(\.id))
    let keptOld = old.filter { newIDs.contains($0.id) }, keptNew = new.filter { oldIDs.contains($0.id) }
    // Kept elements must stay in the same order for a patch; otherwise record everything.
    guard zip(keptOld, keptNew).allSatisfy({ $0.id == $1.id }) else { return .whole(before: old, after: new) }
    let removed = old.indices.filter { !newIDs.contains(old[$0].id) }.map { ($0, old[$0]) }
    let inserted = new.indices.filter { !oldIDs.contains(new[$0].id) }.map { ($0, new[$0]) }
    var changed: [(Int, Element, Element)] = []
    var oldByID: [String: Element] = [:]
    for element in keptOld { oldByID[element.id] = element }
    for (i, element) in new.enumerated() {
      if let previous = oldByID[element.id], previous != element { changed.append((i, previous, element)) }
    }
    return .patch(removed: removed, inserted: inserted, changed: changed)
  }

  /// Applies the change forwards, or backwards to undo it.
  public func apply(to scene: inout Scene, reversed: Bool = false) {
    if let paper { scene.paper = reversed ? paper.0 : paper.1 }
    if let files { scene.files = reversed ? files.0 : files.1 }
    switch elements {
    case .none: break
    case .whole(let before, let after): scene.elements = reversed ? before : after
    case .patch(let removed, let inserted, let changed):
      if reversed {
        for (i, old, _) in changed { scene.elements[i] = old }
        for (i, _) in inserted.reversed() { scene.elements.remove(at: i) }
        for (i, element) in removed { scene.elements.insert(element, at: i) }
      } else {
        for (i, _) in removed.reversed() { scene.elements.remove(at: i) }
        for (i, element) in inserted { scene.elements.insert(element, at: i) }
        for (i, _, new) in changed { scene.elements[i] = new }
      }
    }
  }

  /// The ids of every element the change touches.
  public var elementIDs: Set<String> {
    switch elements {
    case .none: return []
    case .whole(let before, let after): return Set(before.map(\.id) + after.map(\.id))
    case .patch(let removed, let inserted, let changed):
      return Set(removed.map(\.1.id) + inserted.map(\.1.id) + changed.map(\.1.id))
    }
  }

  /// Every version of every element the change touches, for redrawing where they were and are.
  public var touchedElements: [Element] {
    switch elements {
    case .none: return []
    case .whole(let before, let after):
      // Reordering changes what overlaps what, so everything involved is redrawn.
      return before + after
    case .patch(let removed, let inserted, let changed):
      return removed.map(\.1) + inserted.map(\.1) + changed.flatMap { [$0.1, $0.2] }
    }
  }

  public var changesPaper: Bool { paper != nil }
}
