import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Connects keystrokes to the word engine and types the fixes.
///
/// Thread model: `receive(_:)` is called on the event-tap thread and returns at once.
/// The engine runs on its own serial queue, so the tap never waits for the spell checker.
/// A fix is typed only if no other key arrived since the word ended; otherwise it is
/// dropped. A key pressed while the fix is being typed can still land in the middle of it.
public final class KeyboardBridge: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// Called on the engine queue after a fix was typed.
        public var didFix: @Sendable () -> Void = {}
        /// Called on the engine queue after a fix was undone.
        public var didUndo: @Sendable () -> Void = {}
        /// Called on the engine queue when learning notices a word, with the spell checker's
        /// answer. Only while learning is capturing.
        public var didLearn: @Sendable (LearningEvent, SpellVerdict) -> Void = { _, _ in }
        /// Called on the engine queue when the suggestion bar should change. Nil hides it.
        public var didChangeSuggestions: @Sendable (SuggestionBar?) -> Void = { _ in }
        /// Test hook: runs right before a plan is typed.
        public var beforePerform: @Sendable () -> Void = {}
        public init() {}
    }

    fileprivate let queue = DispatchQueue(label: "keymend.engine", qos: .userInteractive)
    private let output: KeyOutput
    fileprivate let checker: SpellChecking
    private let lock = NSLock()

    // Guarded by `lock`.
    private var latestSequence: UInt64 = 0
    private var _enabled = true
    private var _appSkipped = false
    private var _appCareful = false
    private var _neverCorrect = NeverCorrectList()
    private var _learningCaptures = false
    private var _learnedRules = LearnedRules()
    private var _suggestionsAllowed = false
    private var _pickFilter = PickKeyFilter()
    private var _barGeneration: UInt64?
    private var _barFrame: CGRect?

    // Only touched on `queue`.
    private var engine = WordEngine()
    fileprivate var watcher = LearningWatcher()
    private var shownBar: SuggestionBar?
    private var nextBarGeneration: UInt64 = 0
    /// The word the user just picked as typed, so the bar doesn't come straight back for it.
    private var keptWord: String?

    public var hooks: Hooks
    /// Returns true while macOS Secure Input is on (a password field has focus).
    public var secureInputCheck: @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    /// The clock learning uses. For tests.
    public var now: @Sendable () -> Date = { Date() }
    /// True while a modifier key is physically down. A pick waits for it, so a held Option can't
    /// change what the typed keys do.
    public var modifiersHeld: @Sendable () -> Bool = {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskAlternate, .maskControl, .maskShift, .maskCommand]).isEmpty
    }

    public init(output: KeyOutput, checker: SpellChecking, hooks: Hooks = Hooks()) {
        self.output = output
        self.checker = checker
        self.hooks = hooks
    }

    // MARK: Settings (any thread)

    public var isEnabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue }; reset() }
    }

    /// True while the frontmost app is on the skip list.
    public var isAppSkipped: Bool {
        get { lock.withLock { _appSkipped } }
        set { lock.withLock { _appSkipped = newValue }; reset() }
    }

    /// True while the frontmost app uses the Careful rules (terminals).
    public var isAppCareful: Bool {
        get { lock.withLock { _appCareful } }
        set { lock.withLock { _appCareful = newValue }; reset() }
    }

    public var neverCorrect: NeverCorrectList {
        get { lock.withLock { _neverCorrect } }
        set { lock.withLock { _neverCorrect = newValue } }
    }

    /// True while learning may notice words: it's on, not paused, and this app isn't excluded.
    /// Careful apps never learn, whatever this says.
    public var learningCaptures: Bool {
        get { lock.withLock { _learningCaptures } }
        set {
            lock.withLock { _learningCaptures = newValue }
            if !newValue { queue.async { self.watcher.reset() } }
        }
    }

    /// What was learned. Not used in Careful apps.
    public var learnedRules: LearnedRules {
        get { lock.withLock { _learnedRules } }
        set { lock.withLock { _learnedRules = newValue } }
    }

    /// True when the bar may show here: the setting is on and the app uses the normal rules.
    public var suggestionsAllowed: Bool {
        get { lock.withLock { _suggestionsAllowed } }
        set {
            lock.withLock { _suggestionsAllowed = newValue }
            queue.async { self.refreshSuggestions(sequence: nil) }
        }
    }

    public var pickKeys: PickKeys {
        get { lock.withLock { _pickFilter.keys } }
        set { lock.withLock { _pickFilter.keys = newValue } }
    }

    /// Where the bar is on screen (top-left origin), so a click on it doesn't count as a click
    /// elsewhere. Nil when it's hidden.
    public var barFrame: CGRect? {
        get { lock.withLock { _barFrame } }
        set { lock.withLock { _barFrame = newValue } }
    }

    /// Forget the current word (app switch, wake from sleep, layout change).
    public func reset() {
        lock.withLock { latestSequence &+= 1 }
        queue.async {
            self.engine.reset()
            self.watcher.reset()
            self.refreshSuggestions(sequence: nil)
        }
    }

    // MARK: Events

    /// Feeds one event from the tap. Returns immediately.
    public func receive(_ raw: RawKeyEvent) {
        // A pick key the active tap already took isn't typing.
        if raw.kind == .keyDown, lock.withLock({ _pickFilter.heldKey == raw.keyCode }) { return }
        guard let classified = KeyEventClassifier.classify(raw) else { return }
        let (active, careful) = lock.withLock { (_enabled && !_appSkipped, _appCareful) }
        // In Careful mode only the user's own typing counts, not keys another program posts.
        let input = careful && raw.isFromAnotherProgram ? KeyInput.reset : classified
        if !active || secureInputCheck() {
            // Paused, skipped app or password field: hold nothing at all.
            if input != .reset { reset() }
            return
        }
        let seq: UInt64 = lock.withLock { latestSequence &+= 1; return latestSequence }
        queue.async { self.process(input, sequence: seq, careful: careful) }
    }

    /// Feeds a Core Graphics event (what the tap callback calls).
    public func receive(_ event: CGEvent, type: CGEventType) {
        let raw = RawKeyEvent(event, type: type)
        // Clicking the bar picks from it; it isn't a click elsewhere.
        if raw.kind == .mouseDown, barFrame?.contains(event.location) == true { return }
        receive(raw)
    }

    // MARK: Suggestions

    /// Asked by the active tap about every key while it runs. Returns at once.
    public func pickDecision(for raw: RawKeyEvent) -> PickKeyFilter.Decision {
        let (decision, generation) = lock.withLock { (_pickFilter.decide(raw), _barGeneration) }
        if case .pick(let slot) = decision, let generation {
            pick(slot: slot, generation: generation)
        }
        return decision
    }

    /// True while a swallowed pick key is still physically down.
    public var isHoldingPickKey: Bool {
        lock.withLock { _pickFilter.heldKey != nil }
    }

    /// The active tap stopped, so nothing more can be swallowed.
    public func pickTapDidStop() {
        lock.withLock { _pickFilter.releaseHeldKey() }
    }

    /// The user chose from the bar, by key or by click. Slot 0 is the word as typed. Ignored if
    /// the bar has changed since, so a pick can't land on a different word.
    public func pick(slot: Int, generation: UInt64) {
        let sequence: UInt64 = lock.withLock { latestSequence &+= 1; return latestSequence }
        queue.async { self.performPick(slot: slot, generation: generation, sequence: sequence) }
    }

    private func performPick(slot: Int, generation: UInt64, sequence: UInt64) {
        guard let bar = shownBar, bar.generation == generation, slot < bar.choiceCount,
              engine.suggestionWord == bar.typed else { return }
        publish(nil)
        guard slot > 0 else {
            engine.keepAsTyped(bar.typed)
            keptWord = bar.typed
            return
        }
        // Wait briefly for Option to come up. A key pressed meanwhile cancels the pick.
        for _ in 0..<40 where modifiersHeld() { usleep(10_000) }
        let current = lock.withLock { latestSequence == sequence && _enabled && !_appSkipped && !_appCareful }
        guard current, !secureInputCheck() else { return }
        output.perform(KeyPlan(backspaces: bar.typed.count, text: bar.completions[slot - 1] + " "))
        engine.didTypeCompletion()
        watcher.didFix()
    }

    /// Runs on the engine queue after anything that can change the current word. `sequence` nil
    /// means hide if needed whatever else is going on.
    private func refreshSuggestions(sequence: UInt64?) {
        let (allowed, isLatest) = lock.withLock {
            (_suggestionsAllowed && _enabled && !_appSkipped && !_appCareful, sequence.map { $0 == latestSequence } ?? true)
        }
        guard allowed, let word = engine.suggestionWord else {
            keptWord = nil
            publish(nil)
            return
        }
        if word != keptWord { keptWord = nil }
        if keptWord != nil { publish(nil); return }
        // More keys are on the way: don't spend time on a word that's about to change.
        guard word != shownBar?.typed, isLatest else { return }
        let output = self.output
        let completions = SuggestionRules.clean(checker.completions(for: word), typed: word) { output.canType($0) }
        nextBarGeneration &+= 1
        publish(SuggestionBar(generation: nextBarGeneration, typed: word, completions: completions))
    }

    private func publish(_ bar: SuggestionBar?) {
        guard bar != shownBar else { return }
        shownBar = bar
        lock.withLock {
            _pickFilter.choiceCount = bar?.choiceCount ?? 0
            _barGeneration = bar?.generation
        }
        hooks.didChangeSuggestions(bar)
    }

    /// Waits until every queued event has been handled. For tests.
    public func drain() {
        queue.sync {}
    }

    private func process(_ input: KeyInput, sequence: UInt64, careful: Bool) {
        defer { refreshSuggestions(sequence: sequence) }
        let checker = self.checker
        let never = neverCorrect
        let (capturing, learned) = lock.withLock { (_learningCaptures && !careful, careful ? LearnedRules() : _learnedRules) }
        engine.isCareful = careful
        let action = engine.handle(input, verdict: { word in
            if never.contains(word) || checker.hasLearnedWord(word) { return .correct }
            return learned.applied(to: word) { checker.verdict(for: word) }
        })
        if capturing {
            watch(input, action: action, never: never)
        } else {
            watcher.reset()
        }
        guard let plan = action.plan else { return }
        // Careful mode won't risk a wrong letter: every character must have a real key.
        if careful, !output.canType(plan.text) { return }
        // Another key arrived while we were checking: the screen has moved on.
        guard lock.withLock({ latestSequence == sequence }) else { return }
        hooks.beforePerform()
        guard lock.withLock({ latestSequence == sequence && _enabled && !_appSkipped }) else { return }
        output.perform(plan)
        switch action {
        case .correct(let c):
            engine.didApply(c)
            if capturing { watcher.didFix() }
            hooks.didFix()
        case .undo:
            hooks.didUndo()
        case .none:
            break
        }
    }
}

