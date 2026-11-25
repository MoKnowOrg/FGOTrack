import SwiftUI

struct EditorRoute: Identifiable {
    let id = UUID()
    let kind: EntryKind
    var entry: LedgerEntry?
    var funding: Funding = .pooled
    var month: Date = Date()
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
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case amount, merchant }

    init(kind: EntryKind, existing: LedgerEntry?, month: Date, funding: Funding) {
        self.kind = kind; self.existing = existing
        let isDraft = existing?.kind == .receipt
        _title = State(initialValue: existing?.title ?? "")
        _amount = State(initialValue: editableAmount(isDraft ? existing?.suggestedAmount : existing?.amount))
        _date = State(initialValue: (isDraft ? existing?.suggestedDate : nil) ?? existing?.date ?? (Ledger.isCurrentMonth(month) ? Date() : Ledger.start(month)))
        _funding = State(initialValue: kind == .contribution ? .pooled : existing?.funding ?? funding)
        _category = State(initialValue: existing?.category ?? .miscellaneous)
        _person = State(initialValue: existing?.person ?? "")
        _note = State(initialValue: existing?.note ?? "")
        _pickedCategory = State(initialValue: existing != nil && !isDraft)
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
    /// Typing a merchant suggests a category until the user picks one.
    private var titleBinding: Binding<String> {
        Binding(get: { title }, set: { value in
            title = value
            if !pickedCategory, let suggestion = Category.suggest(value) { category = suggestion }
        })
    }
    private var categoryBinding: Binding<Category> { Binding(get: { category }, set: { category = $0; pickedCategory = true }) }

    var body: some View {
        NavigationStack {
            Form {
                if isDraft {
                    Section {
                        Label("Check the suggested details against the photo. Confirming adds this receipt to your spending.", systemImage: "doc.text.magnifyingglass").font(.callout)
                        if let analysis = (liveEntry ?? existing)?.receiptAnalysis { Text(analysis).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section(kind == .contribution ? "Add to the house pool" : "Bill details") {
                    AmountField(placeholder: "Amount", text: $amount, focus: $focusedField, field: .amount)
                    TextField(kind == .contribution ? "Label, e.g. October contribution" : "Merchant or bill, e.g. Swiggy", text: titleBinding)
                        .focused($focusedField, equals: .merchant).submitLabel(.done).onSubmit { focusedField = nil }
                }
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
                    DisclosureGroup(isExpanded: $detailsExpanded) {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        TextField(kind == .contribution ? "Contributor name" : "Logged by", text: $person).textContentType(.name)
                        TextField("Note", text: $note, axis: .vertical)
                    } label: {
                        LabeledContent("Date & notes") { Text(date.formatted(.dateTime.day().month(.abbreviated).year())) }
                    }
                }
                if existing != nil { Section { Button(isDraft ? "Delete receipt" : "Delete entry", role: .destructive) { deleting = true } } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(navigationTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if hasUnsavedChanges { discarding = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button(isDraft ? "Confirm" : "Save", action: saveEntry).fontWeight(.semibold).disabled(!canSave) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(focusedField == .amount ? "Next" : "Done") { focusedField = focusedField == .amount ? .merchant : nil } }
            }
            .messageAlert("Could not save", message: $saveError)
        }
        .onAppear {
            guard baseline == nil else { return }
            baseline = draft; detailsExpanded = !person.isEmpty || !note.isEmpty
            if existing == nil { focusedField = .amount }
        }
        .sheet(isPresented: $viewingReceipt) { ReceiptPhotoViewer(data: receiptData) }
        .interactiveDismissDisabled(hasUnsavedChanges || attachmentLoading)
        .alert("Discard your changes?", isPresented: $discarding) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text(isDraft ? "Your receipt photo stays in Receipts to review." : "These edits have not been saved.") }
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
    private func applySuggestions(_ suggestions: ReceiptSuggestions) {
        guard var original = baseline else { return }
        var suggestions = suggestions, current = draft
        if pickedCategory { suggestions.category = nil } // A chosen category is never replaced.
        current.receive(suggestions, baseline: &original)
        apply(current); baseline = original
    }
    private func saveEntry() {
        guard canSave, let parsed = parseMoney(amount) else { return }
        do {
            let filename = receiptChanged ? try receiptData.map { try store.keepReceipt($0) } : existing?.receiptFilename
            let entry = LedgerEntry(id: existing?.id ?? UUID().uuidString, kind: kind, title: title.trimmed, amount: parsed, date: date, category: category,
                                    funding: funding, person: person.trimmed, note: note.trimmed, receiptFilename: filename, receiptPath: receiptChanged ? nil : existing?.receiptPath)
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
