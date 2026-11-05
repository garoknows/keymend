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

    // Only touched on `queue`.
    private var engine = WordEngine()
    fileprivate var watcher = LearningWatcher()

    public var hooks: Hooks
    /// Returns true while macOS Secure Input is on (a password field has focus).
    public var secureInputCheck: @Sendable () -> Bool = { IsSecureEventInputEnabled() }
    /// The clock learning uses. For tests.
    public var now: @Sendable () -> Date = { Date() }

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

    /// Forget the current word (app switch, wake from sleep, layout change).
    public func reset() {
        lock.withLock { latestSequence &+= 1 }
        queue.async {
            self.engine.reset()
            self.watcher.reset()
        }
    }

    // MARK: Events

    /// Feeds one event from the tap. Returns immediately.
    public func receive(_ raw: RawKeyEvent) {
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
        receive(RawKeyEvent(event, type: type))
    }

    /// Waits until every queued event has been handled. For tests.
    public func drain() {
        queue.sync {}
    }

    private func process(_ input: KeyInput, sequence: UInt64, careful: Bool) {
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

/// A listen-only Core Graphics event tap on its own thread. Needs Input Monitoring
/// (`CGRequestListenEventAccess`), which works inside the App Sandbox.
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
