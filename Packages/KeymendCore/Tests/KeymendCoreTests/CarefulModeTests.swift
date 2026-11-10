import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

/// All text in this file is made up. Every line is typed key by key through the real bridge.

private let dictionary: Set<String> = {
    let system = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
    var words = Set(system.split(separator: "\n").map { $0.lowercased() })
    // The system list leaves out most plurals and contractions.
    words.formUnion(["can't", "don't", "it's", "files", "results", "tests", "fixes", "words", "things", "looks"])
    return words
}()

/// The worst case: it wants to change every word that isn't in the dictionary, and always has
/// a confident suggestion. A line that stays unchanged here is protected by the rules alone.
struct WorstCaseChecker: SpellChecking {
    func verdict(for word: String) -> SpellVerdict {
        dictionary.contains(word.lowercased()) ? .correct : .fix("replacement")
    }
    func hasLearnedWord(_ word: String) -> Bool { false }
}

/// Behaves like a normal spell checker: fixes known typos, doesn't recognize some other words.
struct ProseChecker: SpellChecking {
    func verdict(for word: String) -> SpellVerdict {
        if word != "I", let fix = fakeCheck(word) { return .fix(fix) }
        return dictionary.contains(word.lowercased()) ? .correct : .unknown
    }
    func hasLearnedWord(_ word: String) -> Bool { false }
}

private func carefulHarness(_ checker: SpellChecking = WorstCaseChecker()) -> Harness {
    let h = Harness(checker: checker)
    h.bridge.isAppCareful = true
    h.press(specialKey(KeyCode.returnKey))   // Keymend has now seen the start of a line
    h.bridge.drain()
    h.clear()
    return h
}

/// Types a line, a space and Return, and expects nothing at all to have been changed.
private func expectUntouched(_ line: String, checker: SpellChecking = WorstCaseChecker(), sourceLocation: SourceLocation = #_sourceLocation) {
    let h = carefulHarness(checker)
    h.type(line + " \n")
    #expect(h.field.text == line + " \n", sourceLocation: sourceLocation)
    #expect(h.field.postedEventCount == 0, "Keymend typed something for: \(line)", sourceLocation: sourceLocation)
}

extension Harness {
    func clear() {
        while !field.text.isEmpty { field.apply(specialKey(KeyCode.delete)) }
    }
}

enum Corpus {
    static let listedCommands = [
        "cd ~/projcts/helo", "cd projcts", "ls teh recieve", "ls -la teh", "git comit -m teh", "git psuh orgin main",
        "git chekout mian", "gh pr creat --titel teh", "gh isue list wierd", "brew instal wget teh", "npm instal recieve",
        "npm run tset teh", "rm -rf teh recieve", "rm teh recieve wierd", "mv teh recieve", "cp teh recieve wierd",
        "sudo teh recieve wierd", "claude teh recieve wierd", "python manag recieve teh", "python3 teh recieve",
        "swift buld teh recieve", "xcodebuild teh recieve", "kubectl get teh recieve", "docker biuld teh",
        "ssh teh recieve", "curl teh recieve", "grep teh recieve wierd", "vim teh recieve", "make the teh recieve",
        "find the teh recieve", "cat the teh", "echo the quick teh recieve", "open the teh file",
    ]
    static let lineStartSymbols = [
        "!git statsu teh recieve", "! the quick teh recieve", "./buld teh recieve", "../tol teh recieve",
        "$HOME/bin/tool teh recieve", "$ the quick teh recieve", "/usr/local/bin/tol teh recieve", "/help the quick teh",
        "~/scrpts/run the quick teh", "FOO=bar the quick teh", "#the quick teh recieve", "--flag the quick teh",
        "-x the quick teh", "*the quick teh", "`the quick teh", "(cd the quick teh", "9 the quick teh",
        "\"the quick teh", "'the quick teh",
    ]
    static let codeWordsMidLine = [
        "the quick teh/recieve teh", "the quick src/main teh", "the quick back\\slash teh", "the quick config.yaml teh",
        "the quick foo_bar teh", "the quick --force teh", "the quick -x teh", "the quick well-known teh",
        "the quick a=b teh", "the quick $PATH teh", "the quick ~/path teh", "the quick me@example.com teh",
        "the quick @handle teh", "the quick https://example.com teh", "the quick word: teh", "the quick #tag teh",
        "the quick glob* teh", "the quick `code` teh", "the quick API teh", "the quick camelCase teh",
        "the quick v2 teh", "the quick 42 teh", "the quick (paren) teh", "the quick a|b teh",
    ]
    static let quoted = [
        "please say \"teh recieve\"", "please say 'teh recieve'", "please say \u{201C}teh recieve\u{201D}",
        "please say \u{2018}teh recieve\u{2019}", "the quick \"teh\" word", "the quick 'teh' word",
        "the quick \"teh recieve wierd", "the quick 'teh recieve wierd",
    ]
    static let code = [
        "def recieve(teh):", "for teh in recieve:", "import teh recieve", "from teh import recieve",
        "select teh from recieve", "if teh then recieve", "let teh recieve", "const recieve teh", "return the teh",
        "print the teh", "while the quick teh", "class the quick teh", "x = teh recieve",
    ]
    static let unknownFirstWord = [
        "gst teh recieve", "gcloudd auth lgoin", "wrnglr publsh teh", "kubctl gett teh recieve", "dokcer run the teh",
        "teh quick brown", "recieve the quick",
    ]
    static let shortCommands = [
        "foo", "foo bar", "wrangler publsh", "vault lgoin", "the recieve", "a teh", "x y teh", "b c d teh",
    ]
    /// Lines that can still change. They're unknown commands whose words read like a sentence.
    static let knownGaps: [(typed: String, whatChanges: String)] = [
        ("deploy the staging servr", "servr"),
        ("install the latest packge", "packge"),
        ("restart the main sevice", "sevice"),
        ("please run the build agian", "agian"),
        ("correct horse battery stapel", "stapel"),   // a passphrase at a prompt Secure Input missed
    ]
}

