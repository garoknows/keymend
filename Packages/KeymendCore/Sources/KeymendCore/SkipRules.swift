/// A finished token split into leading punctuation, the word itself and trailing punctuation.
/// "(teh)," becomes prefix "(", core "teh", trailing "),".
public struct Token: Equatable, Sendable {
    public var prefix: String
    public var core: String
    public var trailing: String

    static let leadingPunctuation: Set<Character> = ["(", "\"", "'", "\u{201C}", "\u{2018}", "[", "\u{00BF}", "\u{00A1}"]
    static let trailingPunctuation: Set<Character> = [".", ",", ":", ";", "!", "?", ")", "\"", "'", "\u{201D}", "\u{2019}", "]", "\u{2026}"]

    public init(prefix: String, core: String, trailing: String) {
        self.prefix = prefix
        self.core = core
        self.trailing = trailing
    }

    public init(parsing raw: String) {
        var chars = Array(raw)
        var start = 0
        while start < chars.count, Token.leadingPunctuation.contains(chars[start]) { start += 1 }
        var end = chars.count
        while end > start, Token.trailingPunctuation.contains(chars[end - 1]) { end -= 1 }
        prefix = String(chars[0..<start])
        core = String(chars[start..<end])
        trailing = String(chars[end..<chars.count])
        chars.removeAll()
    }
}

/// Why a word was left alone. Used by tests and nothing else; never logged.
public enum SkipReason: Equatable, Sendable {
    case empty
    case tooLong
    case containsDigit
    case allCaps
    case mixedCase
    case mention       // @name or #tag
    case email
    case url
    case path
    case code          // inside backticks or contains code-like symbols
    case notAWord      // anything other than letters and apostrophes
}

public enum SkipRules {
    /// Longest word Keymend will consider. Longer runs are almost never prose.
    public static let maxWordLength = 40

    static let apostrophes: Set<Character> = ["'", "\u{2019}"]
    static let codeSymbols: Set<Character> = ["_", "=", "<", ">", "{", "}", "|", "*", "$", "%", "^", "&", "+", "\\", "`"]

    /// Returns a reason to leave this token untouched, or nil if the word may be checked.
    /// `insideBackticks` is true when an odd number of backticks came earlier on this line.
    public static func skipReason(for raw: String, insideBackticks: Bool = false) -> SkipReason? {
        if insideBackticks { return .code }
        if raw.isEmpty { return .empty }
        if raw.contains("`") { return .code }
        if raw.first == "@" || raw.first == "#" { return .mention }
        if raw.contains("@") { return .email }
        if raw.contains("://") || raw.lowercased().hasPrefix("www.") { return .url }
        if raw.contains("/") || raw.first == "~" || raw.contains("\\") { return .path }
        if raw.contains(where: { $0.isNumber }) { return .containsDigit }
        if raw.contains(where: { codeSymbols.contains($0) }) { return .code }

        let token = Token(parsing: raw)
        let core = token.core
        if core.isEmpty { return .empty }
        if core.count > maxWordLength { return .tooLong }
        // Dots or other punctuation inside the word: domains (example.com), abbreviations (e.g), file names.
        guard core.allSatisfy({ $0.isLetter || apostrophes.contains($0) }) else {
            if core.contains(".") { return .url }
            return .notAWord
        }
        guard let first = core.first, first.isLetter else { return .notAWord }
        let letters = core.filter { $0.isLetter }
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) { return .allCaps }
        // Capitals after the first letter: iPhone, macOS, McDonald, camelCase.
        if letters.dropFirst().contains(where: { $0.isUppercase }) { return .mixedCase }
        return nil
    }
}
