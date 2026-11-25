import Foundation

enum Category: String, Codable, CaseIterable, Identifiable {
    case rent = "Rent", food = "Food", workspace = "Cafes & coworking", travel = "Travel", utilities = "Utilities", miscellaneous = "Miscellaneous"
    var id: String { rawValue }
    var icon: String {
        switch self { case .rent: "house.fill"; case .food: "fork.knife"; case .workspace: "cup.and.saucer.fill"; case .travel: "tram.fill"; case .utilities: "bolt.fill"; case .miscellaneous: "square.grid.2x2.fill" }
    }
    static func suggest(_ text: String) -> Category? {
        let value = text.lowercased()
        let keywords: [(Category, [String])] = [(.rent, ["rent", "landlord", "lease"]), (.food, ["grocery", "groceries", "swiggy", "zomato", "food", "dinner", "lunch", "breakfast"]), (.workspace, ["cafe", "coffee", "cowork", "co-working", "wework"]), (.travel, ["uber", "ola", "metro", "auto", "flight", "train", "petrol"]), (.utilities, ["electric", "internet", "wifi", "water", "gas", "broadband"])]
        return keywords.first { $0.1.contains { value.contains($0) } }?.0
    }
}
enum Funding: String, Codable, CaseIterable {
    case pooled = "Pooled", personal = "Personal"
    var icon: String { self == .pooled ? "person.3.fill" : "person.crop.circle.fill" }
    var deletionWarning: String { self == .pooled ? "It will be removed from the shared room for all housemates." : "It will be removed from your personal ledger." }
}
enum EntryKind: String, Codable { case expense, contribution, budget, receipt }
struct LedgerEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: EntryKind
    var title: String
    var amount: Int64 // Integer paise avoids floating point accounting errors.
    var date: Date
    var category: Category = .miscellaneous
    var funding: Funding = .pooled
    var person: String = ""
    var note: String = ""
    var modified: Date = Date()
    var deleted: Bool = false
    var receiptFilename: String? = nil
    var receiptPath: String? = nil
    var suggestedAmount: Int64? = nil
    var recognizedText: String? = nil
    var suggestedDate: Date? = nil
    var receiptAnalysis: String? = nil
}
struct Ledger: Codable {
    var entries: [LedgerEntry] = []
    var active: [LedgerEntry] { entries.filter { !$0.deleted } }
    /// All months follow Bengaluru time so every housemate sees the same month boundaries.
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }()
    static func start(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    static func next(_ date: Date) -> Date { calendar.date(byAdding: .month, value: 1, to: start(date))! }
    static func monthID(_ date: Date) -> String { let c = calendar.dateComponents([.year, .month], from: date); return "\(c.year!)-\(c.month!)" }
    static func isCurrentMonth(_ date: Date) -> Bool { monthID(date) == monthID(Date()) }
    func inMonth(_ date: Date) -> [LedgerEntry] {
        let start = Self.start(date), end = Self.next(date)
        return active.filter { $0.date >= start && $0.date < end }
    }
    func balance(before date: Date) -> Int64 {
        active.filter { $0.date < date && $0.funding == .pooled }.reduce(0) { result, item in
            result + (item.kind == .contribution ? item.amount : item.kind == .expense ? -item.amount : 0)
        }
    }
    func spent(_ month: Date, category: Category? = nil, funding: Funding = .pooled) -> Int64 {
        inMonth(month).filter { $0.kind == .expense && $0.funding == funding && (category == nil || $0.category == category) }.reduce(0) { $0 + $1.amount }
    }
    func added(_ month: Date) -> Int64 { inMonth(month).filter { $0.kind == .contribution && $0.funding == .pooled }.reduce(0) { $0 + $1.amount } }
    func budget(_ month: Date, category: Category, funding: Funding = .pooled) -> Int64 {
        let start = Self.start(month)
        return active.filter { $0.kind == .budget && $0.funding == funding && $0.category == category && $0.date <= start }.max { $0.date < $1.date }?.amount ?? 0
    }
    /// Unconfirmed receipt photos, newest first. Never counted as spending.
    func pendingReceipts(_ funding: Funding) -> [LedgerEntry] { active.filter { $0.kind == .receipt && $0.funding == funding }.sorted { $0.date > $1.date } }
    mutating func merge(_ incoming: [LedgerEntry]) {
        // Last writer wins by modification time; an index keeps large syncs linear.
        var index = Dictionary(entries.indices.map { (entries[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in incoming {
            if let position = index[item.id] {
                if item.modified > entries[position].modified { entries[position] = item }
            } else { index[item.id] = entries.count; entries.append(item) }
        }
    }
}
/// Editable values, separate from background receipt metadata.
struct EntryFormDraft: Equatable {
    var title: String
    var amount: String
    var date: Date
    var funding: Funding
    var category: Category
    var person: String
    var note: String
    /// Applies receipt suggestions only to fields the user has not changed since `baseline`,
    /// and moves the baseline so auto-filled values do not count as user edits.
    mutating func receive(_ suggestions: ReceiptSuggestions, baseline: inout Self) {
        if amount == baseline.amount, let total = suggestions.amount, total > 0 { amount = editableAmount(total); baseline.amount = amount }
        if title == baseline.title, let merchant = suggestions.merchant { title = merchant; baseline.title = title }
        if category == baseline.category, let suggested = suggestions.category { category = suggested; baseline.category = category }
        if date == baseline.date, let suggested = suggestions.date { date = suggested; baseline.date = date }
    }
    /// Background OCR/AI updates to an unconfirmed receipt draft. Booked expenses never autofill.
    mutating func receiveReceiptSuggestions(_ entry: LedgerEntry, baseline: inout Self) {
        guard entry.kind == .receipt else { return }
        receive(ReceiptSuggestions(merchant: entry.title, amount: entry.suggestedAmount, date: entry.suggestedDate, category: entry.category), baseline: &baseline)
    }
}
