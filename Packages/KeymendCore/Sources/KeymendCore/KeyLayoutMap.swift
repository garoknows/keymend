@preconcurrency import Carbon.HIToolbox

/// The physical key, and whether Shift is held, that types a character.
public struct KeyStroke: Equatable, Sendable {
    public var code: UInt16
    public var shift: Bool

    public init(code: UInt16, shift: Bool = false) {
        self.code = code
        self.shift = shift
    }
}

/// Which physical key types which character on a keyboard layout.
///
/// Some terminal programs ask for the physical key rather than the text it produced. A posted
/// letter therefore has to say which key it is, or those programs read it as the wrong letter.
public struct KeyLayoutMap: Equatable, Sendable {
    private let strokes: [Character: KeyStroke]

    public init(strokes: [Character: KeyStroke]) {
        self.strokes = strokes
    }

    public func stroke(for ch: Character) -> KeyStroke? {
        strokes[ch]
    }

    /// True when every character of `text` can be typed with one key press on this layout.
    public func canType(_ text: String) -> Bool {
        text.allSatisfy { strokes[$0] != nil }
    }

    /// Reads the current keyboard layout. Returns nil when it has no Unicode key data (some
    /// input methods). macOS requires this call on the main thread.
    @MainActor
    public static func current() -> KeyLayoutMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var map: [Character: KeyStroke] = [:]
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            // No Shift first, so a character reachable both ways uses the plain key. Lower codes
            // are the main keyboard; the keypad comes later and never wins.
            for shift in [false, true] {
                let modifiers = UInt32(shift ? (shiftKey >> 8) & 0xFF : 0)
                for code in UInt16(0)..<UInt16(127) {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                                0, &deadKeys, chars.count, &length, &chars)
                    // A dead key produces no character by itself, so it can't type this one.
                    guard status == noErr, deadKeys == 0, length > 0 else { continue }
                    guard !chars.prefix(length).contains(where: { $0 < 0x20 || $0 == 0x7F }) else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    if text.count == 1, let ch = text.first, map[ch] == nil {
                        map[ch] = KeyStroke(code: code, shift: shift)
                    }
                }
            }
        }
        return map.isEmpty ? nil : KeyLayoutMap(strokes: map)
    }
}
