import CryptoKit
import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

/// All words and sentences in this file are made up.

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A throwaway file. `run-tests-direct.sh` sets the folder, for places where the system's is blocked.
private func testFileURL() -> URL {
    let folder = ProcessInfo.processInfo.environment["KEYMEND_TEST_DIR"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: folder).appendingPathComponent("keymend-test-\(UUID().uuidString)")
}

private struct Script {
    var watcher = LearningWatcher()
    var clock = start
    var events: [LearningEvent] = []

    init() { events += watcher.handle(.newline, now: clock) }

    mutating func type(_ s: String, secondsPerKey: TimeInterval = 0.1) {
        for ch in s {
            clock += secondsPerKey
            events += ch == "\n" ? watcher.handle(.newline, now: clock) : watcher.handle(.text(String(ch)), now: clock)
        }
    }

    mutating func delete(_ n: Int = 1) {
        for _ in 0..<n {
            clock += 0.1
            events += watcher.handle(.backspace, now: clock)
        }
    }

    mutating func wait(_ seconds: TimeInterval) { clock += seconds }
}

@Suite("Learning: noticing corrections")
struct LearningWatcherTests {
    @Test func correctionInsideTheWord() {
        var s = Script()
        s.type("zorp")
        s.delete(2)
        s.type("rp ")
        #expect(s.events.isEmpty)  // same word typed again

        var t = Script()
        t.type("recieve")
        t.delete(4)
        t.type("eive ")
        #expect(t.events == [.corrected(typed: "recieve", corrected: "receive")])
    }

    @Test func correctionJustAfterFinishingTheWord() {
        var s = Script()
        s.type("recieve ")
        s.delete(5)     // the space and "ieve"
        s.type("eive ")
        #expect(s.events == [.corrected(typed: "recieve", corrected: "receive")])
    }

    @Test func correctionWithPunctuationAfterTheWord() {
        var s = Script()
        s.type("recieve, ")
        s.delete(6)     // space, comma, "ieve"
        s.type("eive, ")
        #expect(s.events == [.corrected(typed: "recieve", corrected: "receive")])
    }

    @Test func tooLateIsNotACorrection() {
        var s = Script()
        s.type("recieve ")
        s.wait(6)
        s.delete(5)
        s.type("eive ")
        #expect(!s.events.contains { if case .corrected = $0 { return true } else { return false } })
    }

    @Test func aDifferentWordIsNotACorrection() {
        var s = Script()
        s.type("quick")
        s.delete(5)
        s.type("fast ")
        #expect(s.events.isEmpty)
    }

    @Test func aWordKeptAsTypedIsReportedWhenTheNextWordEnds() {
        var s = Script()
        s.type("zorblat ")
        #expect(s.events.isEmpty)
        #expect(s.watcher.isHoldingFinishedWord)
        s.type("next ")
        #expect(s.events == [.keptWord("zorblat")])
    }

    @Test func aFinishedWordIsLetGoWhenTheWindowEnds() {
        var s = Script()
        s.type("zorblat ")
        let early = s.watcher.expire(now: s.clock + 4)
        #expect(early == [])
        #expect(s.watcher.isHoldingFinishedWord)
        let late = s.watcher.expire(now: s.clock + 5)
        #expect(late == [.keptWord("zorblat")])
        #expect(!s.watcher.isHoldingFinishedWord)
    }

    @Test func aWordYouWentBackToIsNotKept() {
        var s = Script()
        s.type("zorblat ")
        s.delete(3)
        s.type("at next word ")
        #expect(!s.events.contains(.keptWord("zorblat")))
    }

    @Test(arguments: [
        "src/main ", "foo_bar ", "--force ", "-x ", "config.yaml ", "a=b ", "$HOME ", "~/notes ", "me@example.com ",
        "@handle ", "https://example.com ", "#tag ", "glob* ", "API ", "camelCase ", "v2 ", "`code` ", "well-known ",
        "note:thing ", "\"quoted ", "'quoted ",
    ])
    func codeShapedWordsAreNeverNoticed(_ text: String) {
        var s = Script()
        s.type(text)
        s.type("after words here ")
        #expect(s.events.allSatisfy { if case .keptWord(let w) = $0 { return ["after", "words"].contains(w) } else { return false } })
        #expect(s.events.count <= 2)
    }

