import AppKit
import Carbon.HIToolbox
import Combine
import KeymendCore
import ServiceManagement
import SwiftUI

/// The app's state: settings, permissions, today's count and the keyboard bridge.
/// Nothing typed is ever stored here; only settings and a number.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Settings (UserDefaults, inside the app's sandbox container).
    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled); applyState() } }
    @Published private(set) var skipList: [String]
    @Published private(set) var neverCorrect: NeverCorrectList
    @Published private(set) var fixCount = DailyFixCount()
    @Published var launchAtLogin: Bool = false

    // Live state.
    @Published private(set) var canListen = KeyEventTap.hasPermission
    @Published private(set) var canPost = SystemKeyOutput.hasPermission
    @Published private(set) var currentApp: NSRunningApplication?
    @Published private(set) var pulse = false

    var permissionsGranted: Bool { canListen && canPost }
    var todayCount: Int { fixCount.count(on: Date()) }
    var currentAppSkipped: Bool { currentApp?.bundleIdentifier.map(skipList.contains) ?? false }

    private let defaults = UserDefaults.standard
    private let checker = AppleSpellChecker()
    private let output = SystemKeyOutput()
    private let bridge: KeyboardBridge
    private let tap: KeyEventTap
    private var timer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var observers: [NSObjectProtocol] = []

    enum Keys {
        static let enabled = "enabled"
        static let skipList = "skipBundleIDs"
        static let neverCorrect = "neverCorrectWords"
        static let fixCount = "fixCount"
        static let setupShown = "setupShown"
    }

    private init() {
        defaults.register(defaults: [Keys.enabled: true, Keys.skipList: DefaultSkipList.bundleIDs])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        skipList = defaults.stringArray(forKey: Keys.skipList) ?? DefaultSkipList.bundleIDs
        neverCorrect = NeverCorrectList(words: defaults.stringArray(forKey: Keys.neverCorrect) ?? [])
        if let data = defaults.data(forKey: Keys.fixCount), let c = try? JSONDecoder().decode(DailyFixCount.self, from: data) {
            fixCount = c
        }

        var hooks = KeyboardBridge.Hooks()
        hooks.didFix = { Task { @MainActor in AppModel.shared.recordFix() } }
        hooks.didUndo = { Task { @MainActor in AppModel.shared.recordUndo() } }
        output.setLayout(KeyLayoutMap.current())
        bridge = KeyboardBridge(output: output, checker: TimeLimitedSpellChecker(checker), hooks: hooks)
        tap = KeyEventTap(bridge: bridge)
        bridge.neverCorrect = neverCorrect
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called once at launch.
    func start() {
        observeSystem()
        registerHotKey()
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        refreshPermissions()
        // Re-check permissions every 2 s until both are granted, then every 30 s.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshPermissions() }
        }
        if !permissionsGranted || !defaults.bool(forKey: Keys.setupShown) {
            SetupWindowController.shared.show()
        }
    }

    // MARK: Permissions

    func refreshPermissions() {
        let listen = KeyEventTap.hasPermission
        let post = SystemKeyOutput.hasPermission
        if listen != canListen { canListen = listen }
        if post != canPost { canPost = post }
        if listen && !tap.isRunning { tap.start() }
        if permissionsGranted { defaults.set(true, forKey: Keys.setupShown) }
    }

    func requestListenPermission() {
        KeyEventTap.requestPermission()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestPostPermission() {
        SystemKeyOutput.requestPermission()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Pause, skip list, dictionary

    func togglePause() { isEnabled.toggle() }

    func toggleSkipCurrentApp() {
        guard let id = currentApp?.bundleIdentifier else { return }
        if skipList.contains(id) { removeSkip(id) } else { addSkip(id) }
    }

    func addSkip(_ id: String) {
        guard !skipList.contains(id) else { return }
        skipList.append(id)
        saveSkipList()
    }

    func removeSkip(_ id: String) {
        skipList.removeAll { $0 == id }
        saveSkipList()
    }

    func resetSkipList() {
        skipList = DefaultSkipList.bundleIDs
        saveSkipList()
    }

    private func saveSkipList() {
        defaults.set(skipList, forKey: Keys.skipList)
        applyState()
    }

    @discardableResult
    func addNeverCorrect(_ word: String) -> Bool {
        guard neverCorrect.add(word) else { return false }
        // Shared with the Mac's own "Learn Spelling" list, so other apps stop flagging it too.
        checker.learnWord(word.trimmingCharacters(in: .whitespacesAndNewlines))
        saveNeverCorrect()
        return true
    }

    func removeNeverCorrect(_ word: String) {
        neverCorrect.remove(word)
        checker.unlearnWord(word)
        saveNeverCorrect()
    }

    private func saveNeverCorrect() {
        defaults.set(neverCorrect.words, forKey: Keys.neverCorrect)
        bridge.neverCorrect = neverCorrect
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Leave the checkbox showing the real state.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Counting (numbers only)

    private func recordFix() {
        fixCount.increment(on: Date())
        saveCount()
        pulse = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            self.pulse = false
        }
    }

    private func recordUndo() {
        fixCount.decrement(on: Date())
        saveCount()
    }

    private func saveCount() {
        if let data = try? JSONEncoder().encode(fixCount) { defaults.set(data, forKey: Keys.fixCount) }
    }

    // MARK: System events

    private func applyState() {
        bridge.isEnabled = isEnabled
        bridge.isAppSkipped = currentAppSkipped
    }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        // The menu itself doesn't count as "the current app".
        if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            currentApp = app
        }
        applyState()
        bridge.reset()
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { AppModel.shared.updateFrontmostApp(app) }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.afterWake() }
            })
        }
        // Keyboard layout changes: forget the current word.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.output.setLayout(KeyLayoutMap.current())
                AppModel.shared.bridge.reset()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.bridge.reset() }
        })
    }

    private func afterWake() {
        bridge.reset()
        refreshPermissions()
        // The tap can be dropped across sleep; restart it if so.
        if canListen && !tap.isRunning {
            tap.stop()
            tap.start()
        }
    }

    // MARK: Global shortcut (Control-Option-K)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in AppModel.shared.togglePause() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4B4D_4E44), id: 1) // "KMND"
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
