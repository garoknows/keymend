import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

// The 1.1.1 review fixes, applied to the suggestion bar and its pick keys.

/// Completions that can be held back, so a test can act while the engine is busy with a word.
private final class GatedChecker: SpellChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    func verdict(for word: String) -> SpellVerdict { fakeCheck(word).map(SpellVerdict.fix) ?? .correct }
    func hasLearnedWord(_ word: String) -> Bool { false }
    func completions(for partial: String) -> [String] {
        lock.withLock { gate }?.wait()
        return ["hello", "help", "helmet"].filter { $0.hasPrefix(partial.lowercased()) }
    }
    /// The next completions call waits until `open()`.
    func close() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
    func open() { lock.withLock { let g = gate; gate = nil; return g }?.signal() }
}

private final class LastBar: @unchecked Sendable {
    private let lock = NSLock()
    private var _bar: SuggestionBar?
    func record(_ bar: SuggestionBar?) { lock.withLock { _bar = bar } }
    var bar: SuggestionBar? { lock.withLock { _bar } }
}

private func harness(_ checker: GatedChecker = GatedChecker()) -> (Harness, LastBar) {
    let h = Harness(checker: checker)
    let log = LastBar()
    h.bridge.hooks.didChangeSuggestions = { log.record($0) }
    h.bridge.modifiersHeld = { false }
    h.bridge.suggestionsAllowed = true
    h.bridge.drain()
    return (h, log)
}

private func optionNumber(_ slot: Int) -> RawKeyEvent {
    RawKeyEvent(kind: .keyDown, keyCode: PickKeys.numberRow[slot], flags: .maskAlternate, characters: "\u{2122}")
}

@Suite("Suggestions and input methods (review finding 6)")
struct SuggestionInputMethodTests {
    @Test func noBarWhileAnInputMethodIsSelected() {
        let (h, log) = harness()
        h.bridge.isInputMethodActive = true
        h.bridge.drain()
        h.type("he")
        #expect(log.bar == nil)
        #expect(h.field.text == "he")
    }

    @Test func selectingAnInputMethodHidesTheBar() {
        let (h, log) = harness()
        h.type("he")
        #expect(log.bar?.typed == "he")
        h.bridge.isInputMethodActive = true
        h.bridge.drain()
        #expect(log.bar == nil)
    }

    /// The pick tap answers on its own thread, before the engine has caught up. Once an input
    /// method is selected, Option and a number must reach it, even if the bar hasn't gone yet.
    @Test func pickKeysGoThroughTheMomentAnInputMethodIsSelected() throws {
        let checker = GatedChecker()
        let (h, log) = harness(checker)
        h.type("he")
        _ = try #require(log.bar)
        checker.close()
        h.press(keyEvent("l"))             // the engine is now stuck fetching completions
        h.bridge.isInputMethodActive = true
        let decision = h.bridge.pickDecision(for: optionNumber(1))
        checker.open()
        h.bridge.drain()
        #expect(decision == .pass)
        #expect(h.field.text == "hel")
    }

    @Test func aPickKeyHeldBeforehandIsStillReleasedCleanly() throws {
        let (h, log) = harness()
        h.type("he")
        _ = try #require(log.bar)
        #expect(h.bridge.pickDecision(for: optionNumber(1)) == .pick(slot: 1))
        h.bridge.isInputMethodActive = true
        let release = RawKeyEvent(kind: .keyUp, keyCode: PickKeys.numberRow[1], flags: .maskAlternate, characters: "")
        #expect(h.bridge.pickDecision(for: release) == .swallow)
        #expect(!h.bridge.isHoldingPickKey)
    }
}

@Suite("Suggestions and paused states")
struct SuggestionPausedPickTests {
    @Test(arguments: [0, 1])
    func pickKeysGoThroughTheMomentKeymendIsPausedOrTheAppIsSkipped(_ which: Int) throws {
        let checker = GatedChecker()
        let (h, log) = harness(checker)
        h.type("he")
        _ = try #require(log.bar)
        checker.close()
        h.press(keyEvent("l"))
        if which == 0 { h.bridge.isEnabled = false } else { h.bridge.isAppSkipped = true }
        let decision = h.bridge.pickDecision(for: optionNumber(1))
        checker.open()
        h.bridge.drain()
        #expect(decision == .pass)
        #expect(h.field.text == "hel")
    }
}
