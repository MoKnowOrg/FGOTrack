import SwiftUI
import CloudKit
import UniformTypeIdentifiers
import PhotosUI

let ink = Color(red: 0.05, green: 0.20, blue: 0.16)
let accent = Color(red: 0.05, green: 0.40, blue: 0.30)
let canvas = Color(uiColor: .systemGroupedBackground)

struct ContentView: View {
    @EnvironmentObject var backend: SupabaseService
    @EnvironmentObject var store: HouseStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var router = QuickCaptureRouter.shared
    @StateObject private var invitations = RoomInvitationRouter.shared
    @State private var invitationRoute: InvitationRoute?
    @State private var selected: Funding = .pooled
    @State private var editor: EditorRoute?
    @State private var capture = false
    @State private var settings = false
    @State private var captureFunding: Funding = .pooled
    @State private var receiptNotice: UUID?
    @State private var receiptNoticeFunding: Funding = .pooled
    var body: some View {
        Group {
            if backend.restoringSession {
                VStack(spacing: 20) { Image("BrandLogo").resizable().frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 20)); ProgressView("Opening FGOTrack…") }.frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
            } else if backend.user == nil { SignInView() }
            else {
                TabView(selection: $selected) {
                    WorkspaceView(funding: .pooled, add: { openEditor($0, funding: .pooled, month: $1) }, scan: { openCapture(.pooled) }, settings: { settings = true }).tabItem { Label("Pooled", systemImage: "person.3.fill") }.tag(Funding.pooled)
                    WorkspaceView(funding: .personal, add: { openEditor($0, funding: .personal, month: $1) }, scan: { openCapture(.personal) }, settings: { settings = true }).tabItem { Label("Personal", systemImage: "person.crop.circle.fill") }.tag(Funding.personal)
                }.tint(accent)
            }
        }
        .tint(accent)
        .sheet(item: $editor) { route in EntryEditor(kind: route.kind, existing: route.entry, month: route.month, initialFunding: route.funding) }
        .sheet(isPresented: $capture) { QuickReceiptCapture(initialFunding: captureFunding) { funding in receiptNoticeFunding = funding; receiptNotice = UUID() } }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } } } }
        .sheet(item: $invitationRoute) { route in JoinInvitationView(token: route.token) { invitations.clear(route.token); invitationRoute = nil; selected = .pooled }.onDisappear { if backend.user != nil { invitations.clear(route.token) } } }
        .onChange(of: invitations.pending) { _, token in if token != nil { presentInvitation() } }
        .onChange(of: backend.recoveringPassword) { _, recovering in if !recovering { presentInvitation() } }
        .sheet(isPresented: $backend.recoveringPassword) { PasswordRecoveryView().interactiveDismissDisabled() }
        .alert("Needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .overlay(alignment: .top) {
            if receiptNotice != nil {
                Label("Saved to \(receiptNoticeFunding.rawValue) · review later", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold)).padding(14)
                    .background(.regularMaterial, in: Capsule()).padding(.horizontal, 16).padding(.top, 8)
                    .allowsHitTesting(false).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task(id: receiptNotice) {
            guard receiptNotice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { receiptNotice = nil }
        }
        .onChange(of: router.action) { _, _ in consumeShortcut() }
        .onChange(of: backend.restoringSession) { _, restoring in if !restoring { store.updateWidget(); if invitations.pending != nil { presentInvitation() } else { consumeShortcut() } } }
        .onChange(of: backend.user?.id) { _, id in
            editor = nil; capture = false; settings = false; receiptNotice = nil; invitationRoute = nil
            selected = .pooled
            if id != nil { if invitations.pending != nil { presentInvitation() } else { consumeShortcut() } }
        }
        .onChange(of: store.activeRoomID) { _, room in editor = nil; capture = false; if room != nil { selected = .pooled } }
        .onChange(of: phase) { _, value in if value == .active, backend.user != nil { Task { await backend.refreshRooms() } } }
    }
    private func presentInvitation() {
        guard !backend.restoringSession, !backend.recoveringPassword, let user = backend.user?.id, let token = invitations.pending else { return }
        editor = nil; capture = false; settings = false
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard backend.user?.id == user, invitations.pending == token, !backend.recoveringPassword else { return }
            invitationRoute = InvitationRoute(token: token)
        }
    }
    private func openEditor(_ kind: EntryKind, funding: Funding, month: Date = Date()) { guard backend.user != nil else { return }; editor = EditorRoute(kind: kind, funding: funding, month: month) }
    private func openCapture(_ funding: Funding) { guard backend.user != nil else { return }; captureFunding = funding; capture = true }
    private func consumeShortcut() {
        guard invitations.pending == nil, !backend.restoringSession, backend.user != nil, let action = router.action else { return }
        let funding = router.funding ?? (backend.roomID == nil ? .personal : selected)
        selected = funding; router.action = nil
        if funding == .pooled && backend.roomID == nil { return }
        if action == "photo" { openCapture(funding) }
        else if action == "manual" { openEditor(.expense, funding: funding) }
    }
}

