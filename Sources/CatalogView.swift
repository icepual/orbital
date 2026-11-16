import AppKit

@MainActor
final class CatalogView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let footer = NSTextField(labelWithString: "")
    private var indexed: [IndexedApp] = []
    private var results: [IndexedApp] = []
    private var scanning = false
    var onOpen: ((IndexedApp) -> Void)?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        let title = NSTextField(labelWithString: "全部应用")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let back = NSButton(title: "返回圆环", target: self, action: #selector(backPressed))
        back.bezelStyle = .inline

        search.placeholderString = "搜索应用名称、拼音或首字母"
        search.font = .systemFont(ofSize: 15)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.setAccessibilityLabel("搜索应用")

        let column = NSTableColumn(identifier: .init("application"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 44
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor

        for view in [title, back, search, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            back.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            back.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 13),
            search.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: back.trailingAnchor),
            search.heightAnchor.constraint(equalToConstant: 31),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func present(in window: NSWindow, forwarding event: NSEvent?) {
        search.stringValue = ""
        filter()
        if window.makeFirstResponder(search), let event, let editor = search.currentEditor() {
            editor.keyDown(with: event)
        }
    }

    func update(_ apps: [IndexedApp], scanning: Bool) {
        indexed = apps
        self.scanning = scanning
        filter()
    }

    func releaseRows() {
        indexed = []
        results = []
        table.reloadData()
    }

    private func filter() {
        let query = search.stringValue.normalized
        results = indexed.compactMap { app in app.score(query).map { (app, $0) } }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
            }.map(\.0)
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        if scanning && results.isEmpty { footer.stringValue = "正在查找应用…" }
        else if results.isEmpty { footer.stringValue = "没有匹配的应用" }
        else { footer.stringValue = "\(results.count) 个应用   ·   ↑ ↓ 选择   ↵ 打开   Esc 返回" }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("appCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CatalogCell ?? CatalogCell()
        let app = results[row]
        cell.configure(app)
        return cell
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(0, table.selectedRow + delta), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            openSelection()
            return true
        default:
            return false
        }
    }

    @objc private func backPressed() { onBack?() }

    @objc private func openSelection() {
        guard results.indices.contains(table.selectedRow) else { return }
        onOpen?(results[table.selectedRow])
    }
}

private final class CatalogCell: NSTableCellView {
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = .init("appCell")
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13, weight: .medium)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        for view in [icon, labels] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 29),
            icon.heightAnchor.constraint(equalToConstant: 29),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ app: IndexedApp) {
        icon.image = NSWorkspace.shared.icon(forFile: app.url.path)
        name.stringValue = app.name
        path.stringValue = (app.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}
