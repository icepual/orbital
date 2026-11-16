import AppKit
import UniformTypeIdentifiers

@MainActor
enum NativeLauncher {
    static var url: URL? {
        let workspace = NSWorkspace.shared
        for (identifier, path) in [
            ("com.apple.apps.launcher", "/System/Applications/Apps.app"),
            ("com.apple.launchpad", "/System/Applications/Launchpad.app")
        ] {
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier) { return url }
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func icon() -> NSImage? {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "全部应用")
    }
}

struct AppTarget: Codable, Equatable {
    var bundleID: String?
    var path: String?

    init(_ bundleID: String) {
        self.bundleID = bundleID
    }

    init(url: URL) {
        bundleID = Bundle(url: url)?.bundleIdentifier
        path = url.path
    }

    func runningApplication(in applications: [NSRunningApplication]) -> NSRunningApplication? {
        let running = applications.filter { !$0.isTerminated }
        if let path {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if let exact = running.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == url.path }) {
                return exact
            }
            // Keep a saved app copy distinct from another copy with the same bundle identifier.
            if FileManager.default.fileExists(atPath: path) { return nil }
        }
        guard let bundleID else { return nil }
        return running.first { $0.bundleIdentifier == bundleID }
    }

    @MainActor var url: URL? {
        if let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleID {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }
}

struct RingItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var target: AppTarget?
    var symbol: String = "square.stack"
    var iconData: Data?
    var children: [RingItem]?
    var isGroup: Bool { children != nil }

    static func app(_ name: String, _ bundleID: String) -> Self {
        Self(name: name, target: AppTarget(bundleID))
    }

    @MainActor func icon() -> NSImage? {
        if let iconData, let image = NSImage(data: iconData) { return image }
        if isGroup, let artwork = GroupIcon.image(for: symbol) { return artwork }
        if let url = target?.url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: isGroup ? symbol : "app.dashed", accessibilityDescription: nil)
    }
}

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var title: String

    static let choices = [
        Shortcut(key: 49, modifiers: 2048, title: "⌥ 空格"),
        Shortcut(key: 49, modifiers: 6144, title: "⌃⌥ 空格"),
        Shortcut(key: 49, modifiers: 2560, title: "⇧⌥ 空格"),
        Shortcut(key: 49, modifiers: 256, title: "⌘ 空格"),
        Shortcut(key: 36, modifiers: 2048, title: "⌥ 回车")
    ]
}

struct Appearance: Codable {
    var hoverDelay = 0.30
    var animationDuration = 0.32
    var iconSize = 38.0
    var initialRadius: Double?
    var initialRingWidth: Double?
    var magnification = 0.48
    var glow = 0.65

    var ringWidth: Double { initialRingWidth ?? 44 }
}

struct Configuration: Codable {
    var items: [RingItem]
    var shortcut: Shortcut
    var appearance: Appearance?

    static var initial: Self {
        Self(items: [
            .app("Safari", "com.apple.Safari"),
            .app("备忘录", "com.apple.Notes"),
            RingItem(name: "设计", symbol: "square.on.square", children: [
                .app("预览", "com.apple.Preview"), .app("照片", "com.apple.Photos"),
                .app("Freeform", "com.apple.freeform"), .app("图像捕捉", "com.apple.Image_Capture")
            ]),
            .app("音乐", "com.apple.Music"),
            .app("访达", "com.apple.finder"),
            RingItem(name: "收藏", symbol: "star", children: [
                .app("日历", "com.apple.iCal"), .app("提醒事项", "com.apple.reminders")
            ]),
            RingItem(name: "工具", symbol: "wrench.and.screwdriver", children: [
                .app("终端", "com.apple.Terminal"), .app("计算器", "com.apple.calculator"),
                .app("活动监视器", "com.apple.ActivityMonitor"), .app("系统设置", "com.apple.systempreferences")
            ]),
            RingItem(name: "工作", symbol: "briefcase", children: [
                .app("邮件", "com.apple.mail"), .app("文本编辑", "com.apple.TextEdit"),
                .app("快捷指令", "com.apple.shortcuts")
            ])
        ], shortcut: Shortcut.choices[0])
    }

    static func load() -> Self {
        if let data = UserDefaults.standard.data(forKey: "launcherConfiguration"),
           let config = try? JSONDecoder().decode(Self.self, from: data) { return config }
        return .initial
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "launcherConfiguration")
        }
    }
}

struct IndexedApp: Sendable {
    let url: URL
    let name: String
    let rawName: String
    let bundleID: String?
    let romanized: String
    let initials: String

    func score(_ query: String) -> Int? {
        if query.isEmpty { return 0 }
        let names = [name.normalized, rawName.normalized, romanized]
        if names.contains(query) { return 0 }
        if names.contains(where: { $0.hasPrefix(query) }) { return 1 }
        if initials.hasPrefix(query) { return 2 }
        if names.contains(where: { $0.contains(query) }) { return 3 }
        if query.count >= 3, bundleID?.normalized.contains(query) == true { return 4 }
        return nil
    }
}

extension String {
    var normalized: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppIndexer {
    static func scan(userLocations: [URL]) -> [IndexedApp] {
        let fileManager = FileManager()
        let locations = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications")
        ] + userLocations
        var paths: Set<String> = []
        var result: [IndexedApp] = []

        func insert(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.pathExtension.lowercased() == "app",
                  paths.insert(resolved.path).inserted,
                  let bundle = Bundle(url: resolved),
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                  bundle.bundleIdentifier != "com.ice.orbital" else { return }

            let rawName = resolved.deletingPathExtension().lastPathComponent
            let localized = try? resolved.resourceValues(forKeys: [.localizedNameKey]).localizedName
            let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
                ?? localized
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? rawName
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            let roman = name.applyingTransform(.toLatin, reverse: false)?.normalized ?? ""
            let pieces = roman.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            result.append(IndexedApp(url: resolved, name: name, rawName: rawName,
                                     bundleID: bundle.bundleIdentifier,
                                     romanized: pieces.joined(),
                                     initials: String(pieces.compactMap(\.first))))
        }

        for location in locations {
            if location.pathExtension.lowercased() == "app" {
                insert(location)
                continue
            }
            guard let entries = fileManager.enumerator(at: location,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries {
                if entries.level > 3 { entries.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    insert(url)
                    entries.skipDescendants()
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
