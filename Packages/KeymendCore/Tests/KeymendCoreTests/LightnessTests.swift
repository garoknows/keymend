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

    /// Typing a unique phrase through the full bridge leaves no trace in any file this
    /// process can write: the temp folder, the user's caches and the app's would-be container.
    @Test func typedTextNeverReachesDisk() throws {
        let marker = "zqxj" + String(UInt32.random(in: 100_000...999_999)) + "plover"
        let h = Harness()
        h.type("secret phrase \(marker) teh end ")
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let places = [
            URL(fileURLWithPath: NSTemporaryDirectory()),
            home.appendingPathComponent("Library/Containers/io.github.garoknows.keymend"),
            home.appendingPathComponent("Library/Preferences"),
        ]
        let since = Date().addingTimeInterval(-120)
        for place in places {
            guard let walker = fm.enumerator(at: place, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let d = v?.contentModificationDate, d > since, (v?.fileSize ?? 0) < 5_000_000 else { continue }
                if let data = try? Data(contentsOf: url) {
                    #expect(data.range(of: Data(marker.utf8)) == nil, "found typed text in \(url.lastPathComponent)")
                }
            }
        }
    }
}
