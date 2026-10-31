import AppKit
import SwiftUI

/// Shows the first-run setup window.
@MainActor
final class SetupWindowController {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SetupView(model: AppModel.shared, close: { [weak self] in self?.window?.close() }))
            let w = NSWindow(contentViewController: host)
            w.title = "Set Up Keymend"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One window that walks through the two permissions, with an annotated picture of
/// exactly where to click. Each step turns green on its own once granted.
struct SetupView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                KAppIcon(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("keymend").font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Two permissions, then it just works.").foregroundStyle(.secondary)
                }
            }
            SetupStep(
                number: 1,
                title: "Allow Input Monitoring",
                detail: "Lets Keymend see the word you're typing. Nothing is saved, and password fields are never seen.",
                granted: model.canListen,
                button: "Open Input Monitoring",
                action: model.requestListenPermission,
                picture: AnnotatedSettings(pane: "Input Monitoring")
            )
            SetupStep(
                number: 2,
                title: "Allow Keymend to type fixes",
                detail: "Lets Keymend type the corrected word. macOS lists this under Accessibility.",
                granted: model.canPost,
                button: "Open Accessibility",
                action: model.requestPostPermission,
                picture: AnnotatedSettings(pane: "Accessibility")
            )
            HStack {
                Text(model.permissionsGranted
                     ? "All set. Look for the K in your menu bar."
                     : "This window updates by itself when each step is done. If a switch is on but the step stays grey, quit and reopen Keymend.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.permissionsGranted ? "Done" : "Later", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}

struct SetupStep<Picture: View>: View {
    var number: Int
    var title: String
    var detail: String
    var granted: Bool
    var button: String
    var action: () -> Void
    var picture: Picture

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(granted ? Color.green : Brand.thread).frame(width: 24, height: 24)
                        if granted {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        }
                    }
                    Text(title).font(.headline)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(button, action: action)
                }
            }
            .frame(width: 230, alignment: .leading)
            picture
                .opacity(granted ? 0.45 : 1)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(granted ? Color.green.opacity(0.08) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(granted ? Color.green.opacity(0.5) : Color.clear))
    }
}

/// A drawn picture of the System Settings privacy pane, with red boxes and numbered markers
/// on exactly where to click: (1) Privacy & Security, (2) the pane, (3) Keymend's switch.
struct AnnotatedSettings: View {
    var pane: String
    private let red = Color(red: 0.89, green: 0.16, blue: 0.16)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            HStack(spacing: 0) {
                // Sidebar
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6) } }
                        .padding(.bottom, 4)
                    sidebarRow("General", symbol: "gearshape")
                    sidebarRow("Keyboard", symbol: "keyboard")
                    sidebarRow("Privacy & Security", symbol: "hand.raised.fill", selected: true)
                        .overlay(markerBox(1))
                    sidebarRow("Desktop & Dock", symbol: "dock.rectangle")
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 128)
                .background(Color.secondary.opacity(0.08))
                // Content
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 8))
                        Text(pane).font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.vertical, 2)
                    .overlay(markerBox(2))
                    Text("Allow the apps below to \(pane == "Accessibility" ? "control your computer" : "monitor input from your keyboard").")
                        .font(.system(size: 7.5)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        appRow("Another App", on: true)
                        Divider()
                        appRow("Keymend", on: false, keymend: true)
                            .overlay(alignment: .trailing) { markerBox(3).frame(width: 34, height: 20).offset(x: 4) }
                    }
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.07)))
                    Spacer(minLength: 0)
                }
                .padding(8)
            }
        }
        .frame(width: 330, height: 150)
        .accessibilityLabel("System Settings, Privacy & Security, \(pane): turn on the switch next to Keymend.")
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 7)).frame(width: 10)
            Text(title).font(.system(size: 8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor.opacity(0.85) : .clear))
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    private func appRow(_ name: String, on: Bool, keymend: Bool = false) -> some View {
        HStack(spacing: 5) {
            if keymend {
                KAppIcon(size: 14)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 12, height: 12)
            }
            Text(name).font(.system(size: 8.5))
            Spacer()
            Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 18, height: 10)
                .overlay(Circle().fill(.white).frame(width: 8, height: 8).offset(x: on ? 4 : -4))
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func markerBox(_ n: Int) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(red, lineWidth: 1.8)
            .padding(-2)
            .overlay(alignment: .topTrailing) {
                Text("\(n)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(red))
                    .offset(x: 8, y: -8)
            }
    }
}
