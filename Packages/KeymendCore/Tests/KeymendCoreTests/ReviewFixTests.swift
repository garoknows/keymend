import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

/// Tests for the fixes from the November 2026 independent review. Each one failed before its fix.

/// Answers slowly for the words in `slow`, so a time limit runs out on them.
private struct SlowChecker: SpellChecking {
    var slow: Set<String>
    var delay: TimeInterval = 0.3
    var fixes: [String: String] = ["teh": "the"]
    func verdict(for word: String) -> SpellVerdict {
        if slow.contains(word) { Thread.sleep(forTimeInterval: delay) }
        return fixes[word].map(SpellVerdict.fix) ?? .correct
    }
    func hasLearnedWord(_ word: String) -> Bool {
        if slow.contains("hasLearnedWord") { Thread.sleep(forTimeInterval: delay) }
        return false
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LearningEvent] = []
    func add(_ e: LearningEvent) { lock.withLock { _events.append(e) } }
    var events: [LearningEvent] { lock.withLock { _events } }
}

/// A switch tests can flip from inside a hook.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

@Suite("Review 2026-11, finding 4: spell-check timeouts", .serialized)
struct SpellTimeoutTests {
    @Test func runningOutOfTimeIsItsOwnVerdict() {
        let limited = TimeLimitedSpellChecker(SlowChecker(slow: ["salary"]), limit: .milliseconds(50))
        #expect(limited.verdict(for: "salary") == .timedOut)
    }

    @Test func aBusyCheckerAnswersAtOnceInsteadOfQueueing() {
        let limited = TimeLimitedSpellChecker(SlowChecker(slow: ["salary"]), limit: .milliseconds(50))
        #expect(limited.verdict(for: "salary") == .timedOut)
        // The first check is still running. The next one must not wait behind it.
        let start = Date()
        #expect(limited.verdict(for: "hello") == .timedOut)
        #expect(Date().timeIntervalSince(start) < 0.03)
        // Once the slow check has finished, checks work normally again.
        Thread.sleep(forTimeInterval: 0.35)
        #expect(limited.verdict(for: "hello") == .correct)
    }

    @Test func hasLearnedWordHasTheSameLimit() {
        let limited = TimeLimitedSpellChecker(SlowChecker(slow: ["hasLearnedWord"]), limit: .milliseconds(50))
        let start = Date()
        #expect(limited.hasLearnedWord("salary") == false)
        #expect(Date().timeIntervalSince(start) < 0.2)
    }

    @Test func theStoreNeverKeepsATimedOutWord() {
        var store = LearningStore()
        for day in ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-05", "2026-01-06"] {
            store.record(.keptWord("salary"), day: day) { _ in .timedOut }
            store.record(.corrected(typed: "salry", corrected: "salary"), day: day) { _ in .timedOut }
            store.record(.undone(typed: "salry", replacement: "salary"), day: day) { _ in .timedOut }
        }
        #expect(store.items.isEmpty)
    }

    @Test func aTimedOutWordIsNotLearnedOrFixed() {
        let checker = TimeLimitedSpellChecker(SlowChecker(slow: ["salary", "teh"]), limit: .milliseconds(50))
        let h = Harness(checker: checker)
        let log = EventLog()
        h.bridge.hooks.didLearn = { event, _ in log.add(event) }
        h.bridge.learningCaptures = true
        h.bridge.drain()
        h.type("\nsalary here\n")
        Thread.sleep(forTimeInterval: 0.35)
        h.type("teh ")
        Thread.sleep(forTimeInterval: 0.35)
        h.type("\n")
        #expect(!log.events.contains(.keptWord("salary")))
        // A fix that timed out is never typed.
        #expect(h.field.text == "\nsalary here\nteh \n")
        #expect(h.fixes.value == 0)
    }

    @Test func oneSlowCheckDoesNotBlockTheEngineQueue() {
        let checker = TimeLimitedSpellChecker(SlowChecker(slow: ["salary", "hasLearnedWord"], delay: 0.5), limit: .milliseconds(50))
        let h = Harness(checker: checker)
        h.bridge.learningCaptures = true
        h.bridge.drain()
        let start = Date()
        h.type("\nsalary one two three four five six seven eight nine ten\n")
        // Every check after the first slow one answers at once: no 50 ms wait each.
        #expect(Date().timeIntervalSince(start) < 0.4)
    }
}

@Suite("Review 2026-11, finding 5: Secure Input right before typing", .serialized)
struct SecureInputBeforeTypingTests {
    @Test func aPasswordFieldThatTakesFocusMidCheckGetsNothing() {
        let h = Harness()
        let secure = Flag()
        h.bridge.secureInputCheck = { secure.value }
        h.bridge.hooks.beforePerform = { secure.value = true }
        h.type("teh ")
        #expect(h.field.text == "teh ")
        #expect(h.field.postedEventCount == 0)
        #expect(h.fixes.value == 0)
    }

    @Test func anUndoIsNotTypedIntoAPasswordField() {
        let h = Harness()
        let secure = Flag()
        h.bridge.secureInputCheck = { secure.value }
        h.type("teh ")
        #expect(h.field.text == "the ")
        let posted = h.field.postedEventCount
        h.bridge.hooks.beforePerform = { secure.value = true }
        h.backspace()
        #expect(h.field.postedEventCount == posted)
        #expect(h.undos.value == 0)
    }
}

@Suite("Review 2026-11, finding 9: dropped undo or fix", .serialized)
struct DroppedUndoTests {
    /// "tehx" has a fix of its own, so a stale engine would act on text that isn't on screen.
    private struct Checker: SpellChecking {
        func verdict(for word: String) -> SpellVerdict {
            switch word {
            case "teh": return .fix("the")
            case "tehx": return .fix("text")
            default: return .correct
            }
        }
        func hasLearnedWord(_ word: String) -> Bool { false }
    }

    @Test func aDroppedUndoLeavesTheEngineInStepWithTheScreen() {
        let h = Harness(checker: Checker())
        h.type("teh ")
        #expect(h.field.text == "the ")
        // The user presses Delete to undo, but another key lands before the undo is typed.
        let armed = Flag()
        armed.value = true
        let field = h.field, bridge = h.bridge
        h.bridge.hooks.beforePerform = {
            guard armed.value else { return }
            armed.value = false
            let e = keyEvent("x")
            field.apply(e)
            var raw = RawKeyEvent(e, type: .keyDown)
            raw.isFromAnotherProgram = false
            bridge.receive(raw)
        }
        h.backspace()
        #expect(h.field.text == "thex")
        #expect(h.undos.value == 0)
        h.type(" ")
        // The engine must not think "tehx" is on screen and "fix" it.
        #expect(h.field.text == "thex ")
    }

    @Test func aDroppedFixMarksTheWordUnknown() {
        let h = Harness(checker: Checker())
        let armed = Flag()
        armed.value = true
        let field = h.field, bridge = h.bridge
        h.bridge.hooks.beforePerform = {
            guard armed.value else { return }
            armed.value = false
            let e = keyEvent("x")
            field.apply(e)
            var raw = RawKeyEvent(e, type: .keyDown)
            raw.isFromAnotherProgram = false
            bridge.receive(raw)
        }
        h.type("teh ", settle: false)
        #expect(h.field.text == "teh x")
        #expect(h.fixes.value == 0)
        // Nothing is computed from the half-known word, and the next clean word is fixed again.
        h.type(" teh ")
        #expect(h.field.text == "teh x the ")
    }
}
