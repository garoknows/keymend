import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

/// A spell checker with made-up completions.
private struct CompletingChecker: SpellChecking {
    var words = ["hello", "help", "helmet", "helium", "teh", "the", "they"]
    func verdict(for word: String) -> SpellVerdict { fakeCheck(word).map(SpellVerdict.fix) ?? .correct }
    func hasLearnedWord(_ word: String) -> Bool { false }
    func completions(for partial: String) -> [String] {
        words.filter { $0.hasPrefix(partial.lowercased()) }
    }
}

private final class BarLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _bar: SuggestionBar?
    private var _changes = 0
    func record(_ bar: SuggestionBar?) { lock.withLock { _bar = bar; _changes += 1 } }
    var bar: SuggestionBar? { lock.withLock { _bar } }
    var changes: Int { lock.withLock { _changes } }
}

private func suggestingHarness(secure: Bool = false) -> (Harness, BarLog) {
    let h = Harness(checker: CompletingChecker(), secure: secure)
    let log = BarLog()
    h.bridge.hooks.didChangeSuggestions = { log.record($0) }
    h.bridge.modifiersHeld = { false }
    h.bridge.suggestionsAllowed = true
    h.bridge.drain()
    return (h, log)
}

private func pickKey(_ slot: Int, flags: CGEventFlags = .maskAlternate, kind: RawKeyEvent.Kind = .keyDown) -> RawKeyEvent {
    RawKeyEvent(kind: kind, keyCode: PickKeys.numberRow[slot], flags: flags, characters: "\u{2122}")
}

@Suite("Suggestion bar")
struct SuggestionBarTests {
    @Test func noBarForOneLetter() {
        let (h, log) = suggestingHarness()
        h.type("h")
        #expect(log.bar == nil)
    }

    @Test func barShowsTheWordAndUpToThreeCompletions() {
        let (h, log) = suggestingHarness()
        h.type("he")
        #expect(log.bar?.typed == "he")
        #expect(log.bar?.completions == ["hello", "help", "helmet"])
        h.type("lp")
        #expect(log.bar?.typed == "help")
    }

    @Test func barShowsTheWordEvenWithNoCompletions() {
        let (h, log) = suggestingHarness()
        h.type("zq")
        #expect(log.bar?.typed == "zq")
        #expect(log.bar?.completions == [])
    }

    @Test(arguments: [" ", ",", ";", "!", "?", ".", ":", ")"])
    func punctuationHidesTheBar(_ key: String) {
        let (h, log) = suggestingHarness()
        h.type("he")
        #expect(log.bar != nil)
        h.type(key)
        #expect(log.bar == nil)
    }

    @Test func returnTabAndEscapeHideTheBar() {
        for code in [KeyCode.returnKey, KeyCode.tab, KeyCode.escape] {
            let (h, log) = suggestingHarness()
            h.type("he")
            h.press(specialKey(code))
            h.bridge.drain()
            #expect(log.bar == nil)
        }
    }

    @Test func clickingElsewhereHidesTheBarButClickingTheBarDoesNot() {
        let (h, log) = suggestingHarness()
        h.type("he")
        h.bridge.barFrame = CGRect(x: 100, y: 100, width: 200, height: 30)
        let onBar = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 150, y: 110), mouseButton: .left)!
        h.bridge.receive(onBar, type: .leftMouseDown)
        h.bridge.drain()
        #expect(log.bar != nil)
        let elsewhere = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 500, y: 500), mouseButton: .left)!
        h.bridge.receive(elsewhere, type: .leftMouseDown)
        h.bridge.drain()
        #expect(log.bar == nil)
    }

    @Test func switchingAppsHidesTheBar() {
        let (h, log) = suggestingHarness()
        h.type("he")
        h.bridge.reset()
        h.bridge.drain()
        #expect(log.bar == nil)
    }

    @Test func noBarInCarefulApps() {
        let (h, log) = suggestingHarness()
        h.bridge.isAppCareful = true
        h.bridge.drain()
        h.press(specialKey(KeyCode.returnKey))
        h.type("he")
        #expect(log.bar == nil)
    }

    @Test func noBarInSkippedAppsWhenPausedOrWithTheSettingOff() {
        let setups: [@Sendable (KeyboardBridge) -> Void] = [
            { $0.isAppSkipped = true }, { $0.isEnabled = false }, { $0.suggestionsAllowed = false },
        ]
        for setup in setups {
            let (h, log) = suggestingHarness()
            setup(h.bridge)
            h.bridge.drain()
            h.press(specialKey(KeyCode.returnKey))
            h.type("he")
            #expect(log.bar == nil)
        }
    }

    @Test func noBarInPasswordFields() {
        let (h, log) = suggestingHarness(secure: true)
        h.type("he")
        #expect(log.bar == nil)
        #expect(log.changes == 0)
    }

    @Test(arguments: ["`he", "he1", "HE", "he/", "@he", "#he", "iPh"])
    func noBarForWordsKeymendWouldLeaveAlone(_ text: String) {
        let (h, log) = suggestingHarness()
        h.type(text)
        #expect(log.bar == nil)
    }

    @Test func goingBackPastTheWordHidesTheBar() {
        let (h, log) = suggestingHarness()
        h.type("he")
        h.press(specialKey(KeyCode.delete))
        h.bridge.drain()
        #expect(log.bar == nil)
    }
}

