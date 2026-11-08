import Foundation

/// One learned item. These fields are everything Keymend stores about a word: no sentences, no
/// neighbouring words, no app, document or website, and no time of day.
public struct LearnedItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case correction, undo, known
    }

    public enum Status: String, Codable, Sendable {
        /// Seen, but not yet often enough to do anything.
        case watching
        /// Waiting for the user's approval. Not active.
        case proposed
        case active
        /// The user said no. Kept so it isn't proposed again.
        case rejected
    }

    public var kind: Kind
    public var typed: String
    public var correction: String
    public var count: Int
    public var daysSeen: Int
    /// A day only, like 2026-11-02.
    public var lastSeen: String
    public var status: Status

    public var id: String { "\(kind.rawValue)|\(typed.lowercased())|\(correction.lowercased())" }

    public init(kind: Kind, typed: String, correction: String = "", count: Int = 1, daysSeen: Int = 1, lastSeen: String, status: Status = .watching) {
        self.kind = kind
        self.typed = typed
        self.correction = correction
        self.count = count
        self.daysSeen = daysSeen
        self.lastSeen = lastSeen
        self.status = status
    }
}

/// The rules made from the store, in the form the keyboard bridge reads them.
public struct LearnedRules: Equatable, Sendable {
    private var corrections: [String: String] = [:]
    private var blockedFixes: Set<String> = []
    private var knownWords: Set<String> = []

    public init() {}

    public init(items: [LearnedItem]) {
        for item in items where item.status == .active {
            switch item.kind {
            case .correction: corrections[item.typed.lowercased()] = item.correction
            case .undo: blockedFixes.insert(Self.pair(item.typed, item.correction))
            case .known: knownWords.insert(item.typed.lowercased())
            }
        }
    }

    private static func pair(_ a: String, _ b: String) -> String {
        a.lowercased() + "\n" + b.lowercased()
    }

    /// Applies what was learned on top of the spell checker's answer.
    public func applied(to word: String, verdict: () -> SpellVerdict) -> SpellVerdict {
        let key = word.lowercased()
        if knownWords.contains(key) { return .correct }
        let answer = corrections[key].map(SpellVerdict.fix) ?? verdict()
        if case .fix(let s) = answer, blockedFixes.contains(Self.pair(word, s)) { return .correct }
        return answer
    }
}

/// Everything learned, and the rules for what each signal does. No clock of its own: the caller
/// passes the day, so behaviour is exact and testable.
public struct LearningStore: Codable, Equatable, Sendable {
    public static let correctionThreshold = (count: 3, days: 2)
    public static let undoThreshold = 2
    public static let knownThreshold = (count: 5, days: 3)
    /// Items never made active are forgotten after this many days unseen.
    public static let forgetAfterDays = 90
    /// A hard limit, so the store stays small whatever happens.
    public static let maxItems = 5000

    public private(set) var items: [LearnedItem] = []

    public init(items: [LearnedItem] = []) {
        self.items = items
    }

    public var rules: LearnedRules { LearnedRules(items: items) }
    public var proposedCount: Int { items.filter { $0.status == .proposed }.count }

    /// Items for the review screen, most frequent first.
    public func ranked(matching search: String = "") -> [LearnedItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return items
            .filter { q.isEmpty || $0.typed.localizedCaseInsensitiveContains(q) || $0.correction.localizedCaseInsensitiveContains(q) }
            .sorted { ($0.count, $1.typed.lowercased()) > ($1.count, $0.typed.lowercased()) }
    }

    /// Records what the watcher noticed. `verdict` is Apple's spell checker; only words it flags
    /// are ever kept. A word it didn't answer about in time (`.timedOut`) is never kept.
    public mutating func record(_ event: LearningEvent, day: String, verdict: (String) -> SpellVerdict) {
        switch event {
        case .corrected(let typed, let corrected):
            guard LearningRules.isLearnable(typed), LearningRules.isLearnable(corrected),
                  LearningRules.isCloseSpelling(typed, corrected), verdict(typed).isFlagged else { return }
            bump(.correction, typed: typed.lowercased(), correction: corrected, day: day)
        case .undone(let typed, let replacement):
            guard LearningRules.isLearnable(typed), LearningRules.isLearnable(replacement),
                  LearningRules.isCloseSpelling(typed, replacement), verdict(typed).isFlagged else { return }
            bump(.undo, typed: typed.lowercased(), correction: replacement.lowercased(), day: day)
        case .keptWord(let word):
            guard LearningRules.isLearnable(word), verdict(word) == .unknown else { return }
            bump(.known, typed: word, correction: "", day: day)
        }
    }

