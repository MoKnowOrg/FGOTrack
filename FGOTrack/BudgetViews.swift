import SwiftUI

/// One category's spending against its limit for a month.
struct CategoryBudget: Identifiable {
    let category: Category
    let spent: Int64
    let limit: Int64
    var id: Category { category }
    var health: BudgetHealth { BudgetHealth(spent: spent, limit: limit) }
    /// Higher sorts first: over/at/near limit, then unbudgeted spending, then the rest.
    var priority: Int { health.status == .notSet && spent > 0 ? BudgetStatus.healthy.rawValue + 1 : health.status.rawValue }
    var needsAttention: Bool { health.status.rawValue >= BudgetStatus.nearLimit.rawValue }

    /// All categories, most urgent first; equal priorities keep their natural order.
    static func all(in ledger: Ledger, month: Date, funding: Funding) -> [CategoryBudget] {
        Category.allCases.map { CategoryBudget(category: $0, spent: ledger.spent(month, category: $0, funding: funding), limit: ledger.budget(month, category: $0, funding: funding)) }
            .enumerated().sorted { $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority > $1.element.priority }
            .map(\.element)
    }
}

struct BudgetEditor: View {
    let category: Category
    let funding: Funding
    let month: Date
    @EnvironmentObject private var store: HouseStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var originalAmount: String?
    @State private var discarding = false
    @State private var saveError: String?
    @FocusState private var amountFocused: Bool?
    private var changed: Bool { originalAmount.map { amount != $0 } == true }
    private var spent: Int64 { store.ledger.spent(month, category: category, funding: funding) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(placeholder: "Monthly limit", text: $amount, font: .title, focus: $amountFocused, field: true)
                    LabeledContent("Spent in \(month.formatted(.dateTime.month(.wide)))", value: money(spent))
                } header: { Text("\(funding.rawValue) · from \(month.formatted(.dateTime.month(.wide).year()))") }
                footer: { Text("The limit continues each month until you change it. Enter 0 to remove it.") }
            }
            .navigationTitle(category.rawValue).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).fontWeight(.semibold).disabled(parseBudgetMoney(amount) == nil) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { amountFocused = nil } }
            }
            .messageAlert("Could not save budget", message: $saveError)
        }
        .onAppear {
            guard originalAmount == nil else { return }
            amount = editableAmount(store.ledger.budget(month, category: category, funding: funding))
            originalAmount = amount; amountFocused = true
        }
        .interactiveDismissDisabled(changed)
        .alert("Discard this budget change?", isPresented: $discarding) { Button("Discard change", role: .destructive) { dismiss() }; Button("Keep editing", role: .cancel) {} }
        .presentationDetents([.medium, .large])
    }
    private func save() {
        guard let value = parseBudgetMoney(amount) else { return }
        do { try store.setBudget(value, category: category, month: month, funding: funding); dismiss() }
        catch { saveError = error.localizedDescription }
    }
}

/// Status badge, percentage and progress bar shared by summaries and category rows.
private struct BudgetProgress: View {
    let health: BudgetHealth
    let label: String
    var body: some View {
        HStack { BudgetStatusBadge(status: health.status); Spacer(); Text(health.percentage).font(.caption.weight(.semibold)).foregroundStyle(health.status.textColor) }
        ProgressView(value: health.progress).tint(health.status.tint).accessibilityLabel(label).accessibilityValue(health.percentage)
    }
}

private func remainingText(spent: Int64, limit: Int64) -> String {
    spent > limit ? "\(money(spent - limit)) over budget" : "\(money(limit - spent)) left"
}

struct MonthlyBudgetSummary: View {
    let spent: Int64
    let limit: Int64
    private var health: BudgetHealth { BudgetHealth(spent: spent, limit: limit) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monthly budget").font(.headline)
            BudgetProgress(health: health, label: "Monthly budget used")
            HStack(alignment: .firstTextBaseline) {
                Text("\(money(spent)) of \(money(limit))").font(.subheadline)
                Spacer()
                Text(remainingText(spent: spent, limit: limit)).font(.subheadline.weight(.semibold)).foregroundStyle(health.status.textColor)
            }
        }.card()
    }
}

