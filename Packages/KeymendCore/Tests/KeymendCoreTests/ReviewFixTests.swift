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

    /// Generous on purpose: a busy CI machine can wake a thread late (it measured 0.2001 s against
    /// the old 0.2 s bound). Ignoring the limit would take the full 3 seconds.
    @Test func hasLearnedWordHasTheSameLimit() {
        let limited = TimeLimitedSpellChecker(SlowChecker(slow: ["hasLearnedWord"], delay: 3), limit: .milliseconds(50))
        let start = Date()
        #expect(limited.hasLearnedWord("salary") == false)
        #expect(Date().timeIntervalSince(start) < 1.5)
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

/// Says whatever the test sets: an input method (Japanese, Chinese, Korean…) or a plain layout.
private final class FakeInputSource: InputSourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _isInputMethod = false
    var isInputMethod: Bool {
        get { lock.withLock { _isInputMethod } }
        set { lock.withLock { _isInputMethod = newValue } }
    }
    func currentIsInputMethod() -> Bool { isInputMethod }
}

@Suite("Review 2026-11, finding 6: input methods pause Keymend", .serialized)
struct InputMethodPauseTests {
    @Test func inputSourceTypesAreRecognised() {
        #expect(SystemInputSource.isInputMethod(type: "TISTypeKeyboardInputMode"))
        #expect(SystemInputSource.isInputMethod(type: "TISTypeKeyboardInputMethodWithoutModes"))
        #expect(!SystemInputSource.isInputMethod(type: "TISTypeKeyboardLayout"))
    }

    @Test func anInputMethodPausesFixesAndLearningAndResumesAfter() {
        let h = Harness()
        let source = FakeInputSource()
        let pause = InputMethodPause(source: source, bridge: h.bridge)
        let log = EventLog()
        h.bridge.hooks.didLearn = { event, _ in log.add(event) }
        h.bridge.learningCaptures = true

        source.isInputMethod = true
        #expect(pause.refresh() == true)
        #expect(h.bridge.isInputMethodActive)
        // Romaji: Space converts, so it must never end a "word" that gets fixed.
        h.type("teh nihongo zzqqxx desu\n")
        #expect(h.field.text == "teh nihongo zzqqxx desu\n")
        #expect(h.field.postedEventCount == 0)
        #expect(log.events.isEmpty)

        source.isInputMethod = false
        #expect(pause.refresh() == false)
        // As after any pause, the first word is skipped (the caret position was unknown).
        h.type("x teh ")
        #expect(h.field.text.hasSuffix("\nx the "))
    }

    @Test func switchingToAnInputMethodClearsTheWordBeingTyped() {
        let h = Harness()
        let source = FakeInputSource()
        let pause = InputMethodPause(source: source, bridge: h.bridge)
        h.type("te")
        source.isInputMethod = true
        pause.refresh()
        source.isInputMethod = false
        pause.refresh()
        h.type("h ")
        // "teh" was split across the switch: Keymend can't know what's on screen, so it's left.
        #expect(h.field.text == "teh ")
    }
}

/// Behaves like the old KeyEventTap: start() does nothing while a (dead) tap still exists.
private final class FakeTap: KeyEventTapping, @unchecked Sendable {
    var exists = false
    var running = false
    var starts = 0
    var isRunning: Bool { running }
    @discardableResult func start() -> Bool {
        starts += 1
        if exists { return true }
        exists = true
        running = true
        return true
    }
    func stop() { exists = false; running = false }
}

@Suite("Review 2026-11, finding 7: a dead keyboard hook comes back")
struct DeadTapTests {
    @Test func aStoppedTapIsRecreated() {
        let tap = FakeTap()
        #expect(TapSupervisor.ensureRunning(tap, permitted: true))
        // macOS drops the tap (Input Monitoring turned off and on, for example).
        tap.running = false
        #expect(TapSupervisor.ensureRunning(tap, permitted: true))
        #expect(tap.isRunning)
    }

    @Test func withoutPermissionItReportsTheRealState() {
        let tap = FakeTap()
        #expect(TapSupervisor.ensureRunning(tap, permitted: false) == false)
        #expect(tap.starts == 0)
    }

    @Test func aRunningTapIsLeftAlone() {
        let tap = FakeTap()
        TapSupervisor.ensureRunning(tap, permitted: true)
        TapSupervisor.ensureRunning(tap, permitted: true)
        #expect(tap.starts == 1)
    }
}

