import Foundation

/// Only proposes labelled totals. An OCR result is never saved as an amount automatically.
enum ReceiptAmountParser {
    static func suggestedAmount(in text: String) -> Int64? {
        let candidates = totalCandidates(in: text)
        guard let score = candidates.map(\.score).max() else { return nil }
        let best = Set(candidates.filter { $0.score == score }.map(\.amount))
        return best.count == 1 ? best.first : nil
    }
    static func hasConflictingTotals(in text: String) -> Bool {
        let candidates = totalCandidates(in: text)
        guard let score = candidates.map(\.score).max() else { return false }
        return Set(candidates.filter { $0.score == score }.map(\.amount)).count > 1
    }
    private static func totalCandidates(in text: String) -> [(score: Int, amount: Int64)] {
        let lines = text.components(separatedBy: .newlines)
        var candidates: [(score: Int, amount: Int64)] = []
        for (index, line) in lines.enumerated() {
            let label = line.lowercased()
            guard !["subtotal", "sub total", "sub-total", "tax total", "total tax", "total savings", "total discount", "total items", "total quantity"].contains(where: label.contains) else { continue }
            let score: Int
            if label.contains("grand total") || label.contains("amount payable") || label.contains("total payable") || label.contains("net payable") { score = 3 }
            else if label.contains("amount due") || label.contains("net total") || label.contains("balance due") { score = 2 }
            else if label.range(of: "\\btotal\\b", options: .regularExpression) != nil { score = 1 }
            else { continue }
            if let amount = lastAmount(in: line) { candidates.append((score, amount)) }
            else if index + 1 < lines.count, let amount = lastAmount(in: lines[index + 1]) { candidates.append((score, amount)) }
        }
        return candidates
    }
    private static func lastAmount(in line: String) -> Int64? {
        let pattern = #"(?<![\w.\-])(?:\d{1,3}(?:,\d{2,3})+|\d+)(?:\.\d{2})?(?![\w.]|\s*%)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).last.flatMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            return parseMoney(String(line[range]).replacingOccurrences(of: ",", with: ""))
        }
    }
}
