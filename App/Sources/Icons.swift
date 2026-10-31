import AppKit
import SwiftUI

/// The menu bar icon: a bold capital K, drawn as a template image so it matches light and
/// dark menu bars. It dims when paused and briefly turns heavier when Keymend makes a fix.
enum MenuBarIcon {
    static func image(paused: Bool, pulse: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let alpha: CGFloat = paused ? 0.35 : 1
            let font = NSFont.systemFont(ofSize: 15, weight: pulse ? .black : .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            ]
            let k = NSAttributedString(string: "K", attributes: attrs)
            // draw(at:) takes the bottom of the descender; put the baseline so the cap height is centered.
            let baseline = (rect.height - font.capHeight) / 2
            k.draw(at: NSPoint(x: (rect.width - k.size().width) / 2, y: baseline + font.descender))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = paused ? "Keymend (paused)" : "Keymend"
        return img
    }
}

/// Brand colors.
enum Brand {
    static let ink = Color(red: 0x1C / 255, green: 0x22 / 255, blue: 0x30 / 255)
    static let thread = Color(red: 0xE4 / 255, green: 0x57 / 255, blue: 0x2E / 255)
    static let paper = Color(red: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF0 / 255)
}

/// The bold capital K shared by the app icon, the setup window and the website icon:
/// the system font's bold "K" outline, normalized so its cap height is 1 and its top-left
/// corner is at the origin (y grows downward).
enum KGlyph {
    nonisolated(unsafe) static let path: CGPath = {
        let font = NSFont.systemFont(ofSize: 1000, weight: .bold) as CTFont
        var chars = Array("K".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        let raw = CTFontCreatePathForGlyph(font, glyphs[0], nil) ?? CGMutablePath()
        let b = raw.boundingBoxOfPath
        var t = CGAffineTransform(scaleX: 1 / b.height, y: -1 / b.height).translatedBy(x: -b.minX, y: -b.maxY)
        return raw.copy(using: &t) ?? raw
    }()

    /// Width of the K relative to its height.
    static var aspect: CGFloat { path.boundingBoxOfPath.width }
}

/// Apple's macOS app icon grid, as fractions of the canvas (1024 px reference): a rounded
/// square 824 px wide, inset 100 px, with continuous corners of radius 185.4 px.
enum IconGrid {
    static let body: CGFloat = 824.0 / 1024
    static let cornerRadius: CGFloat = 185.4 / 1024
    /// Cap height of the K relative to the rounded square.
    static let letterHeight: CGFloat = 0.6

    static func tile(in side: CGFloat) -> Path {
        let w = side * body, inset = (side - w) / 2
        return Path(roundedRect: CGRect(x: inset, y: inset, width: w, height: w), cornerRadius: side * cornerRadius, style: .continuous)
    }

    static func letter(in side: CGFloat) -> Path {
        let h = side * body * letterHeight
        let w = h * KGlyph.aspect
        var t = CGAffineTransform(translationX: (side - w) / 2, y: (side - h) / 2).scaledBy(x: h, y: h)
        return Path(KGlyph.path.copy(using: &t) ?? KGlyph.path)
    }
}

/// The app icon: an Ink bold K on a Paper rounded square, following Apple's icon grid.
struct KAppIcon: View {
    var size: CGFloat = 64
    var body: some View {
        Canvas { ctx, sz in
            let side = sz.width
            let tile = IconGrid.tile(in: side)
            var shadowed = ctx
            shadowed.addFilter(.shadow(color: .black.opacity(0.3), radius: side * 0.01, x: 0, y: side * 0.01))
            shadowed.fill(tile, with: .color(Brand.paper))
            ctx.fill(IconGrid.letter(in: side), with: .color(Brand.ink))
        }
        .frame(width: size, height: size)
    }
}
