import AppKit

@MainActor
final class RingView: NSView {
    private enum KeyboardFocus {
        case main(UUID)
        case submenu(groupID: UUID, itemID: UUID)
    }

    private let effect = NSVisualEffectView()
    private let mask = CAShapeLayer()
    private let submenuEffect = NSVisualEffectView()
    private let submenuMask = CAShapeLayer()
    private let surface = Surface()
    private let renderer = RingRenderer()
    private let isPreview: Bool
    private var icons: [UUID: NSImage] = [:]
    private var runningItems: Set<UUID> = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var metrics = RingMetrics(items: [], appearance: Appearance())
    private var ringAppearance = Appearance()
    private var animation = RingAnimationEngine()
    private var currentLayout: RingLayout?
    private var dwellTimer: Timer?
    private var pendingHover: UUID?
    private var closeTimer: Timer?
    private var timer: Timer?
    private var previousFrame = 0.0
    private var keyboardFocus: KeyboardFocus?
    private var items: [RingItem] = []
    private(set) var isShowingContextMenu = false
    var onChoose: ((RingItem) -> Void)?
    var onCenter: (() -> Void)?
    var onEmpty: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isPreview }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isPreview else { return nil }
        return super.hitTest(point) == nil ? nil : self
    }

    init(frame: NSRect, isPreview: Bool = false) {
        self.isPreview = isPreview
        super.init(frame: frame)
        for (backdrop, shapeMask) in [(effect, mask), (submenuEffect, submenuMask)] {
            backdrop.material = .popover
            backdrop.state = .active
            backdrop.blendingMode = isPreview ? .withinWindow : .behindWindow
            backdrop.wantsLayer = true
            backdrop.layer?.mask = shapeMask
            shapeMask.fillRule = .evenOdd
            shapeMask.fillColor = NSColor.white.cgColor
            backdrop.frame = bounds
            backdrop.autoresizingMask = [.width, .height]
            addSubview(backdrop)
        }
        submenuEffect.isHidden = true
        surface.wantsLayer = true
        surface.render = { [weak self] in self?.renderScene() }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        setAccessibilityElement(!isPreview)
        setAccessibilityRole(.group)
        setAccessibilityLabel("环启应用菜单")
    }

    required init?(coder: NSCoder) { nil }

    func prepare(_ items: [RingItem], appearance: Appearance) {
        self.items = items
        self.ringAppearance = appearance
        cancelDwell()
        cancelScheduledClose()
        stopAnimationTimer()
        metrics = RingMetrics(items: items, appearance: ringAppearance)
        animation.prepare(isPreview: isPreview, reducedMotion: reducedMotion)
        keyboardFocus = nil
        if !isPreview { observeRunningApps() }
        syncIcons(reloadTop: true)
        redraw()
        if animation.state.opening { animateIfNeeded() }
    }

    func updatePreviewAppearance(_ appearance: Appearance) {
        self.ringAppearance = appearance
        metrics = RingMetrics(items: items, appearance: ringAppearance)
        redraw()
    }

    func showPreviewGroup(_ group: RingItem?, animated: Bool = false) {
        stopAnimationTimer()
        animation.showGroup(group?.id,
                            hasChildren: group?.children?.isEmpty == false,
                            animated: animated)
        syncIcons()
        redraw()
        if animated && group?.children?.isEmpty == false {
            animateIfNeeded()
        }
    }

    var preferredPanelSize: CGFloat { metrics.preferredPanelSize }

    func suspend() {
        runningAppsObservation = nil
        cancelDwell()
        cancelScheduledClose()
        stopAnimationTimer()
        animation.suspend()
        keyboardFocus = nil
        icons = icons.filter { pair in items.contains { $0.id == pair.key } }
        currentLayout = nil
    }

    private var shownGroup: RingItem? {
        guard let id = animation.state.shownGroupID else { return nil }
        return items.first { $0.id == id }
    }

    private var requestedGroup: RingItem? {
        guard let id = animation.state.requestedGroupID else { return nil }
        return items.first { $0.id == id }
    }

    private var reducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func observeRunningApps() {
        refreshRunningItems()
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.runningAppsObservation != nil else { return }
                self.refreshRunningItems()
            }
        }
    }

    private func refreshRunningItems() {
        let running = NSWorkspace.shared.runningApplications
        let entries = items + items.flatMap { $0.children ?? [] }
        let updated = Set(entries.compactMap { entry -> UUID? in
            guard !entry.isGroup, entry.target?.runningApplication(in: running) != nil else {
                return nil
            }
            return entry.id
        })
        guard updated != runningItems else { return }
        runningItems = updated
        surface.needsDisplay = true
    }

    override func layout() {
        super.layout()
        redraw()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard !isPreview else { return }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow,
                                                 .mouseMoved, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }

    private func updatePointer(at point: CGPoint) {
        guard !isShowingContextMenu else { return }
        keyboardFocus = nil
        let layout = currentLayout ?? makeLayout()
        let hovered = RingHitTester.item(at: point, in: layout, mode: .padded)
        let requestedChildren = Set(requestedGroup?.children?.map(\.id) ?? [])
        if hovered?.id == animation.state.requestedGroupID
            || hovered.map({ requestedChildren.contains($0.id) }) == true {
            cancelScheduledClose()
        } else {
            scheduleClose()
        }
        updateHover(hovered?.id)
        guard hovered?.id != pendingHover else { return }
        cancelDwell()
        pendingHover = hovered?.id
        guard let hovered, hovered.isGroup,
              animation.state.requestedGroupID != hovered.id else { return }
        let hoveredID = hovered.id
        if ringAppearance.hoverDelay <= 0 {
            activateDwell(for: hoveredID)
            return
        }
        let dwell = Timer(timeInterval: ringAppearance.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingHover == hoveredID else { return }
                self.activateDwell(for: hoveredID)
            }
        }
        dwellTimer = dwell
        RunLoop.main.add(dwell, forMode: .common)
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        pendingHover = nil
    }

    private func activateDwell(for id: UUID) {
        dwellTimer = nil
        cancelScheduledClose()
        if animation.state.requestedGroupID != id,
           let item = items.first(where: { $0.id == id }) {
            select(item)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if keyboardFocus == nil { mouseMoved(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        guard !isShowingContextMenu, keyboardFocus == nil else { return }
        cancelDwell()
        updateHover(nil)
        scheduleClose()
    }

    private func updateHover(_ item: UUID?) {
        guard item != animation.state.highlightedID else { return }
        animation.setHighlighted(item)
        animateIfNeeded()
    }

    private func cancelScheduledClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }

    private func scheduleClose() {
        guard animation.state.requestedGroupID != nil, closeTimer == nil else { return }
        let pending = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeTimer = nil
                self.animation.clearRequestedGroup()
                self.animateIfNeeded()
            }
        }
        closeTimer = pending
        RunLoop.main.add(pending, forMode: .common)
    }

    override func mouseDown(with event: NSEvent) {
        keyboardFocus = nil
        let point = convert(event.locationInWindow, from: nil)
        let layout = currentLayout ?? makeLayout()
        if let item = RingHitTester.item(at: point, in: layout, mode: .exact) {
            if !item.isGroup || animation.state.requestedGroupID != item.id {
                select(item)
            }
        } else {
            onEmpty?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = currentLayout ?? makeLayout()
        guard let item = RingHitTester.item(at: point, in: layout, mode: .exact),
              !item.isGroup, let target = item.target else { return }
        let menu = NSMenu()
        let action: NSMenuItem
        if let running = target.runningApplication(in: NSWorkspace.shared.runningApplications) {
            action = NSMenuItem(title: "退出", action: #selector(quitContextApp(_:)),
                                keyEquivalent: "")
            action.representedObject = running
        } else {
            action = NSMenuItem(title: "打开", action: #selector(openContextApp(_:)),
                                keyEquivalent: "")
            action.representedObject = item
        }
        action.target = self
        menu.addItem(action)

        keyboardFocus = nil
        cancelDwell()
        cancelScheduledClose()
        isShowingContextMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isShowingContextMenu = false
        if runningAppsObservation != nil, let window {
            updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    @objc private func openContextApp(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? RingItem else { return }
        select(item)
    }

    @objc private func quitContextApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? NSRunningApplication,
              !app.isTerminated else { return }
        if !app.terminate() { NSSound.beep() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            onCenter?()
        case 123, 125, 124, 126:
            cancelDwell()
            cancelScheduledClose()
            let forward = event.keyCode == 124 || event.keyCode == 125
            moveKeyboardFocus(forward: forward)
        case 36, 76:
            guard !event.isARepeat else { return }
            cancelDwell()
            cancelScheduledClose()
            activateKeyboardFocus()
        default:
            super.keyDown(with: event)
        }
    }

    private func moveKeyboardFocus(forward: Bool) {
        func next(in entries: [RingItem], after id: UUID?) -> RingItem? {
            guard !entries.isEmpty else { return nil }
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                return forward ? entries.first : entries.last
            }
            return entries[(index + entries.count + (forward ? 1 : -1)) % entries.count]
        }

        switch keyboardFocus {
        case .submenu(let groupID, let itemID):
            guard let group = items.first(where: { $0.id == groupID }),
                  let children = group.children,
                  let item = next(in: children, after: itemID) else { return }
            keyboardFocus = .submenu(groupID: groupID, itemID: item.id)
            updateHover(item.id)
        case .main(let id):
            if let item = next(in: items, after: id) { focusMainItem(item) }
        case nil:
            let hovered = animation.state.highlightedID
            let mainID = items.contains(where: { $0.id == hovered })
                ? hovered : animation.state.requestedGroupID
            if let item = next(in: items, after: mainID) { focusMainItem(item) }
        }
    }

    private func activateKeyboardFocus() {
        switch keyboardFocus {
        case .main(let id):
            guard let item = items.first(where: { $0.id == id }) else { return }
            if let children = item.children {
                guard let first = children.first else { return }
                keyboardFocus = .submenu(groupID: id, itemID: first.id)
                showKeyboardPreview(of: item, highlighted: first.id)
            } else {
                select(item)
            }
        case .submenu(let groupID, let itemID):
            if let item = items.first(where: { $0.id == groupID })?.children?.first(where: { $0.id == itemID }) {
                select(item)
            }
        case nil:
            onCenter?()
        }
    }

    private func focusMainItem(_ item: RingItem) {
        keyboardFocus = .main(item.id)
        showKeyboardPreview(of: item, highlighted: item.id)
    }

    private func showKeyboardPreview(of item: RingItem, highlighted id: UUID) {
        if item.children?.isEmpty == false {
            if animation.requestGroup(item.id) { syncIcons() }
        } else {
            animation.clearRequestedGroup()
        }
        animation.setHighlighted(id)
        animateIfNeeded()
    }

    @discardableResult func goBack() -> Bool {
        if case .submenu(let groupID, _) = keyboardFocus,
           let parent = items.first(where: { $0.id == groupID }) {
            focusMainItem(parent)
            return true
        }
        guard animation.state.requestedGroupID != nil else { return false }
        if case .main = keyboardFocus {
            cancelDwell()
            cancelScheduledClose()
            animation.clearRequestedGroup()
            animateIfNeeded()
            return true
        }
        return collapse()
    }

    @discardableResult func collapse() -> Bool {
        guard animation.state.requestedGroupID != nil else { return false }
        cancelScheduledClose()
        animation.collapse()
        keyboardFocus = nil
        animateIfNeeded()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        guard !isPreview, let window, !isHidden else { return [] }
        let layout = makeLayout()
        return RingAccessibility.children(
            for: layout,
            running: runningItems,
            parent: self,
            screenFrame: { window.convertToScreen(convert($0, to: nil)) },
            onPress: { [weak self] item in self?.select(item) }
        )
    }

    private func select(_ item: RingItem) {
        guard item.isGroup else { onChoose?(item); return }
        if animation.state.requestedGroupID == item.id {
            collapse()
            return
        }
        if animation.requestGroup(item.id) {
            syncIcons()
        }
        animateIfNeeded()
    }

    private func syncIcons(reloadTop: Bool = false) {
        let topIDs = Set(items.map(\.id))
        let childIDs = Set(shownGroup?.children?.map(\.id) ?? [])
        if reloadTop {
            // prepare() must refresh main icons so edits made in Settings appear
            // without restarting the launcher.
            icons = icons.filter { topIDs.contains($0.key) }
            for item in items { icons[item.id] = item.icon() }
        } else {
            icons = icons.filter { topIDs.contains($0.key) || childIDs.contains($0.key) }
            for item in items where icons[item.id] == nil {
                icons[item.id] = item.icon()
            }
        }
        for child in shownGroup?.children ?? [] where icons[child.id] == nil {
            icons[child.id] = child.icon()
        }
    }

    private func makeLayout() -> RingLayout {
        RingLayout(metrics: metrics, input: RingGeometryInput(
            items: items,
            appearance: ringAppearance,
            bounds: bounds,
            magnification: animation.magnification,
            shownGroupID: animation.state.shownGroupID,
            requestedGroupID: animation.state.requestedGroupID,
            highlightedID: animation.state.highlightedID,
            arc: animation.state.arc,
            intro: animation.state.intro,
            isPreview: isPreview
        ))
    }

    private func stopAnimationTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func animateIfNeeded() {
        if reducedMotion {
            stopAnimationTimer()
            let update = animation.snap(items: items)
            if update.shownGroupChanged { syncIcons() }
            redraw()
            NSAccessibility.post(element: self, notification: .layoutChanged)
            return
        }
        guard timer == nil else { return }
        previousFrame = ProcessInfo.processInfo.systemUptime
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = ticker
        RunLoop.main.add(ticker, forMode: .common)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - previousFrame, 0.05)
        previousFrame = now
        let update = animation.advance(now: now, dt: dt, items: items,
                                       appearance: ringAppearance,
                                       reducedMotion: reducedMotion)
        if update.shownGroupChanged { syncIcons() }
        if update.redraw { redraw() } else { surface.needsDisplay = true }
        if update.settled {
            stopAnimationTimer()
            if update.accessibilityLayoutChanged {
                NSAccessibility.post(element: self, notification: .layoutChanged)
            }
        }
    }

    private func redraw() {
        let layout = makeLayout()
        currentLayout = layout
        // The backdrop and the drawn border use the very same paths for this frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = effect.bounds
        submenuMask.frame = submenuEffect.bounds
        // The backdrop layer uses a bottom-left origin, unlike the ring view.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        mask.path = layout.mainPath.copy(using: &flip)
        submenuMask.path = layout.submenuPath?.copy(using: &flip)
        effect.alphaValue = 0.84 * min(1, animation.state.intro * 2.8)
        submenuEffect.isHidden = layout.submenu == nil
        submenuEffect.alphaValue = effect.alphaValue * (layout.submenu?.glassOpacity ?? 0)
        surface.needsDisplay = true
        surface.displayIfNeeded()
        CATransaction.commit()
    }

    private func renderScene() {
        guard let context = NSGraphicsContext.current?.cgContext,
              let layout = currentLayout else { return }
        renderer.draw(RingScene(layout: layout, appearance: ringAppearance,
                                icons: icons, runningItems: runningItems),
                      in: context)
    }
}

private final class Surface: NSView {
    var render: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { render?() }
}
