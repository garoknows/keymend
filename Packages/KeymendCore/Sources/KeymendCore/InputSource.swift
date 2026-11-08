@preconcurrency import Carbon.HIToolbox

/// Tells whether the selected input source is an input method (Japanese, Chinese, Korean,
/// Vietnamese and similar) rather than a plain keyboard layout.
public protocol InputSourceReading: Sendable {
    func currentIsInputMethod() -> Bool
}

/// Reads the selected input source from macOS. Call on the main thread.
public struct SystemInputSource: InputSourceReading {
    public init() {}

    public func currentIsInputMethod() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return Self.isInputMethod(type: type)
    }

    /// Input methods compose text before it reaches the app (Space can mean "convert"), so the
    /// keys Keymend sees aren't the text on screen.
    public static func isInputMethod(type: String) -> Bool {
        type == kTISTypeKeyboardInputMode as String || type == kTISTypeKeyboardInputMethodWithoutModes as String
    }
}

/// Pauses the keyboard bridge while an input method is selected, like a skipped app: no fixes,
/// no learning, and the current word is forgotten. It resumes when a plain layout is back.
public final class InputMethodPause: @unchecked Sendable {
    private let source: InputSourceReading
    private let bridge: KeyboardBridge

    public init(source: InputSourceReading = SystemInputSource(), bridge: KeyboardBridge) {
        self.source = source
        self.bridge = bridge
    }

    /// Reads the input source and pauses or resumes. Returns true while paused.
    @discardableResult
    public func refresh() -> Bool {
        let paused = source.currentIsInputMethod()
        bridge.isInputMethodActive = paused
        return paused
    }
}
