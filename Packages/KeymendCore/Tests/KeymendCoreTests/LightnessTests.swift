import Foundation
import Testing
@testable import KeymendCore

@Suite("Light on the Mac", .serialized)
struct LightnessTests {
    /// Each keystroke must cost a tiny fraction of the time between keys. At 120 wpm keys
    /// arrive every ~100 ms; 0.5% CPU allows ~0.5 ms of work per key.
    @Test func keystrokeCostIsTiny() {
        let h = Harness()
        let text = String(repeating: "The quick brown fox jumps over teh lazy dog, adn then some. ", count: 60)
        let events = text.map { keyEvent($0) }
        let start = DispatchTime.now().uptimeNanoseconds
        for e in events {
            h.field.apply(e)
            h.bridge.receive(e, type: .keyDown)
        }
        h.bridge.drain()
        let perKeyMicros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000 / Double(events.count)
        #expect(perKeyMicros < 500, "per key: \(perKeyMicros) µs")
    }

    /// The engine never holds more than one word, however much is typed.
    @Test func memoryStaysBounded() {
        var e = WordEngine()
        _ = e.handle(.newline, check: { _ in nil })
        var longest = 0
        for ch in String(repeating: "lorem ipsum dolor sit amet ", count: 500) + String(repeating: "x", count: 5000) {
            _ = e.handle(.text(String(ch)), check: { _ in nil })
            longest = max(longest, e.currentWord.count)
        }
        #expect(longest <= SkipRules.maxWordLength + 8)
    }

    /// Typing a unique word through the full bridge, with learning on, a real encrypted vault on
    /// disk, and the word fixed by Keymend, corrected by the user and learned, leaves no readable
    /// trace in any file this process can write: the temp folders, the user's caches, the app's
    /// container and preferences. The vault file holds only ciphertext.
    @Test func typedTextNeverReachesDisk() throws {
        let marker = Self.lettersOnlyMarker()
        let typo = marker + "q"                  // Keymend fixes this to the marker
        let checker = MarkerChecker(marker: marker, typo: typo)
        let h = Harness(checker: checker)
        let store = LockedStore()
        h.bridge.hooks.didLearn = { event, verdict in store.record(event, verdict) }
        h.bridge.learningCaptures = true
        h.bridge.drain()

        // 1. Typed with a typo that Keymend fixes.
        h.type("\nsecret phrase \(typo) end ")
        #expect(h.field.text.contains("\(marker) end "))
        #expect(h.fixes.value == 1)
        // 2. Typed and kept as is (the checker flags it with no fix, so learning keeps it).
        h.type("\n\(marker) again\n")
        // 3. Typed wrong and corrected by hand within a few seconds.
        h.type("\n\(marker)zz")
        h.backspace(); h.backspace()
        h.type(" end\n")

        // It really was learned, so this test can fail if learning ever writes plain text.
        let learned = store.store
        #expect(learned.items.contains { $0.typed.lowercased() == marker })

        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYMEND_TEST_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("lightness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vaultURL = folder.appendingPathComponent("learning.keymend")
        let vault = LearningVault(fileURL: vaultURL, keys: MemoryKey())
        try vault.save(learned)
        #expect(try vault.load() == learned)

        let bytes = try Data(contentsOf: vaultURL)
        #expect(bytes.range(of: Data(marker.utf8)) == nil, "the vault file holds the word in plain text")
        #expect(bytes.range(of: Data(marker.uppercased().utf8)) == nil)

        let found = Self.filesContaining(marker, in: Self.placesTheAppCanWrite(plus: folder))
        #expect(found.isEmpty, "found typed text in \(found.map(\.lastPathComponent))")
    }

    /// The scan above must be able to find plain text, or its empty result means nothing.
    @Test func theDiskScanFindsPlainText() throws {
        let marker = Self.lettersOnlyMarker()
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYMEND_TEST_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("lightness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("before \(marker) after".utf8).write(to: folder.appendingPathComponent("planted.txt"))
        #expect(Self.filesContaining(marker, in: Self.placesTheAppCanWrite(plus: folder)).map(\.lastPathComponent) == ["planted.txt"])
    }

    /// Random lowercase letters only: digits would be skipped by the engine and prove nothing.
    static func lettersOnlyMarker() -> String {
        let letters = Array("bcdfghjklmnpqrstvwxz")
        return "zq" + String((0..<10).map { _ in letters.randomElement()! }) + "xj"
    }

    static func placesTheAppCanWrite(plus extra: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var places = [
            extra,
            URL(fileURLWithPath: NSTemporaryDirectory()),
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Containers/io.github.garoknows.keymend"),
            home.appendingPathComponent("Library/Preferences"),
        ]
        if let dir = ProcessInfo.processInfo.environment["KEYMEND_TEST_DIR"] { places.append(URL(fileURLWithPath: dir)) }
        return places
    }

    /// Files changed in the last few minutes, under 5 MB, whose bytes contain `marker`.
    static func filesContaining(_ marker: String, in places: [URL]) -> [URL] {
        let fm = FileManager.default
        let needle = Data(marker.utf8)
        let since = Date().addingTimeInterval(-300)
        var found: [URL] = []
        var seen = Set<String>()
        for place in places {
            guard let walker = fm.enumerator(at: place, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { continue }
            for case let url as URL in walker {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true, let d = v?.contentModificationDate, d > since,
                      (v?.fileSize ?? 0) < 5_000_000, seen.insert(url.standardizedFileURL.path).inserted else { continue }
                if let data = try? Data(contentsOf: url), data.range(of: needle) != nil { found.append(url) }
            }
        }
        return found
    }
}

/// Fixes `typo` to `marker`, flags anything else starting with the marker's letters (misspelled,
/// no fix) so learning keeps it, and passes every other word as correct.
private struct MarkerChecker: SpellChecking {
    let marker: String
    let typo: String
    func verdict(for word: String) -> SpellVerdict {
        if word.lowercased() == typo { return .fix(marker) }
        if word.lowercased().hasPrefix(String(marker.prefix(4))) { return .unknown }
        return .correct
    }
    func hasLearnedWord(_ word: String) -> Bool { false }
}

/// The learning store the app keeps in memory, fed the way the app feeds it.
private final class LockedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _store = LearningStore()
    func record(_ e: LearningEvent, _ v: SpellVerdict) {
        lock.withLock { _store.record(e, day: "2026-11-08") { _ in v } }
    }
    var store: LearningStore { lock.withLock { _store } }
}
