import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Connects keystrokes to the word engine and types the fixes.
///
/// Thread model: `receive(_:)` is called on the event-tap thread and returns at once.
/// The engine runs on its own serial queue, so the tap never waits for the spell checker.
/// A fix is typed only if no other key arrived since the word ended; otherwise it is
/// dropped, so a fast typist never loses or doubles characters.
public final class KeyboardBridge: @unchecked Sendable {
    public struct Hooks: Sendable {
        /// Called on the engine queue after a fix was typed.
        public var didFix: @Sendable () -> Void = {}
        /// Called on the engine queue after a fix was undone.
        public var didUndo: @Sendable () -> Void = {}
        /// Test hook: runs right before a plan is typed.
        public var beforePerform: @Sendable () -> Void = {}
        public init() {}
    }

    private let queue = DispatchQueue(label: "keymend.engine", qos: .userInteractive)
    private let output: KeyOutput
    private let checker: SpellChecking
    private let lock = NSLock()

    // Guarded by `lock`.
    private var latestSequence: UInt64 = 0
    private var _enabled = true
    private var _appSkipped = false
    private var _neverCorrect = NeverCorrectList()

    // Only touched on `queue`.
    private var engine = WordEngine()

    public var hooks: Hooks
    /// Returns true while macOS Secure Input is on (a password field has focus).
    public var secureInputCheck: @Sendable () -> Bool = { IsSecureEventInputEnabled() }

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

    public var neverCorrect: NeverCorrectList {
        get { lock.withLock { _neverCorrect } }
        set { lock.withLock { _neverCorrect = newValue } }
    }

    /// Forget the current word (app switch, wake from sleep, layout change).
    public func reset() {
        lock.withLock { latestSequence &+= 1 }
        queue.async { self.engine.reset() }
    }

    // MARK: Events

    /// Feeds one event from the tap. Returns immediately.
    public func receive(_ raw: RawKeyEvent) {
        guard let input = KeyEventClassifier.classify(raw) else { return }
        let active = lock.withLock { _enabled && !_appSkipped }
        if !active || secureInputCheck() {
            // Paused, skipped app or password field: hold nothing at all.
            if input != .reset { reset() }
            return
        }
        let seq: UInt64 = lock.withLock { latestSequence &+= 1; return latestSequence }
        queue.async { self.process(input, sequence: seq) }
    }

    /// Feeds a Core Graphics event (what the tap callback calls).
    public func receive(_ event: CGEvent, type: CGEventType) {
        receive(RawKeyEvent(event, type: type))
    }

    /// Waits until every queued event has been handled. For tests.
    public func drain() {
        queue.sync {}
    }

    private func process(_ input: KeyInput, sequence: UInt64) {
        let checker = self.checker
        let never = neverCorrect
        let action = engine.handle(input) { word in
            if never.contains(word) || checker.hasLearnedWord(word) { return nil }
            return checker.correction(for: word)
        }
        guard let plan = action.plan else { return }
        // Another key arrived while we were checking: the screen has moved on.
        guard lock.withLock({ latestSequence == sequence }) else { return }
        hooks.beforePerform()
        guard lock.withLock({ latestSequence == sequence && _enabled && !_appSkipped }) else { return }
        output.perform(plan)
        switch action {
        case .correct(let c):
            engine.didApply(c)
            hooks.didFix()
        case .undo:
            hooks.didUndo()
        case .none:
            break
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
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
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
