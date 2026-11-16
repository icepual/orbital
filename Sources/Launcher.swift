import AppKit
import Carbon
import ImageIO

@MainActor
final class LauncherPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var config = Configuration.load()
    private let panel = LauncherPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 480),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
    private let ring = RingView(frame: .zero)
    private let catalog = CatalogView(frame: .zero)
    private var catalogOpen = false
    private var isShowing = false
    private var mouseMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var statusItem: NSStatusItem!
    private var shortcutMenu: NSMenuItem!
    private var settings: SettingsWindow?
    private var registration: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var activeShortcut: Shortcut?
    private var shortcutWarning: String?
    private var nextHotKeyID = UInt32(0)
    private var hotKeyDown = false
    private var scanGeneration = 0
    private var index: [IndexedApp] = []
    private var scanTask: Task<Void, Never>?
    private var lastScan: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureEditingMenu()
        configureMenu()
        configurePanel()
        installHandler()
        updateShortcut()
        show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isShowing { show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let registration { UnregisterEventHotKey(registration) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private func configurePanel() {
        panel.title = "环启"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.handleKey = { [weak self] event in self?.handle(event) ?? false }

        let host = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        ring.frame = host.bounds
        ring.autoresizingMask = [.width, .height]
        host.addSubview(ring)
        catalog.isHidden = true
        catalog.autoresizingMask = [.width, .height]
        catalog.frame = host.bounds.insetBy(dx: 19, dy: 30)
        host.addSubview(catalog)
        panel.contentView = host

        ring.onCenter = { [weak self] in self?.openNativeLauncher() }
        ring.onEmpty = { [weak self] in self?.hide() }
        ring.onChoose = { [weak self] item in self?.open(item.target?.url, name: item.name) }
        catalog.onBack = { [weak self] in self?.closeCatalog() }
        catalog.onOpen = { [weak self] app in self?.open(app.url, name: app.name) }
    }

    private func configureEditingMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "环启", action: nil, keyEquivalent: ""))
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.submenu?.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "环启")
            ?? NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "环启")
        statusItem.button?.toolTip = "环启"
        let menu = NSMenu()
        shortcutMenu = NSMenuItem(title: "呼出圆环", action: #selector(toggle), keyEquivalent: "")
        shortcutMenu.target = self
        menu.addItem(shortcutMenu)
        menu.addItem(withTitle: "全部应用", action: #selector(openNativeLauncher), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "退出环启", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func installHandler() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let event, let info else { return OSStatus(eventNotHandledErr) }
            let launcher = Unmanaged<Launcher>.fromOpaque(info).takeUnretainedValue()
            let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { launcher.receiveHotKey(isDown: isDown) }
            return noErr
        }, types.count, &types, context, &eventHandler)
        if result != noErr { eventHandler = nil }
    }

    private func receiveHotKey(isDown: Bool) {
        if isDown && !hotKeyDown { toggle() }
        hotKeyDown = isDown
    }

    private func register(_ binding: Shortcut) -> Bool {
        guard eventHandler != nil else { return false }
        nextHotKeyID &+= 1
        let identifier = EventHotKeyID(signature: 0x4F524254, id: nextHotKeyID)
        var newRegistration: EventHotKeyRef?
        let error = RegisterEventHotKey(binding.key, binding.modifiers, identifier,
                                        GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &newRegistration)
        guard error == noErr, let newRegistration else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        registration = newRegistration
        activeShortcut = binding
        hotKeyDown = false
        return true
    }

    private func updateShortcut() {
        if activeShortcut == config.shortcut || register(config.shortcut) {
            shortcutWarning = nil
        } else {
            if activeShortcut == nil {
                for fallback in Shortcut.choices.prefix(3) where fallback != config.shortcut {
                    if register(fallback) { break }
                }
            }
            shortcutWarning = activeShortcut.map {
                "\(config.shortcut.title) 不可用，当前使用 \($0.title)。"
            } ?? "\(config.shortcut.title) 不可用，可从菜单栏呼出。"
        }
        shortcutMenu.title = activeShortcut.map { "呼出圆环     \($0.title)" } ?? "呼出圆环"
    }

    @objc private func toggle() {
        if isShowing { hide() } else { show() }
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 480, height: 480)
        catalogOpen = false
        catalog.isHidden = true
        ring.isHidden = false
        ring.prepare(config.items, appearance: config.appearance ?? Appearance())
        let size = min(ring.preferredPanelSize, visible.width, visible.height)
        panel.setFrame(CGRect(x: visible.midX - size / 2, y: visible.midY - size / 2,
                              width: size, height: size), display: false)
        ring.layoutSubtreeIfNeeded()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(ring)
        panel.makeMain()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(restoreFocus: false) }
        }
        refreshIndex()
    }

    private func hide(restoreFocus: Bool = true) {
        guard isShowing else { return }
        isShowing = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        catalogOpen = false
        ring.suspend()
        panel.orderOut(nil)
        catalog.releaseRows()
        if restoreFocus {
            if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate()
            } else if settings?.window?.isVisible == true {
                settings?.window?.makeKeyAndOrderFront(nil)
            }
        }
        previousApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !ring.isShowingContextMenu else { return }
        hide(restoreFocus: false)
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            if catalogOpen, let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                return false
            }
            if catalogOpen { closeCatalog() }
            else if !ring.collapse() { hide() }
            return true
        }
        if !catalogOpen, event.keyCode == 43, event.modifierFlags.contains(.command) {
            openSettings()
            return true
        }
        guard !catalogOpen, event.modifierFlags.intersection([.command, .control]).isEmpty,
              ![36, 48, 51, 76, 117, 123, 124, 125, 126].contains(event.keyCode),
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0)
                  && !(0xf700...0xf8ff).contains($0.value) }) else { return false }
        showCatalog(event)
        return true
    }

    @objc private func openNativeLauncher() {
        guard let url = NativeLauncher.url else {
            hide(restoreFocus: false)
            report("无法找到系统的应用启动器", detail: "请从 Dock 打开「应用程序」。")
            return
        }
        open(url, name: "全部应用")
    }

    private func showCatalog(_ event: NSEvent? = nil) {
        guard !catalogOpen else { return }
        catalogOpen = true
        catalog.isHidden = false
        ring.isHidden = true
        ring.suspend()
        refreshIndex()
        catalog.update(index, scanning: scanTask != nil)
        catalog.present(in: panel, forwarding: event)
    }

    private func closeCatalog() {
        catalogOpen = false
        catalog.isHidden = true
        catalog.releaseRows()
        ring.isHidden = false
        ring.prepare(config.items, appearance: config.appearance ?? Appearance())
        panel.makeFirstResponder(ring)
    }

    private func refreshIndex(force: Bool = false) {
        if !force {
            guard scanTask == nil else { return }
            if let lastScan, Date().timeIntervalSince(lastScan) < 4 { return }
        }
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let targets = config.items.flatMap { [$0] + ($0.children ?? []) }.compactMap { $0.target?.url }
        scanTask = Task { [weak self] in
            let apps = await Task.detached(priority: .utility) { AppIndexer.scan(userLocations: targets) }.value
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            self.lastScan = Date()
            self.index = apps
            self.scanTask = nil
            if self.catalogOpen { self.catalog.update(apps, scanning: false) }
        }
    }

    private func open(_ url: URL?, name: String) {
        hide(restoreFocus: false)
        guard let url else {
            report("找不到「\(name)」", detail: "可在环启设置里重新选择要打开的应用。")
            return
        }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: options) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.report("无法打开「\(name)」", detail: error.localizedDescription)
                }
            }
        }
    }

    private func report(_ title: String, detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openSettings() {
        hide(restoreFocus: false)
        if settings == nil {
            let window = SettingsWindow(config: config)
            window.onChange = { [weak self] newConfig in
                self?.config = newConfig
                newConfig.save()
                self?.updateShortcut()
                self?.lastScan = nil
                return self?.shortcutWarning
            }
            settings = window
        }
        settings?.updateStatus(shortcutWarning)
        NSApp.activate()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
func makeIcon(at directory: String) throws {
    let accent = NSColor(red: 0.78, green: 0.69, blue: 1, alpha: 1).cgColor
    for factor in [1, 2] {
        for size in [16, 32, 128, 256, 512] {
            let pixels = size * factor
            let space = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
            let frame = CGRect(x: 7, y: 7, width: 86, height: 86)
            let tile = CGPath(roundedRect: frame, cornerWidth: 20, cornerHeight: 20, transform: nil)
            ctx.saveGState()
            ctx.addPath(tile)
            ctx.clip()
            let colors = [NSColor(red: 0.37, green: 0.28, blue: 0.64, alpha: 1).cgColor,
                          NSColor(red: 0.095, green: 0.075, blue: 0.19, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 25, y: 91), end: CGPoint(x: 80, y: 8), options: [])
            }
            ctx.restoreGState()
            ctx.addPath(tile)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            let origin = CGPoint(x: 46, y: 48)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(7.3)
            ctx.strokeEllipse(in: CGRect(x: origin.x - 18, y: origin.y - 18, width: 36, height: 36))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.94).cgColor)
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            ctx.addArc(center: origin, radius: 31, startAngle: -0.11, endAngle: 1.38, clockwise: false)
            ctx.strokePath()
            let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                if !CGImageDestinationFinalize(dest) { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}

@main
struct OrbitalApp {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--make-icon" {
            try makeIcon(at: CommandLine.arguments[2])
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Launcher()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
