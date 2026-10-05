import Foundation

/// Model output is untrusted until grounded in the OCR text. Never books an expense.
struct ReceiptModelFields {
    var merchant: String?
    var totalINR: String?
    var totalEvidence: String?
    var currency: String?
    var dateISO: String?
    var dateEvidence: String?
    var category: String?
}
struct ReceiptSuggestions {
    var merchant: String?
    var amount: Int64?
    var date: Date?
    var category: Category?

    static func fallback(_ text: String) -> Self {
        let merchant = text.components(separatedBy: .newlines).prefix(4).first {
            $0.count >= 3 && $0.count <= 80 && $0.rangeOfCharacter(from: .letters) != nil && !$0.lowercased().contains("invoice") && !$0.lowercased().contains("receipt")
        }
        return Self(merchant: merchant, amount: ReceiptAmountParser.suggestedAmount(in: text), category: Category.suggest(text))
    }
    static func validated(_ fields: ReceiptModelFields, text: String, captured: Date) -> Self {
        func grounded(_ value: String?) -> String? {
            guard let value else { return nil }
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, normalized(text).contains(normalized(clean)) else { return nil }
            return clean
        }
        let merchant = grounded(fields.merchant).flatMap { $0.count <= 80 && $0.rangeOfCharacter(from: .letters) != nil ? $0 : nil }
        var amount: Int64?
        if fields.currency == "INR", let total = fields.totalINR, let parsed = parseMoney(total),
           let evidence = grounded(fields.totalEvidence), ReceiptAmountParser.suggestedAmount(in: evidence) == parsed,
           !ReceiptAmountParser.hasConflictingTotals(in: text),
           text.range(of: #"\b(?:USD|EUR|GBP|AED|SGD)\b|[$€£]"#, options: [.regularExpression, .caseInsensitive]) == nil {
            let fallback = ReceiptAmountParser.suggestedAmount(in: text)
            if fallback == nil || fallback == parsed { amount = parsed }
        }
        var date: Date?
        if let iso = fields.dateISO, let evidence = grounded(fields.dateEvidence) {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = Ledger.calendar.timeZone; formatter.isLenient = false
            formatter.dateFormat = "yyyy-MM-dd"
            if let candidate = formatter.date(from: iso), formatter.string(from: candidate) == iso,
               Ledger.calendar.component(.year, from: candidate) >= 2000, candidate <= Ledger.calendar.startOfDay(for: captured),
               evidenceDates(evidence).count == 1, evidenceDates(evidence).contains(candidate) { date = candidate }
        }
        var category = fields.category.flatMap(Category.init(rawValue:))
        // A sandwich bought at a café belongs to the café budget. Ground this rule
        // in the printed merchant, rather than letting individual line items win.
        if category == .food, let merchant,
           merchant.range(of: #"\b(?:caf[eé]|coffee|coworking|wework)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { category = .workspace }
        return Self(merchant: merchant, amount: amount, date: date, category: category)
    }
    private static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func evidenceDates(_ value: String) -> Set<Date> {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = Ledger.calendar.timeZone; formatter.isLenient = false
        var dates = Set<Date>()
        for format in ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MM-yyyy", "MM-dd-yyyy", "dd MMM yyyy", "dd MMMM yyyy", "MMM dd, yyyy", "MMMM dd, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { dates.insert(date) }
        }
        return dates
    }
}
