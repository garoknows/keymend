import CoreGraphics
import Foundation

/// Starts and stops the real event tap. Tests use a stand-in.
public protocol PickTapBackend: AnyObject, Sendable {
    /// Returns false if macOS refused the tap.
    func start() -> Bool
    func stop()
}

/// Decides when the active tap may exist. It runs only while the bar is showing, and it stops
/// the moment either permission might be going away.
///
/// Why this matters: one developer reports that turning off Accessibility while an active tap is
/// running can freeze all keyboard and mouse input until a forced restart. Apple hasn't given a
/// fix. Three things keep Keymend out of that state: a click anywhere (needed to reach the switch
/// in System Settings) hides the bar and stops the tap, the system's "Accessibility changed"
/// notice stops it at once, and permissions are re-checked every 0.25 s while it runs. A freeze
/// that happens in the same instant as the switch can't be ruled out.
public final class PickTapController: @unchecked Sendable {
    public static let pollInterval: TimeInterval = 0.25
    /// How long the tap may outlive the bar while waiting for a held pick key to be released.
    public static let lingerLimit: TimeInterval = 1
    /// After a permission change, no restart for this long, so a change still taking effect
    /// can't catch a new tap.
    public static let restartBlock: TimeInterval = 1

    private let backend: PickTapBackend
    private let hasPermission: @Sendable () -> Bool
    private let keyHeld: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let pollInterval: TimeInterval
    private let lingerLimit: TimeInterval
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "keymend.pickkeys.watchdog", qos: .userInitiated)

    // Guarded by `lock`.
    private var running = false
    private var barShowing = false
    private var blockedUntil = Date.distantPast
    private var startFailed = false
    private var timer: DispatchSourceTimer?

    /// Called right after the tap stops.
    public var onStopped: @Sendable () -> Void = {}

    public init(
        backend: PickTapBackend,
        hasPermission: @escaping @Sendable () -> Bool,
        keyHeld: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: TimeInterval = PickTapController.pollInterval,
        lingerLimit: TimeInterval = PickTapController.lingerLimit
    ) {
        self.backend = backend
        self.hasPermission = hasPermission
        self.keyHeld = keyHeld
        self.now = now
        self.pollInterval = pollInterval
        self.lingerLimit = lingerLimit
    }

    public var isRunning: Bool { lock.withLock { running } }
    /// True when macOS refused the tap. The bar still works by clicking.
    public var lastStartFailed: Bool { lock.withLock { startFailed } }

    /// The bar is showing. Starts the tap if it's safe to.
    public func barDidShow() {
        lock.lock()
        barShowing = true
        if running { lock.unlock(); return }
        lock.unlock()
        let allowed = hasPermission()
        lock.withLock {
            guard barShowing, !running, allowed, now() >= blockedUntil else { return }
            running = backend.start()
            startFailed = !running
            if running { startWatchdog() }
        }
    }

    /// The bar is gone. Stops the tap, unless a pick key is still down: then it waits for the
    /// release, so the app doesn't get a stray key, but never longer than `lingerLimit`.
    public func barDidHide() {
        let stopped: Bool = lock.withLock {
            barShowing = false
            guard running else { return false }
            if keyHeld() {
                queue.asyncAfter(deadline: .now() + lingerLimit) { [weak self] in self?.pickKeyReleased() }
                return false
            }
            return stopLocked()
        }
        if stopped { onStopped() }
    }

    /// The pick key came back up, or the wait for it ran out.
    public func pickKeyReleased() {
        let stopped: Bool = lock.withLock { barShowing ? false : stopLocked() }
        if stopped { onStopped() }
    }

    /// Something says a permission may have changed, or macOS turned the tap off. Stops right away.
    public func stopForSafety() {
        let stopped: Bool = lock.withLock {
            blockedUntil = now().addingTimeInterval(PickTapController.restartBlock)
            return stopLocked()
        }
        if stopped { onStopped() }
    }

    private func stopLocked() -> Bool {
        guard running else { return false }
        running = false
        timer?.cancel()
        timer = nil
        backend.stop()
        return true
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in
            guard let self, !self.hasPermission() else { return }
            self.stopForSafety()
        }
        timer = t
        t.resume()
    }
}

/// The active event tap: the one place Keymend can stop a key reaching an app. Its callback only
/// asks the bridge about the key and returns, on its own thread, so it can't hold typing up.
public final class CGPickTapBackend: PickTapBackend, @unchecked Sendable {
    private let bridge: KeyboardBridge
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    /// Called on the tap's thread after a swallowed pick key is released.
    public var onKeyReleased: @Sendable () -> Void = {}
    /// Called on the tap's thread if macOS turns the tap off.
    public var onDisabled: @Sendable () -> Void = {}

    public init(bridge: KeyboardBridge) {
        self.bridge = bridge
    }

    public static var hasPermissions: Bool { CGPreflightListenEventAccess() && CGPreflightPostEventAccess() }

    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: pickKeyTapCallback, userInfo: refcon
        ) else { return false }
        tap = port
        nonisolated(unsafe) let tapPort = port
        nonisolated(unsafe) var loop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            guard let source = CFMachPortCreateRunLoopSource(nil, tapPort, 0) else { ready.signal(); return }
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tapPort, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "keymend.pickkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop
        return true
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
    }

    /// Returns true to let the event through.
    fileprivate func shouldPass(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            onDisabled()
            return true
        case .keyDown, .keyUp:
            // Only the key's position and modifiers: this tap never reads what the key would type.
            let raw = RawKeyEvent(
                kind: type == .keyDown ? .keyDown : .keyUp,
                keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags,
                isOwnEvent: event.getIntegerValueField(.eventSourceUserData) == KeyEventClassifier.ownEventTag
            )
            switch bridge.pickDecision(for: raw) {
            case .pass:
                return true
            case .swallow:
                if type == .keyUp { onKeyReleased() }
                return false
            case .pick:
                return false
            }
        default:
            return true
        }
    }
}

private func pickKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let backend = Unmanaged<CGPickTapBackend>.fromOpaque(refcon).takeUnretainedValue()
    return backend.shouldPass(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}
