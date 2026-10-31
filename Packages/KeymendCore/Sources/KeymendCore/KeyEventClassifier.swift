import CoreGraphics

/// The parts of a keyboard or mouse event Keymend looks at.
public struct RawKeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case keyDown, keyUp, flagsChanged, mouseDown, other }

    public var kind: Kind
    public var keyCode: UInt16
    public var flags: CGEventFlags
    /// The text the key produced, as reported by the event (may be empty, e.g. a dead key).
    public var characters: String
    /// True for events Keymend posted itself.
    public var isOwnEvent: Bool

    public init(kind: Kind, keyCode: UInt16 = 0, flags: CGEventFlags = [], characters: String = "", isOwnEvent: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.characters = characters
        self.isOwnEvent = isOwnEvent
    }
}

extension CGEventFlags: @retroactive @unchecked Sendable {}

/// Virtual key codes used by the bridge (from the ANSI layout; these keys are layout independent).
public enum KeyCode {
    public static let delete: UInt16 = 51
    public static let forwardDelete: UInt16 = 117
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let tab: UInt16 = 48
    public static let escape: UInt16 = 53
    public static let space: UInt16 = 49
    public static let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
    /// F1 to F20, plus volume, brightness and other keys that never type text.
    public static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 114, 72, 73, 74]
}

public enum KeyEventClassifier {
    /// Tag stored in `eventSourceUserData` on every event Keymend posts, so the tap can ignore them.
    public static let ownEventTag: Int64 = 0x4B45_594D_454E_44 // "KEYMEND"

    /// Turns a raw event into engine input. Returns nil for events that change nothing
    /// (key-ups, modifier presses, Keymend's own keystrokes, function keys).
    public static func classify(_ e: RawKeyEvent) -> KeyInput? {
        if e.isOwnEvent { return nil }
        switch e.kind {
        case .mouseDown:
            return .reset
        case .keyUp, .flagsChanged, .other:
            return nil
        case .keyDown:
            break
        }
        // Command or Control shortcuts can paste, undo, move or select text.
        if e.flags.contains(.maskCommand) || e.flags.contains(.maskControl) { return .reset }

        switch e.keyCode {
        case KeyCode.delete:
            // Option-Delete removes a whole word; we can't follow that precisely.
            return e.flags.contains(.maskAlternate) ? .reset : .backspace
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return .newline
        case KeyCode.tab:
            return .tab
        case KeyCode.escape, KeyCode.forwardDelete:
            return .reset
        default:
            break
        }
        if KeyCode.navigation.contains(e.keyCode) { return .reset }
        if KeyCode.functionKeys.contains(e.keyCode) { return nil }

        // Dead keys (Option-E, then E) report no text; the composed character can't be
        // known from here, so stop tracking this word.
        guard !e.characters.isEmpty else { return .reset }
        if e.characters.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .reset }
        return .text(e.characters)
    }
}

extension RawKeyEvent {
    /// Reads the fields Keymend needs from a Core Graphics event.
    public init(_ event: CGEvent, type: CGEventType) {
        let kind: Kind
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        default: kind = .other
        }
        var chars = ""
        if kind == .keyDown {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            chars = String(utf16CodeUnits: buffer, count: min(length, buffer.count))
            // Wipe the local copy; typed text is never kept beyond this call.
            for i in buffer.indices { buffer[i] = 0 }
        }
        self.init(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags,
            characters: chars,
            isOwnEvent: event.getIntegerValueField(.eventSourceUserData) == KeyEventClassifier.ownEventTag
        )
    }
}