    @Test func wordsInQuotesAreNeverNoticed() {
        var s = Script()
        s.type("she said \"zorblat recieve ")
        #expect(s.events == [.keptWord("she"), .keptWord("said")])
        #expect(!s.watcher.isHoldingFinishedWord)
    }

    @Test func aResetWipesEverything() {
        var s = Script()
        s.type("zorblat ")
        _ = s.watcher.handle(.reset, now: s.clock)
        #expect(!s.watcher.isHoldingFinishedWord)
        s.type("recieve")
        s.delete(4)
        s.type("eive ")
        #expect(s.events.isEmpty)  // the caret was unknown when that word started
    }

    @Test func undoIsReported() {
        var s = Script()
        s.type("teh ")
        let fix = Correction(original: "teh", replacement: "the", suffix: " ")
        s.watcher.didFix()
        let undone = s.watcher.didUndo(fix)
        #expect(undone == [.undone(typed: "teh", replacement: "the")])
    }

    @Test func aWordKeymendFixedIsNotKept() {
        var s = Script()
        s.type("teh ")
        s.watcher.didFix()
        s.type("next ")
        #expect(!s.events.contains(.keptWord("teh")))
    }

    @Test func closeSpelling() {
        #expect(LearningRules.isCloseSpelling("recieve", "receive"))
        #expect(LearningRules.isCloseSpelling("teh", "the"))
        #expect(LearningRules.isCloseSpelling("wrold", "world"))
        #expect(LearningRules.isCloseSpelling("Teh", "the"))
        #expect(!LearningRules.isCloseSpelling("quick", "fast"))
        #expect(!LearningRules.isCloseSpelling("cat", "elephant"))
    }
}

@Suite("Learning: what each signal does")
struct LearningStoreTests {
    private static func flagged(_: String) -> SpellVerdict { .unknown }

    @Test func correctionIsProposedAfterThreeTimesOnTwoDaysAndNeverActivatesAlone() throws {
        var store = LearningStore()
        let event = LearningEvent.corrected(typed: "recieve", corrected: "receive")
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        #expect(store.items[0].status == .watching)   // three times, but only one day
        store.record(event, day: "2026-01-02", verdict: Self.flagged)
        #expect(store.items[0].status == .proposed)
        #expect(store.proposedCount == 1)
        // Not active: the spell checker's answer still stands.
        #expect(store.rules.applied(to: "recieve") { .unknown } == .unknown)
        store.approve(store.items[0].id)
        #expect(store.rules.applied(to: "recieve") { .unknown } == .fix("receive"))
    }

    @Test func undoStopsThatFixAfterTwoTimes() {
        var store = LearningStore()
        let event = LearningEvent.undone(typed: "zorp", replacement: "zoro")
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        #expect(store.rules.applied(to: "zorp") { .fix("zoro") } == .fix("zoro"))
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        #expect(store.rules.applied(to: "zorp") { .fix("zoro") } == .correct)
        // A different fix for the same word isn't blocked.
        #expect(store.rules.applied(to: "zorp") { .fix("zarp") } == .fix("zarp"))
    }

    @Test func wordBecomesKnownAfterFiveTimesOnThreeDays() {
        var store = LearningStore()
        for day in ["2026-01-01", "2026-01-01", "2026-01-01", "2026-01-01", "2026-01-02"] {
            store.record(.keptWord("Zorblat"), day: day, verdict: Self.flagged)
        }
        #expect(store.items[0].status == .watching)
        store.record(.keptWord("Zorblat"), day: "2026-01-03", verdict: Self.flagged)
        #expect(store.items[0].status == .active)
        #expect(store.items[0].count == 6)
        #expect(store.items[0].daysSeen == 3)
        #expect(store.items[0].lastSeen == "2026-01-03")
        #expect(store.rules.applied(to: "zorblat") { .fix("zebra") } == .correct)
    }

