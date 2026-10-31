/// The keystrokes needed to change what is on screen: press Delete `backspaces`
/// times, then type `text`.
public struct KeyPlan: Equatable, Sendable {
    public var backspaces: Int
    public var text: String

    public init(backspaces: Int, text: String) {
        self.backspaces = backspaces
        self.text = text
    }
}

/// A correction the engine wants to make for a word that just ended.
public struct Correction: Equatable, Sendable {
    /// The word as typed, without surrounding punctuation ("teh").
    public var original: String
    /// The replacement word ("the").
    public var replacement: String
    /// Characters typed after the word that are deleted and retyped (", " or " ").
    public var suffix: String
    /// Keystrokes that turn "original + suffix" into "replacement + suffix".
    public var plan: KeyPlan

    public init(original: String, replacement: String, suffix: String) {
        self.original = original
        self.replacement = replacement
        self.suffix = suffix
        self.plan = KeyPlan(backspaces: original.count + suffix.count, text: replacement + suffix)
    }

    /// Keystrokes that restore the original word after the user pressed Delete once
    /// right after the fix (that Delete already removed the last character).
    public var undoPlan: KeyPlan {
        let onScreen = replacement + suffix
        let restored = String((original + suffix).dropLast())
        return KeyPlan(backspaces: max(0, onScreen.count - 1), text: restored)
    }
}
