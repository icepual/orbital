import AppKit

struct RingAnimationState {
    var intro: CGFloat = 1
    var opening = false
    var arc: CGFloat = 0
    var shownGroupID: UUID?
    var requestedGroupID: UUID?
    var highlightedID: UUID?
}

struct RingAnimationUpdate {
    var redraw = false
    var shownGroupChanged = false
    var accessibilityLayoutChanged = false
    var settled = false
}

/// Smooths the magnification weights towards the currently highlighted item.
struct HoverMagnification {
    private(set) var values: [UUID: CGFloat] = [:]
    private var targets: [UUID: CGFloat] = [:]
    private var origins: [UUID: CGFloat] = [:]
    private var started: TimeInterval = 0

    mutating func reset() {
        values.removeAll()
        targets.removeAll()
        origins.removeAll()
        started = 0
    }

    mutating func advance(now: TimeInterval,
                          targets newTargets: [UUID: CGFloat],
                          duration: TimeInterval) -> Bool {
        if newTargets != targets {
            origins = values
            targets = newTargets
            started = now
        }
        let progress = duration > 0 ? min(1, (now - started) / duration) : 1
        let eased = RingGeometry.ease(progress)
        var next: [UUID: CGFloat] = [:]
        for id in Set(origins.keys).union(targets.keys) {
            let start = origins[id] ?? 0
            let target = targets[id] ?? 0
            let current = start + (target - start) * eased
            if current > 0.001 { next[id] = current }
        }
        values = next
        return progress < 1
    }

    mutating func snap(to newTargets: [UUID: CGFloat]) {
        origins = values
        targets = newTargets
        values = newTargets.filter { $0.value > 0.001 }
        started = 0
    }
}

/// Owns the submenu arc, intro progress and hover magnification state.
/// It is deliberately free of timers and view references so it can be advanced
/// with synthetic time in tests.
struct RingAnimationEngine {
    private(set) var state = RingAnimationState()
    private var hover = HoverMagnification()

    var magnification: [UUID: CGFloat] { hover.values }

    mutating func prepare(isPreview: Bool, reducedMotion: Bool) {
        state = RingAnimationState()
        state.intro = isPreview || reducedMotion ? 1 : 0
        state.opening = state.intro < 1
        hover.reset()
    }

    mutating func setHighlighted(_ id: UUID?) {
        state.highlightedID = id
    }

    /// Returns true when the shown group changed immediately (the submenu was
    /// not visible yet and its icons have to be loaded).
    @discardableResult
    mutating func requestGroup(_ id: UUID) -> Bool {
        var shownChanged = false
        if state.shownGroupID == nil {
            state.shownGroupID = id
            shownChanged = true
        }
        state.requestedGroupID = id
        return shownChanged
    }

    mutating func collapse() {
        state.requestedGroupID = nil
        state.highlightedID = nil
    }

    mutating func clearRequestedGroup() {
        state.requestedGroupID = nil
    }

    mutating func showGroup(_ id: UUID?, hasChildren: Bool, animated: Bool) {
        state.shownGroupID = id
        state.requestedGroupID = id
        state.arc = hasChildren && !animated ? 1 : 0
    }

    mutating func suspend() {
        state.shownGroupID = nil
        state.requestedGroupID = nil
        state.arc = 0
        hover.reset()
    }

    mutating func advance(now: TimeInterval,
                          dt: TimeInterval,
                          items: [RingItem],
                          appearance: Appearance,
                          reducedMotion: Bool) -> RingAnimationUpdate {
        if reducedMotion {
            return snap(items: items)
        }

        var update = RingAnimationUpdate()
        let oldIntro = state.intro
        let oldGroup = state.shownGroupID
        let oldArc = state.arc

        if state.opening {
            state.intro = min(1, state.intro + dt / 0.23)
            state.opening = state.intro < 1
        }
        if state.shownGroupID == state.requestedGroupID, state.shownGroupID != nil {
            state.arc = min(1, state.arc + dt / appearance.animationDuration)
        } else {
            state.arc = max(0, state.arc - dt / (appearance.animationDuration * 0.5))
            if state.arc == 0 {
                state.shownGroupID = state.requestedGroupID
                update.shownGroupChanged = oldGroup != state.shownGroupID
            }
        }

        let oldMagnification = hover.values
        let hoverMoving = hover.advance(now: now, targets: targets(items: items),
                                        duration: appearance.animationDuration)
        let geometryChanged = oldIntro != state.intro
            || oldGroup != state.shownGroupID
            || oldArc != state.arc
        update.redraw = geometryChanged || oldMagnification != hover.values
        update.accessibilityLayoutChanged = geometryChanged

        let groupSettled = (state.shownGroupID == nil && state.requestedGroupID == nil)
            || (state.arc == 1 && state.shownGroupID != nil
                && state.shownGroupID == state.requestedGroupID)
        update.settled = !state.opening && groupSettled && !hoverMoving
        return update
    }

    mutating func snap(items: [RingItem]) -> RingAnimationUpdate {
        let oldGroup = state.shownGroupID
        state.intro = 1
        state.opening = false
        state.shownGroupID = state.requestedGroupID
        state.arc = state.shownGroupID == nil ? 0 : 1
        hover.snap(to: targets(items: items))
        return RingAnimationUpdate(
            redraw: true,
            shownGroupChanged: oldGroup != state.shownGroupID,
            accessibilityLayoutChanged: true,
            settled: true
        )
    }

    private func targets(items: [RingItem]) -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]

        func add(around id: UUID?, in entries: [RingItem]) {
            guard let id, let selected = entries.firstIndex(where: { $0.id == id }) else {
                return
            }
            for (index, item) in entries.enumerated() {
                let offset = CGFloat(index - selected)
                let influence = exp(-1.1 * offset * offset)
                if influence >= 0.015 { result[item.id] = influence }
            }
        }

        if items.contains(where: { $0.id == state.highlightedID }) {
            add(around: state.highlightedID, in: items)
        } else {
            // Keep the submenu anchor stable while the pointer crosses into the outer arc.
            add(around: state.requestedGroupID, in: items)
        }
        if let shown = state.shownGroupID, shown == state.requestedGroupID,
           let group = items.first(where: { $0.id == shown }) {
            add(around: state.highlightedID, in: group.children ?? [])
        }
        return result
    }
}