    @Test func aCorrectlySpelledWordIsNeverKept() {
        var store = LearningStore()
        store.record(.corrected(typed: "quick", corrected: "quack"), day: "2026-01-01") { _ in .correct }
        store.record(.undone(typed: "quick", replacement: "quack"), day: "2026-01-01") { _ in .correct }
        store.record(.keptWord("quick"), day: "2026-01-01") { _ in .correct }
        store.record(.keptWord("teh"), day: "2026-01-01") { _ in .fix("the") }
        #expect(store.items.isEmpty)
    }

    @Test(arguments: ["me@example.com", "@handle", "foo.bar", "src/main", "API", "camelCase", "v2", "a b"])
    func codeShapesAndHandlesAreNeverCaptured(_ word: String) {
        var store = LearningStore()
        store.record(.keptWord(word), day: "2026-01-01", verdict: Self.flagged)
        store.record(.corrected(typed: word, corrected: "word"), day: "2026-01-01", verdict: Self.flagged)
        store.record(.undone(typed: word, replacement: "word"), day: "2026-01-01", verdict: Self.flagged)
        #expect(store.items.isEmpty)
    }

    @Test func emailsAndHandlesOnlyByHand() {
        var store = LearningStore()
        let email = store.addByHand("me@example.com", day: "2026-01-01")
        let handle = store.addByHand("@handle", day: "2026-01-01")
        let twoWords = store.addByHand("two words", day: "2026-01-01")
        #expect(email && handle && !twoWords)
        #expect(store.items.map(\.status) == [.active, .active])
    }

    @Test func rejectedStaysRejectedAndDeleteForgets() {
        var store = LearningStore()
        let event = LearningEvent.corrected(typed: "recieve", corrected: "receive")
        store.record(event, day: "2026-01-01", verdict: Self.flagged)
        let id = store.items[0].id
        store.reject(id)
        for day in 2...9 { store.record(event, day: "2026-01-0\(day)", verdict: Self.flagged) }
        #expect(store.items[0].status == .rejected)
        #expect(store.rules == LearnedRules())
        store.delete(id)
        #expect(store.items.isEmpty)
        store.record(event, day: "2026-02-01", verdict: Self.flagged)
        #expect(store.items[0].status == .watching)
    }

    @Test func editChangesTheCorrectionAndApproves() {
        var store = LearningStore()
        store.record(.corrected(typed: "recieve", corrected: "receve"), day: "2026-01-01", verdict: Self.flagged)
        let edited = store.edit(store.items[0].id, correction: "receive")
        #expect(edited)
        #expect(store.rules.applied(to: "recieve") { .unknown } == .fix("receive"))
        let refused = store.edit(store.items[0].id, correction: "not/a word")
        #expect(!refused)
    }

    @Test func searchAndRanking() {
        var store = LearningStore()
        store.record(.keptWord("Zorblat"), day: "2026-01-01", verdict: Self.flagged)
        store.record(.keptWord("Quixel"), day: "2026-01-01", verdict: Self.flagged)
        store.record(.keptWord("Quixel"), day: "2026-01-01", verdict: Self.flagged)
        #expect(store.ranked().map(\.typed) == ["Quixel", "Zorblat"])
        #expect(store.ranked(matching: "zor").map(\.typed) == ["Zorblat"])
    }

