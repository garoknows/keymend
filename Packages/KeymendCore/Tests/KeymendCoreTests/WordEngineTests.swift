import Testing
@testable import KeymendCore

/// A tiny fake spell checker so engine tests don't depend on the Mac's dictionaries.
let fakeFixes: [String: String] = [
    "teh": "the", "recieve": "receive", "tomorow": "tomorrow", "adn": "and",
    "wierd": "weird", "alot": "a lot", "i": "I", "dont": "don't", "Teh": "The",
]
func fakeCheck(_ w: String) -> String? { fakeFixes[w] ?? fakeFixes[w.lowercased()] }

/// Types `s` into a fresh engine (starting clean, as if at the start of a text field) and
/// returns every non-empty action, simulating the screen the same way the real app does.
struct Typist {
    var engine = WordEngine()
    var screen = ""
    var actions: [EngineAction] = []

    init() { engine.handle(.newline, check: { _ in nil }) }

    mutating func press(_ input: KeyInput) {
        switch input {
        case .text(let s): screen += s
        case .backspace: if !screen.isEmpty { screen.removeLast() }
        case .newline: screen += "\n"
        case .tab: screen += "\t"
        case .reset: break
        }
        let action = engine.handle(input, check: fakeCheck)
        if let plan = action.plan {
            apply(plan)
            if case .correct(let c) = action { engine.didApply(c) }
            actions.append(action)
        }
    }

    mutating func type(_ s: String) {
        for ch in s { press(.text(String(ch))) }
    }

    mutating func apply(_ plan: KeyPlan) {
        for _ in 0..<plan.backspaces where !screen.isEmpty { screen.removeLast() }
        screen += plan.text
    }
}

func typed(_ s: String) -> String {
    var t = Typist()
    t.type(s)
    return t.screen
}

/// Types `s` with a checker that wants to change every word, and returns the words it was asked
/// about. A word the engine skips must never reach the checker, whatever the checker would say.
func wordsCheckedFixingEverything(_ s: String) -> [String] {
    var e = WordEngine()
    e.handle(.newline, check: { _ in nil })
    var asked: [String] = []
    for ch in s { e.handle(.text(String(ch)), check: { asked.append($0); return "zzz" }) }
    return asked
}

@Suite("Word engine")
struct WordEngineTests {
    @Test func fixesOnSpace() {
        #expect(typed("teh ") == "the ")
        #expect(typed("I will recieve it ") == "I will receive it ")
    }

    @Test func fixesOnImmediatePunctuation() {
        #expect(typed("teh, ") == "the, ")
        #expect(typed("adn; ") == "and; ")
        #expect(typed("wierd! ") == "weird! ")
        #expect(typed("wierd? ") == "weird? ")
    }

    @Test func fixesWithTrailingPeriodWhenSpaceFollows() {
        #expect(typed("see you tomorow. ") == "see you tomorrow. ")
        #expect(typed("(teh) ") == "(the) ")
        #expect(typed("\"teh\" ") == "\"the\" ")
    }

    @Test func periodAloneDoesNotTrigger() {
        // A dot might be part of a domain or file name, so wait for the space.
        #expect(typed("teh.") == "teh.")
        #expect(typed("teh.com ") == "teh.com ")
        #expect(wordsCheckedFixingEverything("teh.com ").isEmpty)
    }

    @Test func keepsCapitalization() {
        #expect(typed("Teh end ") == "The end ")
        #expect(typed("Recieve ") == "Receive ")
    }

    @Test func multiWordReplacement() {
        #expect(typed("thanks alot ") == "thanks a lot ")
    }

    @Test func doesNotFixOnReturnOrTab() {
        var t = Typist()
        t.type("teh")
        t.press(.newline)
        #expect(t.screen == "teh\n")
        t.type("teh")
        t.press(.tab)
        #expect(t.screen == "teh\nteh\t")
        #expect(t.actions.isEmpty)
    }

    @Test func correctWordsAreUntouched() {
        let s = "The quick brown fox jumps over the lazy dog. "
        #expect(typed(s) == s)
    }

    @Test func correctionPlanCounts() {
        let c = Correction(original: "teh", replacement: "the", suffix: " ")
        #expect(c.plan == KeyPlan(backspaces: 4, text: "the "))
        #expect(c.undoPlan == KeyPlan(backspaces: 3, text: "teh"))
        let p = Correction(original: "tomorow", replacement: "tomorrow", suffix: ". ")
        #expect(p.plan == KeyPlan(backspaces: 9, text: "tomorrow. "))
        #expect(p.undoPlan == KeyPlan(backspaces: 9, text: "tomorow."))
    }

    @Test func deleteRightAfterFixUndoes() {
        var t = Typist()
        t.type("teh ")
        #expect(t.screen == "the ")
        t.press(.backspace)
        #expect(t.screen == "teh")
        if case .undo = t.actions.last {} else { Issue.record("expected undo") }
        // Continuing does not fix the word again.
        t.type(" ")
        #expect(t.screen == "teh ")
        // And it stays ignored for the rest of the session.
        t.type("and teh ")
        #expect(t.screen == "teh and teh ")
    }