    private mutating func bump(_ kind: LearnedItem.Kind, typed: String, correction: String, day: String) {
        let key = LearnedItem(kind: kind, typed: typed, correction: correction, lastSeen: day).id
        if let i = items.firstIndex(where: { $0.id == key }) {
            items[i].count += 1
            if items[i].lastSeen != day {
                items[i].daysSeen += 1
                items[i].lastSeen = day
            }
            promote(&items[i])
        } else if items.count < LearningStore.maxItems {
            var item = LearnedItem(kind: kind, typed: typed, correction: correction, lastSeen: day)
            promote(&item)
            items.append(item)
        }
    }

    /// Anything that makes Keymend do less applies by itself. Anything that types something new
    /// waits for the user.
    private func promote(_ item: inout LearnedItem) {
        guard item.status == .watching else { return }
        switch item.kind {
        case .correction:
            let need = LearningStore.correctionThreshold
            if item.count >= need.count, item.daysSeen >= need.days { item.status = .proposed }
        case .undo:
            if item.count >= LearningStore.undoThreshold { item.status = .active }
        case .known:
            let need = LearningStore.knownThreshold
            if item.count >= need.count, item.daysSeen >= need.days { item.status = .active }
        }
    }

    // MARK: Review

    public mutating func approve(_ id: LearnedItem.ID) { setStatus(id, .active) }
    public mutating func reject(_ id: LearnedItem.ID) { setStatus(id, .rejected) }

    private mutating func setStatus(_ id: LearnedItem.ID, _ status: LearnedItem.Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    /// Changes a rule's correction and approves it. Returns false for anything but a plain word.
    @discardableResult
    public mutating func edit(_ id: LearnedItem.ID, correction: String) -> Bool {
        let c = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LearningRules.isLearnable(c), let i = items.firstIndex(where: { $0.id == id }), items[i].kind == .correction else { return false }
        items[i].correction = c
        items[i].status = .active
        // Editing can make two rows the same rule; keep the edited one.
        let newID = items[i].id
        var seen = false
        items.removeAll { item in
            guard item.id == newID else { return false }
            if item.status == .active && !seen { seen = true; return false }
            return true
        }
        return true
    }

    /// Forgets an item, so it can come back if it's seen again.
    public mutating func delete(_ id: LearnedItem.ID) {
        items.removeAll { $0.id == id }
    }

    /// The only way an email or handle gets in: the user adds it by hand.
    @discardableResult
    public mutating func addByHand(_ raw: String, day: String) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 64, !word.contains(where: \.isWhitespace) else { return false }
        let new = LearnedItem(kind: .known, typed: word, lastSeen: day, status: .active)
        if let i = items.firstIndex(where: { $0.id == new.id }) {
            items[i].status = .active
        } else {
            guard items.count < LearningStore.maxItems else { return false }
            items.append(new)
        }
        return true
    }

    public mutating func clear() {
        items = []
    }

    /// Forgets items that were never made active and haven't been seen for 90 days. Active and
    /// rejected items stay until the user deletes them, because a rejection has to be remembered.
    public mutating func forgetStale(today: Date, calendar: Calendar = .current) {
        items.removeAll { item in
            guard item.status == .watching || item.status == .proposed else { return false }
            guard let seen = LearningStore.date(fromDay: item.lastSeen, calendar: calendar) else { return true }
            let age = calendar.dateComponents([.day], from: seen, to: today).day ?? 0
            return age >= LearningStore.forgetAfterDays
        }
    }

    private static func date(fromDay day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Adds another store's items: the higher count and later day win, and rejected stays rejected.
    public mutating func merge(_ other: LearningStore) {
        for incoming in other.items {
            guard let i = items.firstIndex(where: { $0.id == incoming.id }) else {
                if items.count < LearningStore.maxItems { items.append(incoming) }
                continue
            }
            items[i].count = max(items[i].count, incoming.count)
            items[i].daysSeen = max(items[i].daysSeen, incoming.daysSeen)
            items[i].lastSeen = max(items[i].lastSeen, incoming.lastSeen)
            if items[i].status == .rejected || incoming.status == .rejected {
                items[i].status = .rejected
            } else if incoming.status == .active {
                items[i].status = .active
            } else if incoming.status == .proposed, items[i].status == .watching {
                items[i].status = .proposed
            }
        }
    }
}
