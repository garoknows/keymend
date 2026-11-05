import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

/// A stand-in for a text field in another app. It receives real `CGEvent`s, both the
/// user's keystrokes and the ones Keymend posts, and records exactly what text arrives.
final class SimulatedTextField: KeyOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private(set) var postedEventCount = 0
    /// Every event Keymend posted is also shown to the bridge, as the real tap would see it.
    weak var bridge: KeyboardBridge?

    var text: String { lock.withLock { _text } }

    /// Applies one key-down event the way a text field would.
    func apply(_ e: CGEvent) {
        lock.withLock { applyLocked(e) }
    }

    private func applyLocked(_ e: CGEvent) {
        let raw = RawKeyEvent(e, type: .keyDown)
        do {
            if raw.keyCode == KeyCode.delete {
                if !_text.isEmpty { _text.removeLast() }
            } else if raw.keyCode == KeyCode.returnKey {
                _text += "\n"
            } else if raw.keyCode == KeyCode.tab {
                _text += "\t"
            } else if raw.flags.contains(.maskCommand) {
                // shortcuts change nothing in this simple field
            } else {
                _text += raw.characters
            }
        }
    }

    /// This field receives a whole fix as one unit, so a user key can only land before or after
    /// it. That is a simplification: real events can interleave, so these tests do NOT prove a
    /// key can't land in the middle of a fix, only that the stale-fix check works.
    func perform(_ plan: KeyPlan) {
        let downs = KeyEventFactory.events(for: plan, source: nil).filter { $0.type == .keyDown }
        lock.withLock {
            for e in downs { applyLocked(e); postedEventCount += 1 }
        }
        for e in downs { bridge?.receive(e, type: .keyDown) }   // must be ignored: tagged as Keymend's
    }
}

/// Makes the event a physical key press would produce.
func keyEvent(_ ch: Character) -> CGEvent {
    let code: CGKeyCode
    switch ch {
    case " ": code = CGKeyCode(KeyCode.space)
    case "\n": code = CGKeyCode(KeyCode.returnKey)
    case "\t": code = CGKeyCode(KeyCode.tab)
    default: code = 0
    }
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    e.flags = ch.isUppercase ? .maskShift : []
    let units = Array(String(ch).utf16)
    if ch != "\n" && ch != "\t" {
        units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
    }
    return e
}

func specialKey(_ code: UInt16, flags: CGEventFlags = []) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)!
    e.flags = flags
    return e
}

struct FakeChecker: SpellChecking {
    var learned: Set<String> = []
    func verdict(for word: String) -> SpellVerdict { fakeCheck(word).map(SpellVerdict.fix) ?? .correct }
    func hasLearnedWord(_ word: String) -> Bool { learned.contains(word) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ d: Int = 1) { lock.withLock { n += d } }
    var value: Int { lock.withLock { n } }
}

/// One harness run: a fresh field and bridge, starting at the beginning of a line.
final class Harness {
    let field = SimulatedTextField()
    let bridge: KeyboardBridge
    let fixes = Counter()
    let undos = Counter()

    init(checker: SpellChecking = FakeChecker(), secure: Bool = false) {
        var hooks = KeyboardBridge.Hooks()
        let fixes = self.fixes, undos = self.undos
        hooks.didFix = { fixes.add() }
        hooks.didUndo = { undos.add() }
        bridge = KeyboardBridge(output: field, checker: checker, hooks: hooks)
        bridge.secureInputCheck = { secure }
        field.bridge = bridge
        press(specialKey(KeyCode.returnKey))   // start of a fresh line
        field.apply(specialKey(KeyCode.returnKey))
        bridge.drain()
        _ = clearField()
    }

    private func clearField() -> Bool {
        while !field.text.isEmpty { field.apply(specialKey(KeyCode.delete)) }
        return true
    }

    /// The user presses a key: the app gets it, and the tap sees it. Events made in a test look
    /// posted by a program, so they're marked as coming from the keyboard here.
    func press(_ e: CGEvent) {
        field.apply(e)
        var raw = RawKeyEvent(e, type: .keyDown)
        raw.isFromAnotherProgram = false
        bridge.receive(raw)
    }

    /// Types `s` one key at a time. `delay` is the time between keys.
    func type(_ s: String, delay: TimeInterval = 0, settle: Bool = true) {
        for ch in s {
            press(keyEvent(ch))
            if delay > 0 { Thread.sleep(forTimeInterval: delay) } else if settle { bridge.drain() }
        }
        bridge.drain()
    }

