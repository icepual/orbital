import AppKit

/// Immutable snapshot of everything the ring needs for one frame.
/// Renderer, hit tester and accessibility all read this same snapshot.
struct RingGeometryInput {
    let items: [RingItem]
    let appearance: Appearance
    let bounds: CGRect
    let magnification: [UUID: CGFloat]
    let shownGroupID: UUID?
    let requestedGroupID: UUID?
    let highlightedID: UUID?
    let arc: CGFloat
    let intro: CGFloat
    let isPreview: Bool
}

struct SubmenuArc {
    let radius: CGFloat
    let start: Double
    let end: Double
    let angles: [Double]
    let openingScale: CGFloat
    let glassOpacity: CGFloat
}

struct RingLayout {
    let input: RingGeometryInput
    let metrics: RingMetrics
    let shownGroup: RingItem?
    let requestedGroup: RingItem?

    let center: CGPoint
    let sizeFactor: CGFloat
    let zoom: CGFloat
    let mainRadius: CGFloat
    let mainAngles: [Double]
    let mainIconSize: CGFloat
    let mainWidth: CGFloat
    let mainEdge: CGFloat
    let outerWidth: CGFloat
    let mainPath: CGPath
    let submenu: SubmenuArc?
    let submenuPath: CGPath?

    init(metrics: RingMetrics, input: RingGeometryInput) {
        self.metrics = metrics
        self.input = input
        shownGroup = input.shownGroupID.flatMap { id in
            input.items.first { $0.id == id }
        }
        requestedGroup = input.requestedGroupID.flatMap { id in
            input.items.first { $0.id == id }
        }

        center = CGPoint(x: input.bounds.midX, y: input.bounds.midY)
        mainWidth = input.appearance.ringWidth

        let previewScale: CGFloat = shownGroup?.children?.isEmpty == false ? 0.26 : 0.36
        if input.isPreview {
            sizeFactor = previewScale
        } else {
            let available = min(input.bounds.width, input.bounds.height) / 2 - 14
            sizeFactor = min(1, max(0.1,
                available / max(1, metrics.maximumExtent * 1.065)))
        }

        let t = input.intro - 1
        let rawZoom = sizeFactor * (1 + 2.3 * t * t * t + 1.3 * t * t)
        // The intro starts at zero, where the ring is fully transparent. Keep the
        // geometry finite for that invisible frame rather than producing 0 / 0.
        zoom = max(rawZoom, 0.001)

        mainRadius = metrics.baseMainRadius * zoom
        mainIconSize = input.appearance.iconSize * zoom
        mainEdge = (metrics.baseMainRadius + mainWidth / 2) * zoom
        outerWidth = mainWidth * zoom

        mainAngles = RingGeometry.packedAngles(
            entries: input.items,
            radius: mainRadius,
            size: mainIconSize,
            middle: -.pi / 2,
            strengths: input.magnification,
            magnification: input.appearance.magnification,
            zoom: zoom
        )

        if let first = mainAngles.first, let last = mainAngles.last, mainRadius > 0 {
            let capMargin = 2 * zoom / mainRadius
            mainPath = RingGeometry.arcPath(center: center, radius: mainRadius,
                                            width: mainWidth * zoom,
                                            start: first - capMargin,
                                            end: last + capMargin, cap: .round)
        } else {
            mainPath = CGMutablePath()
        }

        var computedSubmenu: SubmenuArc?
        if input.arc > 0, let group = shownGroup,
           let children = group.children, !children.isEmpty,
           let baseRadius = metrics.outerRadii[group.id],
           let parent = input.items.firstIndex(where: { $0.id == group.id }),
           mainAngles.indices.contains(parent) {
            let middle = mainAngles[parent]
            let style = input.appearance.animationStyle
            let progress = RingGeometry.ease(Double(input.arc))
            let radius = (baseRadius + style.extraRadialRoom * (1 - CGFloat(progress))) * zoom

            let angularScale: CGFloat
            let iconScale: CGFloat
            let glassOpacity: CGFloat
            switch style {
            case .fan:
                angularScale = max(0.08, CGFloat(progress))
                iconScale = angularScale
                glassOpacity = min(1, input.arc * 4)
            case .slide:
                angularScale = 1
                iconScale = 0.8 + 0.2 * CGFloat(progress)
                glassOpacity = min(1, input.arc * 1.7)
            case .cascade:
                angularScale = 1
                iconScale = 1
                glassOpacity = min(1, input.arc * 1.7)
            case .spring:
                angularScale = max(0.25,
                                   CGFloat(RingGeometry.ease(Double(min(1, input.arc * 1.65)))))
                let remaining = Double(input.arc) - 1
                let spring = 1 + 2.7 * remaining * remaining * remaining
                    + 1.7 * remaining * remaining
                iconScale = 0.45 + 0.55 * CGFloat(spring)
                glassOpacity = min(1, input.arc * 2.4)
            }

            let angles = RingGeometry.packedAngles(
                entries: children,
                radius: radius,
                size: input.appearance.iconSize * zoom,
                middle: middle,
                strengths: input.magnification,
                magnification: input.appearance.magnification,
                zoom: zoom
            ).map { middle + ($0 - middle) * Double(angularScale) }

            if let first = angles.first, let last = angles.last {
                computedSubmenu = SubmenuArc(
                    radius: radius,
                    start: first - 0.018,
                    end: last + 0.018,
                    angles: angles,
                    openingScale: iconScale,
                    glassOpacity: glassOpacity
                )
            }
        }

        submenu = computedSubmenu
        if let value = computedSubmenu {
            submenuPath = RingGeometry.arcPath(center: center, radius: value.radius,
                                               width: outerWidth, start: value.start,
                                               end: value.end, cap: .round)
        } else {
            submenuPath = nil
        }
    }

    func mainIconCenter(at index: Int) -> CGPoint? {
        guard input.items.indices.contains(index), mainAngles.indices.contains(index) else {
            return nil
        }
        let item = input.items[index]
        let strength = input.magnification[item.id] ?? 0
        return RingGeometry.liftedPoint(
            center: center,
            radius: mainRadius,
            angle: mainAngles[index],
            size: mainIconSize,
            strength: strength,
            magnification: input.appearance.magnification,
            zoom: zoom
        )
    }

    func childIconSize(in arc: SubmenuArc) -> CGFloat {
        input.appearance.iconSize * zoom * arc.openingScale
    }

    func childIconCenter(at index: Int) -> CGPoint? {
        guard let arc = submenu, let children = shownGroup?.children,
              children.indices.contains(index), arc.angles.indices.contains(index) else {
            return nil
        }
        let child = children[index]
        let strength = input.magnification[child.id] ?? 0
        return RingGeometry.liftedPoint(
            center: center,
            radius: arc.radius,
            angle: arc.angles[index],
            size: childIconSize(in: arc),
            strength: strength,
            magnification: input.appearance.magnification,
            zoom: zoom
        )
    }

    func childOpacity(index: Int, count: Int) -> CGFloat {
        let arc = Double(input.arc)
        switch input.appearance.animationStyle {
        case .fan:
            let delay = min(0.34, Double(index) * 0.07)
            return CGFloat(min(1, max(0, (arc - delay) * 2)))
        case .cascade:
            let delay = 0.6 * Double(index) / Double(max(1, count - 1))
            return CGFloat(RingGeometry.ease(min(1, max(0, (arc - delay) / 0.4))))
        case .slide, .spring:
            return CGFloat(min(1, arc * 1.9))
        }
    }
}
