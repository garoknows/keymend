import CoreGraphics

/// What the suggestion bar shows: the word as typed, then up to three completions.
/// Lives in memory only, and only while the bar is showing.
public struct SuggestionBar: Equatable, Sendable {
    /// Changes every time the bar changes, so a pick can never land on a different word.
    public let generation: UInt64
    public let typed: String
    public let completions: [String]

    public init(generation: UInt64, typed: String, completions: [String]) {
        self.generation = generation
        self.typed = typed
        self.completions = completions
    }

    /// Slot 0 is the word as typed; the rest are completions.
    public var choiceCount: Int { completions.count + 1 }
}

public enum SuggestionRules {
    public static let maxCompletions = 3

    /// Keeps only real completions of `typed`: plain words that start with it, spelled once
    /// each, capitalized the way the user started the word.
    public static func clean(_ raw: [String], typed: String, canType: (String) -> Bool = { _ in true }) -> [String] {
        let startsUpper = typed.first?.isUppercase == true
        var out: [String] = []
        for candidate in raw {
            guard candidate.count > typed.count, candidate.count <= SkipRules.maxWordLength,
                  candidate.lowercased().hasPrefix(typed.lowercased()),
                  candidate.allSatisfy({ $0.isLetter || SkipRules.apostrophes.contains($0) }) else { continue }
            let word = startsUpper && candidate.first?.isLowercase == true
                ? candidate.prefix(1).uppercased() + candidate.dropFirst()
                : candidate
            guard canType(word), !out.contains(word) else { continue }
            out.append(word)
            if out.count == maxCompletions { break }
        }
        return out
    }
}

/// The modifier held with the number keys. A setting, for keyboard layouts where Option plus a
/// number types something people need, like # or @.
public enum PickModifier: String, CaseIterable, Sendable {
    case option, controlOption, optionShift

    public var flags: CGEventFlags {
        switch self {
        case .option: return [.maskAlternate]
        case .controlOption: return [.maskControl, .maskAlternate]
        case .optionShift: return [.maskAlternate, .maskShift]
        }
    }

    public var label: String {
        switch self {
        case .option: return "Option + 1, 2, 3, 4"
        case .controlOption: return "Control + Option + 1, 2, 3, 4"
        case .optionShift: return "Option + Shift + 1, 2, 3, 4"
        }
    }
}

/// Which key press picks which slot. The number row's physical keys, whatever the layout.
public struct PickKeys: Equatable, Sendable {
    public static let numberRow: [UInt16] = [18, 19, 20, 21]
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    public var modifier: PickModifier

    public init(modifier: PickModifier = .option) {
        self.modifier = modifier
    }

    /// The slot this key press picks. Modifiers must match exactly, so Command-Option-1 and the
    /// like are never taken.
    public func slot(keyCode: UInt16, flags: CGEventFlags) -> Int? {
        guard flags.intersection(PickKeys.modifiers) == modifier.flags else { return nil }
        return PickKeys.numberRow.firstIndex(of: keyCode)
    }
}

/// Decides what the active tap does with a key. Everything is passed through except a pick key
/// for a slot the bar is showing, its auto-repeats and its release.
public struct PickKeyFilter: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case pass, swallow
        case pick(slot: Int)
    }

    public var keys: PickKeys
    /// How many choices the bar is showing. Zero means no key can be picked.
    public var choiceCount = 0
    /// The pick key still held down. Its repeats and release are swallowed too.
    public private(set) var heldKey: UInt16?

    public init(keys: PickKeys = PickKeys()) {
        self.keys = keys
    }

    public mutating func decide(_ e: RawKeyEvent) -> Decision {
        if e.isOwnEvent { return .pass }
        switch e.kind {
        case .keyDown:
            if e.keyCode == heldKey { return .swallow }
            guard let slot = keys.slot(keyCode: e.keyCode, flags: e.flags), slot < choiceCount else { return .pass }
            heldKey = e.keyCode
            choiceCount = 0
            return .pick(slot: slot)
        case .keyUp:
            guard e.keyCode == heldKey else { return .pass }
            heldKey = nil
            return .swallow
        default:
            return .pass
        }
    }

    public mutating func releaseHeldKey() {
        heldKey = nil
    }
}

/// Where the bar goes: bottom center of the front window, or of the screen if no window is known.
/// Keymend can't read the text cursor's position inside the App Sandbox.
public enum BarPlacement {
    public static let insetFromWindowBottom: CGFloat = 16

    /// - Parameters:
    ///   - window: the front window in screen coordinates with the origin at the top left, which
    ///     is how `CGWindowListCopyWindowInfo` reports it.
    ///   - primaryHeight: the height of the main display, to convert to AppKit coordinates.
    ///   - screens: each screen's visible frame, in AppKit coordinates. The first is the fallback.
    public static func origin(barSize: CGSize, window: CGRect?, primaryHeight: CGFloat, screens: [CGRect]) -> CGPoint {
        let fallback = screens.first ?? CGRect(origin: .zero, size: barSize)
        guard let window else {
            return CGPoint(x: fallback.midX - barSize.width / 2, y: fallback.minY + insetFromWindowBottom)
        }
        let flipped = flip(window, primaryHeight: primaryHeight)
        let center = CGPoint(x: flipped.midX, y: flipped.midY)
        let screen = screens.first { $0.contains(center) } ?? fallback
        let x = min(max(flipped.midX - barSize.width / 2, screen.minX), screen.maxX - barSize.width)
        let y = min(max(flipped.minY + insetFromWindowBottom, screen.minY), screen.maxY - barSize.height)
        return CGPoint(x: x, y: y)
    }

    /// Converts between top-left-origin and AppKit's bottom-left-origin screen coordinates.
    /// The same formula works in both directions.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