extension KeyboardBridge {
    /// Runs on the engine queue. Asks the spell checker about a word once, here, so only words
    /// that could be kept ever leave this queue.
    private func watch(_ input: KeyInput, action: EngineAction, never: NeverCorrectList) {
        let events: [LearningEvent]
        if case .undo(let fix) = action {
            events = watcher.didUndo(fix)
        } else {
            events = watcher.handle(input, now: now())
        }
        deliver(events, never: never)
        guard watcher.isHoldingFinishedWord else { return }
        // Let go of the finished word when its window ends, even if the user stops typing.
        queue.asyncAfter(deadline: .now() + LearningWatcher.window + 0.1) { [weak self] in
            guard let self else { return }
            self.deliver(self.watcher.expire(now: self.now()), never: self.neverCorrect)
        }
    }

    private func deliver(_ events: [LearningEvent], never: NeverCorrectList) {
        for event in events {
            let word: String
            switch event {
            case .corrected(let typed, _), .undone(let typed, _): word = typed
            case .keptWord(let kept): word = kept
            }
            if never.contains(word) { continue }
            let verdict = checker.verdict(for: word)
            switch event {
            case .keptWord: if verdict != .unknown { continue }
            default: if verdict == .correct { continue }
            }
            hooks.didLearn(event, verdict)
        }
    }
}

/// A listen-only Core Graphics event tap on its own thread: this one can't stop a key. Needs
/// Input Monitoring (`CGRequestListenEventAccess`), which works inside the App Sandbox. The only
/// tap that can stop a key is `CGPickTapBackend`, and only while the suggestion bar is showing.
public final class KeyEventTap: @unchecked Sendable {
    private let bridge: KeyboardBridge
    private var tap: CFMachPort?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    public init(bridge: KeyboardBridge) {
        self.bridge = bridge
    }

    public static var hasPermission: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    public var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Starts the tap. Returns false if macOS refused (usually: no Input Monitoring yet).
    @discardableResult
    public func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: keymendTapCallback, userInfo: refcon
        ) else { return false }
        tap = port
        nonisolated(unsafe) let tapPort = port
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            let port = tapPort
            guard let self, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { ready.signal(); return }
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "keymend.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        bridge.reset()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns slow taps off; turn it back on and forget the current word.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            bridge.reset()
        default:
            bridge.receive(event, type: type)
        }
    }
}

private func keymendTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    // Listen-only: the event always continues unchanged.
    return Unmanaged.passUnretained(event)
}
