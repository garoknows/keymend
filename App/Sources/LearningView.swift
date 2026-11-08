import AppKit
import KeymendCore
import SwiftUI

/// Settings → Learning: the switch, the plain explanation, and the review list.
struct LearningTab: View {
    @ObservedObject var learning: LearningModel
    @State private var search = ""
    @State private var selection: LearnedItem.ID?
    @State private var showIntro = false
    @State private var confirmClear = false
    @State private var editing: LearnedItem?
    @State private var editedCorrection = ""
    @State private var newWord = ""
    @State private var passphraseAction: PassphraseAction?
    @State private var passphrase = ""
    @State private var showExclusions = false

    enum PassphraseAction: String, Identifiable {
        case export = "Export", importing = "Import"
        var id: String { rawValue }
    }

    static let explanation = "Keymend will remember single words you often fix or undo, and how often, so it can stop repeating mistakes. It stores words and counts only, never sentences, apps or websites, and only on this Mac, encrypted. You review everything here."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Learn from my typing", isOn: Binding(
                get: { learning.isEnabled },
                set: { on in
                    if on { showIntro = true } else { learning.setEnabled(false) }
                }
            ))
            Text(Self.explanation)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = learning.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if learning.isEnabled {
                enabledContent
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Button("Clear Everything…") { confirmClear = true }
                }
            }
        }
        .padding(20)
        .alert("Turn on learning?", isPresented: $showIntro) {
            Button("Turn On") { learning.setEnabled(true) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(Self.explanation)
        }
        .alert("Clear everything Keymend has learned?", isPresented: $confirmClear) {
            Button("Clear Everything", role: .destructive) {
                learning.clearEverything()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every learned word, the encrypted file and its key. It can't be undone.")
        }
        .sheet(item: $editing) { item in editSheet(item) }
        .sheet(item: $passphraseAction) { action in passphraseSheet(action) }
        .sheet(isPresented: $showExclusions) { ExclusionsSheet(learning: learning) }
    }

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search", text: $search)
                Toggle("Pause", isOn: Binding(get: { learning.isPaused }, set: { learning.setPaused($0) }))
                    .fixedSize()
            }
            Table(rows, selection: $selection) {
                TableColumn("Typed", value: \.typed)
                TableColumn("Correction") { item in Text(item.correction) }
                TableColumn("Count") { item in Text("\(item.count)") }.width(44)
                TableColumn("Last seen", value: \.lastSeen).width(78)
                TableColumn("Status") { item in Text(Self.label(for: item)) }.width(80)
            }
            .contextMenu(forSelectionType: LearnedItem.ID.self) { ids in
                if let id = ids.first, let item = learning.store.items.first(where: { $0.id == id }) {
                    rowActions(item)
                }
            }
            .overlay {
                if rows.isEmpty {
                    Text(search.isEmpty ? "Nothing learned yet" : "No matches").foregroundStyle(.secondary)
                }
            }
            HStack {
                if let item = selected {
                    rowActions(item)
                } else {
                    Text("Select a row to approve, edit, reject or delete it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 22)
            HStack {
                TextField("Add a word, email or handle by hand", text: $newWord)
                    .onSubmit(addWord)
                Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Export…") { passphraseAction = .export }
                Button("Import…") { passphraseAction = .importing }
                Button("Excluded Apps…") { showExclusions = true }
                Spacer()
                Button("Clear Everything…") { confirmClear = true }
            }
        }
    }

    private var rows: [LearnedItem] { learning.store.ranked(matching: search) }
    private var selected: LearnedItem? { selection.flatMap { id in learning.store.items.first { $0.id == id } } }

    @ViewBuilder
    private func rowActions(_ item: LearnedItem) -> some View {
        if item.kind == .correction, item.status != .active {
            Button("Approve") { learning.approve(item) }
        }
        if item.kind == .correction {
            Button("Edit…") {
                editedCorrection = item.correction
                editing = item
            }
        }
        if item.status != .rejected {
            Button("Reject") { learning.reject(item) }
        }
        Button("Delete") {
            learning.delete(item)
            selection = nil
        }
    }

    private func addWord() {
        if learning.addByHand(newWord) { newWord = "" }
    }

    private static func label(for item: LearnedItem) -> String {
        switch (item.kind, item.status) {
        case (_, .rejected): return "Rejected"
        case (_, .watching): return "Watching"
        case (_, .proposed): return "Proposed"
        case (.correction, .active): return "Rule"
        case (.undo, .active): return "Fix stopped"
        case (.known, .active): return "Known"
        }
    }

    private func editSheet(_ item: LearnedItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct \u{201C}\(item.typed)\u{201D} to:")
            TextField("Correction", text: $editedCorrection)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editing = nil }
                Button("Save and Approve") {
                    if learning.edit(item, correction: editedCorrection) {
                        selection = nil
                        editing = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func passphraseSheet(_ action: PassphraseAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(action == .export
                 ? "Choose a passphrase for this file. You'll need it to import the file on another Mac. If you lose it, the file can't be opened."
                 : "Enter the passphrase for the file you're importing. Imported corrections wait for your approval, the same as ones learned here.")
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passphrase", text: $passphrase)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    passphrase = ""
                    passphraseAction = nil
                }
                Button("Choose File…") {
                    let entered = passphrase
                    passphrase = ""
                    passphraseAction = nil
                    DispatchQueue.main.async {
                        if action == .export { learning.export(passphrase: entered) } else { learning.importFile(passphrase: entered) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// The apps Keymend never learns from.
private struct ExclusionsSheet: View {
    @ObservedObject var learning: LearningModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keymend never learns in these apps. Add your banking apps here. A bank's website can't be excluded this way, because Keymend can't tell which website you're on.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(learning.excludedApps, id: \.self) { id in
                    AppRow(bundleID: id).tag(id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Menu("Add App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            if let id = app.bundleIdentifier { learning.addExcluded(id) }
                        }
                    }
                }
                .fixedSize()
                Button("Remove") {
                    if let s = selection {
                        learning.removeExcluded(s)
                        selection = nil
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 340)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !learning.excludedApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}