struct WorkspaceView: View {
    let funding: Funding
    var add: (EntryKind, Date) -> Void
    var scan: () -> Void
    var settings: () -> Void
    @EnvironmentObject private var store: HouseStore
    @EnvironmentObject private var backend: SupabaseService
    @State private var month = Ledger.start(Date())
    @State private var section = 0
    @State private var editor: EditorRoute?
    @State private var budgetCategory: Category?
    @State private var roomEditor: RoomEditorMode?
    @State private var inviting = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var pooled: Bool { funding == .pooled }
    private var ready: Bool { !pooled || backend.currentRoom != nil }
    private var pending: [LedgerEntry] { store.ledger.active.filter { $0.kind == .receipt && $0.funding == funding }.sorted { $0.date > $1.date } }
    private var spent: Int64 { store.ledger.spent(month, funding: funding) }
    private var totalBudget: Int64 { Category.allCases.reduce(0) { $0 + store.ledger.budget(month, category: $1, funding: funding) } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready { Picker("View", selection: $section) { Text("Overview").tag(0); Text("Expenses").tag(1); Text("Budgets").tag(2) }.pickerStyle(.segmented).padding(.horizontal, 20)
                    monthPicker.padding(.horizontal, 20)
                }
                if !ready { roomSetup }
                else if section == 0 { overview }
                else if section == 1 { activity }
                else { budgetList }
            }.background(canvas)
                .navigationTitle(pooled ? (backend.currentRoom?.name ?? "Pooled") : "Personal")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { if ready { captureBar } }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Image("BrandLogo").resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true) }
                    ToolbarItem(placement: .topBarTrailing) { Button(action: settings) { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account and room settings") }
                    if pooled && backend.isOwner { ToolbarItem(placement: .topBarTrailing) { Button { inviting = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Invite people to this room") } }
                    if ready { ToolbarItem(placement: .topBarTrailing) { Button(action: startCapture) { Image(systemName: "camera.fill") }.accessibilityLabel("Scan \(funding.rawValue.lowercased()) receipt") } }
                }
        }.tint(accent)
        .sheet(item: $editor) { route in EntryEditor(kind: route.kind, existing: route.entry, month: month, initialFunding: funding) }
        .sheet(item: $budgetCategory) { category in BudgetEditor(category: category, funding: funding, month: month) }
        .sheet(item: $roomEditor) { RoomEditor(mode: $0) }
        .sheet(isPresented: $inviting) { if let room = backend.currentRoom { InvitePeopleView(room: room) } }
        .onChange(of: section) { _, _ in searchFocused = false }
        .onChange(of: store.activeRoomID) { _, _ in editor = nil; budgetCategory = nil; inviting = false; search = ""; searchFocused = false }
        .onChange(of: store.accountID) { _, _ in editor = nil; budgetCategory = nil; roomEditor = nil }
    }
    private func startCapture() { searchFocused = false; scan() }
    private var captureBar: some View {
        HStack(spacing: 12) {
            Button(action: startCapture) {
                Label("Scan receipt", systemImage: "camera.fill").font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent)
            Button { searchFocused = false; add(.expense, month) } label: {
                Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 48, height: 48)
            }.buttonStyle(.bordered).accessibilityLabel("Enter \(funding.rawValue.lowercased()) expense manually")
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private var monthPicker: some View {
        HStack {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous month")
            Spacer(); Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold)); Spacer()
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next month")
        }
    }
    private func moveMonth(_ count: Int) { month = Ledger.calendar.date(byAdding: .month, value: count, to: month)! }
    private var roomSetup: some View {
        VStack(spacing: 20) {
            Spacer(); Image(systemName: "person.3.sequence.fill").font(.system(size: 52)).foregroundStyle(accent)
            Text("One room. One pool.").font(.title2.bold())
            Text("Create a room for your housemates, or join with an invitation. Your personal expenses stay private.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { roomEditor = .create } label: { Text("Create a room").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent)
            Button("Open an invitation") { roomEditor = .join }.buttonStyle(.bordered).controlSize(.large)
            Spacer(); Spacer()
        }.padding(24)
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(pooled ? "POOL REMAINING" : "PERSONAL SPENDING").font(.caption.weight(.bold)).tracking(1.5)
                    Text(money(pooled ? store.ledger.balance(before: Ledger.next(month)) : spent)).font(.system(size: 40, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    if pooled {
                        HStack { stat("Carried in", store.ledger.balance(before: month)); Spacer(); stat("Added", store.ledger.added(month)); Spacer(); stat("Spent", spent) }
                    } else {
                        Text(totalBudget > 0 ? (spent > totalBudget ? "\(money(spent - totalBudget)) over your total budget" : "\(money(totalBudget - spent)) left of \(money(totalBudget)) budget") : "Your private expenses, outside the house pool.").font(.subheadline)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white).background(ink, in: RoundedRectangle(cornerRadius: 24))
                if pooled { Button { add(.contribution, month) } label: { Label("Add pool funds", systemImage: "plus.circle").frame(minHeight: 44) }.buttonStyle(.bordered) }
                if !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("Receipts to review · \(pending.count)").font(.headline); Spacer(); Button("See all") { section = 1 } }
                        Text("Saved photos. Confirm totals when you have a moment.").font(.caption).foregroundStyle(.secondary)
                        ForEach(pending.prefix(3)) { item in receiptRow(item) }
                    }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }
                ForEach(Category.allCases) { category in
                    let used = store.ledger.spent(month, category: category, funding: funding)
                    let limit = store.ledger.budget(month, category: category, funding: funding)
                    if limit > 0 && used >= limit * 8 / 10 { Label(used > limit ? "\(category.rawValue): \(money(used - limit)) over budget" : "\(category.rawValue): \(money(limit - used)) left", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(used > limit ? .orange : .secondary) }
                }
                HStack { Text("Category budgets").font(.headline); Spacer(); Button(totalBudget == 0 ? "Set budgets" : "Manage") { section = 2 } }
                ForEach(Category.allCases) { category in Button { budgetCategory = category } label: { BudgetRow(category: category, spent: store.ledger.spent(month, category: category, funding: funding), budget: store.ledger.budget(month, category: category, funding: funding)) }.buttonStyle(.plain) }
                Text(pooled ? "Unused pool funds and deficits carry into the next month automatically." : "Personal budgets are private and continue monthly until you change them.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.refreshable { await store.sync() }
    }
    private func stat(_ label: String, _ amount: Int64) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).opacity(0.8); Text(money(amount)).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.6) } }
    private func receiptRow(_ item: LedgerEntry) -> some View {
        Button { editor = EditorRoute(kind: .expense, entry: item, funding: funding) } label: {
            HStack { Image(systemName: "receipt"); VStack(alignment: .leading) { Text(item.title).foregroundStyle(.primary); Text("Needs review").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(item.suggestedAmount.map(money) ?? "Add total").font(.subheadline); Image(systemName: "chevron.right").font(.caption) }.frame(minHeight: 44)
        }.buttonStyle(.plain)
    }
    private var activity: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search merchant or category", text: $search).autocorrectionDisabled().submitLabel(.search).focused($searchFocused).onSubmit { searchFocused = false }
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                }.frame(minHeight: 32)
            }

            let matchingReceipts = pending.filter { search.isEmpty || "\($0.title) \($0.category.rawValue)".localizedCaseInsensitiveContains(search) }
            if !matchingReceipts.isEmpty { Section("Receipt inbox") { ForEach(matchingReceipts) { item in receiptRow(item).swipeActions { Button("Delete", role: .destructive) { store.remove(item) } } } } }
            let entries = store.ledger.inMonth(month).filter { $0.funding == funding && ($0.kind == .expense || $0.kind == .contribution) && (search.isEmpty || "\($0.title) \($0.category.rawValue)".localizedCaseInsensitiveContains(search)) }.sorted { $0.date > $1.date }
            Section(pooled ? "Pool activity" : "Recorded expenses") {
                if entries.isEmpty { ContentUnavailableView(search.isEmpty ? "No expenses this month" : "No matching expenses", systemImage: search.isEmpty ? "receipt" : "magnifyingglass", description: Text(search.isEmpty ? "Tap Scan receipt below, or enter an amount manually." : "Try another merchant or category, or change the month.")) }
                ForEach(entries) { item in
                    Button { editor = EditorRoute(kind: item.kind, entry: item, funding: funding) } label: {
                        HStack(spacing: 12) { Image(systemName: item.kind == .contribution ? "arrow.down.circle.fill" : item.category.icon).foregroundStyle(accent).frame(width: 32); VStack(alignment: .leading, spacing: 5) { Text(item.title).foregroundStyle(.primary); Text(item.kind == .contribution ? "Pool contribution" : item.category.rawValue).font(.caption).foregroundStyle(.secondary) }; Spacer(); VStack(alignment: .trailing, spacing: 5) { Text("\(item.kind == .contribution ? "+" : "")\(money(item.amount))").font(.subheadline.bold()); Text(item.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary) } }
                    }.buttonStyle(.plain).swipeActions { Button("Delete", role: .destructive) { store.remove(item) } }
                }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).refreshable { await store.sync() }
    }
    private var budgetList: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("\(money(totalBudget)) planned").font(.title2.bold())
            Text(pooled ? "Limits apply to the shared room. Tap a category to edit." : "Limits apply only to your personal expenses. Tap a category to edit.").font(.subheadline).foregroundStyle(.secondary)
            ForEach(Category.allCases) { category in Button { budgetCategory = category } label: { BudgetRow(category: category, spent: store.ledger.spent(month, category: category, funding: funding), budget: store.ledger.budget(month, category: category, funding: funding)) }.buttonStyle(.plain) }
            Text("Limits continue into future months until you change them. Set 0 to clear a limit.").font(.caption).foregroundStyle(.secondary)
        }.padding(20) }
    }
}
struct BudgetEditor: View {
    let category: Category
    let funding: Funding
    let month: Date
    @EnvironmentObject private var store: HouseStore
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    var body: some View {
        NavigationStack { Form { Section("\(funding.rawValue) · \(month.formatted(.dateTime.month(.wide).year()))") { TextField("Monthly limit in INR", text: $amount).keyboardType(.decimalPad).font(.title2); Text("Enter 0 to remove the limit from this month onward.").font(.caption).foregroundStyle(.secondary) } }.navigationTitle(category.rawValue).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { if store.setBudget(amount == "0" ? 0 : parseMoney(amount)!, category: category, month: month, funding: funding) { dismiss() } }.disabled(amount != "0" && parseMoney(amount) == nil) }
        } }.onAppear { amount = NSDecimalNumber(decimal: Decimal(store.ledger.budget(month, category: category, funding: funding)) / 100).stringValue }.presentationDetents([.medium, .large])
    }
}
struct BudgetRow: View {
    let category: Category
    let spent: Int64
    let budget: Int64
    var body: some View {
        VStack(spacing: 12) {
            HStack { Image(systemName: category.icon).foregroundStyle(accent).frame(width: 28); Text(category.rawValue).font(.subheadline.weight(.semibold)); Spacer(); Text(money(spent)).font(.subheadline.bold()) }
            if budget > 0 {
                ProgressView(value: min(Double(spent) / Double(budget), 1)).tint(spent > budget ? .orange : accent)
                HStack { Text("of \(money(budget))"); Spacer(); Text(spent > budget ? "\(money(spent - budget)) over" : "\(money(budget - spent)) left").foregroundStyle(spent > budget ? .orange : .secondary) }.font(.caption)
            } else { HStack { Text("No budget set"); Spacer(); Image(systemName: "chevron.right") }.font(.caption).foregroundStyle(.secondary) }
        }.foregroundStyle(.primary).padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
struct EditorRoute: Identifiable { let id = UUID(); let kind: EntryKind; var entry: LedgerEntry?; var funding: Funding = .pooled; var month: Date = Date() }
struct EntryEditor: View {
    @EnvironmentObject var store: HouseStore
    @Environment(\.dismiss) var dismiss
    let kind: EntryKind
    let existing: LedgerEntry?
    @State var title: String
    @State var amount: String
    @State var date: Date
    @State var funding: Funding
    @State var category: Category
    @State var person: String
    @State var note: String
    @State var pickedCategory = false
    @State private var receiptData: Data?
    @State private var receiptChanged = false
    @State private var saveError: String?
    @FocusState private var amountFocused: Bool
    init(kind: EntryKind, existing: LedgerEntry?, month: Date, initialFunding: Funding = .pooled) {
        self.kind = kind; self.existing = existing
        _title = State(initialValue: existing?.title ?? ""); _amount = State(initialValue: existing.map { NSDecimalNumber(decimal: Decimal($0.kind == .receipt ? ($0.suggestedAmount ?? 0) : $0.amount) / 100).stringValue } ?? "")
        if existing?.kind == .receipt && existing?.suggestedAmount == nil { _amount = State(initialValue: "") }
        _date = State(initialValue: (existing?.kind == .receipt ? existing?.suggestedDate : nil) ?? existing?.date ?? (Ledger.monthID(month) == Ledger.monthID(Date()) ? Date() : month))
        _funding = State(initialValue: existing?.funding ?? (HouseStore.shared.accountID != nil && HouseStore.shared.activeRoomID == nil ? .personal : initialFunding)); _category = State(initialValue: existing?.category ?? .miscellaneous)
        _person = State(initialValue: existing?.person ?? ""); _note = State(initialValue: existing?.note ?? "")
        _pickedCategory = State(initialValue: existing != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                if existing?.kind == .receipt { Section { Text("Check the suggested details against the photo. Saving adds this receipt to your spending.").font(.callout); if let analysis = existing?.receiptAnalysis { Text(analysis).font(.caption).foregroundStyle(.secondary) } } }
                Section(kind == .contribution ? "Add to the house pool" : "Bill details") {
                    TextField("Amount in INR", text: $amount).keyboardType(.decimalPad).font(.largeTitle).focused($amountFocused)
                    TextField(kind == .contribution ? "Label, e.g. October contribution" : "Merchant or bill, e.g. Swiggy", text: $title).onChange(of: title) { _, value in if !pickedCategory, let suggestion = Category.suggest(value) { category = suggestion } }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                if kind == .expense {
                    Section("Paid from") { Picker("Source", selection: $funding) { Text("Pooled").tag(Funding.pooled).disabled(store.activeRoomID == nil); Text("Personal").tag(Funding.personal) }.pickerStyle(.segmented); Text(funding == .pooled ? "Deducted from the shared house pool." : "Kept in your private ledger, excluded from the house pool.").font(.caption).foregroundStyle(.secondary) }
                    Section("Category") { Picker("Category", selection: $category) { ForEach(Category.allCases) { Text($0.rawValue).tag($0) } }.onChange(of: category) { _, _ in pickedCategory = true }; if let suggestion = Category.suggest(title) { Button("Use suggested category: \(suggestion.rawValue)") { category = suggestion; pickedCategory = true }.font(.caption) } }
                }
                if kind == .expense { ReceiptAttachment(data: $receiptData, changed: $receiptChanged, amount: $amount, title: $title, date: $date, category: $category, existing: existing) }
                Section("Optional details") { TextField(kind == .contribution ? "Contributor name" : "Logged by", text: $person); TextField("Note", text: $note, axis: .vertical) }
                if existing != nil { Section { Button("Delete entry", role: .destructive) { if store.remove(existing!) { dismiss() } else { saveError = store.error; store.error = nil } } } }
            }.alert("Could not save bill", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) { Button("OK") { saveError = nil } } message: { Text(saveError ?? "") }.navigationTitle(existing?.kind == .receipt ? "Review receipt" : existing != nil ? "Edit entry" : kind == .contribution ? "Add funds" : "Add expense")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button(existing?.kind == .receipt ? "Confirm expense" : "Save") { saveEntry() }.disabled(parseMoney(amount) == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
        }.onAppear { if existing == nil { amountFocused = true } }
    }
    private func saveEntry() {
        guard let parsed = parseMoney(amount) else { saveError = "Enter a valid amount with at most two decimal places."; return }
        do {
            let filename = receiptChanged ? try receiptData.map { try store.keepReceipt($0) } : existing?.receiptFilename
            let entry = LedgerEntry(id: existing?.id ?? UUID().uuidString, kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines), amount: parsed, date: date, category: category, funding: kind == .contribution ? .pooled : funding, person: person, note: note, receiptFilename: filename, receiptPath: receiptChanged ? nil : existing?.receiptPath)
            if store.save(entry) { dismiss() } else { saveError = store.error; store.error = nil }
        } catch { saveError = error.localizedDescription }
    }

}
struct SettingsView: View {
    @EnvironmentObject var backend: SupabaseService
    @EnvironmentObject var store: HouseStore
    @State private var share: ShareRoute?
    @State private var preparing = false
    @State private var exportURL: URL?
    @State private var importing = false
    var body: some View {
        Form {
            Section { HStack(spacing: 16) { Image("BrandLogo").resizable().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 16)); VStack(alignment: .leading, spacing: 6) { Text("FGOTrack").font(.title2.bold()); Text("Personal clarity. Shared control.").foregroundStyle(.secondary) } }.padding(.vertical, 8) }
            AccountSections()
            Section("Receipt intelligence") { Text(ReceiptIntelligence.availabilityMessage).font(.callout); Text("Photos save immediately. Receipt AI improves OCR suggestions on this device without a cloud AI service. Missing or uncertain details stay for review.").font(.caption).foregroundStyle(.secondary) }
            Section("Database backup") { Label(store.syncStatus, systemImage: "externaldrive.badge.checkmark"); Button("Sync now") { Task { await backend.refreshRooms() } }.disabled(store.syncing); Text("Personal entries and budgets are private. Pooled entries and photos are shared only with your room.").font(.caption).foregroundStyle(.secondary) }
            Section("About FGOTrack") { NavigationLink("Privacy policy") { PrivacyPolicyView() }; Link("Contact support", destination: URL(string: "mailto:business@knoworganization.com")!); Text("FGOTrack 1.0 · Built for personal and pooled budgets").font(.caption).foregroundStyle(.secondary) }
            Section("Portable backup") {
                Button("Prepare JSON backup") { do { exportURL = try store.export() } catch { store.error = error.localizedDescription } }
                if let exportURL { ShareLink("Export backup", item: exportURL) }
                Button("Restore / merge backup") { importing = true }
                Text("JSON backups include personal and pooled ledger entries and photo references, but not photo files. Supabase backs up the photos separately. Restore merges entries by ID and modification time.").font(.caption).foregroundStyle(.secondary)
            }
            let archives = store.recoveryArchives()
            if !archives.isEmpty { Section("Previous household backups") { ForEach(archives, id: \.self) { url in ShareLink("Export recovery archive", item: url) }; Text("Created before joining a household. Export to Files to restore later. Restoring pooled entries merges them into your current household.").font(.caption).foregroundStyle(.secondary) } }
            Section("How your pool works") { Text("Carried in + this month's contributions − pooled bills = month-end balance. Positive balances and deficits both carry forward. Backdated edits update later balances automatically."); Text("There are no splits, debts, or settlements. Personal and pooled categories have separate monthly budgets. All amounts are stored exactly in paise.") }
        }.navigationTitle("Settings")
        .sheet(item: $share) { CloudShareView(share: $0.share, container: store.container) { store.error = $0.localizedDescription } }
        .onChange(of: store.accountID) { _, _ in exportURL = nil; importing = false; share = nil }
        .onChange(of: store.activeRoomID) { _, _ in exportURL = nil; importing = false; share = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in do { try store.restore(result.get()) } catch { store.error = error.localizedDescription } }
    }
}
struct ShareRoute: Identifiable { let id = UUID(); let share: CKShare }
struct CloudShareView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onError: (Error) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }
    func makeUIViewController(context: Context) -> UICloudSharingController { let controller = UICloudSharingController(share: share, container: container); controller.delegate = context.coordinator; controller.availablePermissions = [.allowPrivate, .allowReadWrite]; return controller }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
    class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onError: (Error) -> Void
        init(onError: @escaping (Error) -> Void) { self.onError = onError }
        func itemTitle(for csc: UICloudSharingController) -> String? { "Hacker House Pool" }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { onError(error) }
    }
}
