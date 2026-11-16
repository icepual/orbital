import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import ImageIO

@MainActor
final class SettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Action: Int { case app, group, edit, remove, up, down }
    private enum Lane { case main, child }
    private let mainTable = NSTableView()
    private let childTable = NSTableView()
    private let childTitle = NSTextField(labelWithString: "分组应用")
    private let shortcut = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "登录时启动", target: nil, action: nil)
    private let shortcutStatus = NSTextField(labelWithString: "")
    private var mainButtons: [NSButton] = []
    private var childButtons: [NSButton] = []
    private var effectValues: [NSTextField] = []
    private let ringPreview = RingView(frame: .zero, isPreview: true)
    private var config: Configuration
    var onChange: ((Configuration) -> String?)?

    init(config: Configuration) {
        self.config = config
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "环启设置"
        window.center()
        setup()
    }

    required init?(coder: NSCoder) { nil }

    private var selectedMain: Int? {
        config.items.indices.contains(mainTable.selectedRow) ? mainTable.selectedRow : nil
    }

    private var selectedGroup: Int? {
        guard let index = selectedMain, config.items[index].isGroup else { return nil }
        return index
    }

    private var children: [RingItem] {
        guard let index = selectedGroup else { return [] }
        return config.items[index].children ?? []
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "环启")
        title.font = .systemFont(ofSize: 29, weight: .semibold)
        let hint = NSTextField(labelWithString: "添加应用或分组，双击项目修改名称和图标。")
        hint.textColor = .secondaryLabelColor

        shortcut.addItems(withTitles: Shortcut.choices.map(\.title))
        shortcut.selectItem(at: Shortcut.choices.firstIndex(of: config.shortcut) ?? 0)
        shortcut.target = self
        shortcut.action = #selector(changeShortcut)
        shortcutStatus.textColor = .secondaryLabelColor
        shortcutStatus.lineBreakMode = .byTruncatingTail
        login.target = self
        login.action = #selector(toggleLogin)
        refreshLogin()
        let controls = NSStackView(views: [NSTextField(labelWithString: "呼出快捷键"), shortcut, login])
        controls.spacing = 12

        let effects = appearanceControls()
        ringPreview.prepare(config.items, appearance: config.appearance ?? Appearance())
        let previewLabel = NSTextField(labelWithString: "实时预览 · 选中分组可查看子菜单")
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11)

        let mainTitle = NSTextField(labelWithString: "主环")
        let main = column(table: mainTable, label: mainTitle, action: #selector(mainAction(_:)), lane: .main)
        let child = column(table: childTable, label: childTitle, action: #selector(childAction(_:)), lane: .child)
        let reset = NSButton(title: "恢复默认布局…", target: self, action: #selector(resetLayout))
        reset.bezelStyle = .inline

        for view in [title, hint, controls, effects, ringPreview, previewLabel, main, child, reset, shortcutStatus] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 23),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            controls.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            controls.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 14),
            effects.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            effects.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            ringPreview.leadingAnchor.constraint(equalTo: content.centerXAnchor, constant: 36),
            ringPreview.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -40),
            ringPreview.topAnchor.constraint(equalTo: controls.topAnchor),
            ringPreview.bottomAnchor.constraint(equalTo: previewLabel.topAnchor, constant: -2),
            previewLabel.bottomAnchor.constraint(equalTo: effects.bottomAnchor),
            previewLabel.centerXAnchor.constraint(equalTo: ringPreview.centerXAnchor),
            main.topAnchor.constraint(equalTo: effects.bottomAnchor, constant: 18),
            main.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: content.centerXAnchor, constant: -8),
            child.topAnchor.constraint(equalTo: main.topAnchor),
            child.leadingAnchor.constraint(equalTo: content.centerXAnchor, constant: 8),
            child.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -23),
            main.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -14),
            child.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
            reset.trailingAnchor.constraint(equalTo: child.trailingAnchor),
            shortcutStatus.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            shortcutStatus.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -15),
            shortcutStatus.centerYAnchor.constraint(equalTo: reset.centerYAnchor)
        ])
        if !config.items.isEmpty {
            mainTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        refreshChildren()
    }

    private func appearanceControls() -> NSView {
        let appearance = config.appearance ?? Appearance()
        let specs: [(String, Double, Double, Double)] = [
            ("子菜单延迟", appearance.hoverDelay, 0, 0.8),
            ("动画时长", appearance.animationDuration, 0.15, 0.6),
            ("初始图标大小", appearance.iconSize, 28, 48),
            ("初始半径", appearance.initialRadius ?? 30, 30, 150),
            ("初始圆环宽度", appearance.ringWidth, 28, 72),
            ("悬停放大", appearance.magnification, 0.1, 0.8),
            ("边框外发光", appearance.glow, 0, 1)
        ]
        let rows = specs.enumerated().map { index, spec -> [NSView] in
            let label = NSTextField(labelWithString: spec.0)
            let slider = NSSlider(value: spec.1, minValue: spec.2, maxValue: spec.3,
                                  target: self, action: #selector(changeAppearance(_:)))
            slider.tag = index
            slider.isContinuous = true
            slider.setAccessibilityLabel(spec.0)
            slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
            let value = NSTextField(labelWithString: appearanceLabel(index, spec.1))
            value.widthAnchor.constraint(equalToConstant: 90).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            effectValues.append(value)
            return [label, slider, value]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 14
        return grid
    }

    private func appearanceLabel(_ index: Int, _ value: Double) -> String {
        switch index {
        case 0, 1: return "\(Int((value * 1000).rounded())) 毫秒"
        case 2, 3, 4: return "\(Int(value.rounded())) pt"
        case 5: return String(format: "%.2f 倍", 1 + value)
        default: return "\(Int((value * 100).rounded()))%"
        }
    }

    @objc private func changeAppearance(_ sender: NSSlider) {
        var appearance = config.appearance ?? Appearance()
        let value = sender.doubleValue
        switch sender.tag {
        case 0: appearance.hoverDelay = value
        case 1: appearance.animationDuration = value
        case 2: appearance.iconSize = value
        case 3: appearance.initialRadius = value
        case 4: appearance.initialRingWidth = value
        case 5: appearance.magnification = value
        case 6: appearance.glow = value
        default: return
        }
        effectValues[sender.tag].stringValue = appearanceLabel(sender.tag, value)
        config.appearance = appearance
        ringPreview.updatePreviewAppearance(appearance)
        save()
    }

    private func column(table: NSTableView, label: NSTextField, action: Selector, lane: Lane) -> NSStackView {
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = lane == .main ? #selector(editMain) : #selector(editChild)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        var actions: [(Action, String)] = [(.app, "添加应用")]
        if lane == .main { actions.append((.group, "添加分组")) }
        actions += [(.edit, "编辑"), (.remove, "移除"), (.up, "↑"), (.down, "↓")]
        let buttons = actions.map { item -> NSButton in
            let button = NSButton(title: item.1, target: self, action: action)
            button.tag = item.0.rawValue
            button.controlSize = .small
            if item.0 == .up || item.0 == .down {
                button.toolTip = item.0 == .up ? "向前移动" : "向后移动"
                button.setAccessibilityLabel(button.toolTip)
            }
            return button
        }
        if lane == .main { mainButtons = buttons } else { childButtons = buttons }
        let row = NSStackView(views: buttons)
        row.spacing = 4
        let stack = NSStackView(views: [label, scroll, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        return stack
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === mainTable ? config.items.count : children.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = (tableView === mainTable ? config.items : children)[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = item.icon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: item.name + (item.isGroup ? "  ›  \(item.children?.count ?? 0) 个应用" : ""))
        label.lineBreakMode = .byTruncatingTail
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === mainTable { refreshChildren() }
        updateButtons()
    }

    private func refreshChildren() {
        childTitle.stringValue = selectedGroup.map { config.items[$0].name + " · 分组应用" } ?? "选择主环中的分组"
        childTable.deselectAll(nil)
        childTable.reloadData()
        ringPreview.showPreviewGroup(selectedGroup.map { config.items[$0] })
        updateButtons()
    }

    private func updateButtons() {
        for (buttons, enabled, row, count, limit) in [
            (mainButtons, true, mainTable.selectedRow, config.items.count, 16),
            (childButtons, selectedGroup != nil, childTable.selectedRow, children.count, 18)
        ] {
            for button in buttons {
                switch Action(rawValue: button.tag) {
                case .app, .group:
                    button.isEnabled = enabled && count < limit
                    button.toolTip = count >= limit ? "最多 \(limit) 项" : nil
                case .edit, .remove: button.isEnabled = enabled && row >= 0 && row < count
                case .up: button.isEnabled = enabled && row > 0
                case .down: button.isEnabled = enabled && row >= 0 && row < count - 1
                case nil: break
                }
            }
        }
    }

    @objc private func mainAction(_ sender: NSButton) { act(Action(rawValue: sender.tag), lane: .main) }
    @objc private func childAction(_ sender: NSButton) { act(Action(rawValue: sender.tag), lane: .child) }
    @objc private func editMain() { act(.edit, lane: .main) }
    @objc private func editChild() { act(.edit, lane: .child) }

    private func act(_ action: Action?, lane: Lane) {
        guard let action, let window else { return }
        let row = lane == .main ? mainTable.selectedRow : childTable.selectedRow
        let group = selectedGroup
        var items = lane == .main ? config.items : children
        switch action {
        case .app:
            let picker = appPicker(multiple: true)
            picker.beginSheetModal(for: window) { [weak self] result in
                guard let self, result == .OK else { return }
                let limit = lane == .main ? 16 : 18
                items += picker.urls.prefix(max(0, limit - items.count)).map(self.makeApp)
                self.commit(items, lane: lane, group: group, selection: items.count - 1)
            }
        case .group:
            edit(RingItem(name: "新分组", children: []), title: "添加分组") { [weak self] item in
                items.append(item)
                self?.commit(items, lane: lane, group: group, selection: items.count - 1)
            }
        case .edit:
            guard items.indices.contains(row) else { return }
            edit(items[row], title: "编辑项目") { [weak self] item in
                items[row] = item
                self?.commit(items, lane: lane, group: group, selection: row)
            }
        case .remove:
            guard items.indices.contains(row) else { return }
            if items[row].isGroup, !(items[row].children ?? []).isEmpty {
                let alert = NSAlert()
                alert.messageText = "移除「\(items[row].name)」？"
                alert.informativeText = "此分组及其快捷入口会被移出圆环。"
                alert.addButton(withTitle: "移除")
                alert.addButton(withTitle: "取消")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn else { return }
                    items.remove(at: row)
                    self?.commit(items, lane: lane, group: group, selection: min(row, items.count - 1))
                }
                return
            }
            items.remove(at: row)
            commit(items, lane: lane, group: group, selection: min(row, items.count - 1))
        case .up, .down:
            let next = row + (action == .up ? -1 : 1)
            guard items.indices.contains(row), items.indices.contains(next) else { return }
            items.swapAt(row, next)
            commit(items, lane: lane, group: group, selection: next)
        }
    }

    private func commit(_ items: [RingItem], lane: Lane, group: Int?, selection: Int) {
        let table = lane == .main ? mainTable : childTable
        switch lane {
        case .main: config.items = items
        case .child:
            guard let group, config.items.indices.contains(group) else { return }
            config.items[group].children = items
            mainTable.reloadData()
            mainTable.selectRowIndexes(IndexSet(integer: group), byExtendingSelection: false)
            childTitle.stringValue = config.items[group].name + " · 分组应用"
        }
        table.reloadData()
        if selection >= 0 {
            table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
            table.scrollRowToVisible(selection)
        } else { table.deselectAll(nil) }
        ringPreview.prepare(config.items, appearance: config.appearance ?? Appearance())
        if lane == .main {
            refreshChildren()
        } else {
            ringPreview.showPreviewGroup(selectedGroup.map { config.items[$0] })
        }
        updateButtons()
        save()
    }

    private func makeApp(_ url: URL) -> RingItem {
        let bundle = Bundle(url: url)
        let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.localizedInfoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return RingItem(name: name, target: AppTarget(url: url))
    }

    private func appPicker(multiple: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = multiple
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = multiple ? "添加" : "选择"
        return panel
    }

    private func edit(_ item: RingItem, title: String, completion: @escaping (RingItem) -> Void) {
        guard let window else { return }
        let editor = EntryEditor(item: item, title: title)
        window.beginSheet(editor.window) { response in
            if response == .OK { completion(editor.entry) }
        }
    }

    @objc private func changeShortcut() {
        let index = shortcut.indexOfSelectedItem
        guard Shortcut.choices.indices.contains(index) else { return }
        config.shortcut = Shortcut.choices[index]
        save()
    }

    func updateStatus(_ message: String?) {
        shortcutStatus.stringValue = message ?? "配置自动保存"
    }

    private func save() { updateStatus(onChange?(config)) }

    private func refreshLogin() {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.toolTip = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许环启" : nil
    }

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval {
                shortcutStatus.stringValue = "请在系统设置的「登录项」中允许环启。"
            }
        } catch {
            shortcutStatus.stringValue = "无法更新登录项。\(error.localizedDescription)"
        }
        refreshLogin()
    }

    @objc private func resetLayout() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "恢复默认布局？"
        alert.informativeText = "当前的主环和分组设置将被替换。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.commit(Configuration.initial.items, lane: .main, group: nil, selection: 0)
        }
    }
}

