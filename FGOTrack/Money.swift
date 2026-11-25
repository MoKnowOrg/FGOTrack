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

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
