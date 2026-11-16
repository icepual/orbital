import AppKit

struct GroupIcon {
    let symbol: String
    let name: String
    let highlight: UInt32
    let shade: UInt32

    static let palette = [
        Self(symbol: "square.stack", name: "通用", highlight: 0x7789FA, shade: 0x3C43A6),
        Self(symbol: "square.on.square", name: "设计", highlight: 0xC182F8, shade: 0x7939B7),
        Self(symbol: "briefcase", name: "工作", highlight: 0x509BF4, shade: 0x2451A8),
        Self(symbol: "star", name: "收藏", highlight: 0xFAB85E, shade: 0xB95823),
        Self(symbol: "wrench.and.screwdriver", name: "工具", highlight: 0x839BA7, shade: 0x3C546A),
        Self(symbol: "paintbrush", name: "创作", highlight: 0xF785AA, shade: 0xBD3B69),
        Self(symbol: "terminal", name: "开发", highlight: 0x49B998, shade: 0x1D605B),
        Self(symbol: "music.note", name: "音乐", highlight: 0xF7807A, shade: 0xB93454),
        Self(symbol: "folder", name: "文件", highlight: 0x53BACD, shade: 0x217892),
        Self(symbol: "bolt", name: "快捷", highlight: 0xD6A83F, shade: 0x8E5C13),
        Self(symbol: "bubble.left.and.bubble.right", name: "通讯", highlight: 0x78B773, shade: 0x397449),
        Self(symbol: "gamecontroller", name: "娱乐", highlight: 0x8E89E3, shade: 0x55449F)
    ]

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(for symbol: String) -> NSImage? {
        palette.first(where: { $0.symbol == symbol })?.image()
    }

    @MainActor func image() -> NSImage {
        if let cached = Self.cache[symbol] { return cached }
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
                .applying(.init(paletteColors: [.white])))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let light = color(highlight)
        let dark = color(shade)
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [light, dark] as CFArray, locations: [0, 1])
        let sheen = CGGradient(colorsSpace: colorSpace,
                               colors: [NSColor.white.withAlphaComponent(0.33).cgColor,
                                        NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                               locations: [0, 1])
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let tile = CGPath(roundedRect: CGRect(x: 7, y: 7, width: 50, height: 50),
                              cornerWidth: 13, cornerHeight: 13, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1.3), blur: 2.2,
                          color: NSColor.black.withAlphaComponent(0.24).cgColor)
            ctx.setFillColor(dark)
            ctx.addPath(tile)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(tile)
            ctx.clip()
            if let gradient {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 11, y: 58),
                                       end: CGPoint(x: 52, y: 8), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            if let sheen {
                ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 16, y: 54), startRadius: 0,
                                       endCenter: CGPoint(x: 16, y: 54), endRadius: 36, options: [])
            }
            ctx.restoreGState()

            ctx.addPath(tile)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.31).cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokePath()

            if let glyph, glyph.size.width > 0, glyph.size.height > 0 {
                let scale = min(31 / glyph.size.width, 26 / glyph.size.height)
                let width = glyph.size.width * scale
                let height = glyph.size.height * scale
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.8,
                              color: NSColor.black.withAlphaComponent(0.25).cgColor)
                glyph.draw(in: CGRect(x: 32 - width / 2, y: 32 - height / 2, width: width, height: height))
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = false
        Self.cache[symbol] = image
        return image
    }

    private func color(_ rgb: UInt32) -> CGColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1).cgColor
    }
}