    @Test func unapprovedItemsAreForgottenAfterNinetyDays() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.date(from: DateComponents(year: 2026, month: 4, day: 11))!
        var store = LearningStore(items: [
            LearnedItem(kind: .known, typed: "oldwatching", lastSeen: "2026-01-01"),
            LearnedItem(kind: .correction, typed: "oldproposed", correction: "x", lastSeen: "2026-01-01", status: .proposed),
            LearnedItem(kind: .correction, typed: "oldapproved", correction: "x", lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .correction, typed: "oldrejected", correction: "x", lastSeen: "2026-01-01", status: .rejected),
            LearnedItem(kind: .known, typed: "recent", lastSeen: "2026-04-01"),
        ])
        store.forgetStale(today: today, calendar: cal)
        #expect(store.items.map(\.typed) == ["oldapproved", "oldrejected", "recent"])
    }

    @Test func importMergesHigherCountLaterDayAndRejectedWins() {
        var a = LearningStore(items: [
            LearnedItem(kind: .known, typed: "one", count: 5, daysSeen: 1, lastSeen: "2026-01-05"),
            LearnedItem(kind: .correction, typed: "two", correction: "x", lastSeen: "2026-01-01", status: .rejected),
        ])
        let b = LearningStore(items: [
            LearnedItem(kind: .known, typed: "one", count: 2, daysSeen: 4, lastSeen: "2026-01-09"),
            LearnedItem(kind: .correction, typed: "two", correction: "x", lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .known, typed: "three", lastSeen: "2026-01-01"),
        ])
        a.merge(b)
        #expect(a.items[0].count == 5 && a.items[0].daysSeen == 4 && a.items[0].lastSeen == "2026-01-09")
        #expect(a.items[1].status == .rejected)
        #expect(a.items.count == 3)
    }

    /// The store can hold only the allowed fields. Adding a field makes this fail on purpose.
    @Test func storedFieldsAreExactlyTheAllowedOnes() throws {
        let item = LearnedItem(kind: .correction, typed: "recieve", correction: "receive", lastSeen: "2026-01-01")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["kind", "typed", "correction", "count", "daysSeen", "lastSeen", "status"])
        #expect(item.lastSeen.count == 10)
    }
}

final class MemoryKey: LearningKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    var failure: LearningVaultError?
    init(_ key: SymmetricKey? = nil) { self.key = key }
    func loadKey() throws -> SymmetricKey? {
        try lock.withLock {
            if let failure { throw failure }
            return key
        }
    }
    func saveKey(_ key: SymmetricKey) throws { lock.withLock { self.key = key } }
    func deleteKey() throws { lock.withLock { key = nil } }
}

@Suite("Learning: encrypted storage")
struct LearningVaultTests {
    private static func tempURL() -> URL {
        testFileURL()
    }

    private static let sample = LearningStore(items: [
        LearnedItem(kind: .known, typed: "Zorblatmarker", count: 3, lastSeen: "2026-01-01"),
        LearnedItem(kind: .correction, typed: "recievemarker", correction: "receivemarker", lastSeen: "2026-01-01", status: .active),
    ])

    @Test func roundTripAndTheFileHoldsNoPlainWords() throws {
        let url = Self.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let vault = LearningVault(fileURL: url, keys: MemoryKey())
        try vault.save(Self.sample)
        let bytes = try Data(contentsOf: url)
        for plain in ["Zorblatmarker", "recievemarker", "receivemarker", "typed", "count", "2026"] {
            #expect(bytes.range(of: Data(plain.utf8)) == nil, "\(plain) is readable in the file")
        }
        #expect(try vault.load() == Self.sample)
    }

    @Test func noFileMeansAnEmptyStoreWithoutTouchingTheKeychain() throws {
        let keys = MemoryKey()
        keys.failure = .keychain(-1)
        let vault = LearningVault(fileURL: Self.tempURL(), keys: keys)
        #expect(try vault.load() == LearningStore())
    }