@Suite("Careful mode: commands stay exactly as typed", .serialized)
struct CarefulCommandTests {
    @Test(arguments: Corpus.listedCommands) func listedCommands(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.lineStartSymbols) func linesStartingWithSymbolsOrPaths(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.codeWordsMidLine) func codeLookingWordStopsTheLine(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.quoted) func quotedWords(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.code) func codeLines(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.unknownFirstWord) func unknownFirstWord(_ line: String) { expectUntouched(line) }
    @Test(arguments: Corpus.shortCommands) func shortLines(_ line: String) { expectUntouched(line) }

    @Test func commandsWithoutASpaceBeforeReturn() {
        let h = carefulHarness()
        h.type("the teh\nls\ngit psuh\n")
        #expect(h.field.text == "the teh\nls\ngit psuh\n")
        #expect(h.field.postedEventCount == 0)
        // Return never fixes, so the lines above can't fail by themselves. What matters is that a
        // command ended by Return turns the next line off, even when it reads like prose.
        let h2 = carefulHarness()
        h2.type("ls\nthe quick brown recieve \n")
        #expect(h2.field.text == "ls\nthe quick brown recieve \n")
        #expect(h2.field.postedEventCount == 0)
    }

    /// A typo only becomes fixable after two prose words, so each command word is followed by
    /// two of them here: only the command rule keeps these lines as typed.
    @Test(arguments: ["git", "ls", "swift", "npm", "python", "sudo", "brew", "for", "def", "import", "from", "select", "if", "let", "const"])
    func aCommandFirstWordProtectsTheWholeLine(_ command: String) {
        expectUntouched("\(command) the quick recieve")
    }

    @Test func theSameLineWithAnOrdinaryFirstWordIsFixed() {
        let h = carefulHarness()
        h.type("now the quick recieve ")
        #expect(h.field.postedEventCount > 0)
    }

    @Test func returnNeverFixes() {
        let h = carefulHarness(ProseChecker())
        h.type("the quick brown teh\n")
        #expect(h.field.text == "the quick brown teh\n")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func lineAfterACommandIsOff() {
        for first in ["ssh box\n", "sudo thing\n", "gst\n", "!thing\n"] {
            let h = carefulHarness(ProseChecker())
            h.type(first + "the quick brown teh recieve \n")
            #expect(h.field.text == first + "the quick brown teh recieve \n", "after \(first)")
        }
    }

    @Test func secondLineAfterACommandWorksAgain() {
        let h = carefulHarness(ProseChecker())
        h.type("ls\nnot a password\nthe quick brown teh ")
        #expect(h.field.text == "ls\nnot a password\nthe quick brown the ")
    }

    @Test func heredocAndContinuationTurnTheNextLineOff() {
        for first in ["the quick <<EOF \n", "the quick brown \\\n"] {
            let h = carefulHarness(ProseChecker())
            h.type(first + "the quick brown teh \n")
            #expect(h.field.text == first + "the quick brown teh \n", "after \(first)")
        }
    }

    @Test func codeBlockLastsAcrossLinesUntilClosed() {
        let h = carefulHarness(ProseChecker())
        h.type("```\nthe quick brown teh \nthe quick brown teh \n")
        #expect(h.field.postedEventCount == 0)
        h.type("```\nnot a word\nthe quick brown teh ")
        #expect(h.field.text.hasSuffix("the quick brown the "))
    }
}

