import CoreGraphics
import Foundation

/// Ordering, aligning, grouping, and the other Arrange commands, on the elements with the given ids.
extension Scene {
  public enum Order: Sendable { case front, forward, backward, back }

  public enum Alignment: String, CaseIterable, Sendable { case left, center, right, top, middle, bottom }

  public enum Axis: Sendable { case horizontal, vertical }

  /// The elements that act as one when any of `ids` is picked: the outermost group of each,
  /// or the elements of an inner group once the user has entered it.
  public func expandToGroups(_ ids: Set<String>, within entered: String? = nil) -> Set<String> {
    var result = ids
    for id in ids {
      guard let element = self[id], let group = outermostGroup(of: element, within: entered) else { continue }
      for other in elements where other.groups.contains(group) { result.insert(other.id) }
    }
    return result
  }

  /// The group an element is picked by: its outermost group, or the one just inside `entered`.
  public func outermostGroup(of element: Element, within entered: String?) -> String? {
    guard let entered else { return element.groups.last }
    guard let index = element.groups.firstIndex(of: entered) else { return element.groups.last }
    return index > 0 ? element.groups[index - 1] : nil
  }

  /// Bounds of the elements with these ids, on the canvas.
  public func bounds(of ids: Set<String>) -> CGRect {
    elements.lazy.filter { ids.contains($0.id) }.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
  }

  /// The union of the elements' frames, ignoring stroke widths, for selection outlines.
  public func frameBounds(of ids: Set<String>) -> CGRect {
    elements.lazy.filter { ids.contains($0.id) }.map { element in
      element.rotation == 0 ? element.frame : CGRect(boundingPoints: element.worldCorners)
    }.reduce(CGRect.null) { $0.union($1) }
  }

  public var contentBounds: CGRect { elements.map(\.bounds).reduce(CGRect.null) { $0.union($1) } }

  // MARK: Order

  public mutating func reorder(_ ids: Set<String>, _ order: Order) {
    let selected = elements.filter { ids.contains($0.id) }
    guard !selected.isEmpty else { return }
    switch order {
    case .front:
      elements = elements.filter { !ids.contains($0.id) } + selected
    case .back:
      elements = selected + elements.filter { !ids.contains($0.id) }
    case .forward:
      // Each run of selected elements moves above the next unselected element.
      var i = elements.count - 2
      while i >= 0 {
        if ids.contains(elements[i].id), !ids.contains(elements[i + 1].id) {
          var start = i
          while start > 0, ids.contains(elements[start - 1].id) { start -= 1 }
          let above = elements.remove(at: i + 1)
          elements.insert(above, at: start)
          i = start - 1
        } else {
          i -= 1
        }
      }
    case .backward:
      var i = 1
      while i < elements.count {
        if ids.contains(elements[i].id), !ids.contains(elements[i - 1].id) {
          var end = i
          while end < elements.count - 1, ids.contains(elements[end + 1].id) { end += 1 }
          let below = elements.remove(at: i - 1)
          elements.insert(below, at: end)
          i = end + 1
        } else {
          i += 1
        }
      }
    }
  }

  // MARK: Alignment

  /// Lines up the elements, or a single element with the paper.
  public mutating func align(_ ids: Set<String>, _ alignment: Alignment) {
    let units = selectionUnits(ids)
    guard !units.isEmpty else { return }
    let target = units.count == 1 ? paperRect : units.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
    for unit in units {
      let box = unit.bounds
      var dx: CGFloat = 0, dy: CGFloat = 0
      switch alignment {
      case .left: dx = target.minX - box.minX
      case .center: dx = target.midX - box.midX
      case .right: dx = target.maxX - box.maxX
      case .top: dy = target.minY - box.minY
      case .middle: dy = target.midY - box.midY
      case .bottom: dy = target.maxY - box.maxY
      }
      move(unit.ids, dx: dx, dy: dy)
    }
  }

