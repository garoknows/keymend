import AppKit
import SwiftUI

/// The menu bar icon: a small keycap with a stitch across it, drawn as a template image so
/// it matches light and dark menu bars.
enum KeycapIcon {
    static func image(paused: Bool, pulse: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let alpha: CGFloat = paused ? 0.35 : 1
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()

            // Keycap outline.
            let cap = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 13), xRadius: 3.5, yRadius: 3.5)
            cap.lineWidth = 1.5
            cap.stroke()

            // The stitch: a slanted dashed seam with three cross stitches.
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 4, y: 7))
            seam.line(to: NSPoint(x: 14, y: 9))
            seam.lineWidth = pulse ? 1.9 : 1.3
            seam.setLineDash([1.8, 1.4], count: 2, phase: 0)
            seam.lineCapStyle = .round
            seam.stroke()
            for x in [6.0, 9.0, 12.0] {
                let y = 7 + (x - 4) * 0.2
                let st = NSBezierPath()
                st.move(to: NSPoint(x: x - 0.5, y: y - 2.2))
                st.line(to: NSPoint(x: x + 0.5, y: y + 2.2))
                st.lineWidth = pulse ? 1.6 : 1.2
                st.lineCapStyle = .round
                st.stroke()
            }
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