@Suite("Picking from the bar")
struct PickingTests {
    @Test func pickingACompletionReplacesTheWordAndAddsASpace() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        let bar = try #require(log.bar)
        h.bridge.pick(slot: 1, generation: bar.generation)
        h.bridge.drain()
        #expect(h.field.text == "hello ")
        #expect(log.bar == nil)
    }

    @Test func capitalsAreKept() throws {
        let (h, log) = suggestingHarness()
        h.type("He")
        let bar = try #require(log.bar)
        #expect(bar.completions.first == "Hello")
        h.bridge.pick(slot: 1, generation: bar.generation)
        h.bridge.drain()
        #expect(h.field.text == "Hello ")
    }

    @Test func aWordAfterAPickIsTrackedNormally() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        h.bridge.pick(slot: 1, generation: try #require(log.bar).generation)
        h.bridge.drain()
        h.type("teh ")
        #expect(h.field.text == "hello the ")
    }

    @Test func pickingTheQuotedWordKeepsItAndStopsAutocorrect() throws {
        let (h, log) = suggestingHarness()
        h.type("teh")
        h.bridge.pick(slot: 0, generation: try #require(log.bar).generation)
        h.bridge.drain()
        #expect(log.bar == nil)
        #expect(h.field.text == "teh")
        h.type(" ")
        #expect(h.field.text == "teh ")
        #expect(h.fixes.value == 0)
    }

    @Test func withoutThatPickTheWordIsStillFixed() {
        let (h, _) = suggestingHarness()
        h.type("teh ")
        #expect(h.field.text == "the ")
    }

    @Test func theBarStaysAwayForAKeptWordButComesBackForTheNext() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        h.bridge.pick(slot: 0, generation: try #require(log.bar).generation)
        h.bridge.drain()
        #expect(log.bar == nil)
        h.type("l")
        #expect(log.bar?.typed == "hel")
    }

    @Test func aPickForAnOlderBarDoesNothing() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        let old = try #require(log.bar).generation
        h.type("l")
        h.bridge.pick(slot: 1, generation: old)
        h.bridge.drain()
        #expect(h.field.text == "hel")
    }

    @Test func aSlotThatIsntShowingDoesNothing() throws {
        let (h, log) = suggestingHarness()
        h.type("zq")
        h.bridge.pick(slot: 1, generation: try #require(log.bar).generation)
        h.bridge.drain()
        #expect(h.field.text == "zq")
    }

    @Test func aPickWaitsForModifiersToComeUp() throws {
        let (h, log) = suggestingHarness()
        let release = Date().addingTimeInterval(0.1)
        h.bridge.modifiersHeld = { Date() < release }
        h.type("he")
        h.bridge.pick(slot: 1, generation: try #require(log.bar).generation)
        h.bridge.drain()
        #expect(Date() >= release)
        #expect(h.field.text == "hello ")
    }

    @Test func aKeyPressedDuringThatWaitCancelsThePick() throws {
        let (h, log) = suggestingHarness()
        let holding = ManagedFlag(true)
        h.bridge.modifiersHeld = { holding.value }
        h.type("he")
        h.bridge.pick(slot: 1, generation: try #require(log.bar).generation)
        h.press(keyEvent("l"))
        holding.value = false
        h.bridge.drain()
        #expect(h.field.text == "hel")
    }

    @Test func thePickKeyIsntTreatedAsTyping() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        #expect(h.bridge.pickDecision(for: pickKey(1)) == .pick(slot: 1))
        // The listening tap may see the same key. The word mustn't change.
        h.bridge.receive(pickKey(1))
        h.bridge.drain()
        #expect(h.field.text == "hello ")
        #expect(log.bar == nil)
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("Pick keys")
struct PickKeyFilterTests {
    private func filter(choices: Int = 4, modifier: PickModifier = .option) -> PickKeyFilter {
        var f = PickKeyFilter(keys: PickKeys(modifier: modifier))
        f.choiceCount = choices
        return f
    }

    @Test(arguments: 0..<4)
    func optionAndANumberPick(_ slot: Int) {
        var f = filter()
        #expect(f.decide(pickKey(slot)) == .pick(slot: slot))
    }

    @Test func nothingIsTakenWhileTheBarIsHidden() {
        var f = filter(choices: 0)
        for slot in 0..<4 { #expect(f.decide(pickKey(slot)) == .pass) }
    }

    @Test func aNumberForASlotThatIsntShowingGoesThrough() {
        var f = filter(choices: 2)
        #expect(f.decide(pickKey(2)) == .pass)
        #expect(f.decide(pickKey(3)) == .pass)
    }

    @Test func everyOtherKeyGoesThroughUntouched() {
        var f = filter()
        for code in UInt16(0)..<128 where !PickKeys.numberRow.contains(code) {
            #expect(f.decide(RawKeyEvent(kind: .keyDown, keyCode: code, flags: .maskAlternate)) == .pass)
            #expect(f.decide(RawKeyEvent(kind: .keyUp, keyCode: code, flags: .maskAlternate)) == .pass)
        }
        #expect(f.choiceCount == 4)
    }

    @Test(arguments: [CGEventFlags(), .maskCommand, [.maskCommand, .maskAlternate], [.maskControl, .maskAlternate], [.maskAlternate, .maskShift], .maskShift])
    func otherModifiersOnTheNumbersGoThrough(_ flags: CGEventFlags) {
        var f = filter()
        #expect(f.decide(pickKey(0, flags: flags)) == .pass)
    }

    @Test func capsLockDoesntGetInTheWay() {
        var f = filter()
        #expect(f.decide(pickKey(0, flags: [.maskAlternate, .maskAlphaShift])) == .pick(slot: 0))
    }

    @Test(arguments: PickModifier.allCases)
    func theModifierCanBeChanged(_ modifier: PickModifier) {
        var f = filter(modifier: modifier)
        #expect(f.decide(pickKey(1, flags: modifier.flags)) == .pick(slot: 1))
        var other = filter(modifier: modifier)
        let wrong: CGEventFlags = modifier == .option ? [.maskControl, .maskAlternate] : .maskAlternate
        #expect(other.decide(pickKey(1, flags: wrong)) == .pass)
    }

    @Test func aPickKeysRepeatsAndReleaseAreSwallowedThenThingsGoBackToNormal() {
        var f = filter()
        #expect(f.decide(pickKey(1)) == .pick(slot: 1))
        #expect(f.decide(pickKey(1)) == .swallow)
        #expect(f.decide(pickKey(1, kind: .keyUp)) == .swallow)
        #expect(f.heldKey == nil)
        #expect(f.decide(pickKey(1)) == .pass)
        #expect(f.decide(pickKey(1, kind: .keyUp)) == .pass)
    }

    @Test func keymendsOwnKeysGoThrough() {
        var f = filter()
        var own = pickKey(1)
        own.isOwnEvent = true
        #expect(f.decide(own) == .pass)
    }
}

private final class FakeTap: PickTapBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    private var _starts = 0
    private var _refuses = false
    var running: Bool { lock.withLock { _running } }
    var starts: Int { lock.withLock { _starts } }
    var refuses: Bool {
        get { lock.withLock { _refuses } }
        set { lock.withLock { _refuses = newValue } }
    }
    func start() -> Bool {
        lock.withLock {
            if _refuses { return false }
            _running = true
            _starts += 1
            return true
        }
    }
    func stop() { lock.withLock { _running = false } }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

/// The freeze risk: an active tap must not outlive a permission.
@Suite("Stopping the active tap")
struct PickTapSafetyTests {
    private func setup(poll: TimeInterval = 0.01, linger: TimeInterval = 0.05) -> (PickTapController, FakeTap, ManagedFlag, ManagedFlag, FakeClock) {
        let tap = FakeTap(), permitted = ManagedFlag(true), held = ManagedFlag(false), clock = FakeClock()
        let c = PickTapController(
            backend: tap, hasPermission: { permitted.value }, keyHeld: { held.value },
            now: { clock.now }, pollInterval: poll, lingerLimit: linger
        )
        return (c, tap, permitted, held, clock)
    }

    private func waitUntil(_ limit: TimeInterval = 2, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(limit)
        while Date() < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return done()
    }

    @Test func theTapExistsOnlyWhileTheBarIsShowing() {
        let (c, tap, _, _, _) = setup()
        #expect(!tap.running)
        c.barDidShow()
        #expect(tap.running)
        c.barDidHide()
        #expect(!tap.running)
    }

    @Test func keepingTheBarUpDoesntStartASecondTap() {
        let (c, tap, _, _, _) = setup()
        c.barDidShow()
        c.barDidShow()
        #expect(tap.starts == 1)
        c.barDidHide()
    }

    @Test func noTapWithoutPermission() {
        let (c, tap, permitted, _, _) = setup()
        permitted.value = false
        c.barDidShow()
        #expect(!tap.running)
        #expect(tap.starts == 0)
    }

    /// The main check: the switch goes off with the tap running, and nothing else happens.
    @Test func losingPermissionWhileRunningStopsTheTapOnItsOwn() {
        let (c, tap, permitted, _, _) = setup()
        let stopped = ManagedFlag(false)
        c.onStopped = { stopped.value = true }
        c.barDidShow()
        #expect(tap.running)
        permitted.value = false
        #expect(waitUntil { !tap.running })
        #expect(stopped.value)
        #expect(!c.isRunning)
    }

    @Test func theRealCheckRunsAtLeastFourTimesASecond() {
        #expect(PickTapController.pollInterval <= 0.25)
    }

    @Test func theAccessibilityNoticeStopsTheTapBeforeReturning() {
        let (c, tap, _, _, _) = setup(poll: 60)
        c.barDidShow()
        c.stopForSafety()
        #expect(!tap.running)
    }

    @Test func theTapStaysDownWhileThatNoticeSettles() {
        let (c, tap, _, _, clock) = setup(poll: 60)
        c.barDidShow()
        c.stopForSafety()
        c.barDidShow()
        #expect(!tap.running)
        clock.advance(PickTapController.restartBlock + 0.1)
        c.barDidShow()
        #expect(tap.running)
        c.barDidHide()
    }

    @Test func itDoesntComeBackAfterLosingPermissionWhileThePermissionIsGone() {
        let (c, tap, permitted, _, clock) = setup()
        c.barDidShow()
        permitted.value = false
        #expect(waitUntil { !tap.running })
        clock.advance(10)
        c.barDidShow()
        #expect(!tap.running)
        #expect(tap.starts == 1)
    }

    @Test func aRefusedTapIsReportedAndTheBarCarriesOn() {
        let (c, tap, _, _, _) = setup()
        tap.refuses = true
        c.barDidShow()
        #expect(c.lastStartFailed)
        #expect(!c.isRunning)
    }

    @Test func aHeldPickKeyKeepsTheTapUntilItIsReleased() {
        let (c, tap, _, held, _) = setup(poll: 60, linger: 5)
        c.barDidShow()
        held.value = true
        c.barDidHide()
        #expect(tap.running)
        held.value = false
        c.pickKeyReleased()
        #expect(!tap.running)
    }

    @Test func aHeldPickKeyCantKeepTheTapAliveForever() {
        let (c, tap, _, held, _) = setup(poll: 60, linger: 0.02)
        c.barDidShow()
        held.value = true
        c.barDidHide()
        #expect(waitUntil { !tap.running })
    }

    @Test func aPermissionLossBeatsAHeldKey() {
        let (c, tap, permitted, held, _) = setup(linger: 5)
        c.barDidShow()
        held.value = true
        c.barDidHide()
        #expect(tap.running)
        permitted.value = false
        #expect(waitUntil { !tap.running })
    }

    @Test func releasingAPickKeyWhileTheBarIsUpLeavesTheTapRunning() {
        let (c, tap, _, _, _) = setup(poll: 60)
        c.barDidShow()
        c.pickKeyReleased()
        #expect(tap.running)
        c.barDidHide()
    }

    @Test func stoppingLetsGoOfTheHeldKeySoNormalTypingResumes() throws {
        let (h, log) = suggestingHarness()
        h.type("he")
        _ = try #require(log.bar)
        _ = h.bridge.pickDecision(for: pickKey(1))
        #expect(h.bridge.isHoldingPickKey)
        h.bridge.pickTapDidStop()
        #expect(!h.bridge.isHoldingPickKey)
    }
}

@Suite("Suggestion rules")
struct SuggestionRuleTests {
    @Test func keepsOnlyRealCompletions() {
        let out = SuggestionRules.clean(["hello", "he", "world", "hel lo", "he-man", "he1p", "help"], typed: "he")
        #expect(out == ["hello", "help"])
    }

    @Test func atMostThreeAndNoRepeats() {
        #expect(SuggestionRules.clean(["help", "help", "hello", "helmet", "helium"], typed: "he") == ["help", "hello", "helmet"])
    }

    @Test func followsTheCapitalTheUserTyped() {
        #expect(SuggestionRules.clean(["hello"], typed: "He") == ["Hello"])
        #expect(SuggestionRules.clean(["Hello"], typed: "he") == ["Hello"])
    }

    @Test func dropsWordsThisKeyboardCantType() {
        #expect(SuggestionRules.clean(["help", "hello"], typed: "he") { $0 != "help" } == ["hello"])
    }

    @Test func theRealCheckerOffersCompletionsWhenItCanBeReached() {
        // The spell service is out of reach in some restricted environments. CI runs this.
        guard spellServiceAvailable else { return }
        // Just after the service starts it answers with nothing for a moment (seen on fresh CI
        // machines). Completions must arrive soon after, or this fails.
        withRealService("Spell service") {
            let checker = AppleSpellChecker()
            let end = Date().addingTimeInterval(15)
            var offered = checker.completions(for: "hel")
            while offered.isEmpty, Date() < end {
                Thread.sleep(forTimeInterval: 0.25)
                offered = checker.completions(for: "hel")
            }
            #expect(!offered.isEmpty)
        }
    }

    @Test func aSlowCheckerGivesNoCompletionsInsteadOfHoldingUpTyping() {
        struct Slow: SpellChecking {
            func verdict(for word: String) -> SpellVerdict { .correct }
            func hasLearnedWord(_ word: String) -> Bool { false }
            func completions(for partial: String) -> [String] {
                Thread.sleep(forTimeInterval: 3)
                return ["hello"]
            }
        }
        // Generous on purpose: ignoring the limit would take the full 3 seconds.
        let start = Date()
        #expect(TimeLimitedSpellChecker(Slow(), limit: .milliseconds(20)).completions(for: "he") == [])
        #expect(Date().timeIntervalSince(start) < 1.5)
    }
}

@Suite("Where the bar goes")
struct BarPlacementTests {
    private let size = CGSize(width: 300, height: 30)
    private let screen = CGRect(x: 0, y: 40, width: 1440, height: 800)

    @Test func bottomCenterOfTheFrontWindow() {
        // Top-left coordinates: the window spans y 100...700 on a 900-high display.
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        let o = BarPlacement.origin(barSize: size, window: window, primaryHeight: 900, screens: [screen])
        #expect(o == CGPoint(x: 450, y: 216))
    }

    @Test func bottomCenterOfTheScreenWithNoWindow() {
        let o = BarPlacement.origin(barSize: size, window: nil, primaryHeight: 900, screens: [screen])
        #expect(o == CGPoint(x: 570, y: 56))
    }

    @Test func staysOnScreenWhenTheWindowHangsOffIt() {
        let window = CGRect(x: -500, y: 300, width: 600, height: 900)
        let o = BarPlacement.origin(barSize: size, window: window, primaryHeight: 900, screens: [screen])
        #expect(o.x == 0)
        #expect(o.y == 40)
    }

    @Test func usesTheScreenTheWindowIsOn() {
        let second = CGRect(x: 1440, y: 40, width: 1000, height: 800)
        let window = CGRect(x: 1600, y: 100, width: 600, height: 400)
        let o = BarPlacement.origin(barSize: size, window: window, primaryHeight: 900, screens: [screen, second])
        #expect(o.x == 1750)
    }

    @Test func flippingTwiceGivesTheSameRect() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(BarPlacement.flip(BarPlacement.flip(r, primaryHeight: 900), primaryHeight: 900) == r)
    }
}