@MainActor
private final class EntryEditor: NSObject {
    let window: NSWindow
    var entry: RingItem
    private let name = NSTextField()
    private let preview = NSImageView()
    private var iconButtons: [NSButton] = []

    init(item: RingItem, title: String) {
        let size = item.isGroup ? NSSize(width: 420, height: 400) : NSSize(width: 360, height: 212)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled], backing: .buffered, defer: false)
        entry = item
        super.init()
        window.title = title
        name.stringValue = item.name
        name.placeholderString = "名称"
        name.setAccessibilityLabel("名称")
        name.widthAnchor.constraint(equalToConstant: size.width - 44).isActive = true
        preview.image = entry.icon()
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 27).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let iconRow = NSStackView(views: [
            preview,
            NSButton(title: "导入图片…", target: self, action: #selector(pickIcon)),
            NSButton(title: "默认图标", target: self, action: #selector(resetIcon))
        ])
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEdit))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(saveEdit))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, save])
        var parts: [NSView] = [name, iconRow]
        if item.isGroup {
            let galleryTitle = NSTextField(labelWithString: "分组图标")
            galleryTitle.font = .systemFont(ofSize: 12, weight: .semibold)
            parts.append(contentsOf: [galleryTitle, makeIconGallery()])
        } else {
            parts.append(NSButton(title: "更换启动应用…", target: self, action: #selector(pickTarget)))
        }
        let stack = NSStackView(views: parts + [actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let content = window.contentView {
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18)
            ])
        }
        window.initialFirstResponder = name
    }

    private func makeIconGallery() -> NSGridView {
        iconButtons = GroupIcon.palette.enumerated().map { index, icon in
            let button = NSButton(title: icon.name, image: icon.image(), target: self,
                                  action: #selector(changeSymbol(_:)))
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.tag = index
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: 84).isActive = true
            button.heightAnchor.constraint(equalToConstant: 62).isActive = true
            return button
        }
        refreshIconSelection()
        let rows = stride(from: 0, to: iconButtons.count, by: 4).map {
            Array(iconButtons[$0..<min($0 + 4, iconButtons.count)])
        }
        let gallery = NSGridView(views: rows)
        gallery.rowSpacing = 5
        gallery.columnSpacing = 8
        return gallery
    }

    private func refreshIconSelection() {
        for button in iconButtons {
            let selected = entry.iconData == nil && entry.symbol == GroupIcon.palette[button.tag].symbol
            button.state = selected ? .on : .off
            button.layer?.borderWidth = selected ? 1.3 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(selected ? 0.12 : 0).cgColor
        }
    }

    @objc private func pickIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "使用图标"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 96]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
               let data = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) {
                self.entry.iconData = data
                self.preview.image = self.entry.icon()
                self.refreshIconSelection()
            } else { NSSound.beep() }
        }
    }

    @objc private func pickTarget() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "选择应用"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.entry.target = AppTarget(url: url)
            self.preview.image = self.entry.icon()
        }
    }

    @objc private func resetIcon() {
        entry.iconData = nil
        preview.image = entry.icon()
        refreshIconSelection()
    }

    @objc private func changeSymbol(_ sender: NSButton) {
        guard GroupIcon.palette.indices.contains(sender.tag) else { return }
        entry.symbol = GroupIcon.palette[sender.tag].symbol
        resetIcon()
    }

    @objc private func cancelEdit() { window.sheetParent?.endSheet(window, returnCode: .cancel) }

    @objc private func saveEdit() {
        let trimmed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { NSSound.beep(); return }
        entry.name = trimmed
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }
}