    func backspace() { press(specialKey(KeyCode.delete)); bridge.drain() }
}

@Suite("Keyboard bridge harness", .serialized)
struct BridgeHarnessTests {
    @Test func fixesTehInARealEventStream() {
        let h = Harness()
        h.type("I saw teh cat ")
        #expect(h.field.text == "I saw the cat ")
        #expect(h.fixes.value == 1)
        // 4 Deletes + 4 typed characters ("the ").
        #expect(h.field.postedEventCount == 8)
    }

    @Test func ownEventsAreIgnored() {
        let h = Harness()
        h.type("teh teh ")
        // If posted events were fed back into the engine, the second fix would be wrong.
        #expect(h.field.text == "the the ")
        #expect(h.fixes.value == 2)
    }

    @Test func undoWithDelete() {
        let h = Harness()
        h.type("teh ")
        h.backspace()
        #expect(h.field.text == "teh")
        #expect(h.undos.value == 1)
        h.type(" again teh ")
        #expect(h.field.text == "teh again teh ")
    }

    @Test func capitalsAndPunctuation() {
        let h = Harness()
        h.type("Teh plan, adn the rest; recieve it tomorow. ")
        #expect(h.field.text == "The plan, and the rest; receive it tomorrow. ")
    }

    @Test func secureInputMeansNothing() {
        let h = Harness(secure: true)
        h.type("teh password recieve ")
        #expect(h.field.text == "teh password recieve ")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func pausedDoesNothing() {
        let h = Harness()
        h.bridge.isEnabled = false
        h.type("teh ")
        #expect(h.field.text == "teh ")
        h.bridge.isEnabled = true
        h.type("x teh ")
        // The first word after resuming is skipped (the caret position was unknown).
        #expect(h.field.text == "teh x the ")
    }

    @Test func skippedAppDoesNothing() {
        let h = Harness()
        h.bridge.isAppSkipped = true
        h.type("teh recieve ")
        #expect(h.field.text == "teh recieve ")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func neverCorrectList() {
        let h = Harness()
        h.bridge.neverCorrect = NeverCorrectList(words: ["teh"])
        h.type("teh recieve ")
        #expect(h.field.text == "teh receive ")
    }

    @Test func learnedWordsAreLeftAlone() {
        let h = Harness(checker: FakeChecker(learned: ["recieve"]))
        h.type("teh recieve ")
        #expect(h.field.text == "the recieve ")
    }

    @Test func mouseClickResets() {
        let h = Harness()
        h.type("hello te")
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        h.bridge.receive(click, type: .leftMouseDown)
        h.type("h ")
        #expect(h.field.text == "hello teh ")
        #expect(h.fixes.value == 0)
    }

    @Test func arrowKeysAndShortcutsReset() {
        let h = Harness()
        h.type("te")
        h.press(specialKey(123))                       // left arrow
        h.type("h ")
        h.type("rec")
        h.press(specialKey(9, flags: .maskCommand))    // Command-V
        h.type("ieve ")
        #expect(h.fixes.value == 0)
    }

    @Test func returnSendsWithoutFixing() {
        let h = Harness()
        h.type("teh\n")
        #expect(h.field.text == "teh\n")
        h.type("teh ")
        #expect(h.field.text == "teh\nthe ")
    }

    @Test func staleFixIsDropped() {
        // A key arrives after the space but before the fix is typed: the fix must be skipped.
        let h = Harness()
        let injected = Counter()
        let field = h.field
        let bridge = h.bridge
        h.bridge.hooks.beforePerform = {
            guard injected.value == 0 else { return }
            injected.add()
            let e = keyEvent("x")
            field.apply(e)
            bridge.receive(e, type: .keyDown)
        }
        h.type("teh ", settle: false)
        #expect(h.field.text == "teh x")
        #expect(h.fixes.value == 0)
    }

    static let paragraph = "Thanks for teh quick reply, I will recieve the files tomorow. Adn then we can look at teh wierd results together. "
    static let corrected = "Thanks for the quick reply, I will receive the files tomorrow. And then we can look at the weird results together. "

    @Test func fastTyping120WPM() {
        // 120 words per minute is about 10 characters per second.
        let h = Harness()
        h.type(Self.paragraph, delay: 0.1 / 3)    // run 3x faster than 120 wpm to keep the test short
        Thread.sleep(forTimeInterval: 0.1)
        h.bridge.drain()
        #expect(h.field.text == Self.corrected)
    }

