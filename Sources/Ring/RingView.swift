import AppKit

@MainActor
final class RingView: NSView {
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
    private var focusedIndex: Int?
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
        focusedIndex = nil
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
        focusedIndex = nil
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
        focusedIndex = nil
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

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard !isShowingContextMenu else { return }
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

    // Arrow keys traverse the visible entries, Enter activates and Tab opens the system launcher.
    override func keyDown(with event: NSEvent) {
        cancelDwell()
        cancelScheduledClose()
        let visible = items + (requestedGroup?.children ?? [])
        switch event.keyCode {
        case 48:
            onCenter?()
        case 123, 125, 124, 126:
            guard !visible.isEmpty else { return }
            let forward = event.keyCode == 124 || event.keyCode == 125
            let index = focusedIndex ?? (forward ? -1 : 0)
            focusedIndex = (index + visible.count + (forward ? 1 : -1)) % visible.count
            updateHover(visible[focusedIndex!].id)
        case 36, 76:
            if let focusedIndex, visible.indices.contains(focusedIndex) {
                select(visible[focusedIndex])
            } else {
                onCenter?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    @discardableResult func collapse() -> Bool {
        guard animation.state.requestedGroupID != nil else { return false }
        cancelScheduledClose()
        animation.collapse()
        focusedIndex = nil
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
