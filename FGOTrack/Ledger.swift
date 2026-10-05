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
enum Funding: String, Codable, CaseIterable { case pooled = "Pooled", personal = "Personal" }
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
    static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Kolkata")!; return c }
    static func start(_ date: Date) -> Date { calendar.dateInterval(of: .month, for: date)!.start }
    static func next(_ date: Date) -> Date { calendar.date(byAdding: .month, value: 1, to: start(date))! }
    static func monthID(_ date: Date) -> String { let c = calendar.dateComponents([.year, .month], from: date); return "\(c.year!)-\(c.month!)" }
    func inMonth(_ date: Date) -> [LedgerEntry] { active.filter { $0.date >= Self.start(date) && $0.date < Self.next(date) } }
    func balance(before date: Date) -> Int64 {
        active.filter { $0.date < date && $0.funding == .pooled }.reduce(0) { result, item in
            result + (item.kind == .contribution ? item.amount : item.kind == .expense ? -item.amount : 0)
        }
    }
    func spent(_ month: Date, category: Category? = nil, funding: Funding = .pooled) -> Int64 {
        inMonth(month).filter { $0.kind == .expense && $0.funding == funding && (category == nil || $0.category == category) }.reduce(0) { $0 + $1.amount }
    }
    func added(_ month: Date) -> Int64 { inMonth(month).filter { $0.kind == .contribution }.reduce(0) { $0 + $1.amount } }
    func budget(_ month: Date, category: Category, funding: Funding = .pooled) -> Int64 {
        active.filter { $0.kind == .budget && $0.funding == funding && $0.category == category && $0.date <= Self.start(month) }.max { $0.date < $1.date }?.amount ?? 0
    }
    mutating func merge(_ incoming: [LedgerEntry]) {
        for item in incoming {
            if let index = entries.firstIndex(where: { $0.id == item.id }) {
                if item.modified > entries[index].modified { entries[index] = item }
            } else { entries.append(item) }
        }
    }
}
func money(_ amount: Int64) -> String { (Decimal(amount) / 100).formatted(.currency(code: "INR").precision(.fractionLength(0...2))) }
func parseMoney(_ text: String) -> Int64? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
          let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), value > 0, value <= 1_000_000_000 else { return nil }
    return NSDecimalNumber(decimal: value * 100).int64Value
}