@Suite("Careful mode: pasted text and lost track", .serialized)
struct CarefulLostTrackTests {
    private static let events: [(name: String, send: @Sendable (Harness) -> Void)] = [
        ("paste", { $0.press(specialKey(9, flags: .maskCommand)) }),
        ("control key", { $0.press(specialKey(0, flags: .maskControl)) }),
        ("arrow", { $0.press(specialKey(126)) }),
        ("tab", { $0.press(specialKey(KeyCode.tab)) }),
        ("escape", { $0.press(specialKey(KeyCode.escape)) }),
        ("option delete", { $0.press(specialKey(KeyCode.delete, flags: .maskAlternate)) }),
        ("click, the way a mouse paste starts", { h in
            let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            h.bridge.receive(click, type: .leftMouseDown)
        }),
    ]

    @Test func anythingKeymendCannotFollowTurnsOffTheRestOfTheLine() {
        for (name, send) in Self.events {
            let h = carefulHarness(ProseChecker())
            h.type("the quick brown ")
            send(h)
            h.bridge.drain()
            h.type("the quick brown teh recieve ")
            #expect(h.field.postedEventCount == 0, "after \(name)")
            // The next line, seen from its start, works again.
            h.type("\nthe quick brown teh ")
            #expect(h.field.postedEventCount > 0, "next line after \(name)")
        }
    }

