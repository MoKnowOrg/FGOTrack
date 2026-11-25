import Foundation

/// What has been typed before, derived from the ledger itself, so it syncs across devices and
/// housemates and needs no separate storage. Powers merchant autocomplete and learned categories.
struct EntryMemory {
    struct Merchant: Equatable, Identifiable {
        let title: String
        let category: Category
        let lastAmount: Int64
        let uses: Int
        let lastUsed: Date
        var id: String { EntryMemory.key(title) }
    }
    /// Most-used first, then most recent.
    private(set) var merchants: [Merchant] = []
    /// Names typed into "Logged by" / "Contributor", most-used first.
    private(set) var people: [String] = []
    private var byKey: [String: Merchant] = [:]

    /// Placeholder titles that should never be suggested back.
    static let placeholderTitles: Set<String> = ["receipt to review"]

    init(ledger: Ledger, kind: EntryKind) {
        let source = ledger.active.filter { $0.kind == kind }.sorted { $0.date > $1.date }
        var grouped: [String: (latest: LedgerEntry, uses: Int)] = [:]
        var names: [String: (name: String, uses: Int)] = [:]
        for entry in source {
            let key = Self.key(entry.title)
            if !key.isEmpty, !Self.placeholderTitles.contains(key) {
                // `source` is newest first, so the first entry seen keeps its spelling, category and amount.
                grouped[key] = grouped[key].map { ($0.latest, $0.uses + 1) } ?? (entry, 1)
            }
            let person = entry.person.trimmed, personKey = Self.key(person)
            if !personKey.isEmpty { names[personKey] = names[personKey].map { ($0.name, $0.uses + 1) } ?? (person, 1) }
        }
        merchants = grouped.values.map { Merchant(title: $0.latest.title.trimmed, category: $0.latest.category, lastAmount: $0.latest.amount, uses: $0.uses, lastUsed: $0.latest.date) }
            .sorted { $0.uses == $1.uses ? $0.lastUsed > $1.lastUsed : $0.uses > $1.uses }
        byKey = Dictionary(merchants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        people = names.values.sorted { $0.uses == $1.uses ? $0.name < $1.name : $0.uses > $1.uses }.map(\.name)
    }

    /// Ranked matches for partly typed text: whole-title prefix, then word prefix, then anywhere.
    /// An exact match is left out because there is nothing left to complete.
    func suggestions(for text: String, limit: Int = 4) -> [Merchant] {
        let query = Self.key(text)
        guard !query.isEmpty else { return Array(merchants.prefix(limit)) }
        func rank(_ merchant: Merchant) -> Int? {
            let title = merchant.id
            if title == query { return nil }
            if title.hasPrefix(query) { return 0 }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
            return title.contains(query) ? 2 : nil
        }
        return merchants.compactMap { merchant in rank(merchant).map { (merchant, $0) } }
            .enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }
            .prefix(limit).map { $0.element.0 }
    }
    /// The category last used for exactly this merchant, if it has been seen before.
    func category(for title: String) -> Category? { byKey[Self.key(title)]?.category }
    func merchant(named title: String) -> Merchant? { byKey[Self.key(title)] }
    func people(matching text: String, limit: Int = 3) -> [String] {
        let query = Self.key(text)
        return Array(people.filter { query.isEmpty || (Self.key($0).hasPrefix(query) && Self.key($0) != query) }.prefix(limit))
    }

    /// Case-, accent- and spacing-insensitive form used for matching.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Ledger {
    /// An existing expense that looks like the same bill: same source, same day and amount, and
    /// either the same merchant or a scanned receipt (whose OCR name may differ from a typed one).
    func possibleDuplicate(of entry: LedgerEntry, fromReceipt: Bool) -> LedgerEntry? {
        guard entry.kind == .expense else { return nil }
        let day = Self.calendar.startOfDay(for: entry.date), key = EntryMemory.key(entry.title)
        return active.first { other in
            other.id != entry.id && other.kind == .expense && other.funding == entry.funding && other.amount == entry.amount
                && Self.calendar.startOfDay(for: other.date) == day && (fromReceipt || EntryMemory.key(other.title) == key)
        }
    }
}
