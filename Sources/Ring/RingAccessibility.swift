import AppKit

@MainActor
enum RingAccessibility {
    static func children(for layout: RingLayout,
                         running: Set<UUID>,
                         parent: Any,
                         screenFrame: (CGRect) -> NSRect,
                         onPress: @escaping @MainActor (RingItem) -> Void) -> [Any] {
        guard !layout.input.items.isEmpty else { return [] }
        var buttons: [Any] = []

        func button(label: String, at point: CGPoint, radius: CGFloat,
                    action: @escaping @MainActor () -> Void) -> RingAccessibilityButton {
            let element = RingAccessibilityButton(action: action)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(parent)
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            element.setAccessibilityFrame(screenFrame(rect))
            return element
        }

        for (index, item) in layout.input.items.enumerated() {
            let text = item.isGroup ? item.name + "分组" : applicationLabel(item, running: running)
            let strength = layout.input.magnification[item.id] ?? 0
            let point = layout.mainIconCenter(at: index) ?? .zero
            let radius = layout.mainIconSize
                * (1 + layout.input.appearance.magnification * strength) / 2
            buttons.append(button(label: text, at: point, radius: radius) {
                onPress(item)
            })
        }

        if let group = layout.shownGroup, group.id == layout.input.requestedGroupID,
           let children = group.children, let value = layout.submenu,
           layout.input.arc > 0.04 {
            for (index, child) in children.enumerated() {
                let strength = layout.input.magnification[child.id] ?? 0
                let size = layout.childIconSize(in: value)
                let point = layout.childIconCenter(at: index) ?? .zero
                let radius = size * (1 + layout.input.appearance.magnification * strength) / 2
                buttons.append(button(label: applicationLabel(child, running: running),
                                      at: point, radius: radius) {
                    onPress(child)
                })
            }
        }
        return buttons
    }

    private static func applicationLabel(_ item: RingItem, running: Set<UUID>) -> String {
        running.contains(item.id) ? item.name + "，运行中" : item.name
    }
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
        MainActor.assumeIsolated { action() }
        return true
    }
}
