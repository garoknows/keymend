import CoreGraphics
import Foundation

/// Where Keymend's keystrokes go. The app posts real events; tests record them.
public protocol KeyOutput: Sendable {
    func perform(_ plan: KeyPlan)
}

/// Builds the exact Core Graphics events for a plan: one Delete press per character to
/// remove, then one Unicode text event per character to type. Every event is tagged so
/// Keymend's own tap ignores it.
public enum KeyEventFactory {
    public static func events(for plan: KeyPlan, source: CGEventSource?) -> [CGEvent] {
        var out: [CGEvent] = []
        for _ in 0..<max(0, plan.backspaces) {
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(KeyCode.delete), keyDown: down) {
                    e.flags = []
                    e.setIntegerValueField(.eventSourceUserData, value: KeyEventClassifier.ownEventTag)
                    out.append(e)
                }
            }
        }
        for ch in plan.text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) {
                    e.flags = []
                    units.withUnsafeBufferPointer { p in
                        e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: p.baseAddress)
                    }
                    e.setIntegerValueField(.eventSourceUserData, value: KeyEventClassifier.ownEventTag)
                    out.append(e)
                }
            }
        }
        return out
    }
}

/// Posts keystrokes to the system with `CGEvent.post`. Needs the "post events"
/// permission (`CGRequestPostEventAccess`), which works inside the App Sandbox.
public final class SystemKeyOutput: KeyOutput, @unchecked Sendable {
    private let source = CGEventSource(stateID: .privateState)
    private let gap: useconds_t

    /// `gapMicroseconds` pauses between events. Default 0: posting the fix as fast as possible
    /// keeps the window small in which a fast typist's next key could land in the middle of it.
    /// That window is not zero, and its real length has not been measured.
    public init(gapMicroseconds: useconds_t = 0) {
        gap = gapMicroseconds
        source?.userData = KeyEventClassifier.ownEventTag
    }

    public static var hasPermission: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    public func perform(_ plan: KeyPlan) {
        for e in KeyEventFactory.events(for: plan, source: source) {
            e.post(tap: .cghidEventTap)
            if gap > 0 { usleep(gap) }
        }
    }
}
