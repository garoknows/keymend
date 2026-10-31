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

/// The full-color keycap used in the setup window and the app icon.
struct BrandKeycap: View {
    var size: CGFloat = 64
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 64
            let cap = Path(roundedRect: CGRect(x: 8 * s, y: 10 * s, width: 48 * s, height: 44 * s), cornerRadius: 11 * s)
            ctx.fill(cap, with: .color(Brand.paper))
            ctx.stroke(cap, with: .color(Brand.ink), lineWidth: 4 * s)
            var base = Path(); base.move(to: CGPoint(x: 15 * s, y: 44 * s)); base.addLine(to: CGPoint(x: 49 * s, y: 44 * s))
            ctx.stroke(base, with: .color(Brand.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
            var seam = Path(); seam.move(to: CGPoint(x: 16 * s, y: 31 * s)); seam.addLine(to: CGPoint(x: 48 * s, y: 25 * s))
            ctx.stroke(seam, with: .color(Brand.thread), style: StrokeStyle(lineWidth: 3.5 * s, lineCap: .round, dash: [5 * s, 4 * s]))
            for (x, y) in [(22.0, 26.0), (31.0, 24.5), (40.0, 23.0)] {
                var st = Path(); st.move(to: CGPoint(x: x * s, y: y * s)); st.addLine(to: CGPoint(x: (x + 2) * s, y: (y + 8) * s))
                ctx.stroke(st, with: .color(Brand.thread), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}