    @Test(arguments: 1...5)
    func veryFastTypingNeverLosesOrDoublesCharacters(_ run: Int) {
        // 30 ms between keys is about 400 words per minute, far beyond human speed. Some fixes
        // may be dropped as stale, but every word must be either as typed or fixed. The field
        // applies each fix as one unit (see SimulatedTextField), so this can't catch interleaving.
        let h = Harness()
        h.type(Self.paragraph, delay: 0.03, settle: false)
        Thread.sleep(forTimeInterval: 0.2)
        h.bridge.drain()
        let got = h.field.text.split(separator: " ", omittingEmptySubsequences: false)
        let typed = Self.paragraph.split(separator: " ", omittingEmptySubsequences: false)
        let fixed = Self.corrected.split(separator: " ", omittingEmptySubsequences: false)
        #expect(got.count == typed.count)
        for i in 0..<min(got.count, typed.count) {
            #expect(got[i] == typed[i] || got[i] == fixed[i], "word \(i): \(got[i])")
        }
    }

    @Test func classifier() {
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyUp, characters: "a")) == nil)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .flagsChanged)) == nil)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, characters: "a", isOwnEvent: true)) == nil)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, characters: "a")) == .text("a"))
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 51)) == .backspace)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 51, flags: .maskAlternate)) == .reset)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 36)) == .newline)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 48)) == .tab)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 0, flags: .maskCommand, characters: "a")) == .reset)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 14, characters: "")) == .reset)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .keyDown, keyCode: 122)) == nil)
        #expect(KeyEventClassifier.classify(RawKeyEvent(kind: .mouseDown)) == .reset)
    }

    @Test func lettersArePostedAsTheirRealKeys() {
        // The "aaa" bug: every letter used to be posted as key code 0, the physical "A" key.
        let layout = KeyLayoutMap(strokes: [
            "t": KeyStroke(code: 17), "T": KeyStroke(code: 17, shift: true),
            "h": KeyStroke(code: 4), "e": KeyStroke(code: 14), " ": KeyStroke(code: 49),
        ])
        let events = KeyEventFactory.events(for: KeyPlan(backspaces: 1, text: "The "), source: nil, layout: layout)
        let downs = events.filter { $0.type == .keyDown }.map { RawKeyEvent($0, type: .keyDown) }
        #expect(downs.map(\.keyCode) == [51, 17, 4, 14, 49])
        #expect(downs.map(\.characters).suffix(4) == ["T", "h", "e", " "])
        #expect(downs[1].flags.contains(.maskShift))
        #expect(!downs[2].flags.contains(.maskShift))
        // The Shift must be released on the key-up as well, with the same key.
        let ups = events.filter { $0.type == .keyUp }.map { RawKeyEvent($0, type: .keyUp) }
        #expect(ups.map(\.keyCode) == [51, 17, 4, 14, 49])
    }

    @Test func aCharacterTheLayoutCannotTypeIsReported() {
        let layout = KeyLayoutMap(strokes: ["a": KeyStroke(code: 0)])
        #expect(layout.canType("a"))
        #expect(!layout.canType("aé"))
    }

    @MainActor
    @Test func readsTheRealKeyboardLayout() throws {
        // Whatever layout this Mac uses, letters must be on different keys and capitals need Shift.
        let layout = try #require(KeyLayoutMap.current())
        let t = try #require(layout.stroke(for: "t"))
        let h = try #require(layout.stroke(for: "h"))
        let capital = try #require(layout.stroke(for: "T"))
        #expect(t.code != h.code)
        #expect(!t.shift)
        #expect(capital.code == t.code && capital.shift)
    }

    @Test func postedEventsAreTaggedAndExact() {
        let events = KeyEventFactory.events(for: KeyPlan(backspaces: 2, text: "hé"), source: nil)
        #expect(events.count == 8)
        for e in events {
            #expect(e.getIntegerValueField(.eventSourceUserData) == KeyEventClassifier.ownEventTag)
            #expect(e.flags.intersection([.maskShift, .maskCommand, .maskControl, .maskAlternate]).isEmpty)
        }
        let downs = events.filter { $0.type == .keyDown }.map { RawKeyEvent($0, type: .keyDown) }
        #expect(downs.map(\.keyCode).prefix(2) == [51, 51])
        #expect(downs.suffix(2).map(\.characters) == ["h", "é"])
    }
}
