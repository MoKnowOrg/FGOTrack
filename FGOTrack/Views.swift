import SwiftUI

/// Root: session gate, the Pooled/Personal tabs, and app-wide presentations
/// (quick capture, widget shortcuts, invitations, password recovery).
struct ContentView: View {
    @EnvironmentObject private var backend: SupabaseService
    @EnvironmentObject private var store: HouseStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var router = QuickCaptureRouter.shared
    @StateObject private var invitations = RoomInvitationRouter.shared
    @State private var invitationRoute: InvitationRoute?
    @State private var selected: Funding = .pooled
    @State private var editor: EditorRoute?
    @State private var capture: Funding?
    @State private var settings = false
    @State private var receiptNotice: (id: UUID, funding: Funding)?
    var body: some View {
        Group {
            if backend.restoringSession {
                VStack(spacing: 20) { BrandMark(); ProgressView("Opening FGOTrack…") }.frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
            } else if backend.user == nil { SignInView() }
            else {
                TabView(selection: $selected) {
                    ForEach(Funding.allCases, id: \.self) { funding in
                        WorkspaceView(funding: funding, scan: { openCapture(funding) }, settings: { settings = true })
                            .tabItem { Label(funding.rawValue, systemImage: funding.icon) }.tag(funding)
                    }
                }
            }
        }
        .tint(controlAccent)
        .sheet(item: $editor) { EntryEditor(route: $0) }
        .sheet(item: Binding(get: { capture.map(CaptureRoute.init) }, set: { capture = $0?.funding })) { route in
            QuickReceiptCapture(initialFunding: route.funding) { funding in receiptNotice = (UUID(), funding) }
        }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } } } }
        .sheet(item: $invitationRoute) { route in
            JoinInvitationView(token: route.token) { invitations.clear(route.token); invitationRoute = nil; selected = .pooled }
                .onDisappear { if backend.user != nil { invitations.clear(route.token) } }
        }
        .sheet(isPresented: $backend.recoveringPassword) { PasswordRecoveryView().interactiveDismissDisabled() }
        .messageAlert("Needs attention", message: $store.error)
        .overlay(alignment: .top) {
            if let notice = receiptNotice {
                Banner(text: "Saved to \(notice.funding.rawValue) · review it later", icon: "checkmark.circle.fill").allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let deleted = store.recentlyDeleted {
                Banner(text: "Deleted \(deleted.title)", icon: "trash", action: ("Undo", undoDelete)).padding(.bottom, 120)
            }
        }
        .animation(.snappy, value: receiptNotice?.id)
        .animation(.snappy, value: store.recentlyDeleted?.id)
        .task(id: store.recentlyDeleted?.id) {
            guard store.recentlyDeleted != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { store.recentlyDeleted = nil }
        }
        .task(id: receiptNotice?.id) {
            guard let notice = receiptNotice else { return }
            UIAccessibility.post(notification: .announcement, argument: "Receipt saved to \(notice.funding.rawValue)")
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { receiptNotice = nil }
        }
        .onChange(of: invitations.pending) { _, token in if token != nil { presentInvitation() } }
        .onChange(of: backend.recoveringPassword) { _, recovering in if !recovering { presentInvitation() } }
        .onChange(of: router.action) { _, _ in consumeShortcut() }
        .onChange(of: backend.restoringSession) { _, restoring in if !restoring { store.updateWidget(); resumePendingRoute() } }
        .onChange(of: backend.user?.id) { _, id in
            editor = nil; capture = nil; settings = false; receiptNotice = nil; invitationRoute = nil; selected = .pooled
            if id != nil { resumePendingRoute() }
        }
        .onChange(of: store.activeRoomID) { _, room in editor = nil; capture = nil; if room != nil { selected = .pooled } }
        .onChange(of: phase) { _, value in if value == .active, backend.user != nil { Task { await backend.refreshRooms() } } }
    }
    private func undoDelete() { do { try store.undoRemove() } catch { store.error = error.localizedDescription } }
    private func resumePendingRoute() { if invitations.pending != nil { presentInvitation() } else { consumeShortcut() } }
    private func presentInvitation() {
        guard !backend.restoringSession, !backend.recoveringPassword, let user = backend.user?.id, let token = invitations.pending else { return }
        editor = nil; capture = nil; settings = false
        Task {
            // Let any dismissing sheet finish before presenting the invitation.
            try? await Task.sleep(for: .milliseconds(400))
            guard backend.user?.id == user, invitations.pending == token, !backend.recoveringPassword else { return }
            invitationRoute = InvitationRoute(token: token)
        }
    }
    private func openCapture(_ funding: Funding) { guard backend.user != nil else { return }; capture = funding }
    private func consumeShortcut() {
        guard invitations.pending == nil, !backend.restoringSession, backend.user != nil, let action = router.action else { return }
        let funding = router.funding ?? (backend.roomID == nil ? .personal : selected)
        selected = funding; router.action = nil
        // Without a room, the Pooled tab shows room setup instead.
        if funding == .pooled && backend.roomID == nil { return }
        switch action {
        case .photo: openCapture(funding)
        case .manual: editor = EditorRoute(kind: .expense, funding: funding)
        }
    }
}
private struct CaptureRoute: Identifiable { let funding: Funding; var id: Funding { funding } }

