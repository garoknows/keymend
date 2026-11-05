import AppKit
import KeymendCore
import SwiftUI

/// Settings: General, Apps, Dictionary, Learning.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var learning = AppModel.shared.learning

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppsTab(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            DictionaryTab(model: model)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            LearningTab(learning: learning)
                .tabItem {
                    let waiting = learning.store.proposedCount
                    Label(waiting > 0 ? "Learning (\(waiting))" : "Learning", systemImage: "brain")
                }
        }
        .frame(width: 600, height: 520)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Fix spelling as I type", isOn: $model.isEnabled)
                Toggle("Open Keymend at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                LabeledContent("Pause or resume") {
                    Text("⌃⌥K").font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            Section("Permissions") {
                PermissionRow(title: "Input Monitoring", detail: "See the keys you type", granted: model.canListen)
                PermissionRow(title: "Typing fixes", detail: "Listed under Accessibility", granted: model.canPost)
                if !model.permissionsGranted {
                    Button("Show Setup…") { SetupWindowController.shared.show() }
                }
            }
            Section("Coming in 1.1") {
                Text("Your Mac Text Replacements in every app, capitalize sentences, double-space period, and other languages.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Keymend never connects to the internet. It doesn't save what you type. If you turn on Learning, it keeps single words and counts, encrypted, on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "Allowed" : "Not yet").foregroundStyle(.secondary)
        }
    }
}

struct AppsTab: View {
    @ObservedObject var model: AppModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Careful Mode fixes only lines that look like plain language, for apps where you also type commands or code. Keymend stays off completely in skipped apps.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                Section("Careful Mode") {
                    ForEach(model.carefulList.filter { !model.skipList.contains($0) }, id: \.self) { id in
                        AppRow(bundleID: id).tag(id)
                    }
                }
                Section("Skipped") {
                    ForEach(model.skipList, id: \.self) { id in
                        AppRow(bundleID: id).tag(id)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Menu("Skip App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier { model.addSkip(id) }
                        }
                    }
                }
                .fixedSize()
                Menu("Careful App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier { model.addCareful(id) }
                        }
                    }
                }
                .fixedSize()
                Button("Remove") {
                    if let s = selection {
                        if model.skipList.contains(s) { model.removeSkip(s) } else { model.removeCareful(s) }
                        selection = nil
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Restore Defaults") { model.resetSkipList() }
            }
        }
        .padding(20)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !model.skipList.contains($0.bundleIdentifier!) && !model.carefulList.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

struct AppRow: View {
    var bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                if url == nil {
                    Text("Not installed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    private var name: String {
        if let url { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return bundleID
    }
    private var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

struct DictionaryTab: View {
    @ObservedObject var model: AppModel
    @State private var newWord = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words Keymend never changes. They're also added to your Mac's own spelling dictionary. Words it learns by itself aren't: those stay in the Learning tab.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Add a word, like a name or product", text: $newWord)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(selection: $selection) {
                ForEach(model.neverCorrect.words, id: \.self) { Text($0).tag($0) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if model.neverCorrect.words.isEmpty {
                    Text("No words yet").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Remove") {
                    if let s = selection { model.removeNeverCorrect(s); selection = nil }
                }
                .disabled(selection == nil)
                Spacer()
            }
        }
        .padding(20)
    }

    private func add() {
        if model.addNeverCorrect(newWord) { newWord = "" }
    }
}
