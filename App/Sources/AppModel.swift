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
    @Published private(set) var carefulList: [String]
    @Published private(set) var neverCorrect: NeverCorrectList
    /// The never-correct words Keymend added to the Mac's "Learn Spelling" list itself.
    private var taughtSpellings: TaughtSpellings
    @Published private(set) var fixCount = DailyFixCount()
    @Published var launchAtLogin: Bool = false

    // Live state.
    @Published private(set) var canListen = KeyEventTap.hasPermission
    @Published private(set) var canPost = SystemKeyOutput.hasPermission
    @Published private(set) var currentApp: NSRunningApplication?
    @Published private(set) var pulse = false
    /// True only while the keyboard hook really is running (not just allowed to).
    @Published private(set) var tapRunning = false
    /// True while an input method (Japanese, Chinese, Korean…) is selected: Keymend pauses itself.
    @Published private(set) var inputMethodActive = false

    var permissionsGranted: Bool { canListen && canPost }
    /// Allowed to run, but the hook isn't running, so nothing is being fixed.
    var tapStopped: Bool { permissionsGranted && !tapRunning }
    var todayCount: Int { fixCount.count(on: Date()) }
    var currentAppMode: AppMode {
        guard let id = currentApp?.bundleIdentifier else { return .on }
        return mode(for: id)
    }
    var currentAppSkipped: Bool { currentAppMode == .skip }
    var currentAppIsTerminal: Bool { currentApp?.bundleIdentifier.map(AppModePolicy.terminals.contains) ?? false }

    func mode(for id: String) -> AppMode {
        AppModePolicy.mode(for: id, skipList: skipList, carefulList: carefulList)
    }

    private let defaults = UserDefaults.standard
    private let checker = AppleSpellChecker()
    private let output = SystemKeyOutput()
    private let bridge: KeyboardBridge
    private let tap: KeyEventTap
    private let inputMethodPause: InputMethodPause
    let learning: LearningModel
    private var timer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var observers: [NSObjectProtocol] = []

    enum Keys {
        static let enabled = "enabled"
        static let skipList = "skipBundleIDs"
        static let carefulList = "carefulBundleIDs"
        static let neverCorrect = "neverCorrectWords"
        static let taughtSpellings = "neverCorrectTaughtToMac"
        static let fixCount = "fixCount"
        static let setupShown = "setupShown"
    }

    private init() {
        defaults.register(defaults: [Keys.enabled: true, Keys.skipList: DefaultSkipList.bundleIDs, Keys.carefulList: DefaultCarefulList.bundleIDs])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        skipList = defaults.stringArray(forKey: Keys.skipList) ?? DefaultSkipList.bundleIDs
        carefulList = defaults.stringArray(forKey: Keys.carefulList) ?? DefaultCarefulList.bundleIDs
        neverCorrect = NeverCorrectList(words: defaults.stringArray(forKey: Keys.neverCorrect) ?? [])
        taughtSpellings = TaughtSpellings(words: defaults.stringArray(forKey: Keys.taughtSpellings) ?? [])
        if let data = defaults.data(forKey: Keys.fixCount), let c = try? JSONDecoder().decode(DailyFixCount.self, from: data) {
            fixCount = c
        }

        var hooks = KeyboardBridge.Hooks()
        hooks.didFix = { Task { @MainActor in AppModel.shared.recordFix() } }
        hooks.didUndo = { Task { @MainActor in AppModel.shared.recordUndo() } }
        hooks.didLearn = { event, verdict in Task { @MainActor in AppModel.shared.learning.record(event, verdict: verdict) } }
        output.setLayout(KeyLayoutMap.current())
        bridge = KeyboardBridge(output: output, checker: TimeLimitedSpellChecker(checker), hooks: hooks)
        tap = KeyEventTap(bridge: bridge)
        inputMethodPause = InputMethodPause(bridge: bridge)
        learning = LearningModel(bridge: bridge, defaults: defaults)
        bridge.neverCorrect = neverCorrect
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Called once at launch.
    func start() {
        observeSystem()
        learning.start()
        registerHotKey()
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        inputMethodActive = inputMethodPause.refresh()
        refreshPermissions()
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
        // A hook macOS stopped is recreated, not just "started" again (which did nothing).
        let running = TapSupervisor.ensureRunning(tap, permitted: listen)
        if running != tapRunning { tapRunning = running }
        if permissionsGranted { defaults.set(true, forKey: Keys.setupShown) }
        schedulePermissionCheck()
    }

    /// Re-checks permissions every 2 s until both are granted, then every 30 s.
    private func schedulePermissionCheck() {
        let interval: TimeInterval = permissionsGranted ? 30 : 2
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshPermissions() }
        }
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
        if skipList.contains(id) {
            guard confirmTerminal(id) else { return }
            removeSkip(id)
        } else {
            addSkip(id)
        }
    }

    /// Only Ghostty detects password prompts well enough to run without a warning.
    private func confirmTerminal(_ id: String) -> Bool {
        guard AppModePolicy.terminals.contains(id), !DefaultCarefulList.bundleIDs.contains(id) else { return true }
        let alert = NSAlert()
        alert.messageText = "Use Keymend in this terminal?"
        alert.informativeText = "Keymend will use Careful Mode here. A password typed at a terminal prompt can reach Keymend's memory unless this terminal turns on Secure Keyboard Entry, which also stops Keymend working in it. Nothing is saved, but a passphrase with spaces could be changed. Some commands can still change: see the README."
        alert.addButton(withTitle: "Use Careful Mode")
        alert.addButton(withTitle: "Keep Skipping")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func toggleCarefulCurrentApp() {
        guard let id = currentApp?.bundleIdentifier, !AppModePolicy.terminals.contains(id) else { return }
        if carefulList.contains(id) { removeCareful(id) } else { addCareful(id) }
    }

    func addCareful(_ id: String) {
        guard !carefulList.contains(id) else { return }
        carefulList.append(id)
        skipList.removeAll { $0 == id }
        saveModes()
    }

    /// A terminal is never in plain On mode, so taking one off this list skips it instead.
    func removeCareful(_ id: String) {
        carefulList.removeAll { $0 == id }
        if AppModePolicy.terminals.contains(id), !skipList.contains(id) { skipList.append(id) }
        saveModes()
    }

    func addSkip(_ id: String) {
        guard !skipList.contains(id) else { return }
        skipList.append(id)
        saveModes()
    }

    func removeSkip(_ id: String) {
        skipList.removeAll { $0 == id }
        saveModes()
    }

    func resetSkipList() {
        skipList = DefaultSkipList.bundleIDs
        carefulList = DefaultCarefulList.bundleIDs
        saveModes()
    }

    private func saveModes() {
        defaults.set(skipList, forKey: Keys.skipList)
        defaults.set(carefulList, forKey: Keys.carefulList)
        applyState()
    }

    @discardableResult
    func addNeverCorrect(_ word: String) -> Bool {
        guard neverCorrect.add(word) else { return false }
        // Shared with the Mac's own "Learn Spelling" list, so other apps stop flagging it too.
        taughtSpellings.add(word, to: checker)
        saveNeverCorrect()
        return true
    }

    func removeNeverCorrect(_ word: String) {
        neverCorrect.remove(word)
        // Only taken off the Mac's list if Keymend put it there.
        taughtSpellings.remove(word, from: checker)
        saveNeverCorrect()
    }

    private func saveNeverCorrect() {
        defaults.set(neverCorrect.words, forKey: Keys.neverCorrect)
        defaults.set(taughtSpellings.words, forKey: Keys.taughtSpellings)
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
        bridge.isAppSkipped = currentAppMode == .skip
        bridge.isAppCareful = currentAppMode == .careful
        // Nothing typed in Keymend's own windows is learned, including its search box.
        let keymendIsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        learning.frontmostAppChanged(keymendIsInFront ? nil : currentApp?.bundleIdentifier)
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
        // Keyboard layout or input method changes: forget the current word, and pause while an
        // input method (Japanese, Chinese, Korean…) is selected.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.output.setLayout(KeyLayoutMap.current())
                AppModel.shared.inputMethodActive = AppModel.shared.inputMethodPause.refresh()
                AppModel.shared.bridge.reset()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.bridge.reset() }
        })
    }

    private func afterWake() {
        bridge.reset()
        // The tap can be dropped across sleep; refreshPermissions recreates it if so.
        refreshPermissions()
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