  /// Spaces the elements evenly between the first and last.
  public mutating func distribute(_ ids: Set<String>, _ axis: Axis) {
    var units = selectionUnits(ids)
    guard units.count >= 3 else { return }
    let horizontal = axis == .horizontal
    units.sort { horizontal ? $0.bounds.midX < $1.bounds.midX : $0.bounds.midY < $1.bounds.midY }
    let first = units.first!.bounds, last = units.last!.bounds
    let span = horizontal ? last.maxX - first.minX : last.maxY - first.minY
    let occupied = units.reduce(0) { $0 + (horizontal ? $1.bounds.width : $1.bounds.height) }
    let gap = (span - occupied) / CGFloat(units.count - 1)
    var position = horizontal ? first.maxX + gap : first.maxY + gap
    for unit in units.dropFirst().dropLast() {
      let box = unit.bounds
      if horizontal {
        move(unit.ids, dx: position - box.minX, dy: 0)
        position += box.width + gap
      } else {
        move(unit.ids, dx: 0, dy: position - box.minY)
        position += box.height + gap
      }
    }
  }

  /// Elements that move together: each group among the ids, and each ungrouped element.
  struct Unit {
    var ids: Set<String>
    var bounds: CGRect
  }

  /// How many things align and distribute would move: groups count once.
  public func unitCount(of ids: Set<String>) -> Int { selectionUnits(ids).count }

  func selectionUnits(_ ids: Set<String>) -> [Unit] {
    // Only groups wholly inside the selection move as one.
    var total: [String: Int] = [:], selected: [String: Int] = [:]
    for element in elements {
      for group in element.groups {
        total[group, default: 0] += 1
        if ids.contains(element.id) { selected[group, default: 0] += 1 }
      }
    }
    var units: [Unit] = []
    var byGroup: [String: Int] = [:]
    for element in elements where ids.contains(element.id) {
      if let group = element.groups.last(where: { total[$0] == selected[$0] }) {
        if let index = byGroup[group] {
          units[index].ids.insert(element.id)
          units[index].bounds = units[index].bounds.union(element.bounds)
          continue
        }
        byGroup[group] = units.count
      }
      units.append(Unit(ids: [element.id], bounds: element.bounds))
    }
    return units
  }

  public mutating func move(_ ids: Set<String>, dx: CGFloat, dy: CGFloat) {
    guard dx != 0 || dy != 0 else { return }
    for i in elements.indices where ids.contains(elements[i].id) {
      elements[i].x += dx
      elements[i].y += dy
    }
    updateBindings(changed: ids)
  }

  // MARK: Groups and locks

  /// Groups the elements, returning the new group's id.
  @discardableResult
  public mutating func group(_ ids: Set<String>) -> String? {
    guard ids.count > 1 else { return nil }
    let group = "g" + Element.newID()
    for i in elements.indices where ids.contains(elements[i].id) { elements[i].groups.append(group) }
    // A group's elements sit together in the stacking order, at the frontmost one's place.
    let members = elements.filter { ids.contains($0.id) }
    guard let top = elements.lastIndex(where: { ids.contains($0.id) }) else { return group }
    let above = elements[(top + 1)...].map(\.self)
    elements = elements[...top].filter { !ids.contains($0.id) } + members + above
    return group
  }

  /// Removes the outermost group of each element, returning the elements that were grouped.
  @discardableResult
  public mutating func ungroup(_ ids: Set<String>) -> Set<String> {
    var changed: Set<String> = []
    let groups = Set(elements.filter { ids.contains($0.id) }.compactMap(\.groups.last))
    for i in elements.indices {
      guard let last = elements[i].groups.last, groups.contains(last) else { continue }
      elements[i].groups.removeLast()
      changed.insert(elements[i].id)
    }
    return changed
  }

  public mutating func setLocked(_ ids: Set<String>, _ locked: Bool) {
    for i in elements.indices where ids.contains(elements[i].id) { elements[i].locked = locked }
  }

  // MARK: Duplicating and deleting

  /// Copies the elements, offset by `offset`, returning the new ids. Groups made only of copied
  /// elements are copied too, and lines stay attached to elements copied with them.
  @discardableResult
  public mutating func duplicate(_ ids: Set<String>, offset: CGPoint) -> [String] {
    let copies = Scene.copies(of: elements.filter { ids.contains($0.id) }, offset: offset)
    elements += copies
    return copies.map(\.id)
  }

