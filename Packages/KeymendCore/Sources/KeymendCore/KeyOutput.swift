import CoreGraphics
import Foundation

/// Where Keymend's keystrokes go. The app posts real events; tests record them.
public protocol KeyOutput: Sendable {
    func perform(_ plan: KeyPlan)
    /// True when `text` can be typed with real key presses on the current keyboard layout.
    func canType(_ text: String) -> Bool
}

extension KeyOutput {
    public func canType(_ text: String) -> Bool { true }
}

/// Builds the exact Core Graphics events for a plan: one Delete press per character to
/// remove, then one Unicode text event per character to type. Every event is tagged so
/// Keymend's own tap ignores it.
public enum KeyEventFactory {
    /// With a `layout`, each character is posted as its real key (and Shift for capitals), so
    /// programs that read the physical key get the right letter. A character the layout can't
    /// type by itself, or a nil `layout`, falls back to key code 0 with the text attached,
    /// which is fine everywhere except terminal programs that read the physical key.
    public static func events(for plan: KeyPlan, source: CGEventSource?, layout: KeyLayoutMap? = nil) -> [CGEvent] {
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
            let stroke = layout?.stroke(for: ch)
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(stroke?.code ?? 0), keyDown: down) {
                    e.flags = stroke?.shift == true ? .maskShift : []
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
    private let lock = NSLock()
    private var layout: KeyLayoutMap?

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

    /// Sets the keyboard layout to type with. Call at launch and when the layout changes.
    public func setLayout(_ layout: KeyLayoutMap?) {
        lock.withLock { self.layout = layout }
    }

    public func canType(_ text: String) -> Bool {
        lock.withLock { layout?.canType(text) ?? false }
    }

    public func perform(_ plan: KeyPlan) {
        let layout = lock.withLock { self.layout }
        for e in KeyEventFactory.events(for: plan, source: source, layout: layout) {
            e.post(tap: .cghidEventTap)
            if gap > 0 { usleep(gap) }
        }
    }
}
