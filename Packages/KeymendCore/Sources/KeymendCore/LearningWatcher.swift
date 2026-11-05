import Foundation

/// Something the learning feature noticed. Single words only, and only ever in memory until the
/// store decides what to keep.
public enum LearningEvent: Equatable, Sendable {
    /// The user went back and changed `typed` to `corrected` within a few seconds.
    case corrected(typed: String, corrected: String)
    /// The user pressed Delete right after Keymend changed `typed` to `replacement`.
    case undone(typed: String, replacement: String)
    /// The user finished `word` and moved on without going back to it.
    case keptWord(String)
}

/// Which words learning may look at. Same idea as Careful Mode's code rules: plain words only,
/// so commands, paths, code, emails and handles are never recorded.
public enum LearningRules {
    public static func isLearnable(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= SkipRules.maxWordLength else { return false }
        return CarefulRules.plainWord(word) == word
    }

    /// True when `a` and `b` are at most `limit` single-letter edits apart. Swapping two
    /// neighbouring letters counts as one, and capitals are ignored.
    public static func isCloseSpelling(_ a: String, _ b: String, limit: Int = 2) -> Bool {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard abs(x.count - y.count) <= limit else { return false }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) <= limit }
        var table = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { table[i][0] = i }
        for j in 0...y.count { table[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[x.count][y.count] <= limit
    }
}

/// Follows typing to notice corrections and words kept as typed.
///
/// Privacy: holds the current word and, for at most `window` seconds, the last finished word.
/// Both are in memory only and are wiped on every reset. It never holds a second finished word.
public struct LearningWatcher: Sendable {
    /// How long after a word Keymend still counts going back to it as a correction.
    public static let window: TimeInterval = 5

    private struct Finished: Sendable {
        /// As typed, with any punctuation, which is what's on screen.
        var raw: String
        var word: String
        var at: Date
    }

    private var current = ""
    /// The word as it was when the user first pressed Delete in it.
    private var beforeEdit: String?
    private var editStarted: Date?
    private var finished: Finished?
    /// Keymend can't tell what's on screen until the next word starts.
    private var lost = true
    /// A quote or backtick came earlier on this line, so the rest of it isn't learned from.
    private var lineIsQuoted = false

    public init() {}

    /// Feeds one keystroke and returns anything it completed.
    public mutating func handle(_ input: KeyInput, now: Date) -> [LearningEvent] {
        switch input {
        case .text(let s):
            var events: [LearningEvent] = []
            for ch in s { events += handle(character: ch, now: now) }
            return events
        case .backspace:
            handleBackspace(now: now)
            return []
        case .newline:
            let events = endWord(now: now, keepFinished: false)
            lineIsQuoted = false
            lost = false
            return events
        case .tab:
            let events = commitFinished()
            reset()
            return events
        case .reset:
            reset()
            return []
        }
    }

    /// Lets go of the last finished word once the window has passed. Keymend calls this on a
    /// timer, so the word isn't held longer than that when the user stops typing.
    public mutating func expire(now: Date) -> [LearningEvent] {
        guard let done = finished, now.timeIntervalSince(done.at) >= LearningWatcher.window else { return [] }
        return commitFinished()
    }

    /// True while a finished word is being held.
    public var isHoldingFinishedWord: Bool { finished != nil }

    /// Keymend just changed this word, so it's not one the user kept or went back to.
    public mutating func didFix() {
        finished = nil
        current = ""
        beforeEdit = nil
        editStarted = nil
        lost = false
    }

    /// Keymend just put the user's word back. Returns the undo.
    public mutating func didUndo(_ fix: Correction) -> [LearningEvent] {
        reset()
        guard LearningRules.isLearnable(fix.original), LearningRules.isLearnable(fix.replacement) else { return [] }
        return [.undone(typed: fix.original, replacement: fix.replacement)]
    }

    /// Wipes everything held in memory.
    public mutating func reset() {
        current = ""
        beforeEdit = nil
        editStarted = nil
        finished = nil
        lost = true
        lineIsQuoted = false
    }

    private mutating func handle(character ch: Character, now: Date) -> [LearningEvent] {
        if ch.isWhitespace {
            return endWord(now: now, keepFinished: true)
        }
        if ch == "`" || CarefulRules.doubleQuotes.contains(ch) { lineIsQuoted = true }
        // A single quote at the start of a word opens a quote; inside a word it's an apostrophe.
        if current.isEmpty, CarefulRules.singleQuotes.contains(ch) { lineIsQuoted = true }
        current.append(ch)
        if current.count > SkipRules.maxWordLength + 8 {
            current = ""
            beforeEdit = nil
            finished = nil
            lost = true
        }
        return []
    }

    private mutating func handleBackspace(now: Date) {
        if !current.isEmpty {
            if beforeEdit == nil {
                beforeEdit = current
                editStarted = now
            }
            current.removeLast()
            return
        }
        // Deleting back into the word just finished.
        if let done = finished, now.timeIntervalSince(done.at) <= LearningWatcher.window, !lost {
            current = done.raw
            finished = nil
            return
        }
        finished = nil
        lost = true
    }

    private mutating func endWord(now: Date, keepFinished: Bool) -> [LearningEvent] {
        var events = commitFinished()
        defer {
            current = ""
            beforeEdit = nil
            editStarted = nil
        }
        let raw = current
        // Lost track at the start of this word: its beginning may not be what's on screen.
        let wasLost = lost
        lost = false
        guard !raw.isEmpty, !wasLost else { return events }
        guard !lineIsQuoted, let word = CarefulRules.plainWord(raw), LearningRules.isLearnable(word) else {
            return events
        }
        if let before = beforeEdit, let started = editStarted {
            let typed = CarefulRules.plainWord(before) ?? before
            if typed != word, now.timeIntervalSince(started) <= LearningWatcher.window,
               LearningRules.isLearnable(typed), LearningRules.isCloseSpelling(typed, word) {
                events.append(.corrected(typed: typed, corrected: word))
            }
            // A word the user edited isn't a word they kept as typed.
            return events
        }
        if keepFinished {
            finished = Finished(raw: raw, word: word, at: now)
        } else {
            events.append(.keptWord(word))
        }
        return events
    }

    private mutating func commitFinished() -> [LearningEvent] {
        guard let done = finished else { return [] }
        finished = nil
        return [.keptWord(done.word)]
    }
}