struct BudgetRow: View {
    let budget: CategoryBudget
    /// False on the category's own screen, where the card is a summary rather than a link.
    var isLink = true
    private var health: BudgetHealth { budget.health }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: budget.category.icon).foregroundStyle(budget.limit > 0 ? health.status.textColor : controlAccent).frame(width: 28)
                Text(budget.category.rawValue).font(.subheadline.weight(.semibold))
                Spacer()
                if isLink { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }
            if budget.limit > 0 {
                BudgetProgress(health: health, label: "\(budget.category.rawValue) budget used")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(money(budget.spent)) of \(money(budget.limit))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(remainingText(spent: budget.spent, limit: budget.limit)).font(.subheadline.weight(.semibold)).foregroundStyle(health.status.textColor)
                }
            } else {
                HStack {
                    Text(budget.spent > 0 ? "\(money(budget.spent)) spent · no limit" : "No limit set").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if isLink { Label("Set limit", systemImage: "plus.circle").font(.caption.weight(.semibold)).foregroundStyle(controlAccent) }
                }
            }
        }
        .foregroundStyle(.primary).card()
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(health.status.tint.opacity(budget.limit > 0 ? 0.3 : 0), lineWidth: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityAddTraits(isLink ? .isButton : []).accessibilityHint(isLink ? "Shows this category's expenses" : "")
    }
}

/// One category for one month: its budget status, its expenses, and the limit editor.
struct CategoryDetailView: View {
    let category: Category
    let funding: Funding
    let month: Date
    @EnvironmentObject private var store: HouseStore
    @State private var editor: EditorRoute?
    @State private var editingLimit = false
    @State private var deleting: LedgerEntry?
    private var entries: [LedgerEntry] {
        store.ledger.inMonth(month).filter { $0.kind == .expense && $0.funding == funding && $0.category == category }.sorted { $0.date > $1.date }
    }
    private var budget: CategoryBudget {
        CategoryBudget(category: category, spent: store.ledger.spent(month, category: category, funding: funding), limit: store.ledger.budget(month, category: category, funding: funding))
    }
    var body: some View {
        List {
            Section {
                Button { editingLimit = true } label: { Label(budget.limit > 0 ? "Change monthly limit" : "Set monthly limit", systemImage: "slider.horizontal.3") }
            } header: {
                BudgetRow(budget: budget, isLink: false).textCase(nil).padding(.horizontal, -16).padding(.bottom, 8)
            }
            Section {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No \(category.rawValue.lowercased()) expenses", systemImage: category.icon)
                    } description: { Text("Nothing recorded in \(month.formatted(.dateTime.month(.wide).year())).") }
                    actions: { Button("Add expense") { add() }.buttonStyle(.bordered) }
                } else {
                    ForEach(entries) { item in
                        Button { editor = EditorRoute(kind: .expense, entry: item, funding: funding) } label: { EntryRow(entry: item) }.buttonStyle(.plain)
                            .swipeActions { Button("Delete", role: .destructive) { deleting = item } }
                            .swipeActions(edge: .leading) { Button { repeatEntry(item) } label: { Label("Add again", systemImage: "arrow.clockwise") }.tint(controlAccent) }
                    }
                }
            } header: { Text(month.formatted(.dateTime.month(.wide).year())) }
            footer: { if !entries.isEmpty { Text("\(entries.count) \(entries.count == 1 ? "expense" : "expenses") · \(money(budget.spent))") } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(category.rawValue).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button(action: add) { Image(systemName: "plus") }.accessibilityLabel("Add \(category.rawValue) expense") } }
        .sheet(item: $editor) { EntryEditor(route: $0, month: month) }
        .sheet(isPresented: $editingLimit) { BudgetEditor(category: category, funding: funding, month: month) }
        .confirmationDialog("Delete this entry?", isPresented: Binding(present: $deleting), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { do { try store.remove(item) } catch { store.error = error.localizedDescription } }; deleting = nil }
        } message: { Text(funding.deletionWarning) }
    }
    private func add() { editor = EditorRoute(kind: .expense, funding: funding, month: month, category: category) }
    private func repeatEntry(_ item: LedgerEntry) { editor = EditorRoute(kind: .expense, funding: funding, template: item) }
}
