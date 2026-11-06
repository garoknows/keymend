import AppKit
import Foundation
import Testing
@testable import KeymendCore

@Suite("Smart skips")
struct SkipRulesTests {
    @Test(arguments: ["teh", "Teh", "(teh),", "don't", "it\u{2019}s", "teh."])
    func plainWordsMayBeChecked(_ w: String) {
        #expect(SkipRules.skipReason(for: w) == nil)
    }

    @Test func allCaps() {
        #expect(SkipRules.skipReason(for: "TEH") == .allCaps)
        #expect(SkipRules.skipReason(for: "NASA,") == .allCaps)
    }

    @Test func numbers() {
        #expect(SkipRules.skipReason(for: "teh2") == .containsDigit)
        #expect(SkipRules.skipReason(for: "4th") == .containsDigit)
    }

    @Test func urls() {
        #expect(SkipRules.skipReason(for: "https://exmaple.com") == .url)
        #expect(SkipRules.skipReason(for: "www.exmaple.com") == .url)
        #expect(SkipRules.skipReason(for: "exmaple.com") == .url)
        #expect(SkipRules.skipReason(for: "e.g.") == .url)
    }

    @Test func emails() {
        #expect(SkipRules.skipReason(for: "someone@exmaple.com") == .email)
    }

    @Test func mentionsAndTags() {
        #expect(SkipRules.skipReason(for: "@teh") == .mention)
        #expect(SkipRules.skipReason(for: "#teh") == .mention)
    }

    @Test func paths() {
        #expect(SkipRules.skipReason(for: "~/Documnets") == .path)
        #expect(SkipRules.skipReason(for: "src/mian") == .path)
        #expect(SkipRules.skipReason(for: "C:\\teh") == .path)
    }

    @Test func code() {
        #expect(SkipRules.skipReason(for: "`teh`") == .code)
        #expect(SkipRules.skipReason(for: "teh", insideBackticks: true) == .code)
        #expect(SkipRules.skipReason(for: "snake_case") == .code)
        #expect(SkipRules.skipReason(for: "a=b") == .code)
    }

    @Test func mixedCase() {
        #expect(SkipRules.skipReason(for: "iPhone") == .mixedCase)
        #expect(SkipRules.skipReason(for: "camelCase") == .mixedCase)
    }

    @Test func hyphensAndOtherSymbols() {
        #expect(SkipRules.skipReason(for: "well-knwon") == .notAWord)
    }

    @Test func tooLong() {
        #expect(SkipRules.skipReason(for: String(repeating: "a", count: 41)) == .tooLong)
    }

    @Test func tokenParsing() {
        #expect(Token(parsing: "(teh),") == Token(prefix: "(", core: "teh", trailing: "),"))
        #expect(Token(parsing: "teh") == Token(prefix: "", core: "teh", trailing: ""))
        #expect(Token(parsing: "...") == Token(prefix: "", core: "", trailing: "..."))
    }

    @Test func engineHonoursEverySkip() {
        let samples = [
            "TEH ", "teh2 ", "https://teh.com ", "teh@exmaple.com ", "@teh ", "#teh ",
            "~/teh ", "`teh` ", "iTeh ", "teh_teh ",
        ]
        for s in samples { #expect(typed(s) == s, "changed: \(s)") }
    }
}

@Suite("Settings models")
struct SettingsTests {
    @Test func neverCorrectListStartsEmpty() {
        #expect(NeverCorrectList().words.isEmpty)
    }

    @Test func neverCorrectAddRemove() {
        var l = NeverCorrectList()
        let a1 = l.add("Zorblat"); #expect(a1)
        let a2 = l.add("zorblat"); #expect(!a2) // case-insensitive duplicate
        let a3 = l.add("two words"); #expect(!a3)
        let a4 = l.add("   "); #expect(!a4)
        #expect(l.contains("ZORBLAT"))
        l.remove("zorblat")
        #expect(!l.contains("Zorblat"))
    }

    @Test func defaultSkipListCoversThePRD() {
        let ids = Set(DefaultSkipList.bundleIDs)
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
                   "com.apple.dt.Xcode", "com.microsoft.Word", "com.apple.Notes", "com.apple.mail",
                   "com.apple.iWork.Pages", "com.apple.MobileSMS", "com.apple.Safari"] {
            #expect(ids.contains(id), "missing \(id)")
        }
    }

    @Test func dailyCountRollsOver() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d1 = Date(timeIntervalSince1970: 1_800_000_000)
        let d2 = d1.addingTimeInterval(86_400)
        var c = DailyFixCount()
        c.increment(on: d1, calendar: cal)
        c.increment(on: d1, calendar: cal)
        #expect(c.count(on: d1, calendar: cal) == 2)
        #expect(c.count(on: d2, calendar: cal) == 0)
        c.decrement(on: d1, calendar: cal)
        #expect(c.count(on: d1, calendar: cal) == 1)
        c.increment(on: d2, calendar: cal)
        #expect(c.count(on: d2, calendar: cal) == 1)
    }

    @Test func summaryText() {
        #expect(DailyFixCount.summary(0) == "No fixes yet today")
        #expect(DailyFixCount.summary(1) == "Fixed 1 typo today")
        #expect(DailyFixCount.summary(42) == "Fixed 42 typos today")
    }
}

/// The Mac's spell service runs as a separate system process. Some restricted shells
/// (for example a sandboxed build agent) cannot reach it; these tests then skip.
let spellServiceAvailable: Bool = withRealService("Spell service") {
    NSSpellChecker.shared.checkSpelling(of: "teh", startingAt: 0).location != NSNotFound
}

@Suite("Apple spell checker (on-device)")
struct AppleSpellCheckerTests {
    @Test(.enabled(if: spellServiceAvailable, "macOS spell service not reachable from this process"))
    func fixesCommonTypos() {
        withRealService("Spell service") {
            let c = AppleSpellChecker()
            #expect(c.correction(for: "teh") == "the")
            #expect(c.correction(for: "recieve") == "receive")
        }
    }

    @Test(.enabled(if: spellServiceAvailable, "macOS spell service not reachable from this process"))
    func leavesCorrectWordsAlone() {
        withRealService("Spell service") {
            let c = AppleSpellChecker()
            for w in ["the", "receive", "keyboard", "quietly"] {
                #expect(c.correction(for: w) == nil, "changed \(w)")
            }
        }
    }

    @Test func timeLimitGivesUp() {
        struct Slow: SpellChecking {
            func verdict(for word: String) -> SpellVerdict { Thread.sleep(forTimeInterval: 0.3); return .fix("x") }
            func hasLearnedWord(_ word: String) -> Bool { false }
        }
        let limited = TimeLimitedSpellChecker(Slow(), limit: .milliseconds(50))
        let start = Date()
        #expect(limited.correction(for: "teh") == nil)
        #expect(Date().timeIntervalSince(start) < 0.2)
    }
}