    @Test(arguments: [true, false])
    func aFileThatCannotBeOpenedIsAnErrorAndStaysUntouched(_ wrongKey: Bool) throws {
        let url = Self.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try LearningVault(fileURL: url, keys: MemoryKey()).save(Self.sample)
        let before = try Data(contentsOf: url)
        let keys = MemoryKey(wrongKey ? SymmetricKey(size: .bits256) : nil)
        #expect(throws: LearningVaultError.cannotDecrypt) { try LearningVault(fileURL: url, keys: keys).load() }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aCorruptFileIsAnError() throws {
        let url = Self.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryKey()
        let vault = LearningVault(fileURL: url, keys: keys)
        try vault.save(Self.sample)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: url)
        #expect(throws: LearningVaultError.cannotDecrypt) { try vault.load() }
    }

    @Test func aKeychainFailureStopsSavingInsteadOfMakingANewKey() throws {
        let url = Self.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryKey()
        let vault = LearningVault(fileURL: url, keys: keys)
        try vault.save(Self.sample)
        let before = try Data(contentsOf: url)
        keys.failure = .keychain(-25308)
        #expect(throws: LearningVaultError.keychain(-25308)) { try vault.save(LearningStore()) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func destroyRemovesFileAndKey() throws {
        let url = Self.tempURL()
        let keys = MemoryKey()
        let vault = LearningVault(fileURL: url, keys: keys)
        try vault.save(Self.sample)
        try vault.destroy()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try keys.loadKey() == nil)
    }

    @Test func exportNeedsThePassphraseAndHoldsNoPlainWords() throws {
        let data = try LearningVault.exportData(Self.sample, passphrase: "made up passphrase", rounds: 1000)
        #expect(data.range(of: Data("Zorblatmarker".utf8)) == nil)
        #expect(try LearningVault.store(fromExport: data, passphrase: "made up passphrase") == Self.sample)
        #expect(throws: LearningVaultError.wrongPassphrase) { try LearningVault.store(fromExport: data, passphrase: "another") }
        #expect(throws: LearningVaultError.notAnExport) { try LearningVault.store(fromExport: Data("not an export file at all, sorry about that".utf8), passphrase: "x") }
    }

    @Test func exportToAFile() throws {
        let url = Self.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        try LearningVault.writeExport(Self.sample, passphrase: "made up", to: url, rounds: 1000)
        #expect(try LearningVault.readExport(from: url, passphrase: "made up") == Self.sample)
    }
}

/// Collects what the bridge reports. A real store records it, as the app does.
private final class LearnedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LearningEvent] = []
    func add(_ e: LearningEvent) { lock.withLock { _events.append(e) } }
    var events: [LearningEvent] { lock.withLock { _events } }
}

private func learningHarness(_ checker: SpellChecking = ProseChecker(), capturing: Bool = true, secure: Bool = false) -> (Harness, LearnedLog) {
    let h = Harness(checker: checker, secure: secure)
    let log = LearnedLog()
    h.bridge.hooks.didLearn = { event, _ in log.add(event) }
    h.bridge.learningCaptures = capturing
    h.bridge.drain()
    return (h, log)
}

@Suite("Learning: through the keyboard harness", .serialized)
struct LearningBridgeTests {
    @Test func offByDefault() {
        let h = Harness(checker: ProseChecker())
        #expect(!h.bridge.learningCaptures)
        let log = LearnedLog()
        h.bridge.hooks.didLearn = { event, _ in log.add(event) }
        h.type("zzqqxx words here ")
        #expect(log.events.isEmpty)
    }

    @Test func noticesAWordKeptAsTypedAndNothingElse() {
        let (h, log) = learningHarness()
        h.type("\nthe zzqqxx word over here ")
        #expect(log.events == [.keptWord("zzqqxx")])   // the correctly spelled words never leave the queue
    }

    @Test func noticesACorrection() {
        let (h, log) = learningHarness()
        h.type("\nzzqqxx")
        h.backspace()
        h.backspace()
        h.type("yy ")
        #expect(log.events == [.corrected(typed: "zzqqxx", corrected: "zzqqyy")])
    }

    @Test func noticesAnUndo() {
        let (h, log) = learningHarness(FakeChecker())
        h.type("\nteh ")
        h.backspace()
        #expect(log.events == [.undone(typed: "teh", replacement: "the")])
    }

    @Test func nothingUnderSecureInput() {
        let (h, log) = learningHarness(secure: true)
        h.type("\nzzqqxx more zzqqyy again ")
        #expect(log.events.isEmpty)
    }

    @Test func nothingInAnExcludedApp() {
        let (h, log) = learningHarness(capturing: false)
        h.type("\nzzqqxx more zzqqyy again ")
        #expect(log.events.isEmpty)
    }

    @Test func nothingInCarefulApps() {
        let (h, log) = learningHarness()
        h.bridge.isAppCareful = true
        h.type("\nzzqqxx more zzqqyy again ")
        h.type("\nthe quick zzqqxx ")
        #expect(log.events.isEmpty)
    }