    @Test func undoAfterPunctuationFix() {
        var t = Typist()
        t.type("teh,")
        #expect(t.screen == "the,")
        t.press(.backspace)
        #expect(t.screen == "teh")
    }

    @Test func deleteLaterDoesNotUndo() {
        var t = Typist()
        t.type("teh x")
        t.press(.backspace)
        #expect(t.screen == "the ")
        #expect(t.actions.count == 1)
    }

    @Test func otherWordsStillFixedAfterUndo() {
        var t = Typist()
        t.type("teh ")
        t.press(.backspace)
        t.type(" recieve ")
        #expect(t.screen == "teh receive ")
    }

    @Test func backspaceEditsCurrentWord() {
        var t = Typist()
        t.type("tex")
        t.press(.backspace)
        t.type("h ")
        #expect(t.screen == "the ")
    }

    @Test func backspacePastWordStartTaints() {
        var t = Typist()
        t.type("hello ")
        t.press(.backspace)      // caret now right after "hello"
        t.type("teh ")           // real word on screen is "helloteh"
        #expect(t.screen == "helloteh ")
        t.type("teh ")           // next clean word is fixed again
        #expect(t.screen == "helloteh the ")
    }

    @Test func resetTaintsUntilNextWord() {
        var t = Typist()
        t.type("some ")
        t.press(.reset)          // click: caret could be mid-word
        t.type("teh ")
        #expect(t.screen == "some teh ")
        t.type("teh ")
        #expect(t.screen == "some teh the ")
    }

    @Test func startsTaintedUntilFirstBoundary() {
        var e = WordEngine()
        #expect(e.tainted)
        _ = e.handle(.text("t"), check: fakeCheck)
        _ = e.handle(.text("e"), check: fakeCheck)
        _ = e.handle(.text("h"), check: fakeCheck)
        #expect(e.handle(.text(" "), check: fakeCheck) == .none)
        #expect(!e.tainted)
    }

    @Test func newlineStartsClean() {
        var t = Typist()
        t.press(.reset)
        t.press(.newline)
        t.type("teh ")
        #expect(t.screen == "\nthe ")
    }

    @Test func nothingInsideBackticks() {
        #expect(typed("run `teh` now ") == "run `teh` now ")
        #expect(wordsCheckedFixingEverything("run `teh` now ") == ["run", "now"])
        #expect(typed("run `foo teh bar` teh ") == "run `foo teh bar` the ")
    }

    @Test func backticksResetOnNewline() {
        var t = Typist()
        t.type("open `code")
        t.press(.newline)
        t.type("teh ")
        #expect(t.screen == "open `code\nthe ")
    }

    @Test func checkerIsOnlyAskedAtWordEnd() {
        var e = WordEngine()
        _ = e.handle(.newline, check: { _ in nil })
        var asked: [String] = []
        for ch in "teh" { _ = e.handle(.text(String(ch)), check: { asked.append($0); return nil }) }
        #expect(asked.isEmpty)
        _ = e.handle(.text(" "), check: { asked.append($0); return nil })
        #expect(asked == ["teh"])
    }

    @Test func bufferClearedWhenWordEnds() {
        var e = WordEngine()
        _ = e.handle(.newline, check: { _ in nil })
        for ch in "secret" { _ = e.handle(.text(String(ch)), check: { _ in nil }) }
        #expect(e.currentWord == "secret")
        _ = e.handle(.text(" "), check: { _ in nil })
        #expect(e.currentWord.isEmpty)
        for ch in "word" { _ = e.handle(.text(String(ch)), check: { _ in nil }) }
        _ = e.handle(.reset, check: { _ in nil })
        #expect(e.currentWord.isEmpty)
    }

    @Test func veryLongRunsAreDropped() {
        var e = WordEngine()
        _ = e.handle(.newline, check: { _ in nil })
        for _ in 0..<60 { _ = e.handle(.text("a"), check: { _ in nil }) }
        #expect(e.currentWord.count <= SkipRules.maxWordLength + 8)
        #expect(e.tainted)
    }

    @Test func rejectsUnsafeSuggestions() {
        #expect(WordEngine.acceptable("", for: "teh") == nil)
        #expect(WordEngine.acceptable("teh", for: "teh") == nil)
        #expect(WordEngine.acceptable("the\n", for: "teh") == nil)
        #expect(WordEngine.acceptable("a much much longer phrase", for: "teh") == nil)
        #expect(WordEngine.acceptable("the", for: "Teh") == "The")
        #expect(WordEngine.acceptable("English", for: "english") == "English")
    }

    @Test func multiCharacterTextEvents() {
        var t = Typist()
        t.press(.text("teh "))
        #expect(t.screen == "the ")
    }

    @Test func lowercaseIBecomesCapital() {
        #expect(typed("so i think ") == "so I think ")
    }
}
