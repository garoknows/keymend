/// One keystroke, already classified, as the engine sees it.
public enum KeyInput: Equatable, Sendable {
    /// Printable text produced by a key (usually one character).
    case text(String)
    /// The Delete (backspace) key.
    case backspace
    /// Return or Enter. Ends the word without fixing it: in chat apps Return sends the
    /// message, so retyping afterwards would land in an empty box.
    case newline
    /// Tab. Ends the word without fixing it (it often moves focus to another field).
    case tab
    /// Anything that moves the caret or changes text in ways the engine cannot follow:
    /// arrow keys, Command shortcuts, mouse clicks, app switches.
    case reset
}

/// What the engine wants done after a keystroke.
public enum EngineAction: Equatable, Sendable {
    case none
    /// Replace the word that just ended.
    case correct(Correction)
    /// Put back the word the user typed before the last fix.
    case undo(Correction)

    public var plan: KeyPlan? {
        switch self {
        case .none: return nil
        case .correct(let c): return c.plan
        case .undo(let c): return c.undoPlan
        }
    }
}

/// Tracks the word being typed and decides when and how to fix it.
///
/// Privacy: the engine holds only the current word (at most `SkipRules.maxWordLength`
/// characters plus surrounding punctuation). It is cleared when the word ends, on
/// every reset, and it is never written anywhere.
public struct WordEngine: Sendable {
    /// Punctuation that ends a word and triggers a check right away.
    public static let immediateTriggers: Set<Character> = [",", ";", "!", "?"]
    /// Whitespace that ends a word and triggers a check.
    public static let whitespaceTriggers: Set<Character> = [" ", "\u{00A0}"]

    private var buffer: String = ""
    /// True when the caret may be in the middle of an unknown word (after a click, an
    /// arrow key or deleting past the start of the word). Nothing is fixed until the
    /// next word starts cleanly.
    private(set) public var tainted: Bool = true
    /// Odd number of backticks typed on this line: we are inside `code`.
    private var insideBackticks = false
    /// The last fix, kept until the next keystroke so Delete can undo it.
    private var undoable: Correction?
    /// Words the user undid this session (lowercased). Never fixed again until quit.
    private(set) public var sessionIgnored: Set<String> = []
    /// True in apps that use the Careful rules (terminals). See `CarefulLine`.
    public var isCareful = false { didSet { if oldValue != isCareful { careful = CarefulLine() } } }
    private var careful = CarefulLine()

    public init() {}

    /// The current partial word. Exposed for tests only.
    public var currentWord: String { buffer }

    /// The word to suggest completions for, or nil when the bar shouldn't show. The same words
    /// Keymend would fix: no code, links, paths, numbers or ALL CAPS, and never in Careful apps.
    public var suggestionWord: String? {
        guard !isCareful, !tainted,
              SkipRules.skipReason(for: buffer, insideBackticks: insideBackticks) == nil else { return nil }
        let token = Token(parsing: buffer)
        guard token.trailing.isEmpty, token.core.count >= 2 else { return nil }
        return token.core
    }

    /// The user picked the word as typed: it won't be autocorrected for the rest of the session.
    public mutating func keepAsTyped(_ word: String) {
        sessionIgnored.insert(word.lowercased())
    }

    /// A completion and a space were typed in place of the current word.
    public mutating func didTypeCompletion() {
        clearWord(tainted: false)
    }

    /// Feeds one keystroke. `check` is asked for a correction only when a word ends.
    @discardableResult
    public mutating func handle(_ input: KeyInput, check: (String) -> String?) -> EngineAction {
        handle(input, verdict: { word in check(word).map(SpellVerdict.fix) ?? .correct })
    }

    /// Feeds one keystroke. `verdict` is asked about a word only when a word ends.
    @discardableResult
    public mutating func handle(_ input: KeyInput, verdict: (String) -> SpellVerdict) -> EngineAction {
        let pendingUndo = undoable
        undoable = nil

        switch input {
        case .backspace:
            if let fix = pendingUndo {
                sessionIgnored.insert(fix.original.lowercased())
                careful.stop()
                // After the undo the screen ends with the original word (minus the
                // character Delete removed), so keep tracking it as the current word.
                buffer = String((fix.original + fix.suffix).dropLast())
                tainted = false
                return .undo(fix)
            }
            if buffer.isEmpty {
                tainted = true
                careful.stop()
            } else {
                let removed = buffer.removeLast()
                if removed == "`" { insideBackticks.toggle() }
            }
            return .none

        case .newline:
            endLine(verdict: verdict)
            return .none

        case .tab, .reset:
            clearWord(tainted: true)
            insideBackticks = false
            careful.stop()
            return .none

        case .text(let s):
            var action = EngineAction.none
            for ch in s {
                action = handleCharacter(ch, verdict: verdict)
            }
            return action
        }
    }