  /// Fresh copies of elements, with new ids for the elements and for the groups among them.
  public static func copies(of originals: [Element], offset: CGPoint) -> [Element] {
    var newIDs: [String: String] = [:]
    for element in originals { newIDs[element.id] = Element.newID() }
    var newGroups: [String: String] = [:]
    for group in Set(originals.flatMap(\.groups)) { newGroups[group] = "g" + Element.newID() }
    return originals.map { original in
      var copy = original
      copy.id = newIDs[original.id]!
      copy.x += offset.x
      copy.y += offset.y
      copy.groups = original.groups.compactMap { newGroups[$0] }
      copy.startBinding = original.startBinding.flatMap { b in newIDs[b.element].map { .init(element: $0, anchor: b.anchor) } }
      copy.endBinding = original.endBinding.flatMap { b in newIDs[b.element].map { .init(element: $0, anchor: b.anchor) } }
      return copy
    }
  }

  /// Deletes the elements, detaching lines attached to them.
  public mutating func delete(_ ids: Set<String>) {
    elements.removeAll { ids.contains($0.id) }
    for i in elements.indices {
      if let binding = elements[i].startBinding, ids.contains(binding.element) { elements[i].startBinding = nil }
      if let binding = elements[i].endBinding, ids.contains(binding.element) { elements[i].endBinding = nil }
    }
    removeUnusedFiles()
  }

  // MARK: Flipping and rotating

  /// Mirrors the elements across the middle of their bounds.
  public mutating func flip(_ ids: Set<String>, _ axis: Axis) {
    let box = bounds(of: ids)
    guard !box.isNull else { return }
    mirror(ids, axis, around: box.center)
  }

  mutating func mirror(_ ids: Set<String>, _ axis: Axis, around pivot: CGPoint) {
    let horizontal = axis == .horizontal
    for i in elements.indices where ids.contains(elements[i].id) {
      var e = elements[i]
      let c = e.center
      let mirrored = horizontal ? CGPoint(x: 2 * pivot.x - c.x, y: c.y) : CGPoint(x: c.x, y: 2 * pivot.y - c.y)
      e.x = mirrored.x - e.width / 2
      e.y = mirrored.y - e.height / 2
      e.rotation = Element.normalized(-e.rotation)
      if e.isPointBased {
        e.points = e.points.map { horizontal ? CGPoint(x: e.width - $0.x, y: $0.y) : CGPoint(x: $0.x, y: e.height - $0.y) }
      }
      if e.kind == .image {
        if horizontal { e.flipX.toggle() } else { e.flipY.toggle() }
        if var crop = e.crop {
          if horizontal { crop.origin.x = 1 - crop.maxX } else { crop.origin.y = 1 - crop.maxY }
          e.crop = crop
        }
      }
      if var binding = e.startBinding {
        binding.anchor = mirroredAnchor(binding.anchor, horizontal)
        e.startBinding = binding
      }
      if var binding = e.endBinding {
        binding.anchor = mirroredAnchor(binding.anchor, horizontal)
        e.endBinding = binding
      }
      elements[i] = e
    }
    // Anchors on mirrored targets flip with them.
    for i in elements.indices where !ids.contains(elements[i].id) {
      for keyPath in [\Element.startBinding, \Element.endBinding] {
        if var binding = elements[i][keyPath: keyPath], ids.contains(binding.element) {
          binding.anchor = mirroredAnchor(binding.anchor, horizontal)
          elements[i][keyPath: keyPath] = binding
        }
      }
    }
    updateBindings(changed: ids)
  }

  private func mirroredAnchor(_ anchor: CGPoint, _ horizontal: Bool) -> CGPoint {
    horizontal ? CGPoint(x: 1 - anchor.x, y: anchor.y) : CGPoint(x: anchor.x, y: 1 - anchor.y)
  }

  /// Turns the elements by `angle` around the middle of their bounds.
  public mutating func rotate(_ ids: Set<String>, by angle: CGFloat, around pivot: CGPoint? = nil) {
    let pivot = pivot ?? frameBounds(of: ids).center
    for i in elements.indices where ids.contains(elements[i].id) {
      elements[i].rotate(by: angle, around: pivot)
    }
    updateBindings(changed: ids)
  }
}
