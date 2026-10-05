import SwiftUI
import CloudKit
import WidgetKit

@MainActor final class HouseStore: ObservableObject {
    static let shared = HouseStore()
    private var storageReadable = true
    private var syncAgain = false
    private var generation = 0
    @Published private(set) var accountID: UUID?
    @Published private(set) var activeRoomID: UUID?
    @Published var ledger = Ledger()
    @Published var error: String?
    @Published var syncStatus = "Saved on this iPhone"
    @Published var syncing = false
    @Published var cloudEnabled = UserDefaults.standard.bool(forKey: "cloudEnabled")
    @Published var sharedZoneName = UserDefaults.standard.string(forKey: "sharedZoneName")
    @Published var sharedOwner = UserDefaults.standard.string(forKey: "sharedOwner")
    private var url: URL
    var container: CKContainer { CKContainer(identifier: "iCloud.com.fgotrack.house") }
    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack/ledger.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) { ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url)) }
        } catch { storageReadable = false; self.error = "Could not read saved ledger. Your existing file has been preserved. \(error.localizedDescription)" }
    }
    @discardableResult func persist() -> Bool {
        guard storageReadable else { error = "Saved data could not be read. Restore a valid backup before making changes."; return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            updateWidget()
            return true
        } catch { self.error = "Could not save: \(error.localizedDescription)"; return false }
    }
    @discardableResult func save(_ entry: LedgerEntry) -> Bool {
        guard accountID != nil else { error = "Sign in to FGOTrack before making changes."; return false }
        guard storageReadable else { persist(); return false }
        if accountID != nil && activeRoomID == nil && entry.funding == .pooled { error = BackendError.chooseRoom.localizedDescription; return false }
        guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.title.count <= 500 else { error = "Enter a bill label of up to 500 characters."; return false }
        let previousLedger = ledger
        var entry = entry; entry.modified = Date()
        if let previous = ledger.entries.first(where: { $0.id == entry.id }), previous.funding != entry.funding {
            if let filename = entry.receiptFilename, !FileManager.default.fileExists(atPath: (try? receiptURL(filename))?.path ?? "") { error = "Download the receipt photo before changing its funding source, or remove the attachment."; return false }
            var tombstone = previous; tombstone.deleted = true; tombstone.modified = entry.modified
            ledger.entries[ledger.entries.firstIndex(where: { $0.id == previous.id })!] = tombstone
            entry.id = UUID().uuidString
            entry.receiptPath = nil
        }
        if let index = ledger.entries.firstIndex(where: { $0.id == entry.id }) { ledger.entries[index] = entry } else { ledger.entries.append(entry) }
        guard persist() else { ledger = previousLedger; return false }
        if accountID != nil || cloudEnabled { Task { await sync() } }
        return true
    }
    @discardableResult func remove(_ entry: LedgerEntry) -> Bool { var item = entry; item.deleted = true; return save(item) }
    func setBudget(_ amount: Int64, category: Category, month: Date, funding: Funding = .pooled) -> Bool {
        save(LedgerEntry(id: "budget-\(funding == .personal ? "personal-" : "")\(Ledger.monthID(month))-\(category.rawValue)", kind: .budget, title: category.rawValue, amount: amount, date: Ledger.start(month), category: category, funding: funding))
    }
    func export() throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("FGOTrack-backup.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: target, options: .atomic); return target
    }
    func restore(_ url: URL) throws {
        guard accountID != nil else { throw BackendError.signInRequired }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let backup = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        guard backup.entries.allSatisfy({ $0.amount >= 0 && $0.amount <= 100_000_000_000 }) else { throw CocoaError(.fileReadCorruptFile) }
        if accountID != nil && activeRoomID == nil && backup.active.contains(where: { $0.funding == .pooled }) { throw BackendError.chooseRoom }
        storageReadable = true; ledger.merge(backup.entries); persist()
        if accountID != nil || cloudEnabled { Task { await sync() } }
    }
    func activateAccount(_ user: UUID?, room: UUID?) {
        guard accountID != user || activeRoomID != room else { return }
        let personal = accountID == user && user != nil ? ledger.entries.filter { $0.funding == .personal } : []
        persist(); generation += 1; syncing = false; syncAgain = false
        accountID = user; activeRoomID = room
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack")
        url = user.map { base.appendingPathComponent("accounts/\($0.uuidString)/\(room?.uuidString ?? "personal")/ledger.json") } ?? base.appendingPathComponent("ledger.json")
        ledger = Ledger(); storageReadable = true; syncStatus = "Saved on this iPhone"
        do { if FileManager.default.fileExists(atPath: url.path) { ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url)) } }
        catch { storageReadable = false; self.error = "Could not read this account's ledger. Restore a valid backup. \(error.localizedDescription)" }
        ledger.merge(personal); if !personal.isEmpty { persist() }; updateWidget()
    }
    func updateWidget() {
        guard accountID != nil, activeRoomID != nil else { PoolWidgetSnapshot().write(); WidgetCenter.shared.reloadTimelines(ofKind: "HousePoolWidget"); return }
        let month = Ledger.start(Date())
        PoolWidgetSnapshot(balance: ledger.balance(before: Ledger.next(month)), spent: ledger.spent(month), pending: ledger.active.filter { $0.kind == .receipt && $0.funding == .pooled }.count, month: month.formatted(.dateTime.month(.abbreviated).year()), updated: Date()).write()
        WidgetCenter.shared.reloadTimelines(ofKind: "HousePoolWidget")
    }
    func readQuickReceipt(_ entry: LedgerEntry, data: Data) {
        let expected = generation
        let originalModified = ledger.active.first { $0.id == entry.id }?.modified
        Task {
            guard let text = try? await ReceiptOCR.recognize(data), expected == generation,
                  var current = ledger.active.first(where: { $0.id == entry.id }), current.kind == .receipt, current.modified == originalModified else { return }
            let fallback = ReceiptSuggestions.fallback(text)
            current.recognizedText = text
            current.suggestedAmount = fallback.amount
            current.title = fallback.merchant ?? current.title
            current.category = fallback.category ?? .miscellaneous
            current.receiptAnalysis = "OCR suggestions · check against photo"
            guard save(current) else { return }
            let baseline = ledger.active.first { $0.id == entry.id }
            guard let suggestions = await ReceiptIntelligence.suggestions(for: text, captured: entry.date), expected == generation,
                  var latest = ledger.active.first(where: { $0.id == entry.id }), latest.kind == .receipt,
                  latest.modified == baseline?.modified, latest.receiptFilename == entry.receiptFilename else { return }
            // Never overwrite a later edit or confirmation, or cross account/room boundaries.
            latest.title = suggestions.merchant ?? latest.title
            latest.suggestedAmount = suggestions.amount ?? latest.suggestedAmount
            latest.suggestedDate = suggestions.date
            latest.category = suggestions.category ?? latest.category
            latest.receiptAnalysis = "On-device AI suggestions · check against photo"
            save(latest)
        }
    }
    func eraseAccountCache(_ user: UUID) throws {
        guard accountID != user else { throw CocoaError(.fileWriteUnknown) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack/accounts/\(user.uuidString)")
        if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
        UserDefaults.standard.removeObject(forKey: "rooms-\(user)")
        UserDefaults.standard.removeObject(forKey: "room-\(user)")
        UserDefaults.standard.removeObject(forKey: "imported-local-\(user)")
    }
    private var receiptDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack")
        return base.appendingPathComponent(accountID.map { "accounts/\($0.uuidString)/receipts" } ?? "receipts")
    }
    private func receiptURL(_ filename: String) throws -> URL {
        guard filename.hasSuffix(".jpg"), UUID(uuidString: String(filename.dropLast(4))) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        return receiptDirectory.appendingPathComponent(filename)
    }
    func keepReceipt(_ data: Data) throws -> String {
        guard accountID != nil else { throw BackendError.signInRequired }
        guard data.count <= 10_485_760 else { throw CocoaError(.fileWriteOutOfSpace) }
        let filename = UUID().uuidString.lowercased() + ".jpg"
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        try data.write(to: receiptURL(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return data
    }
    private func syncSupabase(expected: Int) async throws {
        let backend = SupabaseService.shared
        guard backend.user?.id == accountID else { throw CancellationError() }
        let room = activeRoomID
        let fetched = try await backend.fetchEntries(room: room)
        guard generation == expected else { throw CancellationError() }
        ledger.merge(fetched); persist()
        let remote = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modified > b.modified ? a : b })
        let pending = ledger.entries.filter { $0.funding == .personal || room != nil }
        for var item in pending {
            guard generation == expected else { throw CancellationError() }
            if let existing = remote[item.id], existing.modified >= item.modified { continue }
            if !item.deleted, let filename = item.receiptFilename, item.receiptPath == nil {
                guard let data = try await receiptData(for: item) else { throw BackendError.missingReceipt }
                guard generation == expected, let accountID else { throw CancellationError() }
                let scope = item.funding == .personal ? "personal/\(accountID.uuidString.lowercased())" : "rooms/\(room!.uuidString.lowercased())"
                let path = scope + "/" + filename
                try await backend.uploadReceipt(data, path: path)
                guard generation == expected else { throw CancellationError() }
                item.receiptPath = path
                if let index = ledger.entries.firstIndex(where: { $0.id == item.id && $0.modified == item.modified }) { ledger.entries[index].receiptPath = path; persist() }
            }
            let saved = try await backend.mergeEntry(item, room: item.funding == .personal ? nil : room)
            guard generation == expected else { throw CancellationError() }
            ledger.merge([saved]); persist()
        }
    }
    var canImportLocalLedger: Bool {
        guard let accountID, activeRoomID != nil else { return false }
        return !UserDefaults.standard.bool(forKey: "imported-local-\(accountID)")
    }
    func importLocalLedger() throws {
        guard let accountID, activeRoomID != nil, !syncing, canImportLocalLedger else { throw BackendError.chooseRoom }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FGOTrack")
        let localURL = base.appendingPathComponent("ledger.json")
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        let local = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: localURL))
        var imported = ledger
        for var entry in local.active {
            if let filename = entry.receiptFilename {
                guard filename.hasSuffix(".jpg"), UUID(uuidString: String(filename.dropLast(4))) != nil else { throw CocoaError(.fileReadCorruptFile) }
                let data = try Data(contentsOf: base.appendingPathComponent("receipts").appendingPathComponent(filename))
                entry.receiptFilename = try keepReceipt(data)
            }
            entry.receiptPath = nil
            if entry.kind != .budget { entry.id = UUID().uuidString }
            entry.modified = Date(); imported.merge([entry])
        }
        let old = ledger; ledger = imported
        guard persist() else { ledger = old; throw CocoaError(.fileWriteUnknown) }
        UserDefaults.standard.set(true, forKey: "imported-local-\(accountID)")
        Task { await sync() }
    }
    var pooledZone: CKRecordZone.ID { CKRecordZone.ID(zoneName: sharedZoneName ?? "HousePool", ownerName: sharedOwner ?? CKCurrentUserDefaultName) }
    func sync() async {
        guard accountID != nil, storageReadable else { return }
        if syncing { syncAgain = true; return }
        let expected = generation
        syncing = true; syncStatus = "Syncing…"
        defer { if generation == expected { syncing = false; if syncAgain { syncAgain = false; Task { await sync() } } } }
        if accountID != nil {
            do { try await syncSupabase(expected: expected); if generation == expected { syncStatus = "Synced with Supabase · \(Date().formatted(date: .omitted, time: .shortened))" } }
            catch { if generation == expected { syncStatus = "Saved locally · sync needs attention"; self.error = error.localizedDescription } }
            return
        }
        do {
            guard try await container.accountStatus() == .available else { throw SyncError.noAccount }
            try await syncZone(CKRecordZone.ID(zoneName: "Personal", ownerName: CKCurrentUserDefaultName), database: container.privateCloudDatabase, personal: true, expected: expected)
            try await syncZone(pooledZone, database: sharedOwner == nil ? container.privateCloudDatabase : container.sharedCloudDatabase, personal: false, expected: expected)
            guard generation == expected else { return }
            persist(); syncStatus = "Synced with iCloud · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch { if generation == expected { persist(); syncStatus = "Sync needs attention"; self.error = error.localizedDescription } }
    }
    private func syncZone(_ zone: CKRecordZone.ID, database: CKDatabase, personal: Bool, expected: Int) async throws {
        if zone.ownerName == CKCurrentUserDefaultName { _ = try await database.save(CKRecordZone(zoneID: zone)) }
        let records = try await fetch(zone, database: database)
        guard generation == expected else { throw CancellationError() }
        let decoder = JSONDecoder()
        ledger.merge(try records.compactMap { record in
            guard record.recordType == "LedgerItem", let data = record["payload"] as? Data else { return nil }
            return try decoder.decode(LedgerEntry.self, from: data)
        })
        persist()
        let remote = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID.recordName, $0) })
        let pending = ledger.entries.filter { ($0.funding == .personal) == personal }
        for item in pending {
            guard generation == expected else { throw CancellationError() }
            if let existing = remote[item.id], let updated = existing["updated"] as? Date, updated >= item.modified { continue }
            let record = remote[item.id] ?? CKRecord(recordType: "LedgerItem", recordID: CKRecord.ID(recordName: item.id, zoneID: zone))
            record["payload"] = try JSONEncoder().encode(item) as CKRecordValue
            record["updated"] = item.modified as CKRecordValue
            do { _ = try await database.save(record) }
            catch let error as CKError where error.code == .serverRecordChanged {
                guard let server = error.serverRecord, let data = server["payload"] as? Data else { throw error }
                let latest = try decoder.decode(LedgerEntry.self, from: data)
                guard generation == expected else { throw CancellationError() }
                if latest.modified >= item.modified { ledger.merge([latest]) }
                else { server["payload"] = record["payload"]; server["updated"] = record["updated"]; _ = try await database.save(server) }
            }
        }
    }
    private func fetch(_ zone: CKRecordZone.ID, database: CKDatabase) async throws -> [CKRecord] {
        var all: [CKRecord] = []; var token: CKServerChangeToken?; var more = true
        while more {
            let page: ([CKRecord], CKServerChangeToken?, Bool) = try await withCheckedThrowingContinuation { continuation in
                let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration(); options.previousServerChangeToken = token
                let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: options])
                operation.fetchAllChanges = false
                var records: [CKRecord] = []; var resultToken: CKServerChangeToken?; var hasMore = false; var failure: Error?
                operation.recordWasChangedBlock = { _, result in switch result { case .success(let record): records.append(record); case .failure(let error): failure = error } }
                operation.recordZoneFetchResultBlock = { _, result in
                    switch result { case .success(let value): resultToken = value.serverChangeToken; hasMore = value.moreComing; case .failure(let error): failure = error }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    if let failure { continuation.resume(throwing: failure) }
                    else { switch result { case .success: continuation.resume(returning: (records, resultToken, hasMore)); case .failure(let error): continuation.resume(throwing: error) } }
                }
                database.add(operation)
            }
            all += page.0; token = page.1; more = page.2
        }
        return all
    }
    func prepareShare() async throws -> CKShare {
        guard accountID == nil else { throw BackendError.chooseRoom }
        guard sharedOwner == nil else { throw SyncError.onlyOwner }
        cloudEnabled = true; UserDefaults.standard.set(true, forKey: "cloudEnabled")
        await sync()
        guard syncStatus.hasPrefix("Synced") else { throw SyncError.syncFirst }
        let zone = try await container.privateCloudDatabase.recordZone(for: pooledZone)
        if let reference = zone.share { return try await container.privateCloudDatabase.record(for: reference.recordID) as! CKShare }
        let share = CKShare(recordZoneID: pooledZone); share[CKShare.SystemFieldKey.title] = "Hacker House Pool" as CKRecordValue; share.publicPermission = .none
        return try await container.privateCloudDatabase.save(share) as! CKShare
    }
    func recoveryArchives() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("before-joining-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func accept(_ metadata: CKShare.Metadata) async {
        guard accountID == nil else { error = "Sign out of Supabase before accepting an iCloud household invitation."; return }
        guard !syncing else { error = "Wait for the current sync to finish, then open the invitation again."; return }
        guard storageReadable else { persist(); return }
        do {
            _ = try await container.accept(metadata)
            let zone = metadata.share.recordID.zoneID
            if sharedZoneName != zone.zoneName || sharedOwner != zone.ownerName {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let archive = url.deletingLastPathComponent().appendingPathComponent("before-joining-\(UUID().uuidString).json")
                try JSONEncoder().encode(ledger).write(to: archive, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                ledger.entries.removeAll { $0.funding == .pooled }
            }
            sharedZoneName = zone.zoneName; sharedOwner = zone.ownerName
            UserDefaults.standard.set(sharedZoneName, forKey: "sharedZoneName"); UserDefaults.standard.set(sharedOwner, forKey: "sharedOwner")
            cloudEnabled = true; UserDefaults.standard.set(true, forKey: "cloudEnabled"); persist(); await sync()
        } catch { self.error = error.localizedDescription }
    }
}
enum SyncError: LocalizedError {
    case noAccount, onlyOwner, syncFirst
    var errorDescription: String? { switch self { case .noAccount: "Sign into iCloud in Settings to back up and share your house."; case .onlyOwner: "The household owner manages invitations."; case .syncFirst: "Finish a successful iCloud sync before inviting housemates. Check the iCloud configuration and try again." } }
}
