import AppKit

struct RingScene {
    let layout: RingLayout
    let appearance: Appearance
    let icons: [UUID: NSImage]
    let runningItems: Set<UUID>
}

/// Draws a ring frame. It never reads or mutates view state; everything comes
/// from the scene's immutable layout snapshot.
struct RingRenderer {
    func draw(_ scene: RingScene, in context: CGContext) {
        let layout = scene.layout
        let intro = layout.input.intro
        context.saveGState()
        context.setAlpha(CGFloat(min(1, intro * 2.8)))
        defer { context.restoreGState() }

        glass(layout.mainPath, glow: scene.appearance.glow, zoom: layout.zoom, context: context)
        if let group = layout.shownGroup, let children = group.children,
           let value = layout.submenu, let submenuPath = layout.submenuPath {
            context.saveGState()
            context.setAlpha(value.glassOpacity * min(1, intro * 2.8))
            glass(submenuPath, glow: scene.appearance.glow, zoom: layout.zoom, context: context)
            context.restoreGState()
            for (index, child) in children.enumerated()
                where child.id != layout.input.highlightedID {
                drawChild(child, index: index, count: children.count, arc: value,
                          scene: scene, context: context)
            }
            if let index = children.firstIndex(where: {
                $0.id == layout.input.highlightedID
            }) {
                drawChild(children[index], index: index, count: children.count,
                          arc: value, scene: scene, context: context)
            }
        }

        for index in layout.input.items.indices
            where layout.input.items[index].id != layout.input.highlightedID {
            drawMain(index, scene: scene, context: context)
        }
        if let index = layout.input.items.firstIndex(where: {
            $0.id == layout.input.highlightedID
        }) {
            drawMain(index, scene: scene, context: context)
        }
        drawHoverLabel(scene, expandedArc: layout.submenu, context: context)
    }

    private func drawMain(_ index: Int, scene: RingScene, context: CGContext) {
        let layout = scene.layout
        let item = layout.input.items[index]
        let strength = layout.input.magnification[item.id] ?? 0
        let theta = layout.mainAngles[index]
        guard let point = layout.mainIconCenter(at: index) else { return }
        drawIcon(scene.icons[item.id], at: point,
                 size: layout.mainIconSize * (1 + scene.appearance.magnification * strength),
                 lift: strength, running: scene.runningItems.contains(item.id),
                 center: layout.center, zoom: layout.zoom, context: context)
        if item.isGroup {
            let indicator = RingGeometry.polar(
                center: layout.center,
                radius: layout.mainRadius + 13 * layout.zoom + strength * 13 * layout.zoom,
                angle: theta
            )
            let dot = (layout.input.requestedGroupID == item.id ? 3.0 : 1.7) * layout.zoom
            context.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            context.fillEllipse(in: CGRect(x: indicator.x - dot / 2,
                                           y: indicator.y - dot / 2,
                                           width: dot, height: dot))
        }
    }

    private func drawChild(_ item: RingItem, index: Int, count: Int, arc value: SubmenuArc,
                           scene: RingScene, context: CGContext) {
        let layout = scene.layout
        let strength = layout.input.magnification[item.id] ?? 0
        let size = layout.childIconSize(in: value)
        guard let point = layout.childIconCenter(at: index) else { return }
        let alpha = layout.childOpacity(index: index, count: count)
        drawIcon(scene.icons[item.id], at: point,
                 size: size * (1 + scene.appearance.magnification * strength),
                 lift: strength, alpha: alpha,
                 running: scene.runningItems.contains(item.id),
                 center: layout.center, zoom: layout.zoom, context: context)
    }

