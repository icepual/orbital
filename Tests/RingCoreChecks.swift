import AppKit

/// Lightweight regression checks for the pure ring core. This intentionally
/// avoids a test framework so the project remains dependency-free and can be
/// run with `./test.sh` next to `./build.sh`.
@main
struct RingCoreChecks {
    @MainActor
    static func main() {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures += 1
                print("FAIL: \(message)")
            }
        }
        func finite(_ value: CGFloat) -> Bool { value.isFinite }

        let items = Configuration.initial.items
        let group = items.first(where: { $0.isGroup })!
        let bounds = CGRect(x: 0, y: 0, width: 650, height: 650)

        for style in SubmenuAnimation.allCases {
            var appearance = Appearance()
            appearance.submenuAnimation = style
            let metrics = RingMetrics(items: items, appearance: appearance)
            check(finite(metrics.baseMainRadius), "\(style) base radius")
            check(finite(metrics.maximumExtent), "\(style) maximum extent")
            check(finite(metrics.preferredPanelSize), "\(style) panel size")
            check(metrics.preferredPanelSize >= 480, "\(style) minimum panel size")

            for intro in [CGFloat(0), 0.001, 0.5, 1] {
                for arc in [CGFloat(0), 0.05, 0.3, 0.6, 1] {
                    let input = RingGeometryInput(
                        items: items,
                        appearance: appearance,
                        bounds: bounds,
                        magnification: [:],
                        shownGroupID: group.id,
                        requestedGroupID: group.id,
                        highlightedID: nil,
                        arc: arc,
                        intro: intro,
                        isPreview: false
                    )
                    let layout = RingLayout(metrics: metrics, input: input)
                    check(finite(layout.zoom), "\(style) zoom")
                    check(finite(layout.mainRadius), "\(style) main radius")
                    check(layout.mainAngles.allSatisfy { $0.isFinite },
                          "\(style) main angles")

                    if arc > 0 {
                        guard let submenu = layout.submenu else {
                            failures += 1
                            print("FAIL: \(style) missing submenu at arc \(arc)")
                            continue
                        }
                        check(finite(submenu.radius), "\(style) submenu radius")
                        check(submenu.angles.allSatisfy { $0.isFinite },
                              "\(style) submenu angles")
                    }

                    if intro == 1 {
                        for (index, item) in items.enumerated() {
                            guard let center = layout.mainIconCenter(at: index) else {
                                failures += 1
                                print("FAIL: \(style) missing main center")
                                continue
                            }
                            check(RingHitTester.item(at: center, in: layout, mode: .exact)?.id
                                    == item.id,
                                  "\(style) main hit \(item.name)")
                        }
                    }
                }
            }
        }

        // The preview scale is smaller, but should still be finite and renderable.
        var previewAppearance = Appearance()
        previewAppearance.submenuAnimation = .spring
        let previewMetrics = RingMetrics(items: items, appearance: previewAppearance)
        let previewLayout = RingLayout(metrics: previewMetrics, input: RingGeometryInput(
            items: items,
            appearance: previewAppearance,
            bounds: CGRect(x: 0, y: 0, width: 300, height: 300),
            magnification: [:],
            shownGroupID: group.id,
            requestedGroupID: group.id,
            highlightedID: nil,
            arc: 1,
            intro: 1,
            isPreview: true
        ))
        check(finite(previewLayout.zoom), "preview zoom")
        check(previewLayout.zoom > 0 && previewLayout.zoom < 1, "preview zoom range")

        // Opening, closing and reduced-motion settling.
        var engine = RingAnimationEngine()
        engine.prepare(isPreview: false, reducedMotion: false)
        check(engine.state.intro == 0, "intro starts at zero")
        _ = engine.requestGroup(group.id)
        var now = 0.0
        var settled = false
        for _ in 0..<240 {
            now += 1.0 / 60.0
            let update = engine.advance(now: now, dt: 1.0 / 60.0, items: items,
                                        appearance: Appearance(), reducedMotion: false)
            if update.settled { settled = true; break }
        }
        check(settled, "submenu settles")
        check(engine.state.arc > 0.99, "submenu opens")
        engine.collapse()
        for _ in 0..<240 {
            now += 1.0 / 60.0
            let update = engine.advance(now: now, dt: 1.0 / 60.0, items: items,
                                        appearance: Appearance(), reducedMotion: false)
            if update.settled { break }
        }
        check(engine.state.arc < 0.01, "submenu closes")
        check(engine.state.shownGroupID == nil, "shown group cleared")

        engine.prepare(isPreview: false, reducedMotion: true)
        check(engine.state.intro == 1, "reduced motion skips intro")
        _ = engine.requestGroup(group.id)
        _ = engine.snap(items: items)
        check(engine.state.arc == 1, "reduced motion snaps open")
        engine.collapse()
        _ = engine.snap(items: items)
        check(engine.state.arc == 0, "reduced motion snaps closed")

        if failures == 0 {
            print("Ring core checks passed")
        } else {
            print("\(failures) check(s) failed")
            exit(1)
        }
    }
}