    @Test func nothingFromAnythingCodeShaped() {
        let (h, log) = learningHarness(FlagAll())
        h.type("\ngit push origin main --force ")
        #expect(!log.events.contains(.keptWord("--force")))
        h.type("\nsrc/main me@example.com @handle foo_bar API camelCase v2 `code` ")
        h.type("\n")
        for e in log.events {
            if case .keptWord(let w) = e {
                #expect(!["src/main", "me@example.com", "@handle", "foo_bar", "API", "camelCase", "v2", "`code`"].contains(w))
            }
        }
    }

    /// A made-up sentence through the real bridge and a real store, then decrypted: only single
    /// allowed words can be in there, never the sentence or its neighbours.
    @Test func aSentenceNeverReachesStorage() throws {
        let (h, _) = learningHarness(FlagAll())
        let collected = StoreBox()
        h.bridge.hooks.didLearn = { event, verdict in collected.record(event, verdict) }
        h.type("\nthe zorblat quixel met plover at noon \n")
        let url = testFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = MemoryKey()
        let vault = LearningVault(fileURL: url, keys: keys)
        try vault.save(collected.store)
        let reopened = try vault.load()
        let json = String(decoding: try JSONEncoder().encode(reopened), as: UTF8.self)
        #expect(!json.contains("zorblat quixel"))
        #expect(!json.contains("noon \n"))
        for item in reopened.items {
            #expect(!item.typed.contains(" "))
            #expect(item.correction.isEmpty)
        }
    }

    @Test func approvedRuleIsTypedKnownWordIsLeftAlone() {
        let h = Harness(checker: FakeChecker())
        h.bridge.learnedRules = LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", lastSeen: "2026-01-01", status: .active),
            LearnedItem(kind: .known, typed: "teh", lastSeen: "2026-01-01", status: .active),
        ]).rules
        h.type("zorp teh ")
        #expect(h.field.text == "zoro teh ")
    }

    @Test func aProposedRuleDoesNothing() {
        let h = Harness(checker: FakeChecker())
        h.bridge.learnedRules = LearningStore(items: [
            LearnedItem(kind: .correction, typed: "zorp", correction: "zoro", lastSeen: "2026-01-01", status: .proposed),
        ]).rules
        h.type("zorp ")
        #expect(h.field.text == "zorp ")
    }

    @Test func aBlockedFixStops() {
        let h = Harness(checker: FakeChecker())
        h.bridge.learnedRules = LearningStore(items: [
            LearnedItem(kind: .undo, typed: "teh", correction: "the", lastSeen: "2026-01-01", status: .active),
        ]).rules
        h.type("teh recieve ")
        #expect(h.field.text == "teh receive ")
    }

    @Test func rulesAreNotUsedInCarefulApps() {
        let h = Harness(checker: ProseChecker())
        h.bridge.isAppCareful = true
        h.bridge.learnedRules = LearningStore(items: [
            LearnedItem(kind: .correction, typed: "quick", correction: "quack", lastSeen: "2026-01-01", status: .active),
        ]).rules
        h.press(specialKey(KeyCode.returnKey))
        h.bridge.drain()
        h.type("the over quick ")
        #expect(h.field.text == "\nthe over quick ")
    }

    @Test func turningOffWipesWhatIsHeld() {
        let (h, log) = learningHarness()
        h.type("\nzzqqxx ")
        h.bridge.learningCaptures = false
        h.bridge.drain()
        h.bridge.learningCaptures = true
        h.type("next ")
        #expect(log.events.isEmpty)
    }
}

/// Flags every word, with no confident fix.
private struct FlagAll: SpellChecking {
    func verdict(for word: String) -> SpellVerdict { .unknown }
    func hasLearnedWord(_ word: String) -> Bool { false }
}

private final class StoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _store = LearningStore()
    func record(_ e: LearningEvent, _ v: SpellVerdict) {
        lock.withLock { _store.record(e, day: "2026-01-01") { _ in v } }
    }
    var store: LearningStore { lock.withLock { _store } }
}
