import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var backend: SupabaseService
    @EnvironmentObject private var store: HouseStore
    @State private var exporting: LedgerBackupDocument?
    @State private var importing = false
    @State private var notice: String?
    @State private var failure: String?
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    BrandMark(size: 60)
                    VStack(alignment: .leading, spacing: 4) { Text("FGOTrack").font(.title2.bold()); Text("Personal clarity. Shared control.").foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            AccountSections()
            Section {
                LabeledContent { if store.syncing { ProgressView() } } label: { Label(store.syncStatus, systemImage: store.syncError == nil ? "checkmark.icloud" : "exclamationmark.icloud") }
                if let reason = store.syncError { Text(reason).font(.caption).foregroundStyle(.secondary) }
                Button("Sync now") { Task { await backend.refreshRooms() } }.disabled(store.syncing)
            } header: { Text("Backup") } footer: { Text("Personal entries and budgets are private. Pooled entries and photos are shared only with your room.") }
            Section {
                Button { do { exporting = LedgerBackupDocument(data: try store.backupData()) } catch { failure = error.localizedDescription } } label: { Label("Export JSON backup", systemImage: "square.and.arrow.up") }
                Button { importing = true } label: { Label("Restore from backup", systemImage: "square.and.arrow.down") }
            } header: { Text("Portable backup") } footer: { Text("Backups contain this room's and your personal entries, without photo files. Restoring merges entries; newer edits win.") }
            Section { Text(ReceiptIntelligence.availabilityMessage) } header: { Text("Receipt suggestions") } footer: { Text("Text recognition and receipt AI run on this iPhone. Suggestions never count as spending until you confirm them.") }
            Section("How your pool works") {
                Text("Carried in + this month's contributions − pooled expenses = month-end balance. Surpluses and deficits carry into the next month, and backdated edits update later months.")
                Text("There are no splits or debts to settle. Pooled and personal categories have separate monthly limits.")
            }
            Section {
                NavigationLink("Privacy & information") { PrivacyPolicyView() }
                Link("Contact support", destination: AppInfo.supportURL)
                LabeledContent("Version", value: AppInfo.version)
            } header: { Text("About") }
            DeleteAccountSection()
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .refreshable { await backend.refreshRooms() }
        .fileExporter(isPresented: Binding(present: $exporting), document: exporting, contentType: .json, defaultFilename: store.backupFilename) { result in
            if case .failure(let error) = result { failure = error.localizedDescription } else { notice = "Backup exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { let count = try store.restore(result.get()); notice = "Restored \(count) \(count == 1 ? "entry" : "entries"). Newer edits were kept." }
            catch { failure = error.localizedDescription }
        }
        .onChange(of: store.accountID) { _, _ in exporting = nil; importing = false }
        .onChange(of: store.activeRoomID) { _, _ in exporting = nil; importing = false }
        .messageAlert("Backup", message: $notice)
        .messageAlert("Something went wrong", message: $failure)
    }
}

struct LedgerBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Non-blocking banner shown above the capture bar while local changes await backup.
struct SyncNotice: View {
    @EnvironmentObject private var store: HouseStore
    @State private var details = false
    var body: some View {
        HStack(spacing: 12) {
            Button { details = true } label: {
                Label("Saved on this iPhone · backup pending", systemImage: "exclamationmark.icloud").font(.caption.weight(.medium))
                    .foregroundStyle(BudgetStatus.watch.textColor).multilineTextAlignment(.leading)
            }.buttonStyle(.plain).accessibilityHint("Shows why backup is pending")
            Spacer(minLength: 0)
            Button { Task { await store.sync() } } label: { if store.syncing { ProgressView() } else { Text("Retry").font(.caption.weight(.semibold)) } }
                .disabled(store.syncing).frame(minWidth: 44, minHeight: 44)
        }.padding(.horizontal, 20).background(cardBackground)
        .alert("Backup pending", isPresented: $details) {
            Button("Retry backup") { Task { await store.sync() } }
            Button("Later", role: .cancel) {}
        } message: { Text("Your changes are saved on this iPhone. Housemates won't see them until backup succeeds.\n\n\(store.syncError ?? "Try again when you're connected.")") }
    }
}
