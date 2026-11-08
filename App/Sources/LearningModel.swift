import AppKit
import Combine
import KeymendCore

/// The Learning Dictionary's state: the switch, the review list and the encrypted file.
/// Learning is off until the user turns it on. While it's off, no words are in memory here.
@MainActor
final class LearningModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isPaused: Bool
    @Published private(set) var excludedApps: [String]
    @Published private(set) var store = LearningStore()
    @Published var problem: String?

    private let defaults: UserDefaults
    private let bridge: KeyboardBridge
    private var frontmostApp: String?
    private var saveTask: Task<Void, Never>?

    enum Keys {
        static let enabled = "learningEnabled"
        static let paused = "learningPaused"
        static let excluded = "learningExcludedApps"
    }

    init(bridge: KeyboardBridge, defaults: UserDefaults) {
        self.bridge = bridge
        self.defaults = defaults
        defaults.register(defaults: [Keys.excluded: DefaultLearningExclusions.bundleIDs])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        isPaused = defaults.bool(forKey: Keys.paused)
        excludedApps = defaults.stringArray(forKey: Keys.excluded) ?? DefaultLearningExclusions.bundleIDs
    }

    /// Called once at launch. Touches the Keychain only if learning is on.
    func start() {
        if isEnabled { open() }
    }

    private func vault() throws -> LearningVault {
        LearningVault(fileURL: try LearningVault.defaultFileURL(), keys: KeychainLearningKey())
    }

    /// Loads the file. If it can't be opened, learning stays off and the file isn't touched.
    private func open() {
        do {
            store = try vault().load()
            store.forgetStale(today: Date())
            problem = nil
            applyRules()
        } catch {
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            store = LearningStore()
            problem = "Keymend couldn't open your learned words, so learning stayed off. Nothing was changed. To start over, use Clear Everything."
            applyRules()
        }
    }

    // MARK: Switches

    func setEnabled(_ on: Bool) {
        if on {
            isEnabled = true
            defaults.set(true, forKey: Keys.enabled)
            open()
        } else {
            saveNow()
            isEnabled = false
            defaults.set(false, forKey: Keys.enabled)
            store = LearningStore()
            applyRules()
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        defaults.set(paused, forKey: Keys.paused)
        applyRules()
    }

    /// Follows the frontmost app, so excluded apps never reach the learning code.
    func frontmostAppChanged(_ bundleID: String?) {
        frontmostApp = bundleID
        applyRules()
    }

    private func applyRules() {
        let excluded = frontmostApp.map(excludedApps.contains) ?? true
        bridge.learningCaptures = isEnabled && !isPaused && !excluded
        bridge.learnedRules = isEnabled ? store.rules : LearnedRules()
    }

    // MARK: Exclusions

    func addExcluded(_ id: String) {
        guard !excludedApps.contains(id) else { return }
        excludedApps.append(id)
        saveExcluded()
    }

    func removeExcluded(_ id: String) {
        excludedApps.removeAll { $0 == id }
        saveExcluded()
    }

    private func saveExcluded() {
        defaults.set(excludedApps, forKey: Keys.excluded)
        applyRules()
    }

    // MARK: Words

    /// Something the watcher noticed. Only words the spell checker flagged get here.
    func record(_ event: LearningEvent, verdict: SpellVerdict) {
        guard isEnabled, !isPaused else { return }
        let before = store.rules
        store.record(event, day: today) { _ in verdict }
        if store.rules != before { applyRules() }
        scheduleSave()
    }

    private var today: String { DailyFixCount.dayKey(for: Date()) }

    func approve(_ item: LearnedItem) { change { $0.approve(item.id) } }
    func reject(_ item: LearnedItem) { change { $0.reject(item.id) } }
    func delete(_ item: LearnedItem) { change { $0.delete(item.id) } }

    @discardableResult
    func edit(_ item: LearnedItem, correction: String) -> Bool {
        var ok = false
        change { ok = $0.edit(item.id, correction: correction) }
        return ok
    }

    @discardableResult
    func addByHand(_ word: String) -> Bool {
        var ok = false
        change { ok = $0.addByHand(word, day: today) }
        return ok
    }

    private func change(_ body: (inout LearningStore) -> Void) {
        body(&store)
        applyRules()
        saveNow()
    }

    /// Wipes the words, the file and the key.
    func clearEverything() {
        saveTask?.cancel()
        store.clear()
        applyRules()
        do {
            try vault().destroy()
            problem = nil
        } catch {
            problem = "Keymend cleared its memory, but couldn't remove the file or its key."
        }
    }

    // MARK: Saving

    /// Waits a little, so a burst of typing means one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard isEnabled else { return }
        do {
            try vault().save(store)
        } catch {
            problem = "Keymend couldn't save your learned words."
        }
    }

    // MARK: Export and import

    func export(passphrase: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Keymend Learned Words.keymendlearning"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LearningVault.writeExport(store, passphrase: passphrase, to: url)
            problem = nil
        } catch {
            problem = "Keymend couldn't write that file."
        }
    }

    func importFile(passphrase: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Opening the file takes deliberate key work (about a second), so it runs off the main
        // thread and the menu bar and Settings stay responsive.
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LearningVault.readExport(from: url, passphrase: passphrase) }
            }.value
            switch result {
            case .success(let incoming):
                var refused = 0
                change { refused = $0.merge(incoming) }
                problem = refused == 0 ? nil
                    : "\(refused) item\(refused == 1 ? "" : "s") in that file weren't plain words Keymend could learn, so they were left out."
            case .failure(LearningVaultError.wrongPassphrase):
                problem = "That passphrase doesn't open this file."
            case .failure:
                problem = "That isn't a Keymend export."
            }
        }
    }
}