    @Test func keysFromAnotherProgramAreNotTyping() {
        let h = carefulHarness(ProseChecker())
        h.type("the quick brown ")
        h.bridge.receive(RawKeyEvent(kind: .keyDown, keyCode: 0, characters: "x", isFromAnotherProgram: true))
        h.bridge.drain()
        // The leading space ends "x" as a word of its own if it was wrongly counted as typing,
        // and then "teh" would be fixed (the line already has three prose words).
        h.type(" teh ")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func anEventPostedByAProgramIsRecognized() {
        // This test process counts as "another program" for an event it made itself.
        #expect(RawKeyEvent(keyEvent("x"), type: .keyDown).isFromAnotherProgram)
    }

    @Test func keysFromAnotherProgramStillWorkOutsideCareful() {
        // The posted "h" finishes the word. If it were ignored, the engine would hold "te".
        let h = Harness()
        h.type("te")
        h.field.apply(keyEvent("h"))
        h.bridge.receive(RawKeyEvent(kind: .keyDown, keyCode: 4, characters: "h", isFromAnotherProgram: true))
        h.bridge.drain()
        h.type(" ")
        #expect(h.field.text == "the ")
        #expect(h.fixes.value == 1)
    }

    @Test func aLineNotSeenFromItsStartIsOff() {
        // Switching to the terminal: Keymend doesn't know what's on the line yet.
        let h = Harness(checker: ProseChecker())
        h.bridge.isAppCareful = true
        h.type("the quick brown teh ")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func deletingBackIntoTheLastWordTurnsOffTheLine() {
        let h = carefulHarness(ProseChecker())
        h.type("the quick ")
        h.backspace()   // the space
        h.backspace()   // into "quick", which Keymend no longer holds
        h.type("k brown teh ")
        #expect(h.field.postedEventCount == 0)
    }

    @Test func undoWorksAndThenTheLineStaysOff() {
        let h = carefulHarness(ProseChecker())
        h.type("the quick teh ")
        #expect(h.field.text == "the quick the ")
        h.backspace()
        #expect(h.field.text == "the quick teh")
        h.type(" and recieve ")
        #expect(h.field.text == "the quick teh and recieve ")
    }

    @Test func noFixWhenTheLayoutCannotTypeIt() {
        struct NoKeys: KeyOutput {
            let field: SimulatedTextField
            func perform(_ plan: KeyPlan) { field.perform(plan) }
            func canType(_ text: String) -> Bool { false }
        }
        let field = SimulatedTextField()
        let bridge = KeyboardBridge(output: NoKeys(field: field), checker: ProseChecker())
        bridge.secureInputCheck = { false }
        bridge.isAppCareful = true
        for e in "\nthe quick teh ".map({ keyEvent($0) }) {
            field.apply(e)
            var raw = RawKeyEvent(e, type: .keyDown)
            raw.isFromAnotherProgram = false
            bridge.receive(raw)
        }
        bridge.drain()
        #expect(field.postedEventCount == 0)
    }

    @Test func secureInputMeansNothingInCarefulMode() {
        let h = Harness(checker: ProseChecker(), secure: true)
        h.bridge.isAppCareful = true
        h.type("\nthe quick brown teh ")
        #expect(h.field.postedEventCount == 0)
    }
}

@Suite("Careful mode: plain-language typing is fixed", .serialized)
struct CarefulProseTests {
    @Test(arguments: [
        ("can you fix the wierd bug ", "can you fix the weird bug "),
        ("Please tell me if you recieve the results ", "Please tell me if you receive the results "),
        ("Make sure the plan is teh best one ", "Make sure the plan is the best one "),
        ("I think the plan is good, adn it works. ", "I think the plan is good, and it works. "),
        ("I think the plan is teh. Next ", "I think the plan is the. Next "),
        ("what do you think of teh plan? ", "what do you think of the plan? "),
        ("it's not teh same ", "it's not the same "),
    ])
    func fixes(_ pair: (String, String)) {
        let h = carefulHarness(ProseChecker())
        h.type(pair.0)
        #expect(h.field.text == pair.1)
    }

    @Test func eachNewMessageIsCheckedAfterReturn() {
        let h = carefulHarness(ProseChecker())
        h.type("the quick teh \n")
        h.type("not this one ")
        h.type("\nand one more teh ")
        #expect(h.field.text == "the quick the \nnot this one \nand one more the ")
    }

    /// The price of the prose gate, shown on purpose.
    @Test(arguments: [
        "teh plan is good",                    // the first word must be a real word
        "the teh plan is good",                // two correct words must come first
        "the quick zzqqx teh plan",            // a word with no confident fix stops the line
        "the quick well-known teh plan",       // so does a code-looking word
    ])
    func theGateLeavesTheseAlone(_ line: String) {
        expectUntouched(line, checker: ProseChecker())
    }
}

@Suite("Careful mode: known gaps", .serialized)
struct CarefulKnownGapTests {
    /// These lines are NOT protected, and the README says so. Each one is an unknown command or
    /// a passphrase whose words read exactly like a sentence. If a rule change makes one of these
    /// safe, this test fails: move the line into the protected lists and update the README.
    @Test(arguments: Corpus.knownGaps)
    func theseCanStillChange(_ gap: (typed: String, whatChanges: String)) {
        let h = carefulHarness()
        h.type(gap.typed + " ")
        #expect(h.field.text == gap.typed.replacingOccurrences(of: gap.whatChanges, with: "replacement") + " ")
    }
}

@Suite("App modes")
struct AppModeTests {
    @Test func ghosttyIsCarefulByDefaultAndOtherTerminalsAreSkipped() {
        let skip = DefaultSkipList.bundleIDs, careful = DefaultCarefulList.bundleIDs
        #expect(careful == ["com.mitchellh.ghostty"])
        #expect(AppModePolicy.mode(for: "com.mitchellh.ghostty", skipList: skip, carefulList: careful) == .careful)
        for id in AppModePolicy.terminals where id != "com.mitchellh.ghostty" {
            #expect(AppModePolicy.mode(for: id, skipList: skip, carefulList: careful) == .skip, "\(id)")
        }
    }

    @Test func aTerminalIsNeverPlainOn() {
        for id in AppModePolicy.terminals {
            #expect(AppModePolicy.mode(for: id, skipList: [], carefulList: []) == .careful, "\(id)")
        }
    }

    @Test func skipWinsSoATerminalCanBeTurnedOffQuickly() {
        #expect(AppModePolicy.mode(for: "com.mitchellh.ghostty", skipList: ["com.mitchellh.ghostty"], carefulList: ["com.mitchellh.ghostty"]) == .skip)
    }

    @Test func otherAppsAreOnUnlessListed() {
        #expect(AppModePolicy.mode(for: "com.example.chat", skipList: [], carefulList: []) == .on)
        #expect(AppModePolicy.mode(for: "com.example.chat", skipList: [], carefulList: ["com.example.chat"]) == .careful)
    }
}

/// The same lines through Apple's real spell checker, where it's available (it is on CI; the
/// local sandbox blocks it). The results for prose depend on Apple's dictionary, so only the
/// protected lines and an obvious typo are checked.
@Suite("Careful mode with the real spell checker", .serialized)
struct CarefulRealCheckerTests {
    @Test(.enabled(if: spellServiceAvailable, "macOS spell service not reachable from this process"))
    func protectedLinesStayExactlyAsTyped() {
        let lines = Corpus.listedCommands + Corpus.lineStartSymbols + Corpus.codeWordsMidLine + Corpus.quoted + Corpus.code + Corpus.unknownFirstWord
        withRealService("Spell service", seconds: 120) {
            for line in lines {
                expectUntouched(line, checker: AppleSpellChecker())
            }
        }
    }

    @Test(.enabled(if: spellServiceAvailable, "macOS spell service not reachable from this process"))
    func plainLanguageIsFixed() {
        withRealService("Spell service") {
            let h = carefulHarness(AppleSpellChecker())
            h.type("can you fix the teh ")
            #expect(h.field.text == "can you fix the the ")
        }
    }
}