@Suite("Review 2026-11, finding 8: importing a word file")
struct ImportTests {
    @Test func anImportedCorrectionWaitsForApproval() {
        var store = LearningStore()
        let skipped = store.merge(LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", count: 9, daysSeen: 3, lastSeen: "2026-01-01", status: .active),
        ]))
        #expect(skipped == 0)
        #expect(store.items.first?.status == .proposed)
        #expect(store.rules == LearnedRules())
    }

    @Test func aCorrectionAlreadyApprovedHereStaysApproved() {
        var store = LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", lastSeen: "2026-01-01", status: .active),
        ])
        store.merge(LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", count: 4, daysSeen: 2, lastSeen: "2026-02-01", status: .active),
        ]))
        #expect(store.items.first?.status == .active)
        #expect(store.items.first?.count == 4)
    }

    @Test func anImportedProposalNeverOverridesAnExistingWatchingItemToActive() {
        var store = LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", lastSeen: "2026-01-01"),
        ])
        store.merge(LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", lastSeen: "2026-01-01", status: .active),
        ]))
        #expect(store.items.first?.status == .proposed)
    }

    @Test(arguments: [
        LearnedItem(kind: .correction, typed: "the", correction: "rm -rf", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .correction, typed: "the", correction: "the\nend", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .correction, typed: "the", correction: "THE", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .correction, typed: "a b", correction: "ab", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .correction, typed: "teh", correction: "", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .correction, typed: "teh", correction: "https://example.com", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .undo, typed: "teh", correction: "something", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .known, typed: "two words", lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .known, typed: String(repeating: "a", count: 65), lastSeen: "2026-01-01", status: .active),
        LearnedItem(kind: .known, typed: "fine", count: 0, lastSeen: "2026-01-01"),
        LearnedItem(kind: .known, typed: "fine", count: 2, daysSeen: 3, lastSeen: "2026-01-01"),
        LearnedItem(kind: .known, typed: "fine", lastSeen: "yesterday"),
        LearnedItem(kind: .known, typed: "fine", lastSeen: "2026-13-45"),
    ])
    func anItemLiveLearningCouldNeverMakeIsRejected(_ item: LearnedItem) {
        var store = LearningStore()
        #expect(store.merge(LearningStore(items: [item])) == 1)
        #expect(store.items.isEmpty)
    }

    @Test func handAddedWordsAndNormalItemsStillImport() {
        var store = LearningStore()
        let skipped = store.merge(LearningStore(items: [
            LearnedItem(kind: .known, typed: "me@example.com", lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .known, typed: "Zorblat", count: 5, daysSeen: 3, lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .undo, typed: "teh", correction: "the", count: 2, lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .correction, typed: "recieve", correction: "receive", lastSeen: "2026-01-01", status: .rejected),
        ]))
        #expect(skipped == 0)
        #expect(store.items.count == 4)
        // Things that only make Keymend do less apply at once, as with live learning.
        #expect(store.items.filter { $0.status == .active }.count == 3)
    }

    @Test(arguments: [UInt32(1_000), 99_999, 2_000_001, 10_000_000])
    func aFileAskingForAStrangeAmountOfWorkIsRefused(_ rounds: UInt32) throws {
        // A hand-made file header: refused before any key work starts, so this test is instant.
        var data = Data("KEYMEND-LEARNING-1".utf8)
        withUnsafeBytes(of: rounds.bigEndian) { data.append(contentsOf: $0) }
        data.append(Data(repeating: 7, count: 16 + 64))
        let start = Date()
        #expect(throws: LearningVaultError.notAnExport) { try LearningVault.store(fromExport: data, passphrase: "p") }
        #expect(Date().timeIntervalSince(start) < 0.05)
    }

    @Test func theDefaultAmountOfWorkIsAccepted() {
        #expect(LearningVault.allowedRounds.contains(LearningVault.rounds))
    }
}

/// The Mac's shared "Learn Spelling" list, in memory.
private final class FakeSpellingList: SystemSpellingList, @unchecked Sendable {
    var learned: Set<String>
    var calls: [String] = []
    init(_ learned: Set<String> = []) { self.learned = learned }
    func hasLearnedWord(_ word: String) -> Bool { learned.contains(word) }
    func learnWord(_ word: String) { calls.append("learn \(word)"); learned.insert(word) }
    func unlearnWord(_ word: String) { calls.append("unlearn \(word)"); learned.remove(word) }
}

@Suite("Review 2026-11, finding 10: only unlearn what Keymend taught")
struct TaughtSpellingTests {
    @Test func aWordTheUserLearnedBeforeKeymendStaysLearned() {
        let mac = FakeSpellingList(["Zorblatt"])
        var taught = TaughtSpellings()
        taught.add("Zorblatt", to: mac)
        taught.remove("Zorblatt", from: mac)
        #expect(mac.learned.contains("Zorblatt"))
        #expect(mac.calls.isEmpty)
    }

    @Test func aWordKeymendTaughtIsUnlearnedWhenRemoved() {
        let mac = FakeSpellingList()
        var taught = TaughtSpellings()
        taught.add("  Zorblat ", to: mac)
        #expect(mac.learned == ["Zorblat"])
        // The never-correct list ignores case, so removal does too.
        taught.remove("zorblat", from: mac)
        #expect(mac.learned.isEmpty)
        #expect(taught.words.isEmpty)
    }

    @Test func theRecordSurvivesARestart() {
        let mac = FakeSpellingList()
        var taught = TaughtSpellings()
        taught.add("Zorblat", to: mac)
        var reloaded = TaughtSpellings(words: taught.words)
        reloaded.remove("Zorblat", from: mac)
        #expect(mac.learned.isEmpty)
    }
}