/// One tab: Overview, Expenses and Budgets for either the shared pool or personal spending.
struct WorkspaceView: View {
    let funding: Funding
    var scan: () -> Void
    var settings: () -> Void
    @EnvironmentObject private var store: HouseStore
    @EnvironmentObject private var backend: SupabaseService
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var month = Ledger.start(Date())
    @SceneStorage private var section: WorkspaceSection
    @State private var editor: EditorRoute?
    @State private var roomEditor: RoomEditorMode?
    @State private var inviting = false
    @State private var deletingEntry: LedgerEntry?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private enum WorkspaceSection: String, CaseIterable { case overview = "Overview", expenses = "Expenses", budgets = "Budgets" }
    init(funding: Funding, scan: @escaping () -> Void, settings: @escaping () -> Void) {
        self.funding = funding; self.scan = scan; self.settings = settings
        // Each tab remembers whether you were on Overview, Expenses or Budgets.
        _section = SceneStorage(wrappedValue: .overview, "workspace-section-\(funding.rawValue)")
    }
    private var pooled: Bool { funding == .pooled }
    private var ready: Bool { !pooled || backend.currentRoom != nil }
    private var ledger: Ledger { store.ledger }
    private var pending: [LedgerEntry] { ledger.pendingReceipts(funding) }
    private var spent: Int64 { ledger.spent(month, funding: funding) }
    private var monthEndBalance: Int64 { ledger.balance(before: Ledger.next(month)) }
    private var categories: [CategoryBudget] { CategoryBudget.all(in: ledger, month: month, funding: funding) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready {
                    VStack(spacing: 4) {
                        Picker("Section", selection: $section) { ForEach(WorkspaceSection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        monthPicker
                    }.padding(.horizontal, 20).padding(.top, 4)
                    switch section {
                    case .overview: overview
                    case .expenses: activity
                    case .budgets: budgetList
                    }
                } else { roomSetup }
            }
            .background(canvas)
            .navigationTitle(pooled ? (backend.currentRoom?.name ?? "Pooled") : "Personal")
            .navigationDestination(for: Category.self) { CategoryDetailView(category: $0, funding: funding, month: month) }
            .navigationBarTitleDisplayMode(.inline)
            .modifier(RoomTitleMenu(enabled: pooled && backend.rooms.count > 1, menu: roomMenu))
            .safeAreaInset(edge: .bottom, spacing: 0) { if ready { VStack(spacing: 0) { if store.syncError != nil { SyncNotice() }; captureBar } } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandMark(size: 28) }
                if pooled && backend.isOwner { ToolbarItem(placement: .topBarTrailing) { Button { inviting = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Invite people") } }
                ToolbarItem(placement: .topBarTrailing) { Button(action: settings) { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account and settings") }
            }
        }
        .sheet(item: $editor) { EntryEditor(route: $0, month: month) }
        .sheet(item: $roomEditor) { RoomEditor(mode: $0) }
        .sheet(isPresented: $inviting) { if let room = backend.currentRoom { InvitePeopleView(room: room) } }
        .confirmationDialog(deletingEntry?.kind == .receipt ? "Delete this receipt?" : "Delete this entry?", isPresented: Binding(present: $deletingEntry), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deletingEntry { delete(item) } }
        } message: { Text(funding.deletionWarning) }
        .onChange(of: section) { _, _ in searchFocused = false }
        .onChange(of: store.activeRoomID) { _, _ in resetPresentations(); search = "" }
        .onChange(of: store.accountID) { _, _ in resetPresentations(); roomEditor = nil; search = ""; month = Ledger.start(Date()); section = .overview }
    }
    private func resetPresentations() { editor = nil; inviting = false; deletingEntry = nil; searchFocused = false }
    private func delete(_ item: LedgerEntry) {
        do { try store.remove(item) } catch { store.error = error.localizedDescription }
        deletingEntry = nil
    }
    private func add(_ kind: EntryKind) { searchFocused = false; editor = EditorRoute(kind: kind, funding: funding, month: month) }
    private func repeatEntry(_ item: LedgerEntry) { editor = EditorRoute(kind: item.kind, funding: funding, template: item) }
    private func edit(_ item: LedgerEntry) { editor = EditorRoute(kind: item.kind == .receipt ? .expense : item.kind, entry: item, funding: funding) }

    // MARK: Header and footer

    private var roomMenu: some View {
        Picker("Room", selection: Binding(get: { backend.roomID }, set: { backend.selectRoom($0) })) {
            ForEach(backend.rooms) { Text($0.name).tag(Optional($0.id)) }
        }.disabled(backend.working || store.syncing)
    }
    private var captureBar: some View {
        HStack(spacing: 12) {
            PrimaryButton(action: { searchFocused = false; scan() }) { Label("Scan receipt", systemImage: "camera.fill") }
            Button { add(.expense) } label: { Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 30, height: 30) }
                .buttonStyle(.bordered).controlSize(.large).accessibilityLabel("Add \(funding.rawValue.lowercased()) expense manually")
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
    private var monthPicker: some View {
        HStack {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous month")
            Spacer()
            Button { month = Ledger.start(Date()) } label: {
                VStack(spacing: 2) {
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if !Ledger.isCurrentMonth(month) { Text("Back to this month").font(.caption2).foregroundStyle(controlAccent) }
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityHint(Ledger.isCurrentMonth(month) ? "" : "Returns to the current month")
            Spacer()
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next month")
        }
    }
    private func moveMonth(_ count: Int) { month = Ledger.calendar.date(byAdding: .month, value: count, to: month) ?? month }

    private var roomSetup: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.3.sequence.fill").font(.system(size: 52)).foregroundStyle(controlAccent).accessibilityHidden(true)
            Text("One room. One pool.").font(.title2.bold())
            Text("Create a room for your housemates, or join one with an invitation. Your personal expenses stay private.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            PrimaryButton(action: { roomEditor = .create }) { Text("Create a room") }
            Button { roomEditor = .join } label: { Text("Join with an invitation").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
            Spacer(); Spacer()
        }.padding(24)
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                if pooled {
                    let status = BudgetHealth.poolStatus(balance: monthEndBalance, spent: spent)
                    HStack {
                        BudgetStatusBadge(status: status, text: status.poolLabel)
                        Spacer()
                        Button { add(.contribution) } label: { Label("Add pool funds", systemImage: "plus.circle").font(.subheadline.weight(.semibold)) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                let limit = categories.reduce(0) { $0 + $1.limit }
                if limit > 0 { MonthlyBudgetSummary(spent: spent, limit: limit) }
                if !pending.isEmpty { receiptInbox }
                let attention = categories.filter(\.needsAttention).count
                if attention > 0 {
                    Button { section = .budgets } label: {
                        HStack { Label("\(attention) \(attention == 1 ? "category needs" : "categories need") attention", systemImage: "exclamationmark.triangle.fill"); Spacer(); Image(systemName: "chevron.right") }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(BudgetStatus.nearLimit.textColor).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
                HStack { Text("Category budgets").font(.headline); Spacer(); Button(limit == 0 ? "Set budgets" : "See all") { section = .budgets } }
                categoryCards(Array(categories.prefix(3)))
                Text(pooled ? "Unused pool funds and deficits carry into the next month automatically." : "Personal budgets are private and continue monthly until you change them.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.refreshable { await store.sync() }
    }
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pooled ? "POOL REMAINING" : "SPENT THIS MONTH").font(.caption.weight(.bold)).tracking(1.5)
            Text(money(pooled ? monthEndBalance : spent)).font(.system(size: 40, weight: .semibold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
            if pooled {
                let stats = [PoolStat(label: "Carried in", amount: ledger.balance(before: month)), PoolStat(label: "Added", amount: ledger.added(month)), PoolStat(label: "Spent", amount: spent)]
                // Stack label/value rows at accessibility sizes so amounts stay readable.
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top))
                layout {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 4) { Text(stat.label).font(.caption).opacity(0.8); Text(money(stat.amount)).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.6) }
                        if stat.id != stats.last?.id && !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                    }
                }
            } else {
                Text("Your private expenses, outside the house pool.").font(.subheadline).opacity(0.9)
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.white)
        .background(ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
    private var receiptInbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Receipts to review · \(pending.count)").font(.headline); Spacer(); if pending.count > 3 { Button("See all") { section = .expenses } } }
            Text("Confirm the totals to add them to spending.").font(.caption).foregroundStyle(.secondary)
            ForEach(pending.prefix(3)) { item in Divider(); receiptRow(item) }
        }.card()
    }
    private func receiptRow(_ item: LedgerEntry) -> some View {
        Button { edit(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.viewfinder").foregroundStyle(controlAccent).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) { Text(item.title).foregroundStyle(.primary); Text("Needs review · \(item.date.formatted(.dateTime.day().month(.abbreviated)))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(item.suggestedAmount.map(money) ?? "Add total").font(.subheadline).foregroundStyle(item.suggestedAmount == nil ? .secondary : .primary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func categoryCards(_ items: [CategoryBudget]) -> some View {
        ForEach(items) { item in NavigationLink(value: item.category) { BudgetRow(budget: item) }.buttonStyle(.plain) }
    }

    // MARK: Expenses

    private func matches(_ item: LedgerEntry) -> Bool { search.trimmed.isEmpty || "\(item.title) \(item.category.rawValue) \(item.note)".localizedCaseInsensitiveContains(search.trimmed) }
    private var activity: some View {
        let receipts = pending.filter(matches)
        let entries = ledger.inMonth(month).filter { $0.funding == funding && ($0.kind == .expense || $0.kind == .contribution) && matches($0) }.sorted { $0.date > $1.date }
        return List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search merchant, category or note", text: $search).autocorrectionDisabled().submitLabel(.search).focused($searchFocused).onSubmit { searchFocused = false }
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
                }.frame(minHeight: 32)
            }
            if !receipts.isEmpty {
                Section("Receipts to review") { ForEach(receipts) { item in receiptRow(item).swipeActions { Button("Delete", role: .destructive) { deletingEntry = item } } } }
            }
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { item in
                        Button { edit(item) } label: { EntryRow(entry: item) }.buttonStyle(.plain)
                            .swipeActions { Button("Delete", role: .destructive) { deletingEntry = item } }
                            .swipeActions(edge: .leading) { Button { repeatEntry(item) } label: { Label("Add again", systemImage: "arrow.clockwise") }.tint(controlAccent) }
                            .contextMenu {
                                Button { edit(item) } label: { Label("Edit", systemImage: "pencil") }
                                Button { repeatEntry(item) } label: { Label("Add again today", systemImage: "arrow.clockwise") }
                                Button(role: .destructive) { deletingEntry = item } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: { Text(pooled ? "Pool activity" : "Expenses") }
                footer: { Text("\(entries.count) \(entries.count == 1 ? "entry" : "entries") · \(money(entries.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount })) spent") }
            } else if receipts.isEmpty {
                Section {
                    if search.trimmed.isEmpty { ContentUnavailableView("No expenses in \(month.formatted(.dateTime.month(.wide)))", systemImage: "receipt", description: Text("Tap Scan receipt below, or + to enter an amount.")) }
                    else { ContentUnavailableView.search(text: search) }
                }
            }
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).refreshable { await store.sync() }
    }

    // MARK: Budgets

    private var budgetList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let limit = categories.reduce(0) { $0 + $1.limit }
                if limit > 0 { MonthlyBudgetSummary(spent: spent, limit: limit) }
                else { Text("Set monthly limits").font(.title2.bold()) }
                Text(pooled ? "Limits apply to the shared room. Tap a category to see its expenses or change its limit." : "Limits apply only to your personal expenses. Tap a category to see its expenses or change its limit.").font(.subheadline).foregroundStyle(.secondary)
                categoryCards(categories)
                Text("Green under 50% · Yellow 50–79% · Red 80% and above. Limits continue into future months until you change them.").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}

/// A booked expense or contribution in the Expenses list.
struct EntryRow: View {
    let entry: LedgerEntry
    private var isContribution: Bool { entry.kind == .contribution }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isContribution ? "arrow.down.circle.fill" : entry.category.icon).foregroundStyle(controlAccent).frame(width: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).foregroundStyle(.primary)
                Text(isContribution ? "Pool contribution" : entry.category.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(isContribution ? "+" : "")\(money(entry.amount))").font(.subheadline.bold()).foregroundStyle(isContribution ? controlAccent : .primary)
                Text(entry.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary)
            }
            if entry.receiptFilename != nil { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Has receipt photo") }
        }.contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct PoolStat: Identifiable { let label: String; let amount: Int64; var id: String { label } }

/// Room switcher in the navigation title, shown only when there is more than one room.
private struct RoomTitleMenu<Menu: View>: ViewModifier {
    let enabled: Bool
    let menu: Menu
    func body(content: Content) -> some View {
        if enabled { content.toolbarTitleMenu { menu } } else { content }
    }
}
