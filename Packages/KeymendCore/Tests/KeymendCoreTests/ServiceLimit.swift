import Foundation
import Testing

/// Runs a call into a macOS system service (spell checker, keyboard layout), and stops the whole
/// test run with a clear message if it doesn't come back. A blocked call can't be cancelled and
/// may hold the main thread, so ending the run is the only way to fail fast. Exit code 3.
func withServiceLimit<T>(
    _ service: String,
    seconds: TimeInterval = 30,
    onTimeout: @escaping @Sendable () -> Void = {},
    _ body: () throws -> T
) rethrows -> T {
    let done = DispatchSemaphore(value: 0)
    let watcher = Thread {
        guard done.wait(timeout: .now() + seconds) == .timedOut else { return }
        onTimeout()
    }
    watcher.start()
    defer { done.signal() }
    return try body()
}

/// What a real service call does when it runs out of time.
func stopTestRun(_ service: String, after seconds: TimeInterval = 30) -> @Sendable () -> Void {
    {
        FileHandle.standardError.write(Data("SERVICE HANG: \(service) gave no answer in \(Int(seconds))s. Stopping the test run.\n".utf8))
        _exit(3)
    }
}

/// The same limit, for the real services the tests call.
func withRealService<T>(_ service: String, seconds: TimeInterval = 30, _ body: () throws -> T) rethrows -> T {
    try withServiceLimit(service, seconds: seconds, onTimeout: stopTestRun(service, after: seconds), body)
}

@Suite("Time limit on system services")
struct ServiceLimitTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        func set() { lock.withLock { isSet = true } }
        var value: Bool { lock.withLock { isSet } }
    }

    @Test func aCallThatDoesntComeBackIsCaughtQuickly() {
        let fired = Flag()
        let start = Date()
        withServiceLimit("slow service", seconds: 0.05, onTimeout: { fired.set() }) {
            let end = Date().addingTimeInterval(2)
            while !fired.value, Date() < end { Thread.sleep(forTimeInterval: 0.005) }
        }
        #expect(fired.value)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func aCallThatComesBackIsLeftAlone() {
        let fired = Flag()
        #expect(withServiceLimit("quick service", seconds: 0.05, onTimeout: { fired.set() }) { 42 } == 42)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!fired.value)
    }
}
