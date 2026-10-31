import AppKit
import KeymendCore
import SwiftUI

@main
struct KeymendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: KeycapIcon.image(paused: !model.isEnabled || !model.permissionsGranted, pulse: model.pulse))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.start() }
    }
}

/// The menu: On/Paused switch, today's count, skip the current app, Settings, Quit.
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.permissionsGranted {
            Button("Finish Setup…") { SetupWindowController.shared.show() }
            Divider()
        }
        Toggle(model.isEnabled ? "Keymend is On" : "Keymend is Paused", isOn: $model.isEnabled)
            .keyboardShortcut("k", modifiers: [.control, .option])
        Text(DailyFixCount.summary(model.todayCount))
        Divider()
        if let app = model.currentApp, let name = app.localizedName {
            Button(model.currentAppSkipped ? "Don't Skip in \(name)" : "Skip in \(name)") {
                model.toggleSkipCurrentApp()
            }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Keymend") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
