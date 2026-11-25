import Foundation

enum BudgetStatus: Int, Equatable {
    case notSet, healthy, watch, nearLimit, reached, over
    var label: String {
        switch self {
        case .notSet: "Set a budget"
        case .healthy: "On track"
        case .watch: "Watch spending"
        case .nearLimit: "Nearly used up"
        case .reached: "Limit reached"
        case .over: "Over budget"
        }
    }
    var icon: String {
        switch self {
        case .notSet: "plus.circle"
        case .healthy: "checkmark.circle.fill"
        case .watch: "exclamationmark.circle.fill"
        case .nearLimit, .reached, .over: "exclamationmark.triangle.fill"
        }
    }
}
struct BudgetHealth {
    let spent: Int64
    let limit: Int64
    var status: BudgetStatus {
        guard limit > 0 else { return .notSet }
        if spent > limit { return .over }
        if spent == limit { return .reached }
        // Decimal comparisons keep thresholds exact without overflowing paise.
        if Decimal(spent) * 5 >= Decimal(limit) * 4 { return .nearLimit }
        if Decimal(spent) * 2 >= Decimal(limit) { return .watch }
        return .healthy
    }
    var progress: Double { limit > 0 ? min(max(Double(spent) / Double(limit), 0), 1) : 0 }
    var percentage: String {
        guard limit > 0 else { return "" }
        let percent = max(Decimal(spent), 0) * 100 / Decimal(limit)
        if percent > 999 { return "999%+ used" }
        var value = percent, whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .down)
        return "\(NSDecimalNumber(decimal: whole).intValue)% used"
    }
    static func poolStatus(balance: Int64, spent: Int64) -> BudgetStatus {
        if balance < 0 { return .over }
        if balance == 0 { return spent > 0 ? .reached : .notSet }
        let available = Decimal(balance) + Decimal(max(spent, 0))
        if Decimal(spent) * 5 >= available * 4 { return .nearLimit }
        if Decimal(spent) * 2 >= available { return .watch }
        return .healthy
    }
}

#if canImport(UIKit)
import SwiftUI
extension BudgetStatus {
    var tint: Color {
        switch self {
        case .notSet: .secondary
        case .healthy: .green
        case .watch: .yellow
        case .nearLimit, .reached, .over: .red
        }
    }
    var textColor: Color {
        Color(uiColor: UIColor { traits in
            switch self {
            case .notSet: return .secondaryLabel
            case .healthy: return traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.04, green: 0.40, blue: 0.24, alpha: 1)
            case .watch: return traits.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.45, green: 0.31, blue: 0.01, alpha: 1)
            case .nearLimit, .reached, .over: return traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.70, green: 0.08, blue: 0.12, alpha: 1)
            }
        })
    }
    var poolLabel: String {
        switch self {
        case .notSet: "Add pool funds"
        case .healthy: "Pool on track"
        case .watch: "Half the pool used"
        case .nearLimit: "Pool running low"
        case .reached: "Pool empty"
        case .over: "Pool in deficit"
        }
    }
}
struct BudgetStatusBadge: View {
    let status: BudgetStatus
    var text: String? = nil
    var body: some View {
        Label(text ?? status.label, systemImage: status.icon)
            .font(.caption.weight(.semibold)).foregroundStyle(status.textColor)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(status.tint.opacity(0.14), in: Capsule())
    }
}
#endif