    private func glass(_ shape: CGPath, glow: CGFloat, zoom: CGFloat, context: CGContext) {
        if glow > 0 {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 10 * zoom,
                              color: NSColor.white.withAlphaComponent(glow * 0.8).cgColor)
            context.setStrokeColor(NSColor.white.withAlphaComponent(glow).cgColor)
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
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.midX, y: rect.minY),
                                       end: CGPoint(x: rect.midX, y: rect.maxY),
                                       options: [])
        }
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.58).cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
    }

    private func drawIcon(_ image: NSImage?, at point: CGPoint, size: CGFloat, lift: CGFloat,
                          alpha: CGFloat = 1, running: Bool, center: CGPoint,
                          zoom: CGFloat, context: CGContext) {
        guard let image, alpha > 0 else { return }
        let displayed = image.isTemplate
            ? image.withSymbolConfiguration(.init(paletteColors: [.white])) ?? image
            : image
        let aspect = displayed.size.height > 0
            ? displayed.size.width / displayed.size.height : 1
        let width = size * min(1, aspect)
        let height = size / max(1, aspect)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -(1 + lift * 2)),
                          blur: 2 + lift * 4,
                          color: NSColor.black.withAlphaComponent(image.isTemplate ? 0.64 : 0.24).cgColor)
        displayed.draw(in: CGRect(x: point.x - width / 2, y: point.y - height / 2,
                                  width: width, height: height), from: .zero,
                       operation: .sourceOver, fraction: alpha, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
        context.restoreGState()
        if running {
            let diameter = min(4.5 * zoom, size * 0.13)
            let radius = RingGeometry.distance(point, center)
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

    private func drawHoverLabel(_ scene: RingScene, expandedArc: SubmenuArc?,
                                context: CGContext) {
        let layout = scene.layout
        let highlighted = layout.input.highlightedID

        if let index = layout.input.items.firstIndex(where: { $0.id == highlighted }) {
            let item = layout.input.items[index]
            let theta = layout.mainAngles[index]
            let strength = layout.input.magnification[item.id] ?? 0
            let lifted = layout.mainIconCenter(at: index) ?? .zero
            let iconReach = layout.mainIconSize
                * (1 + scene.appearance.magnification * strength) / sqrt(2)
            var radius = max(layout.mainEdge + 24 * layout.zoom,
                             RingGeometry.distance(layout.center, lifted) + iconReach
                                + 16 * layout.zoom)
            if let value = expandedArc {
                let middle = (value.start + value.end) / 2
                let offset = atan2(sin(theta - middle), cos(theta - middle))
                if abs(offset) < (value.end - value.start) / 2 + 0.24 {
                    radius = max(radius, value.radius + layout.outerWidth / 2
                                    + 24 * layout.zoom)
                }
            }
            tooltip(item.name,
                    at: RingGeometry.polar(center: layout.center, radius: radius, angle: theta),
                    strength: strength, layout: layout, context: context)
        } else if let children = layout.shownGroup?.children, let value = expandedArc,
                  let index = children.firstIndex(where: { $0.id == highlighted }) {
            let theta = value.angles[index]
            let strength = layout.input.magnification[children[index].id] ?? 0
            let size = layout.childIconSize(in: value)
            let lifted = layout.childIconCenter(at: index) ?? .zero
            let iconReach = size * (1 + scene.appearance.magnification * strength) / sqrt(2)
            let radius = max(value.radius + layout.outerWidth / 2 + 23 * layout.zoom,
                             RingGeometry.distance(layout.center, lifted) + iconReach
                                + 16 * layout.zoom)
            tooltip(children[index].name,
                    at: RingGeometry.polar(center: layout.center, radius: radius, angle: theta),
                    strength: strength, layout: layout, context: context)
        }
    }

    private func tooltip(_ name: String, at point: CGPoint, strength: CGFloat,
                         layout: RingLayout, context: CGContext) {
        guard strength > 0.08 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: max(10, 12 * layout.zoom), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para
        ]
        let title = name as NSString
        let width = min(156, ceil(title.size(withAttributes: attributes).width) + 20)
        let x = min(max(4, point.x - width / 2), layout.input.bounds.width - width - 4)
        let height: CGFloat = 24
        let y = min(max(3, point.y - height / 2),
                    layout.input.bounds.height - height - 3)
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
        title.draw(with: CGRect(x: x + 8,
                                y: y + (height - font.ascender + font.descender) / 2,
                                width: width - 16, height: height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                   attributes: attributes)
        context.restoreGState()
    }
}
