import AppKit

enum RingHitMode {
    /// Clicking only hits icons and the visible submenu band.
    case exact
    /// Hovering also bridges the gaps between icons and the glass band.
    case padded
}

enum RingHitTester {
    static func item(at point: CGPoint, in layout: RingLayout, mode: RingHitMode) -> RingItem? {
        switch mode {
        case .exact:
            return exactItem(at: point, in: layout)
        case .padded:
            return hoverItem(at: point, in: layout)
        }
    }

    private static func exactItem(at point: CGPoint, in layout: RingLayout) -> RingItem? {
        let items = layout.input.items
        let magnification = layout.input.appearance.magnification

        for (index, entry) in items.enumerated().sorted(by: {
            (layout.input.magnification[$0.element.id] ?? 0)
                > (layout.input.magnification[$1.element.id] ?? 0)
        }) {
            guard let pointCenter = layout.mainIconCenter(at: index) else { continue }
            let strength = layout.input.magnification[entry.id] ?? 0
            let radius = layout.mainIconSize * (1 + magnification * strength) / 2
            if RingGeometry.distance(point, pointCenter)
                <= radius + RingGeometry.iconGap * layout.zoom / 4 {
                return entry
            }
        }

        if let highlighted = layout.input.highlightedID,
           let index = items.firstIndex(where: { $0.id == highlighted }),
           layout.mainAngles.indices.contains(index) {
            let center = RingGeometry.polar(center: layout.center,
                                            radius: layout.mainRadius,
                                            angle: layout.mainAngles[index])
            if RingGeometry.distance(point, center) <= layout.mainIconSize / 2 {
                return items[index]
            }
        }

        if let group = layout.shownGroup, group.id == layout.input.requestedGroupID,
           let children = group.children, let value = layout.submenu,
           layout.input.arc > 0.04, let submenuPath = layout.submenuPath {
            let size = layout.childIconSize(in: value)
            let nearest = children.indices.min { left, right in
                let leftPoint = layout.childIconCenter(at: left) ?? .zero
                let rightPoint = layout.childIconCenter(at: right) ?? .zero
                return RingGeometry.distance(point, leftPoint)
                    < RingGeometry.distance(point, rightPoint)
            }
            if let nearest, layout.childOpacity(index: nearest, count: children.count) > 0.15,
               let nearestPoint = layout.childIconCenter(at: nearest) {
                let item = children[nearest]
                let strength = layout.input.magnification[item.id] ?? 0
                let radius = size * (1 + magnification * strength) / 2
                if submenuPath.contains(point, using: .evenOdd)
                    || RingGeometry.distance(point, nearestPoint) <= radius {
                    return item
                }
            }
        }
        return nil
    }

    private static func hoverItem(at point: CGPoint, in layout: RingLayout) -> RingItem? {
        if let item = exactItem(at: point, in: layout) { return item }
        if let item = paddedItem(at: point, entries: layout.input.items,
                                 angles: layout.mainAngles, radius: layout.mainRadius,
                                 width: layout.mainWidth * layout.zoom,
                                 iconSize: layout.mainIconSize, path: layout.mainPath,
                                 layout: layout) {
            return item
        }
        if let group = layout.shownGroup, group.id == layout.input.requestedGroupID,
           let children = group.children, let value = layout.submenu,
           layout.input.arc > 0.04, let submenuPath = layout.submenuPath {
            return paddedItem(at: point, entries: children, angles: value.angles,
                              radius: value.radius, width: layout.outerWidth,
                              iconSize: layout.childIconSize(in: value),
                              path: submenuPath, layout: layout)
        }
        return nil
    }

    private static func paddedItem(at point: CGPoint,
                                   entries: [RingItem],
                                   angles: [Double],
                                   radius: CGFloat,
                                   width: CGFloat,
                                   iconSize: CGFloat,
                                   path: CGPath,
                                   layout: RingLayout) -> RingItem? {
        guard let first = angles.first, let last = angles.last else { return nil }
        let middle = (first + last) / 2
        let offset = atan2(point.y - layout.center.y, point.x - layout.center.x) - middle
        let angle = middle + atan2(sin(offset), cos(offset))
        guard let nearest = angles.indices.min(by: {
            abs(angles[$0] - angle) < abs(angles[$1] - angle)
        }) else { return nil }

        if path.contains(point, using: .evenOdd) { return entries[nearest] }
        guard let right = angles.firstIndex(where: { $0 >= angle }), right > 0,
              right < entries.count else { return nil }

        // Bridge the gap at the visible height of the lifted icons as well as on the ring.
        let left = right - 1
        func outerEdge(_ index: Int) -> CGFloat {
            let strength = layout.input.magnification[entries[index].id] ?? 0
            return radius + RingGeometry.radialLift(
                size: iconSize, strength: strength,
                magnification: layout.input.appearance.magnification,
                zoom: layout.zoom
            ) + iconSize * (1 + layout.input.appearance.magnification * strength) / 2
        }
        let fraction = (angle - angles[left]) / (angles[right] - angles[left])
        let outer = outerEdge(left) * (1 - fraction) + outerEdge(right) * fraction
        let pointerRadius = RingGeometry.distance(point, layout.center)
        guard pointerRadius >= radius - width / 2,
              pointerRadius <= max(radius + width / 2, outer) else { return nil }
        return entries[nearest]
    }
}
