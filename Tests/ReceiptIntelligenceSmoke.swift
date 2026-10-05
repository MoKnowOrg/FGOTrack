import Foundation
import FoundationModels

/// Run on a Mac with Apple Intelligence enabled; only synthetic data is used.
@main struct ReceiptIntelligenceSmoke {
    @MainActor static func main() async throws {
        print(ReceiptIntelligence.availabilityMessage)
        let cancelled = Task { @MainActor in await ReceiptIntelligence.suggestions(for: "Total 123.00", captured: Date()) }
        cancelled.cancel()
        guard await cancelled.value == nil else { fatalError("Cancelled extraction returned suggestions") }
        guard #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available else {
            print("Cancellation passed; live model check skipped because Apple Intelligence is unavailable.")
            return
        }
        let text = "HACKER HOUSE CAFE\n04 October 2026\nCoffee x 3 300.00\nSandwich 150.00\nSubtotal 450.00\nGST 22.50\nGrand Total INR 472.50"
        guard let result = await ReceiptIntelligence.suggestions(for: text, captured: Date()),
              result.merchant == "HACKER HOUSE CAFE", result.amount == 47250, result.date != nil, result.category == .workspace else {
            fatalError("Synthetic receipt extraction did not produce grounded expected fields")
        }
        print("Live on-device model extracted merchant, total, date and category; cancellation passed.")
    }
}
