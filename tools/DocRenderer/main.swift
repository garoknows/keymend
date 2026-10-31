// Renders the app icon and the documentation pictures from the app's real SwiftUI views.
// Built by tools/render-assets.sh together with App/Sources (minus the app entry point).
// This tool is never shipped; the app itself writes no files.
import AppKit
import SwiftUI

@MainActor
func png(_ view: some View, scale: CGFloat = 2, to url: URL) {
    let r = ImageRenderer(content: view)
    r.scale = scale
    guard let cg = r.cgImage else { print("render failed: \(url.lastPathComponent)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) \(cg.width)x\(cg.height)")
}

/// SVG path data for a SwiftUI path.
func svgPath(_ path: Path) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    path.forEach { e in
        switch e {
        case .move(let p): d += "M\(f(p.x)) \(f(p.y))"
        case .line(let p): d += "L\(f(p.x)) \(f(p.y))"
        case .quadCurve(let p, let c): d += "Q\(f(c.x)) \(f(c.y)) \(f(p.x)) \(f(p.y))"
        case .curve(let p, let c1, let c2): d += "C\(f(c1.x)) \(f(c1.y)) \(f(c2.x)) \(f(c2.y)) \(f(p.x)) \(f(p.y))"
        case .closeSubpath: d += "Z"
        }
    }
    return d
}

/// The website icon: the same tile and K as the app icon, on the same 1024 grid.
func iconSVG() -> String {
    let side: CGFloat = 1024
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="keymend">
      <defs><filter id="s" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/></filter></defs>
      <path filter="url(#s)" fill="#F7F5F0" d="\(svgPath(IconGrid.tile(in: side)))"/>
      <path fill="#1C2230" d="\(svgPath(IconGrid.letter(in: side)))"/>
    </svg>

    """
}

// Settings tabs use AppKit-backed Form and List, which ImageRenderer cannot draw;
// screenshots of those come from the running app instead.

/// A light, branded backdrop for documentation pictures.
struct Backdrop<Content: View>: View {
    var content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.12)))
            .padding(24)
            .background(Brand.paper)
            .environment(\.colorScheme, .light)
    }
}

/// A drawing of the open menu, matching MenuContent.
struct MenuPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Image(nsImage: MenuBarIcon.image(paused: false, pulse: false)).renderingMode(.template)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.1)))
                Text("Fri 9:41").font(.system(size: 13))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 2) {
                row("checkmark", "Keymend is On", "⌃⌥K")
                row(nil, "Fixed 42 typos today", nil, dim: true)
                Divider().padding(.vertical, 3)
                row(nil, "Skip in Slack", nil)
                row(nil, "Settings…", "⌘,")
                Divider().padding(.vertical, 3)
                row(nil, "Quit Keymend", "⌘Q")
            }
            .padding(6)
            .frame(width: 250)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.97)).shadow(radius: 6, y: 2))
            .padding(.leading, 120).padding(.top, 2).padding(.bottom, 10)
        }
        .frame(width: 420)
        .background(LinearGradient(colors: [Color(red: 0.86, green: 0.88, blue: 0.93), Brand.paper], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .light)
    }

    func row(_ check: String?, _ title: String, _ key: String?, dim: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: check ?? "checkmark").opacity(check == nil ? 0 : 1).font(.system(size: 11, weight: .semibold)).frame(width: 14)
            Text(title).foregroundStyle(dim ? Color.secondary : Color.primary)
            Spacer()
            if let key { Text(key).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6).padding(.vertical, 3)
    }
}

@main
struct DocRenderer {
    @MainActor static func main() {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        guard args.count >= 4 else { print("usage: DocRenderer <iconset dir> <docs images dir> <site icon.svg>"); exit(2) }
        let iconset = URL(fileURLWithPath: args[1])
        let docs = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        for base in [16, 32, 128, 256, 512] {
            png(KAppIcon(size: CGFloat(base)), scale: 1, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            png(KAppIcon(size: CGFloat(base)), scale: 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        png(KAppIcon(size: 256), scale: 2, to: docs.appendingPathComponent("icon.png"))
        try! iconSVG().write(toFile: args[3], atomically: false, encoding: .utf8)
        print("wrote \(URL(fileURLWithPath: args[3]).lastPathComponent)")

        let model = AppModel.shared
        png(Backdrop { SetupView(model: model) }, to: docs.appendingPathComponent("setup-window.png"))
        png(Backdrop { AnnotatedSettings(pane: "Input Monitoring").padding(16) }, scale: 3, to: docs.appendingPathComponent("step1-input-monitoring.png"))
        png(Backdrop { AnnotatedSettings(pane: "Accessibility").padding(16) }, scale: 3, to: docs.appendingPathComponent("step2-accessibility.png"))
        png(MenuPicture(), to: docs.appendingPathComponent("menu.png"))
    }
}
