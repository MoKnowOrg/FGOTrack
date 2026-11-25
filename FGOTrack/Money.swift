import Foundation

/// Money is stored as integer paise. These helpers are shared by the app, widget and tests.
/// Whole rupees show no decimals; anything with paise always shows two (₹9,439.50, never ₹9,439.5).
func money(_ amount: Int64) -> String {
    (Decimal(amount) / 100).formatted(.currency(code: "INR").precision(.fractionLength(amount % 100 == 0 ? 0 : 2)))
}

/// Plain rupee text for an editable field, e.g. 12345 → "123.45". Empty for zero.
func editableAmount(_ paise: Int64?) -> String {
    guard let paise, paise > 0 else { return "" }
    return paise % 100 == 0 ? "\(paise / 100)" : String(format: "%lld.%02lld", paise / 100, paise % 100)
}

/// Accepts the keypad's locale decimal separator (e.g. "12,50") as well as ".".
private func normalizedAmountInput(_ text: String, locale: Locale) -> String {
    var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let separator = locale.decimalSeparator, separator != "." { clean = clean.replacingOccurrences(of: separator, with: ".") }
    return clean
}

func parseMoney(_ text: String, locale: Locale = .current) -> Int64? {
    let clean = normalizedAmountInput(text, locale: locale)
    guard clean.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
          let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")), value > 0, value <= 1_000_000_000 else { return nil }
    return NSDecimalNumber(decimal: value * 100).int64Value
}

/// Like `parseMoney`, but zero is valid and clears a budget limit.
func parseBudgetMoney(_ text: String, locale: Locale = .current) -> Int64? {
    let clean = normalizedAmountInput(text, locale: locale)
    guard clean.range(of: "^[0-9]+(?:\\.[0-9]{1,2})?$", options: .regularExpression) != nil else { return nil }
    if Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) == 0 { return 0 }
    return parseMoney(clean, locale: locale)
}

/// Keeps typed or pasted text in the shape of a rupee amount: digits, one decimal separator and
/// at most two decimals. Letters, symbols and grouping commas are dropped, so "₹1,234.567abc"
/// becomes "1234.56". The separator the user typed ("." or the locale's) is kept.
func sanitizedAmountInput(_ text: String, locale: Locale = .current) -> String {
    let localeSeparator = Character(locale.decimalSeparator ?? ".")
    let separators: Set<Character> = [".", localeSeparator]
    let positions = text.indices.filter { separators.contains(text[$0]) }
    // One kind of separator: the first is decimal. Mixed (e.g. "1.234,50"): the last is decimal.
    let decimalIndex = Set(positions.map { text[$0] }).count > 1 ? positions.last : positions.first
    var whole = "", fraction = "", separator: Character?
    for index in text.indices {
        let character = text[index]
        if index == decimalIndex { separator = character; continue }
        guard character.isASCII, character.isNumber else { continue }
        if separator == nil { if whole.count < 10 { whole.append(character) } }
        else if fraction.count < 2 { fraction.append(character) }
    }
    guard let separator else { return whole }
    return (whole.isEmpty ? "0" : whole) + String(separator) + fraction
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
