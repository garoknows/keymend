import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import KeymendCore

// beta.2 froze a real Mac when Accessibility was switched off while the bar was showing. The pick
// keys now use system hot keys, registered only while the bar shows, instead of an active event
// tap. Hot keys need no permission and put nothing in the system's input path.

/// Records hot key registrations instead of making them.
private final class FakeRegistrar: HotKeyRegistering, @unchecked Sendable {
    struct Key: Equatable { var keyCode: UInt32; var modifiers: UInt32; var id: UInt32 }
    private let lock = NSLock()
    private var _keys: [Key] = []
    private var _refuseAfter: Int?
    var keys: [Key] { lock.withLock { _keys } }
    /// Refuse every registration once this many are in place.
    var refuseAfter: Int? {
        get { lock.withLock { _refuseAfter } }
        set { lock.withLock { _refuseAfter = newValue } }
    }
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) -> Bool {
        lock.withLock {
            if let limit = _refuseAfter, _keys.count >= limit { return false }
            _keys.append(Key(keyCode: keyCode, modifiers: modifiers, id: id))
            return true
        }
    }
    func unregisterAll() { lock.withLock { _keys.removeAll() } }
}

private struct Completing: SpellChecking {
    func verdict(for word: String) -> SpellVerdict { .correct }
    func hasLearnedWord(_ word: String) -> Bool { false }
    func completions(for partial: String) -> [String] {
        ["hello", "help", "helmet"].filter { $0.hasPrefix(partial.lowercased()) }
    }
}

private final class Bar: @unchecked Sendable {
    private let lock = NSLock()
    private var _bar: SuggestionBar?
    func record(_ bar: SuggestionBar?) { lock.withLock { _bar = bar } }
    var bar: SuggestionBar? { lock.withLock { _bar } }
}

private func barHarness(_ modifier: PickModifier = .controlOption) -> (Harness, Bar) {
    let h = Harness(checker: Completing())
    let log = Bar()
    h.bridge.hooks.didChangeSuggestions = { log.record($0) }
    h.bridge.modifiersHeld = { false }
    h.bridge.pickKeys = PickKeys(modifier: modifier)
    h.bridge.suggestionsAllowed = true
    h.bridge.drain()
    return (h, log)
}

@Suite("Pick keys as hot keys, no active tap")
struct PickHotKeyTests {
    @Test func theHotKeysAreTheNumberRowWithTheChosenModifiers() {
        let r = FakeRegistrar()
        let backend = HotKeyPickBackend(registrar: r, modifier: { .controlOption })
        #expect(backend.start())
        #expect(r.keys.map(\.keyCode) == [UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3), UInt32(kVK_ANSI_4)])
        #expect(r.keys.allSatisfy { $0.modifiers == UInt32(controlKey | optionKey) })
        #expect(r.keys.map { HotKeyPickBackend.slot(forHotKeyID: $0.id) } == [0, 1, 2, 3])
        backend.stop()
        #expect(r.keys.isEmpty)
    }

    @Test(arguments: [(PickModifier.option, UInt32(optionKey)), (.controlOption, UInt32(controlKey | optionKey)), (.optionShift, UInt32(optionKey | shiftKey))])
    func eachSettingRegistersItsOwnModifiers(_ modifier: PickModifier, _ carbon: UInt32) {
        let r = FakeRegistrar()
        #expect(HotKeyPickBackend(registrar: r, modifier: { modifier }).start())
        #expect(r.keys.allSatisfy { $0.modifiers == carbon })
    }

    /// macOS refuses some combinations (recent versions refuse Option alone). Then none of the
    /// keys stay registered, and the bar still works by clicking.
    @Test func aRefusedKeyLeavesNoneRegistered() {
        let r = FakeRegistrar()
        r.refuseAfter = 2
        #expect(!HotKeyPickBackend(registrar: r, modifier: { .option }).start())
        #expect(r.keys.isEmpty)
    }

    @Test func otherHotKeysArentPickKeys() {
        #expect(HotKeyPickBackend.slot(forHotKeyID: 1) == nil)            // the pause shortcut
        #expect(HotKeyPickBackend.slot(forHotKeyID: HotKeyPickBackend.firstID + 4) == nil)
    }

    @Test func pressingTheHotKeyPicksAndReleasingItLetsGo() throws {
        let (h, log) = barHarness()
        h.type("he")
        _ = try #require(log.bar)
        #expect(h.bridge.hotKey(slot: 1, pressed: true) == .pick(slot: 1))
        h.bridge.drain()
        #expect(h.field.text == "hello ")
        #expect(h.bridge.isHoldingPickKey)
        #expect(h.bridge.hotKey(slot: 1, pressed: false) == .swallow)
        #expect(!h.bridge.isHoldingPickKey)
    }

    /// The listening tap may see the key press before the hot key arrives. It mustn't count as
    /// a shortcut, which would end the word and hide the bar before the pick lands.
    @Test func aPickKeySeenFirstByTheListeningTapDoesntEndTheWord() throws {
        let (h, log) = barHarness()
        h.type("he")
        _ = try #require(log.bar)
        let press = RawKeyEvent(kind: .keyDown, keyCode: PickKeys.numberRow[1], flags: PickModifier.controlOption.flags, characters: "2")
        h.bridge.receive(press)
        h.bridge.drain()
        #expect(log.bar?.typed == "he")
        #expect(h.bridge.hotKey(slot: 1, pressed: true) == .pick(slot: 1))
        h.bridge.drain()
        #expect(h.field.text == "hello ")
    }

    @Test func aHotKeyForASlotThatIsntShowingDoesNothing() throws {
        let (h, log) = barHarness()
        h.type("zq")
        _ = try #require(log.bar)
        #expect(h.bridge.hotKey(slot: 2, pressed: true) == .pass)
        h.bridge.drain()
        #expect(h.field.text == "zq")
    }
}
