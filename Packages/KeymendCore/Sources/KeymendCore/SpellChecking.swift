import AppKit
import Foundation

/// Something that can suggest a confident correction for a single word.
public protocol SpellChecking: Sendable {
    /// Whether `word` is spelled correctly and, if not, whether there's a confident correction.
    func verdict(for word: String) -> SpellVerdict
    /// True when the word is in the Mac's own "Learn Spelling" list.
    func hasLearnedWord(_ word: String) -> Bool
}

extension SpellChecking {
    /// A confident correction for `word`, or nil to leave it alone.
    public func correction(for word: String) -> String? {
        if case .fix(let s) = verdict(for: word) { return s }
        return nil
    }
}

/// Apple's on-device spell checker, the same engine as Mac autocorrect. Offline.
public final class AppleSpellChecker: SpellChecking, @unchecked Sendable {
    private let tag: Int
    private let lock = NSLock()

    public init() {
        tag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    deinit {
        NSSpellChecker.shared.closeSpellDocument(withTag: tag)
    }

    public func verdict(for word: String) -> SpellVerdict {
        lock.lock(); defer { lock.unlock() }
        let checker = NSSpellChecker.shared
        let ns = word as NSString
        let range = NSRange(location: 0, length: ns.length)
        let language = checker.language()
        // Only words the checker flags as misspelled are candidates.
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                         inSpellDocumentWithTag: tag, wordCount: nil)
        guard miss.location != NSNotFound else { return .correct }
        // `correction(forWordRange:)` returns Apple's autocorrection, only when it is confident.
        let fix = checker.correction(forWordRange: range, in: word, language: language, inSpellDocumentWithTag: tag)
        return fix.map(SpellVerdict.fix) ?? .unknown
    }

    public func hasLearnedWord(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return NSSpellChecker.shared.hasLearnedWord(word)
    }

    /// Adds a word to the Mac's shared "Learn Spelling" list.
    public func learnWord(_ word: String) {
        lock.lock(); defer { lock.unlock() }
        NSSpellChecker.shared.learnWord(word)
    }

    /// Removes a word from the Mac's shared "Learn Spelling" list.
    public func unlearnWord(_ word: String) {
        lock.lock(); defer { lock.unlock() }
        NSSpellChecker.shared.unlearnWord(word)
    }
}

/// Wraps another checker and gives up when it takes longer than `limit`, so typing is never slowed.
public final class TimeLimitedSpellChecker: SpellChecking, @unchecked Sendable {
    private let base: SpellChecking
    private let limit: DispatchTimeInterval
    private let queue = DispatchQueue(label: "keymend.spellcheck", qos: .userInitiated)

    public init(_ base: SpellChecking, limit: DispatchTimeInterval = .milliseconds(50)) {
        self.base = base
        self.limit = limit
    }

    /// Running out of time counts as `.unknown`: nothing gets fixed.
    public func verdict(for word: String) -> SpellVerdict {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let base = self.base
        queue.async {
            box.set(base.verdict(for: word))
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success else { return .unknown }
        return box.get() ?? .unknown
    }

    public func hasLearnedWord(_ word: String) -> Bool {
        base.hasLearnedWord(word)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: SpellVerdict?
        func set(_ v: SpellVerdict) { lock.lock(); value = v; lock.unlock() }
        func get() -> SpellVerdict? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
