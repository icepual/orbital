import AppKit

/// Intrinsic ring dimensions. These only depend on the item tree and the
/// appearance settings, so they are cached until either of those changes.
struct RingMetrics {
    let baseMainRadius: CGFloat
    let outerRadii: [UUID: CGFloat]
    let maximumExtent: CGFloat
    let preferredPanelSize: CGFloat

    init(items: [RingItem], appearance: Appearance) {
        let mainWidth = appearance.ringWidth
        let childIconSize = appearance.iconSize
        let magnification = appearance.magnification

        baseMainRadius = RingGeometry.fittedRadius(
            count: items.count,
            size: appearance.iconSize,
            lift: 6,
            minimum: max(appearance.initialRadius ?? 30, mainWidth / 2 + 10),
            span: RingGeometry.mainSpan,
            magnification: magnification
        )

        let mainIconReach = appearance.iconSize / sqrt(2)
        let mainOutset = max(mainWidth / 2,
                             mainIconReach * (1 + 2 * magnification) + 4)
        let childInset = max(mainWidth / 2, childIconSize / sqrt(2))
        // Reserve room for both glass bands and icon corners throughout magnification.
        let minimum = baseMainRadius + mainOutset + childInset + 7

        var outerRadii: [UUID: CGFloat] = [:]
        for group in items {
            guard let children = group.children, !children.isEmpty else { continue }
            outerRadii[group.id] = RingGeometry.fittedRadius(
                count: children.count,
                size: childIconSize,
                lift: 0,
                minimum: minimum,
                magnification: magnification
            )
        }
        self.outerRadii = outerRadii

        let childOutset = max(mainWidth / 2,
                              childIconSize * (1 + 2 * magnification) / sqrt(2) + 4)
        let animationRoom = appearance.animationStyle.extraRadialRoom
            + (appearance.animationStyle == .spring ? childIconSize * 0.08 : 0)
        let submenuExtent = (outerRadii.values.max() ?? 0) + childOutset + animationRoom
        maximumExtent = max(baseMainRadius + mainOutset, submenuExtent)
        preferredPanelSize = max(480, ceil(2 * (maximumExtent * 1.065 + 14)))
    }
}

/// Stateless geometry helpers shared by the layout, hit tester and renderer.
enum RingGeometry {
    static let mainSpan: CGFloat = 5 * .pi / 3
    static let iconGap: CGFloat = 10

    static func fittedRadius(count: Int,
                             size: CGFloat,
                             lift: CGFloat,
                             minimum: CGFloat,
                             span: CGFloat = 2 * .pi,
                             magnification: CGFloat) -> CGFloat {
        let activeHalf = size * (1 + magnification) / 2
        let neighborHalf = size * (1 + magnification * exp(-1.1)) / 2
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
    static func packedAngles(entries: [RingItem],
                             radius: CGFloat,
                             size: CGFloat,
                             middle: Double,
                             strengths: [UUID: CGFloat],
                             magnification: CGFloat,
                             zoom: CGFloat,
                             iconGap: CGFloat = RingGeometry.iconGap) -> [Double] {
        guard !entries.isEmpty, radius > 0 else { return [] }
        let halves = entries.map { entry -> CGFloat in
            let strength = strengths[entry.id] ?? 0
            let half = size * (1 + magnification * strength) / 2
            let iconRadius = radius + radialLift(size: size, strength: strength,
                                                 magnification: magnification, zoom: zoom)
            return asin(min(0.99, half / max(iconRadius, 0.0001)))
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

    static func radialLift(size: CGFloat,
                           strength: CGFloat,
                           magnification: CGFloat,
                           zoom: CGFloat) -> CGFloat {
        (size * magnification / sqrt(2) + 4 * zoom) * strength
    }

    static func liftedPoint(center: CGPoint,
                            radius: CGFloat,
                            angle: Double,
                            size: CGFloat,
                            strength: CGFloat,
                            magnification: CGFloat,
                            zoom: CGFloat) -> CGPoint {
        polar(center: center,
              radius: radius + radialLift(size: size, strength: strength,
                                          magnification: magnification, zoom: zoom),
              angle: angle)
    }

    static func polar(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    static func distance(_ point: CGPoint, _ other: CGPoint) -> CGFloat {
        hypot(point.x - other.x, point.y - other.y)
    }

    static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    static func arcPath(center: CGPoint,
                        radius: CGFloat,
                        width: CGFloat,
                        start: Double,
                        end: Double,
                        cap: CGLineCap) -> CGPath {
        let spine = CGMutablePath()
        spine.addArc(center: center, radius: max(radius, 0.0001),
                     startAngle: start, endAngle: end, clockwise: false)
        return spine.copy(strokingWithWidth: max(width, 0.0001),
                          lineCap: cap, lineJoin: .round, miterLimit: 0)
    }
}
