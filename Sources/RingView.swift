import AppKit

@MainActor
final class RingView: NSView {
    private let effect = NSVisualEffectView()
    private let mask = CAShapeLayer()
    private let surface = Surface()
    private let isPreview: Bool
    private var icons: [UUID: NSImage] = [:]
    private var runningItems: Set<UUID> = []
    private var runningAppsObservation: NSKeyValueObservation?
    private var magnification: [UUID: CGFloat] = [:]
    private var visualSettings = Appearance()
    private var baseMainRadius: CGFloat = 30
    private var outerRadii: [UUID: CGFloat] = [:]
    private var maximumExtent: CGFloat = 0
    private var mainPath: CGPath = CGMutablePath()
    private var submenuPath: CGPath?
    private var submenuGeometry: Arc?
    private var dwellTimer: Timer?
    private var pendingHover: UUID?
    private var hoverTargets: [UUID: CGFloat] = [:]
    private var hoverOrigins: [UUID: CGFloat] = [:]
    private var hoverStarted = 0.0
    private var closeTimer: Timer?
    private var timer: Timer?
    private var previousFrame = 0.0
    private var intro = 1.0
    private var arc = 0.0
    private var opening = false
    private var shownGroup: RingItem?
    private var requestedGroup: RingItem?
    private var highlighted: UUID?
    private var hoverPoint: CGPoint?
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
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = isPreview ? .withinWindow : .behindWindow
        effect.wantsLayer = true
        effect.layer?.mask = mask
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.white.cgColor
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        surface.wantsLayer = true
        surface.render = { [weak self] in self?.render() }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        setAccessibilityElement(!isPreview)
        setAccessibilityRole(.group)
        setAccessibilityLabel("环启应用菜单")
    }

    required init?(coder: NSCoder) { nil }

    func prepare(_ items: [RingItem], appearance: Appearance) {
        self.visualSettings = appearance
        cancelDwell()
        hoverTargets.removeAll()
        hoverOrigins.removeAll()
        cancelScheduledClose()
        self.items = items
        if !isPreview { observeRunningApps() }
        updateRingRadii()
        icons = icons.filter { pair in items.contains { $0.id == pair.key } }
        for item in items { icons[item.id] = item.icon() }
        shownGroup = nil
        requestedGroup = nil
        highlighted = nil
        focusedIndex = nil
        hoverPoint = nil
        magnification.removeAll()
        arc = 0
        intro = isPreview || reducedMotion ? 1 : 0
        opening = intro < 1
        redraw()
        if opening { animate() }
    }

    func updatePreviewAppearance(_ appearance: Appearance) {
        visualSettings = appearance
        updateRingRadii()
        redraw()
    }

    func showPreviewGroup(_ group: RingItem?) {
        if let prior = shownGroup?.children {
            for child in prior { icons.removeValue(forKey: child.id) }
        }
        shownGroup = group
        requestedGroup = group
        for child in group?.children ?? [] { icons[child.id] = child.icon() }
        arc = group == nil ? 0 : 1
        redraw()
    }

    var preferredPanelSize: CGFloat {
        max(480, ceil(2 * (maximumExtent * 1.065 + 14)))
    }

    func suspend() {
        runningAppsObservation = nil
        cancelDwell()
        cancelScheduledClose()
        timer?.invalidate()
        timer = nil
        shownGroup = nil
        requestedGroup = nil
        arc = 0
        // Keep the small primary icon cache and release icons from other groups.
        icons = icons.filter { pair in items.contains { $0.id == pair.key } }
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
            guard !entry.isGroup, entry.target?.runningApplication(in: running) != nil else { return nil }
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
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
                                                             .mouseMoved, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }

    private func updatePointer(at point: CGPoint) {
        guard !isShowingContextMenu else { return }
        focusedIndex = nil
        hoverPoint = point
        let hovered = item(at: point)
        if hovered?.id == requestedGroup?.id
            || hovered.map({ child in requestedGroup?.children?.contains(where: { $0.id == child.id }) == true }) == true {
            cancelScheduledClose()
        } else {
            scheduleClose()
        }
        updateHover(hovered?.id)
        guard hovered?.id != pendingHover else { return }
        cancelDwell()
        pendingHover = hovered?.id
        guard let hovered, hovered.isGroup, requestedGroup?.id != hovered.id else { return }
        let activate = { [weak self] in
            guard let self, self.pendingHover == hovered.id else { return }
            self.dwellTimer = nil
            self.cancelScheduledClose()
            if self.requestedGroup?.id != hovered.id { self.select(hovered) }
        }
        if visualSettings.hoverDelay <= 0 { activate(); return }
        let dwell = Timer(timeInterval: visualSettings.hoverDelay, repeats: false) { _ in
            MainActor.assumeIsolated { activate() }
        }
        dwellTimer = dwell
        RunLoop.main.add(dwell, forMode: .common)
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        pendingHover = nil
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard !isShowingContextMenu else { return }
        cancelDwell()
        hoverPoint = nil
        updateHover(nil)
        scheduleClose()
    }

    private func updateHover(_ item: UUID?) {
        guard item != highlighted else { return }
        highlighted = item
        animate()
    }

    private func cancelScheduledClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }

    private func scheduleClose() {
        guard requestedGroup != nil, closeTimer == nil else { return }
        let pending = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeTimer = nil
                self.requestedGroup = nil
                self.animate()
            }
        }
        closeTimer = pending
        RunLoop.main.add(pending, forMode: .common)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item = item(at: point) {
            if !item.isGroup || requestedGroup?.id != item.id { select(item) }
        } else {
            onEmpty?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let item = item(at: point), !item.isGroup, let target = item.target else { return }
        let menu = NSMenu()
        let action: NSMenuItem
        if let running = target.runningApplication(in: NSWorkspace.shared.runningApplications) {
            action = NSMenuItem(title: "退出", action: #selector(quitContextApp(_:)), keyEquivalent: "")
            action.representedObject = running
        } else {
            action = NSMenuItem(title: "打开", action: #selector(openContextApp(_:)), keyEquivalent: "")
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
        guard let app = sender.representedObject as? NSRunningApplication, !app.isTerminated else { return }
        if !app.terminate() { NSSound.beep() }
    }

    // Arrow keys traverse the visible entries, Enter activates and Tab opens the system launcher.
    override func keyDown(with event: NSEvent) {
        cancelDwell()
        cancelScheduledClose()
        hoverPoint = nil
        let visible = items + (requestedGroup?.children ?? [])
        switch event.keyCode {
        case 48: onCenter?()
        case 123, 125, 124, 126:
            guard !visible.isEmpty else { return }
            let forward = event.keyCode == 124 || event.keyCode == 125
            let index = focusedIndex ?? (forward ? -1 : 0)
            focusedIndex = (index + visible.count + (forward ? 1 : -1)) % visible.count
            updateHover(visible[focusedIndex!].id)
        case 36, 76:
            if let focusedIndex, visible.indices.contains(focusedIndex) {
                select(visible[focusedIndex])
            } else { onCenter?() }
        default: super.keyDown(with: event)
        }
    }

    @discardableResult func collapse() -> Bool {
        guard requestedGroup != nil else { return false }
        cancelScheduledClose()
        requestedGroup = nil
        focusedIndex = nil
        highlighted = nil
        animate()
        NSAccessibility.post(element: self, notification: .layoutChanged)
        return true
    }

    override func accessibilityChildren() -> [Any]? {
        guard !isPreview, let window, !isHidden else { return [] }
        var buttons: [Any] = []
        func button(label: String, at point: CGPoint, radius: CGFloat,
                    action: @escaping @MainActor () -> Void) -> RingAccessibilityButton {
            let element = RingAccessibilityButton(action: action)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
            return element
        }
        for (index, item) in items.enumerated() {
            let text = item.isGroup ? item.name + "分组" : applicationLabel(item)
            let strength = magnification[item.id] ?? 0
            let point = liftedIcon(radius: mainRadius, angle: mainAngles[index], size: mainIconSize, strength: strength)
            buttons.append(button(label: text, at: point, radius: mainIconSize * (1 + visualSettings.magnification * strength) / 2) { [weak self] in
                self?.select(item)
            })
        }
        if let group = shownGroup, group.id == requestedGroup?.id,
           let children = group.children, let value = outerArc(for: group), arc > 0.04 {
            for (index, child) in children.enumerated() {
                let strength = magnification[child.id] ?? 0
                let size = childIconSize * zoom * value.openingScale
                let point = liftedIcon(radius: value.radius, angle: value.angles[index], size: size, strength: strength)
                buttons.append(button(label: applicationLabel(child), at: point, radius: size * (1 + visualSettings.magnification * strength) / 2) { [weak self] in
                    self?.select(child)
                })
            }
        }
        return buttons
    }

    private func applicationLabel(_ item: RingItem) -> String {
        runningItems.contains(item.id) ? item.name + "，运行中" : item.name
    }

    private func select(_ item: RingItem) {
        guard item.isGroup else { onChoose?(item); return }
        if requestedGroup?.id == item.id { collapse(); return }
        requestedGroup = item
        if shownGroup == nil {
            shownGroup = item
            for child in item.children ?? [] { icons[child.id] = child.icon() }
        }
        animate()
    }

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var sizeFactor: CGFloat {
        if isPreview { return submenuPreviewScale }
        let available = min(bounds.width, bounds.height) / 2 - 14
        return min(1, max(0.1, available / max(1, maximumExtent * 1.065)))
    }
    private var submenuPreviewScale: CGFloat {
        shownGroup?.children?.isEmpty == false ? 0.26 : 0.36
    }
    private var zoom: CGFloat {
        let t = intro - 1
        return sizeFactor * (1 + 2.3 * t * t * t + 1.3 * t * t)
    }
    private var mainRadius: CGFloat { baseMainRadius * zoom }
    private let mainSpan: CGFloat = 5 * .pi / 3
    private var mainWidth: CGFloat { visualSettings.ringWidth }
    private var mainIconSize: CGFloat { visualSettings.iconSize * zoom }
    private var mainEdge: CGFloat { (baseMainRadius + mainWidth / 2) * zoom }
    private var outerBandWidth: CGFloat { visualSettings.ringWidth }
    private var outerWidth: CGFloat { outerBandWidth * zoom }
    private var childIconSize: CGFloat { visualSettings.iconSize }

    private func updateRingRadii() {
        baseMainRadius = fittedRadius(count: items.count, size: visualSettings.iconSize, lift: 6,
                                     minimum: max(visualSettings.initialRadius ?? 30, mainWidth / 2 + 10),
                                     span: mainSpan)
        let mainIconReach = visualSettings.iconSize / sqrt(2)
        let mainOutset = max(mainWidth / 2, mainIconReach * (1 + 2 * visualSettings.magnification) + 4)
        let childInset = max(outerBandWidth / 2, childIconSize / sqrt(2))
        // Reserve room for both glass bands and icon corners throughout magnification.
        let minimum = baseMainRadius + mainOutset + childInset + 7
        outerRadii.removeAll(keepingCapacity: true)
        for group in items {
            guard let children = group.children, !children.isEmpty else { continue }
            outerRadii[group.id] = fittedRadius(count: children.count, size: childIconSize,
                                               lift: 0, minimum: minimum)
        }
        let childOutset = max(outerBandWidth / 2,
                              childIconSize * (1 + 2 * visualSettings.magnification) / sqrt(2) + 4)
        maximumExtent = max(baseMainRadius + mainOutset, (outerRadii.values.max() ?? 0) + childOutset)
    }

    private let iconGap: CGFloat = 10

    private func fittedRadius(count: Int, size: CGFloat, lift: CGFloat, minimum: CGFloat,
                              span: CGFloat = 2 * .pi) -> CGFloat {
        let scale = visualSettings.magnification
        let activeHalf = size * (1 + scale) / 2
        let neighborHalf = size * (1 + scale * exp(-1.1)) / 2
        var lower = max(minimum, activeHalf + lift + 1)
        var upper = max(lower + CGFloat(count) * (size + iconGap),
                        CGFloat(count) * (size + iconGap) / max(0.1, span))
        for _ in 0..<14 {
            let radius = (lower + upper) / 2
            let total = 2 * (asin(activeHalf / (radius - lift))
                + CGFloat(min(2, max(0, count - 1))) * asin(neighborHalf / (radius - lift))
                + CGFloat(max(0, count - 3)) * asin(size / (2 * radius)))
                + (CGFloat(count) * iconGap + 14) / radius
            if total > span { lower = radius } else { upper = radius }
        }
        return upper
    }

    // Pack angular footprints with a constant gap. Any extra space stays at the ends.
    private func packedAngles(_ entries: [RingItem], radius: CGFloat, size: CGFloat,
                              middle: Double) -> [Double] {
        let halves = entries.map { entry -> CGFloat in
            let strength = magnification[entry.id] ?? 0
            let half = size * (1 + visualSettings.magnification * strength) / 2
            let iconRadius = radius + radialLift(size: size, strength: strength)
            return asin(min(0.99, half / iconRadius))
        }
        let gap = iconGap * zoom / radius
        let occupied = 2 * halves.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * gap
        var edge = middle - occupied / 2
        return halves.map { half in
            let angle = edge + half
            edge += 2 * half + gap
            return angle
        }
    }

    private var mainAngles: [Double] {
        // View coordinates increase downwards, so an arc centered at the top leaves its gap below.
        packedAngles(items, radius: mainRadius, size: mainIconSize, middle: -.pi / 2)
    }

    private struct Arc {
        var radius: CGFloat
        var start: Double
        var end: Double
        var angles: [Double]
        var openingScale: CGFloat
    }

    private func outerArc(for group: RingItem) -> Arc? {
        guard let children = group.children, !children.isEmpty,
              let baseRadius = outerRadii[group.id],
              let parent = items.firstIndex(where: { $0.id == group.id }) else { return nil }
        let middle = mainAngles[parent]
        let progress = ease(arc)
        let radius = baseRadius * zoom
        let openingScale = max(0.08, progress)
        let angles = packedAngles(children, radius: radius, size: childIconSize * zoom, middle: middle)
            .map { middle + ($0 - middle) * openingScale }
        let start = angles[0] - 0.018
        let end = angles[angles.count - 1] + 0.018
        return Arc(radius: radius, start: start, end: end, angles: angles, openingScale: openingScale)
    }

    private func animate() {
        if reducedMotion {
            intro = 1
            opening = false
            shownGroup = requestedGroup
            for child in shownGroup?.children ?? [] { icons[child.id] = child.icon() }
            arc = shownGroup == nil ? 0 : 1
            _ = advanceHover(1)
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
        let oldIntro = intro
        let oldGroup = shownGroup?.id
        let oldArc = arc
        if opening {
            intro = min(1, intro + dt / 0.23)
            opening = intro < 1
        }
        if shownGroup?.id == requestedGroup?.id, shownGroup != nil {
            arc = min(1, arc + dt / visualSettings.animationDuration)
        } else {
            arc = max(0, arc - dt / (visualSettings.animationDuration * 0.5))
            if arc == 0 {
                if let prior = shownGroup?.children {
                    for child in prior { icons.removeValue(forKey: child.id) }
                }
                shownGroup = requestedGroup
                for child in shownGroup?.children ?? [] { icons[child.id] = child.icon() }
            }
        }
        let priorMagnification = magnification
        let hoverMoving = advanceHover(1 - exp(-24 * dt))
        let geometryChanged = oldIntro != intro || oldGroup != shownGroup?.id || oldArc != arc
        if geometryChanged || priorMagnification != magnification { redraw() }
        else { surface.needsDisplay = true }

        let groupSettled = shownGroup == nil && requestedGroup == nil
            || arc == 1 && shownGroup?.id == requestedGroup?.id
        if !opening && groupSettled && !hoverMoving {
            timer?.invalidate()
            timer = nil
            if geometryChanged { NSAccessibility.post(element: self, notification: .layoutChanged) }
        }
    }

    private func advanceHover(_ fraction: CGFloat) -> Bool {
        var targets: [UUID: CGFloat] = [:]
        func addMagnification(around id: UUID?, in entries: [RingItem]) {
            guard let selected = entries.firstIndex(where: { $0.id == id }) else { return }
            for (index, item) in entries.enumerated() {
                let offset = CGFloat(index - selected)
                let influence = exp(-1.1 * offset * offset)
                if influence >= 0.015 { targets[item.id] = influence }
            }
        }

        if items.contains(where: { $0.id == highlighted }) {
            addMagnification(around: highlighted, in: items)
        } else {
            // Keep the submenu anchor stable while the pointer crosses into the outer arc.
            addMagnification(around: requestedGroup?.id, in: items)
        }
        if let group = shownGroup, group.id == requestedGroup?.id {
            addMagnification(around: highlighted, in: group.children ?? [])
        }
        let now = ProcessInfo.processInfo.systemUptime
        if targets != hoverTargets {
            hoverOrigins = magnification
            hoverTargets = targets
            hoverStarted = now
        }
        let progress = fraction == 1 ? 1 : min(1, (now - hoverStarted) / visualSettings.animationDuration)
        let eased = ease(progress)
        for id in Set(hoverOrigins.keys).union(hoverTargets.keys) {
            let start = hoverOrigins[id] ?? 0
            let target = hoverTargets[id] ?? 0
            let current = start + (target - start) * eased
            magnification[id] = current > 0.001 ? current : nil
        }
        return progress < 1
    }

    private func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    private func distance(_ point: CGPoint, _ other: CGPoint) -> CGFloat {
        hypot(point.x - other.x, point.y - other.y)
    }
    private func polar(_ radius: CGFloat, _ theta: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
    }
    private func radialLift(size: CGFloat, strength: CGFloat) -> CGFloat {
        (size * visualSettings.magnification / sqrt(2) + 4 * zoom) * strength
    }

    private func liftedIcon(radius: CGFloat, angle: CGFloat, size: CGFloat, strength: CGFloat) -> CGPoint {
        polar(radius + radialLift(size: size, strength: strength), angle)
    }

    private func arcPath(_ radius: CGFloat, _ width: CGFloat, _ start: Double,
                         _ end: Double, _ cap: CGLineCap) -> CGPath {
        let spine = CGMutablePath()
        spine.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return spine.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .round, miterLimit: 0)
    }
    private func outerShape(_ value: Arc) -> CGPath {
        arcPath(value.radius, outerWidth, value.start, value.end, .round)
    }

    private func redraw() {
        mainPath = makeMainPath()
        submenuGeometry = arc > 0 ? shownGroup.flatMap(outerArc) : nil
        submenuPath = submenuGeometry.map(outerShape)
        // The backdrop and the drawn border use the very same paths for this frame.
        let combined = CGMutablePath()
        combined.addPath(mainPath)
        if let submenuPath { combined.addPath(submenuPath) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = effect.bounds
        // The backdrop layer uses a bottom-left origin, unlike the ring view.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        mask.path = combined.copy(using: &flip)
        effect.alphaValue = 0.84 * min(1, intro * 2.8)
        surface.needsDisplay = true
        surface.displayIfNeeded()
        CATransaction.commit()
    }

    private func item(at point: CGPoint) -> RingItem? {
        for (index, entry) in items.enumerated().sorted(by: {
            (magnification[$0.element.id] ?? 0) > (magnification[$1.element.id] ?? 0)
        }) {
            let strength = magnification[entry.id] ?? 0
            let pointCenter = liftedIcon(radius: mainRadius, angle: mainAngles[index], size: mainIconSize, strength: strength)
            let radius = mainIconSize * (1 + visualSettings.magnification * strength) / 2
            if distance(point, pointCenter) <= radius + iconGap * zoom / 4 { return entry }
        }
        if let index = items.firstIndex(where: { $0.id == highlighted }),
           distance(point, polar(mainRadius, mainAngles[index])) <= mainIconSize / 2 {
            return items[index]
        }
        if let group = shownGroup, group.id == requestedGroup?.id,
           let children = group.children, let value = outerArc(for: group), arc > 0.04 {
            let size = childIconSize * zoom * value.openingScale
            func iconCenter(_ index: Int) -> CGPoint {
                let strength = magnification[children[index].id] ?? 0
                return liftedIcon(radius: value.radius, angle: value.angles[index], size: size, strength: strength)
            }
            let nearest = children.indices.min {
                distance(point, iconCenter($0)) < distance(point, iconCenter($1))
            }
            if let nearest {
                let item = children[nearest]
                let strength = magnification[item.id] ?? 0
                let radius = size * (1 + visualSettings.magnification * strength) / 2
                if outerShape(value).contains(point, using: .evenOdd)
                    || distance(point, iconCenter(nearest)) <= radius { return item }
            }
        }
        return nil
    }

    private func makeMainPath() -> CGPath {
        let angles = mainAngles
        guard let first = angles.first, let last = angles.last else { return CGMutablePath() }
        let capMargin = 2 * zoom / mainRadius
        return arcPath(mainRadius, mainWidth * zoom, first - capMargin, last + capMargin, .round)
    }

    private func render() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(CGFloat(min(1, intro * 2.8)))
        defer { context.restoreGState() }

        glass(mainPath, context)
        let expandedArc = submenuGeometry
        if let group = shownGroup, let children = group.children, let value = expandedArc,
           let submenuPath {
            context.saveGState()
            context.setAlpha(CGFloat(min(1, arc * 4)))
            glass(submenuPath, context)
            for (index, child) in children.enumerated() where child.id != highlighted {
                drawChild(child, index: index, arc: value, context: context)
            }
            if let index = children.firstIndex(where: { $0.id == highlighted }) {
                drawChild(children[index], index: index, arc: value, context: context)
            }
            context.restoreGState()
        }

        for index in items.indices where items[index].id != highlighted {
            drawMain(index, context: context)
        }
        if let index = items.firstIndex(where: { $0.id == highlighted }) {
            drawMain(index, context: context)
        }
        drawHoverLabel(context, expandedArc: expandedArc)
    }

    private func drawMain(_ index: Int, context: CGContext) {
        let item = items[index]
        let strength = magnification[item.id] ?? 0
        let theta = mainAngles[index]
        let point = liftedIcon(radius: mainRadius, angle: theta, size: mainIconSize, strength: strength)
        drawIcon(icons[item.id], at: point, size: mainIconSize * (1 + visualSettings.magnification * strength),
                 lift: strength, running: runningItems.contains(item.id), context: context)
        if item.isGroup {
            let indicator = polar(mainRadius + 13 * zoom + strength * 13 * zoom, theta)
            let dot = (requestedGroup?.id == item.id ? 3.0 : 1.7) * zoom
            context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            context.fillEllipse(in: CGRect(x: indicator.x - dot / 2, y: indicator.y - dot / 2,
                                           width: dot, height: dot))
        }
    }

    private func drawChild(_ item: RingItem, index: Int, arc value: Arc, context: CGContext) {
        let strength = magnification[item.id] ?? 0
        let theta = value.angles[index]
        let size = childIconSize * zoom * value.openingScale
        let point = liftedIcon(radius: value.radius, angle: theta, size: size, strength: strength)
        let delay = min(0.34, Double(index) * 0.07)
        let alpha = min(1, max(0, (arc - delay) * 2))
        drawIcon(icons[item.id], at: point, size: size * (1 + visualSettings.magnification * strength),
                 lift: strength, alpha: alpha, running: runningItems.contains(item.id), context: context)
    }

    private func glass(_ shape: CGPath, _ context: CGContext) {
        if visualSettings.glow > 0 {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 10 * zoom,
                              color: NSColor.white.withAlphaComponent(visualSettings.glow * 0.8).cgColor)
            context.setStrokeColor(NSColor.white.withAlphaComponent(visualSettings.glow).cgColor)
            context.setLineWidth(1.25 * zoom)
            context.addPath(shape)
            context.strokePath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(shape)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 10,
                          color: NSColor.black.withAlphaComponent(0.23).cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(0.8)
        context.strokePath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip(using: .evenOdd)
        let colors = [NSColor.white.withAlphaComponent(0.24).cgColor,
                      NSColor.white.withAlphaComponent(0.035).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
            let rect = shape.boundingBoxOfPath
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                       end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.58).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
    }

    private func drawIcon(_ image: NSImage?, at point: CGPoint, size: CGFloat, lift: CGFloat,
                          alpha: CGFloat = 1, running: Bool, context: CGContext) {
        guard let image, alpha > 0 else { return }
        let displayed = image.isTemplate
            ? image.withSymbolConfiguration(.init(paletteColors: [.white])) ?? image
            : image
        let aspect = displayed.size.height > 0 ? displayed.size.width / displayed.size.height : 1
        let width = size * min(1, aspect)
        let height = size / max(1, aspect)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -(1 + lift * 2)), blur: 2 + lift * 4,
                          color: NSColor.black.withAlphaComponent(image.isTemplate ? 0.64 : 0.24).cgColor)
        displayed.draw(in: CGRect(x: point.x - width / 2, y: point.y - height / 2,
                                   width: width, height: height), from: .zero, operation: .sourceOver,
                       fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        context.restoreGState()
        if running {
            let diameter = min(4.5 * zoom, size * 0.13)
            let radius = distance(point, center)
            guard radius > 0, width > 0, height > 0 else { return }
            let dx = (center.x - point.x) / radius
            let dy = (center.y - point.y) / radius
            let iconEdge = 0.5 / max(abs(dx) / width, abs(dy) / height)
            let offset = iconEdge + 2.5 * zoom + diameter / 2
            let dot = CGRect(x: point.x + dx * offset - diameter / 2,
                             y: point.y + dy * offset - diameter / 2,
                             width: diameter, height: diameter)
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(alpha * 0.82).cgColor)
            context.fillEllipse(in: dot)
            context.setStrokeColor(NSColor.white.withAlphaComponent(alpha * 0.90).cgColor)
            context.setLineWidth(0.75 * zoom)
            context.strokeEllipse(in: dot)
            context.restoreGState()
        }
    }

    private func drawHoverLabel(_ context: CGContext, expandedArc: Arc?) {
        if let index = items.firstIndex(where: { $0.id == highlighted }) {
            let item = items[index]
            let theta = mainAngles[index]
            let strength = magnification[item.id] ?? 0
            let lifted = liftedIcon(radius: mainRadius, angle: theta, size: mainIconSize, strength: strength)
            let iconReach = mainIconSize * (1 + visualSettings.magnification * strength) / sqrt(2)
            var radius = max(mainEdge + 24 * zoom, distance(center, lifted) + iconReach + 16 * zoom)
            if let value = expandedArc {
                let middle = (value.start + value.end) / 2
                let offset = atan2(sin(theta - middle), cos(theta - middle))
                if abs(offset) < (value.end - value.start) / 2 + 0.24 {
                    radius = max(radius, value.radius + outerWidth / 2 + 24 * zoom)
                }
            }
            tooltip(item.name, at: polar(radius, theta), strength: magnification[item.id] ?? 0, context: context)
        } else if let children = shownGroup?.children, let value = expandedArc,
                  let index = children.firstIndex(where: { $0.id == highlighted }) {
            let theta = value.angles[index]
            let strength = magnification[children[index].id] ?? 0
            let size = childIconSize * zoom * value.openingScale
            let lifted = liftedIcon(radius: value.radius, angle: theta, size: size, strength: strength)
            let iconReach = size * (1 + visualSettings.magnification * strength) / sqrt(2)
            let radius = max(value.radius + outerWidth / 2 + 23 * zoom,
                             distance(center, lifted) + iconReach + 16 * zoom)
            tooltip(children[index].name, at: polar(radius, theta), strength: strength, context: context)
        }
    }

    private func tooltip(_ name: String, at point: CGPoint, strength: CGFloat, context: CGContext) {
        guard strength > 0.08 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: max(10, 12 * zoom), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
        ]
        let title = name as NSString
        let width = min(156, ceil(title.size(withAttributes: attributes).width) + 20)
        let x = min(max(4, point.x - width / 2), bounds.width - width - 4)
        let height: CGFloat = 24
        let y = min(max(3, point.y - height / 2), bounds.height - height - 3)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let shape = CGPath(roundedRect: frame, cornerWidth: 9, cornerHeight: 9, transform: nil)
        context.saveGState()
        context.setAlpha(min(1, strength * 1.6))
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 5,
                          color: NSColor.black.withAlphaComponent(0.30).cgColor)
        context.addPath(shape)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.40).cgColor)
        context.setLineWidth(0.65)
        context.addPath(shape)
        context.strokePath()
        title.draw(with: CGRect(x: x + 8, y: y + (height - font.ascender + font.descender) / 2,
                                width: width - 16, height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        context.restoreGState()
    }
}

private final class Surface: NSView {
    var render: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { render?() }
}


@MainActor
private final class RingAccessibilityButton: NSAccessibilityElement {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()
        setAccessibilityElement(true)
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