    /// Marks a correction as typed on screen, so the next Delete can undo it.
    public mutating func didApply(_ correction: Correction) {
        undoable = correction
    }

    /// Clears everything except the session's undone words.
    public mutating func reset() {
        clearWord(tainted: true)
        insideBackticks = false
        undoable = nil
        careful = CarefulLine()
    }

    private mutating func endLine(verdict: (String) -> SpellVerdict) {
        if isCareful {
            let ignored = sessionIgnored
            careful.endLine(lastWord: buffer) { ignored.contains($0.lowercased()) ? .correct : verdict($0) }
        }
        clearWord(tainted: false)
        insideBackticks = false
    }

    private mutating func clearWord(tainted: Bool) {
        buffer = ""
        self.tainted = tainted
    }

    private mutating func handleCharacter(_ ch: Character, verdict: (String) -> SpellVerdict) -> EngineAction {
        if WordEngine.whitespaceTriggers.contains(ch) {
            let action = evaluate(word: buffer, delimiter: String(ch), verdict: verdict)
            clearWord(tainted: false)
            return action
        }
        if ch.isNewline {
            endLine(verdict: verdict)
            return .none
        }
        if WordEngine.immediateTriggers.contains(ch) {
            let token = Token(parsing: buffer)
            // Only trigger when the word so far has no trailing punctuation of its own
            // ("teh," yes; "ok?!" is handled when the space comes).
            if token.trailing.isEmpty, !buffer.isEmpty {
                let action = evaluate(word: buffer, delimiter: String(ch), verdict: verdict)
                clearWord(tainted: false)
                // Keep later punctuation from being treated as part of a new word.
                return action
            }
        }
        if ch == "`" { insideBackticks.toggle() }
        buffer.append(ch)
        if buffer.count > SkipRules.maxWordLength + 8 {
            // Far too long to be a word: stop holding it.
            clearWord(tainted: true)
            careful.stop()
        }
        return .none
    }

    private mutating func evaluate(word raw: String, delimiter: String, verdict: (String) -> SpellVerdict) -> EngineAction {
        if isCareful {
            // A word the user undid this session counts as correct.
            let ignored = sessionIgnored
            guard let suggestion = careful.consider(raw, verdict: { ignored.contains($0.lowercased()) ? .correct : verdict($0) }) else { return .none }
            let token = Token(parsing: raw)
            guard !tainted, let replacement = WordEngine.acceptable(suggestion, for: token.core) else { return .none }
            return .correct(Correction(original: token.core, replacement: replacement, suffix: token.trailing + delimiter))
        }
        if tainted || raw.isEmpty { return .none }
        // A backtick earlier on the line means this word may be code. The toggle already
        // ran for backticks inside `raw`, so look at the state before this word.
        let backticksInWord = raw.filter { $0 == "`" }.count
        let insideBefore = backticksInWord % 2 == 0 ? insideBackticks : !insideBackticks
        if SkipRules.skipReason(for: raw, insideBackticks: insideBefore) != nil { return .none }

        let token = Token(parsing: raw)
        let word = token.core
        if sessionIgnored.contains(word.lowercased()) { return .none }
        guard case .fix(let suggestion) = verdict(word) else { return .none }
        guard let replacement = WordEngine.acceptable(suggestion, for: word) else { return .none }
        return .correct(Correction(original: word, replacement: replacement, suffix: token.trailing + delimiter))
    }

    /// Applies the original word's capitalization and rejects unsafe suggestions.
    static func acceptable(_ suggestion: String, for word: String) -> String? {
        var s = suggestion
        if s.isEmpty || s == word { return nil }
        if s.contains(where: { $0.isNewline || $0 == "\t" }) { return nil }
        if s.count > word.count + 6 { return nil }
        if s.lowercased() == word.lowercased() && s.first?.isUppercase == true && word.first?.isLowercase == true {
            // Pure capitalization change of a lowercase word ("english" -> "English") is fine.
            return s
        }
        if let first = word.first, first.isUppercase, let sFirst = s.first, sFirst.isLowercase {
            s = sFirst.uppercased() + s.dropFirst()
        }
        return s == word ? nil : s
    }
}
