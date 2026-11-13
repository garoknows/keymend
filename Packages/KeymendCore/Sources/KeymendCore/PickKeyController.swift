import CoreGraphics
import Foundation

/// Starts and stops whatever takes the pick keys: the hot keys in `HotKeyPickBackend`. Tests use
/// a stand-in.
public protocol PickTapBackend: AnyObject, Sendable {
    /// Returns false if macOS refused the keys.
    func start() -> Bool
    func stop()
}

/// Decides when the pick keys are taken: only while the bar is showing, plus up to
/// `lingerLimit` to swallow the release of a key that's still held when the bar goes.
///
/// History: in beta.2 the pick keys came from an active event tap, and this controller was the
/// safeguard against a known macOS problem: switching off Accessibility while an active tap runs
/// can freeze all keyboard and mouse input. On a real Mac the safeguard lost that race and input
/// froze until a forced restart. The pick keys are now hot keys, which need no permission and
/// can't freeze input, so the permission checks here are only a second line of defence.
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
