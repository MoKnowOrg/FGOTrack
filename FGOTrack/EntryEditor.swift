import SwiftUI

struct EditorRoute: Identifiable {
    let id = UUID()
    let kind: EntryKind
    var entry: LedgerEntry?
    var funding: Funding = .pooled
    var month: Date = Date()
    /// Preselected category, e.g. when adding from a category's detail screen.
    var category: Category?
    /// A previous entry to copy for "Add again" (new entry, dated today).
    var template: LedgerEntry?
}

/// Add or edit an expense or pool contribution, or confirm a receipt draft.
struct EntryEditor: View {
    @EnvironmentObject private var store: HouseStore
    @Environment(\.dismiss) private var dismiss
    let kind: EntryKind
    let existing: LedgerEntry?
    @State private var title: String
    @State private var amount: String
    @State private var date: Date
    @State private var funding: Funding
    @State private var category: Category
    @State private var person: String
    @State private var note: String
    /// True once the user chooses a category, which stops merchant-based suggestions.
    @State private var pickedCategory: Bool
    @State private var receiptData: Data?
    @State private var receiptChanged = false
    @State private var saveError: String?
    @State private var baseline: EntryFormDraft?
    @State private var discarding = false
    @State private var deleting = false
    @State private var detailsExpanded = false
    @State private var attachmentLoading = false
    @State private var viewingReceipt = false
    @State private var memory: EntryMemory?
    @State private var duplicate: LedgerEntry?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case amount, merchant, person }

    init(route: EditorRoute, month: Date? = nil) {
        self.init(kind: route.kind, existing: route.entry, month: month ?? route.month, funding: route.funding, category: route.category, template: route.template)
    }
    init(kind: EntryKind, existing: LedgerEntry?, month: Date, funding: Funding, category: Category? = nil, template: LedgerEntry? = nil) {
        self.kind = kind; self.existing = existing
        let isDraft = existing?.kind == .receipt
        let source = existing ?? template
        let defaultDate = Ledger.isCurrentMonth(month) ? Date() : Ledger.start(month)
        _title = State(initialValue: source?.title ?? "")
        _amount = State(initialValue: editableAmount(isDraft ? existing?.suggestedAmount : source?.amount))
        _date = State(initialValue: existing.map { (isDraft ? $0.suggestedDate : nil) ?? $0.date } ?? defaultDate)
        _funding = State(initialValue: kind == .contribution ? .pooled : source?.funding ?? funding)
        _category = State(initialValue: category ?? source?.category ?? .miscellaneous)
        _person = State(initialValue: source?.person ?? "")
        _note = State(initialValue: existing?.note ?? "")
        // A category preset from the screen you started on is only a default: typing or picking a merchant may change it.
        _pickedCategory = State(initialValue: template != nil || (existing != nil && !isDraft))
    }

    private var isDraft: Bool { existing?.kind == .receipt }
    private var draft: EntryFormDraft { EntryFormDraft(title: title, amount: amount, date: date, funding: funding, category: category, person: person, note: note) }
    private var hasUnsavedChanges: Bool { receiptChanged || baseline.map { $0 != draft } == true }
    private var liveEntry: LedgerEntry? { existing.flatMap { original in store.ledger.active.first { $0.id == original.id } } }
    private var canSave: Bool { !attachmentLoading && parseMoney(amount) != nil && !title.trimmed.isEmpty }
    private var navigationTitle: String {
        if isDraft { return "Review receipt" }
        if existing != nil { return kind == .contribution ? "Edit contribution" : "Edit expense" }
        return kind == .contribution ? "Add pool funds" : "Add expense"
    }
    /// Typing a merchant suggests a category, learned from earlier entries first, until the user picks one.
    private var titleBinding: Binding<String> {
        Binding(get: { title }, set: { value in
            title = String(value.prefix(InputLimit.title))
            if !pickedCategory, let suggestion = memory?.category(for: title) ?? Category.suggest(title) { category = suggestion }
        })
    }
    private var categoryBinding: Binding<Category> { Binding(get: { category }, set: { category = $0; pickedCategory = true }) }
    /// Merchants to offer under the field: completions while typing, most-used when empty.
    private var merchantSuggestions: [EntryMemory.Merchant] {
        guard focusedField == .merchant, let memory else { return [] }
        let query = EntryMemory.placeholderTitles.contains(EntryMemory.key(title)) ? "" : title
        return memory.suggestions(for: query, limit: query.trimmed.isEmpty ? 3 : 4)
    }
    private var personSuggestions: [String] { focusedField == .person ? memory?.people(matching: person) ?? [] : [] }
    private var amountHint: String? {
        guard !amount.isEmpty, parseMoney(amount) == nil else { return nil }
        return "Enter an amount above ₹0 with up to two decimals."
    }

    var body: some View {
        NavigationStack {
            Form {
                if isDraft {
                    Section {
                        Label("Check the suggested details against the photo. Confirming adds this receipt to your spending.", systemImage: "doc.text.magnifyingglass").font(.callout)
                        if let analysis = (liveEntry ?? existing)?.receiptAnalysis { Text(analysis).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    AmountField(placeholder: "Amount", text: $amount, focus: $focusedField, field: .amount)
                    TextField(kind == .contribution ? "Label, e.g. October contribution" : "Merchant or bill, e.g. Swiggy", text: titleBinding)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .focused($focusedField, equals: .merchant).submitLabel(.done).onSubmit { focusedField = nil }
                    ForEach(merchantSuggestions) { merchant in
                        SuggestionRow(title: merchant.title, detail: kind == .expense ? "\(merchant.category.rawValue) · \(money(merchant.lastAmount))" : money(merchant.lastAmount)) { pick(merchant) }
                    }
                } header: { Text(kind == .contribution ? "Add to the house pool" : "Bill details") }
                footer: { if let amountHint { Text(amountHint).foregroundStyle(.red) } }
                if kind == .expense {
                    ReceiptAttachment(data: $receiptData, changed: $receiptChanged, existing: existing,
                                      onSuggestions: applySuggestions, onLoadingChanged: { attachmentLoading = $0 }, onViewPhoto: { viewingReceipt = true })
                    Section {
                        Picker("Category", selection: categoryBinding) { ForEach(Category.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) } }
                        Picker("Paid from", selection: $funding) {
                            Text("Pooled").tag(Funding.pooled).disabled(store.activeRoomID == nil)
                            Text("Personal").tag(Funding.personal)
                        }.pickerStyle(.segmented)
                    } footer: { Text(funding == .pooled ? "Deducted from the shared house pool." : "Kept in your private ledger, outside the house pool.") }
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    DisclosureGroup(kind == .contribution ? "Contributor & note" : "Logged by & note", isExpanded: $detailsExpanded) {
                        TextField(kind == .contribution ? "Contributor name" : "Logged by", text: limited($person, to: InputLimit.name))
                            .textContentType(.name).textInputAutocapitalization(.words).focused($focusedField, equals: .person)
                        ForEach(personSuggestions, id: \.self) { name in SuggestionRow(title: name, icon: "person") { person = name; focusedField = nil } }
                        TextField("Note", text: limited($note, to: InputLimit.note), axis: .vertical)
                    }
                }
                if existing != nil { Section { Button(isDraft ? "Delete receipt" : "Delete entry", role: .destructive) { deleting = true } } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if hasUnsavedChanges { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button(isDraft ? "Confirm" : "Save") { saveEntry() }.fontWeight(.semibold).disabled(!canSave) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(focusedField == .amount ? "Next" : "Done") { focusedField = focusedField == .amount ? .merchant : nil } }
            }
            .messageAlert("Could not save", message: $saveError)
        }
        .onAppear {
            guard baseline == nil else { return }
            memory = EntryMemory(ledger: store.ledger, kind: kind == .contribution ? .contribution : .expense)
            baseline = draft; detailsExpanded = !person.isEmpty || !note.isEmpty
            if existing == nil { focusedField = amount.isEmpty ? .amount : .merchant }
        }
        .sheet(isPresented: $viewingReceipt) { ReceiptPhotoViewer(data: receiptData) }
        .interactiveDismissDisabled(hasUnsavedChanges || attachmentLoading)
        .alert("Discard your changes?", isPresented: $discarding) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text(isDraft ? "Your receipt photo stays in Receipts to review." : "These edits have not been saved.") }
        .alert("This looks like a duplicate", isPresented: Binding(present: $duplicate)) {
            Button("Save anyway") { saveEntry(allowDuplicate: true) }
            Button("Cancel", role: .cancel) { duplicate = nil }
        } message: {
            if let duplicate { Text("\(duplicate.title) for \(money(duplicate.amount)) is already recorded on \(duplicate.date.formatted(.dateTime.day().month(.wide)))\(duplicate.person.isEmpty ? "" : " by \(duplicate.person)").") }
        }
        .confirmationDialog(isDraft ? "Delete this receipt?" : "Delete this entry?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteEntry)
        } message: { Text(funding.deletionWarning) }
        .onChange(of: liveEntry) { _, updated in
            guard let updated, isDraft, var original = baseline else { return }
            var current = draft
            current.receiveReceiptSuggestions(updated, baseline: &original)
            apply(current); baseline = original
        }
    }
    private func apply(_ form: EntryFormDraft) { title = form.title; amount = form.amount; date = form.date; category = form.category }
    private func pick(_ merchant: EntryMemory.Merchant) {
        title = merchant.title
        if !pickedCategory { category = merchant.category }
        if amount.isEmpty { amount = editableAmount(merchant.lastAmount) }
        focusedField = nil
    }
    private func applySuggestions(_ suggestions: ReceiptSuggestions) {
        guard var original = baseline else { return }
        var suggestions = suggestions, current = draft
        if pickedCategory { suggestions.category = nil } // A chosen category is never replaced.
        current.receive(suggestions, baseline: &original)
        apply(current); baseline = original
    }
    private func saveEntry(allowDuplicate: Bool = false) {
        guard canSave, let parsed = parseMoney(amount) else { return }
        duplicate = nil
        var entry = LedgerEntry(id: existing?.id ?? UUID().uuidString, kind: kind, title: title.trimmed, amount: parsed, date: date, category: category,
                                funding: funding, person: person.trimmed, note: note.trimmed, receiptFilename: existing?.receiptFilename, receiptPath: existing?.receiptPath)
        // New bills and receipt confirmations are checked against what is already booked.
        if !allowDuplicate, existing == nil || isDraft, let match = store.ledger.possibleDuplicate(of: entry, fromReceipt: isDraft) {
            duplicate = match; return
        }
        do {
            if receiptChanged { entry.receiptFilename = try receiptData.map { try store.keepReceipt($0) }; entry.receiptPath = nil }
            try store.save(entry)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
    private func deleteEntry() {
        guard let existing else { return }
        do { try store.remove(liveEntry ?? existing); dismiss() } catch { saveError = error.localizedDescription }
    }
}

/// Full-screen, zoomable receipt photo.
struct ReceiptPhotoViewer: View {
    let data: Data?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let data, let image = UIImage(data: data) { ZoomableReceiptPhoto(image: image).ignoresSafeArea(edges: .bottom) }
                else { ContentUnavailableView("Photo unavailable", systemImage: "photo") }
            }
            .navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
