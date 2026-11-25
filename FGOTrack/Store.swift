import SwiftUI
import WidgetKit

/// Local-first ledger for the signed-in account and active room. Every change is written to disk
/// first, then backed up to Supabase in the background.
@MainActor final class HouseStore: ObservableObject {
    static let shared = HouseStore()
    private static let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack")
    private static let legacyLedgerURL = baseDirectory.appendingPathComponent("ledger.json")
    private static let fileProtection: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private var storageReadable = true
    private var syncAgain = false
    /// Increments on every account/room switch so late async work never crosses boundaries.
    private var generation = 0
    private var url = HouseStore.legacyLedgerURL
    @Published private(set) var accountID: UUID?
    @Published private(set) var activeRoomID: UUID?
    @Published private(set) var ledger = Ledger()
    /// Unexpected failures that are not tied to an open form.
    @Published var error: String?
    @Published private(set) var syncStatus = "Saved on this iPhone"
    @Published private(set) var syncing = false
    @Published private(set) var syncError: String?

    // MARK: Local storage

    private func load(_ file: URL) {
        ledger = Ledger(); storageReadable = true
        do { if FileManager.default.fileExists(atPath: file.path) { ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file)) } }
        catch { storageReadable = false; self.error = "Could not read this account's saved ledger. Your file has been preserved; restore a valid backup. \(error.localizedDescription)" }
    }
    private func persist() throws {
        guard storageReadable else { throw StoreError.unreadable }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: url, options: Self.fileProtection)
        } catch { throw StoreError.writeFailed(error.localizedDescription) }
    }
    /// Background writes (sync merges) report failures without interrupting the user.
    private func persistQuietly() {
        do { try persist() } catch { self.error = error.localizedDescription }
    }

    // MARK: Editing

    func save(_ entry: LedgerEntry) throws {
        guard accountID != nil else { throw BackendError.signInRequired }
        guard storageReadable else { throw StoreError.unreadable }
        if activeRoomID == nil && entry.funding == .pooled { throw BackendError.chooseRoom }
        guard !entry.title.trimmed.isEmpty, entry.title.count <= 500 else { throw StoreError.invalidTitle }
        let previousLedger = ledger
        var entry = entry; entry.modified = Date()
        if let index = ledger.entries.firstIndex(where: { $0.id == entry.id }), ledger.entries[index].funding != entry.funding {
            // Pooled and personal rows live under different access rules, so a source change is a delete + insert.
            if let filename = entry.receiptFilename, !FileManager.default.fileExists(atPath: (try? receiptURL(filename))?.path ?? "") { throw StoreError.receiptNotDownloaded }
            ledger.entries[index].deleted = true; ledger.entries[index].modified = entry.modified
            entry.id = UUID().uuidString
            entry.receiptPath = nil
        }
        if let index = ledger.entries.firstIndex(where: { $0.id == entry.id }) { ledger.entries[index] = entry } else { ledger.entries.append(entry) }
        do { try persist() } catch { ledger = previousLedger; throw error }
        updateWidget()
        Task { await sync() }
    }
    /// The entry most recently deleted by the user, offered for Undo until replaced or cleared.
    @Published var recentlyDeleted: LedgerEntry?
    func remove(_ entry: LedgerEntry) throws {
        var item = entry; item.deleted = true
        try save(item)
        recentlyDeleted = entry
    }
    func undoRemove() throws {
        guard var entry = recentlyDeleted else { return }
        recentlyDeleted = nil
        entry.deleted = false
        try save(entry)
    }
    func setBudget(_ amount: Int64, category: Category, month: Date, funding: Funding) throws {
        try save(LedgerEntry(id: "budget-\(funding == .personal ? "personal-" : "")\(Ledger.monthID(month))-\(category.rawValue)", kind: .budget, title: category.rawValue, amount: amount, date: Ledger.start(month), category: category, funding: funding))
    }

    // MARK: Portable backup

    var backupFilename: String { "FGOTrack-backup-\(Date().formatted(.iso8601.year().month().day()))" }
    func backupData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ledger)
    }
    /// Merges a backup by entry ID and modification time. Returns the number of entries read.
    @discardableResult func restore(_ url: URL) throws -> Int {
        guard accountID != nil else { throw BackendError.signInRequired }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let backup = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        guard backup.entries.allSatisfy({ $0.amount >= 0 && $0.amount <= 100_000_000_000 }) else { throw CocoaError(.fileReadCorruptFile) }
        if activeRoomID == nil && backup.active.contains(where: { $0.funding == .pooled }) { throw BackendError.chooseRoom }
        let previous = ledger, wasReadable = storageReadable
        storageReadable = true; ledger.merge(backup.entries)
        do { try persist() } catch { ledger = previous; storageReadable = wasReadable; throw error }
        updateWidget()
        Task { await sync() }
        return backup.active.count
    }

    // MARK: Account and room switching

    func activateAccount(_ user: UUID?, room: UUID?) {
        guard accountID != user || activeRoomID != room else { return }
        // Personal entries follow the account across rooms.
        let personal = accountID == user && user != nil ? ledger.entries.filter { $0.funding == .personal } : []
        if accountID != nil { persistQuietly() }
        generation += 1; syncing = false; syncAgain = false
        accountID = user; activeRoomID = room; recentlyDeleted = nil
        url = user.map { Self.baseDirectory.appendingPathComponent("accounts/\($0.uuidString)/\(room?.uuidString ?? "personal")/ledger.json") } ?? Self.legacyLedgerURL
        if user != nil { load(url) } else { ledger = Ledger(); storageReadable = true }
        syncError = nil; syncStatus = "Saved on this iPhone"
        if !personal.isEmpty { ledger.merge(personal); persistQuietly() }
        updateWidget()
    }
    func eraseAccountCache(_ user: UUID) throws {
        guard accountID != user else { throw CocoaError(.fileWriteUnknown) }
        let base = Self.baseDirectory.appendingPathComponent("accounts/\(user.uuidString)")
        if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
        for key in ["rooms-\(user)", "room-\(user)", "imported-local-\(user)"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: Widget

    func updateWidget() {
        defer { WidgetCenter.shared.reloadTimelines(ofKind: "HousePoolWidget") }
        guard accountID != nil, activeRoomID != nil else { PoolWidgetSnapshot().write(); return }
        let month = Ledger.start(Date())
        PoolWidgetSnapshot(balance: ledger.balance(before: Ledger.next(month)), spent: ledger.spent(month), pending: ledger.pendingReceipts(.pooled).count, month: month.formatted(.dateTime.month(.abbreviated).year()), updated: Date()).write()
    }

    // MARK: Receipt photos

    private var receiptDirectory: URL { Self.baseDirectory.appendingPathComponent(accountID.map { "accounts/\($0.uuidString)/receipts" } ?? "receipts") }
    private func receiptURL(_ filename: String) throws -> URL {
        guard Self.isValidReceiptFilename(filename) else { throw CocoaError(.fileReadInvalidFileName) }
        return receiptDirectory.appendingPathComponent(filename)
    }
    private static func isValidReceiptFilename(_ name: String) -> Bool { name.hasSuffix(".jpg") && UUID(uuidString: String(name.dropLast(4))) != nil }
    func keepReceipt(_ data: Data) throws -> String {
        guard accountID != nil else { throw BackendError.signInRequired }
        guard data.count <= 10_485_760 else { throw CocoaError(.fileWriteOutOfSpace) }
        let filename = UUID().uuidString.lowercased() + ".jpg"
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try data.write(to: receiptURL(filename), options: Self.fileProtection)
        return filename
    }
    func receiptData(for entry: LedgerEntry) async throws -> Data? {
        guard let filename = entry.receiptFilename else { return nil }
        let file = try receiptURL(filename)
        if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
        guard let path = entry.receiptPath, accountID != nil else { throw BackendError.missingReceipt }
        let expected = generation
        let data = try await SupabaseService.shared.downloadReceipt(path)
        guard generation == expected else { throw CancellationError() }
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try data.write(to: file, options: Self.fileProtection); return data
    }
    /// Fills a quick-capture draft in two passes: fast OCR first, then on-device AI.
    /// Never overwrites a later edit or confirmation, and never crosses account/room boundaries.
    func readQuickReceipt(_ entry: LedgerEntry, data: Data) {
        let expected = generation
        func current(unchangedSince modified: Date?) -> LedgerEntry? {
            guard expected == generation, let item = ledger.active.first(where: { $0.id == entry.id }), item.kind == .receipt,
                  item.modified == modified, item.receiptFilename == entry.receiptFilename else { return nil }
            return item
        }
        let captured = ledger.active.first { $0.id == entry.id }?.modified
        Task {
            guard let text = try? await ReceiptOCR.recognize(data), var draft = current(unchangedSince: captured) else { return }
            let fallback = ReceiptSuggestions.fallback(text)
            draft.recognizedText = text
            draft.apply(fallback)
            draft.receiptAnalysis = "Text recognition suggestions · check against photo"
            guard (try? save(draft)) != nil else { return }
            let afterOCR = ledger.active.first { $0.id == entry.id }?.modified
            guard let ai = await ReceiptIntelligence.suggestions(for: text, captured: entry.date), var latest = current(unchangedSince: afterOCR) else { return }
            latest.apply(ai)
            latest.receiptAnalysis = "On-device AI suggestions · check against photo"
            try? save(latest)
        }
    }

    // MARK: Supabase sync

    func recordSyncFailure(_ message: String) {
        guard accountID != nil else { return }
        syncError = message; syncStatus = "Saved locally · backup pending"
    }
    func sync() async {
        guard accountID != nil, storageReadable else { return }
        if syncing { syncAgain = true; return }
        let expected = generation
        syncing = true; syncStatus = "Syncing…"
        defer {
            if generation == expected {
                syncing = false; updateWidget()
                if syncAgain { syncAgain = false; Task { await sync() } }
            }
        }
        do {
            try await syncSupabase(expected: expected)
            if generation == expected { syncError = nil; syncStatus = "Backed up · \(Date().formatted(date: .omitted, time: .shortened))" }
        } catch { if generation == expected { recordSyncFailure(error.localizedDescription) } }
    }
    private func syncSupabase(expected: Int) async throws {
        let backend = SupabaseService.shared
        guard backend.user?.id == accountID else { throw CancellationError() }
        let room = activeRoomID
        let fetched = try await backend.fetchEntries(room: room)
        guard generation == expected else { throw CancellationError() }
        ledger.merge(fetched); try persist()
        let remote = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modified > b.modified ? a : b })
        // Upload entries in scope that the server lacks or has an older copy of.
        let outgoing = ledger.entries.filter { item in (item.funding == .personal || room != nil) && (remote[item.id].map { $0.modified < item.modified } ?? true) }
        for var item in outgoing {
            guard generation == expected else { throw CancellationError() }
            if !item.deleted, let filename = item.receiptFilename, item.receiptPath == nil {
                guard let data = try await receiptData(for: item) else { throw BackendError.missingReceipt }
                guard generation == expected, let accountID else { throw CancellationError() }
                let scope = item.funding == .personal ? "personal/\(accountID.uuidString.lowercased())" : "rooms/\(room!.uuidString.lowercased())"
                let path = scope + "/" + filename
                try await backend.uploadReceipt(data, path: path)
                guard generation == expected else { throw CancellationError() }
                item.receiptPath = path
                if let index = ledger.entries.firstIndex(where: { $0.id == item.id && $0.modified == item.modified }) { ledger.entries[index].receiptPath = path; try persist() }
            }
            let saved = try await backend.mergeEntry(item, room: item.funding == .personal ? nil : room)
            guard generation == expected else { throw CancellationError() }
            ledger.merge([saved]); try persist()
        }
    }

    // MARK: One-time import of the pre-account local ledger

    var canImportLocalLedger: Bool {
        guard let accountID, activeRoomID != nil, FileManager.default.fileExists(atPath: Self.legacyLedgerURL.path) else { return false }
        return !UserDefaults.standard.bool(forKey: "imported-local-\(accountID)")
    }
    func importLocalLedger() throws {
        guard let accountID, activeRoomID != nil, !syncing, canImportLocalLedger else { throw BackendError.chooseRoom }
        let local = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: Self.legacyLedgerURL))
        var imported = ledger
        for var entry in local.active {
            if let filename = entry.receiptFilename {
                guard Self.isValidReceiptFilename(filename) else { throw CocoaError(.fileReadCorruptFile) }
                let data = try Data(contentsOf: Self.baseDirectory.appendingPathComponent("receipts").appendingPathComponent(filename))
                entry.receiptFilename = try keepReceipt(data)
            }
            entry.receiptPath = nil
            if entry.kind != .budget { entry.id = UUID().uuidString }
            entry.modified = Date(); imported.merge([entry])
        }
        let old = ledger; ledger = imported
        do { try persist() } catch { ledger = old; throw error }
        UserDefaults.standard.set(true, forKey: "imported-local-\(accountID)")
        updateWidget()
        Task { await sync() }
    }
}

enum StoreError: LocalizedError {
    case unreadable, writeFailed(String), invalidTitle, receiptNotDownloaded
    var errorDescription: String? {
        switch self {
        case .unreadable: "Saved data could not be read. Restore a valid backup from Settings before making changes."
        case .writeFailed(let reason): "Could not save on this iPhone. \(reason)"
        case .invalidTitle: "Enter a label of up to 500 characters."
        case .receiptNotDownloaded: "Download the receipt photo before changing where it was paid from, or remove the photo."
        }
    }
}

private extension LedgerEntry {
    /// Copies suggestions onto a receipt draft, keeping existing values where a suggestion is missing.
    mutating func apply(_ suggestions: ReceiptSuggestions) {
        title = suggestions.merchant ?? title
        suggestedAmount = suggestions.amount ?? suggestedAmount
        suggestedDate = suggestions.date ?? suggestedDate
        category = suggestions.category ?? category
    }
}
