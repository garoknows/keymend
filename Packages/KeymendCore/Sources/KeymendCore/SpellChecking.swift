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
///
/// Only one check runs at a time. A check that runs out of time keeps running in the background,
/// and while it does every new question is answered at once with "no answer" instead of waiting
/// behind it. So one slow call costs at most `limit`, never a queue of them.
public final class TimeLimitedSpellChecker: SpellChecking, @unchecked Sendable {
    private let base: SpellChecking
    private let limit: DispatchTimeInterval
    private let queue = DispatchQueue(label: "keymend.spellcheck", qos: .userInitiated)
    private let lock = NSLock()
    /// True while a call to `base` is running. Guarded by `lock`.
    private var busy = false

    public init(_ base: SpellChecking, limit: DispatchTimeInterval = .milliseconds(50)) {
        self.base = base
        self.limit = limit
    }

    /// Running out of time, or the checker still being busy with an earlier word, is `.timedOut`:
    /// nothing gets fixed and nothing is learned.
    public func verdict(for word: String) -> SpellVerdict {
        let base = self.base
        return run(fallback: .timedOut) { base.verdict(for: word) }
    }

    /// Running out of time counts as "not learned", so the word goes on to `verdict(for:)`,
    /// which then answers `.timedOut` at once while the checker is busy.
    public func hasLearnedWord(_ word: String) -> Bool {
        let base = self.base
        return run(fallback: false) { base.hasLearnedWord(word) }
    }

    private func run<T: Sendable>(fallback: T, _ body: @escaping @Sendable () -> T) -> T {
        let claimed: Bool = lock.withLock {
            if busy { return false }
            busy = true
            return true
        }
        guard claimed else { return fallback }
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            box.set(body())
            lock.withLock { busy = false }
            done.signal()
        }
        guard done.wait(timeout: .now() + limit) == .success else { return fallback }
        return box.get() ?? fallback
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
