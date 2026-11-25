import Foundation
import SwiftUI
import Supabase
import AuthenticationServices

struct HouseRoom: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let owner_id: UUID
}
struct RoomMember: Codable, Identifiable {
    let room_id: UUID
    let user_id: UUID
    let display_name: String
    var id: UUID { user_id }
}
struct RoomInviteLink: Decodable { let token: UUID; let expires_at: String; var url: URL { RoomInvitation.url(token: token) } }
struct RoomInvitePreview: Decodable { let room_id: UUID; let room_name: String; let member_count: Int; let already_member: Bool }
struct RemoteLedgerRow: Decodable { let payload: LedgerEntry }

@MainActor final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()
    let client: SupabaseClient?
    @Published private(set) var user: User?
    @Published private(set) var rooms: [HouseRoom] = []
    @Published private(set) var roomID: UUID?
    @Published private(set) var members: [RoomMember] = []
    @Published var error: String?
    @Published var working = false
    @Published private(set) var restoringSession = true
    @Published var recoveringPassword = false
    @Published private(set) var googleEnabled = false
    @Published private(set) var appleEnabled = false
    private var authTask: Task<Void, Never>?
    var currentRoom: HouseRoom? { rooms.first { $0.id == roomID } }
    var isOwner: Bool { currentRoom?.owner_id == user?.id && user != nil }
    var displayName: String { user?.userMetadata["full_name"]?.stringValue ?? user?.userMetadata["name"]?.stringValue ?? user?.email?.components(separatedBy: "@").first ?? "Housemate" }
    private static let authCallback = URL(string: "fgotrack://auth/callback")!
    /// Project URL and publishable key from Info.plist; nil when the build is not configured.
    private static let config: (url: URL, key: String)? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String, let url = URL(string: raw), url.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String, !key.isEmpty else { return nil }
        return (url, key)
    }()
    init() {
        if let config = Self.config {
            client = SupabaseClient(supabaseURL: config.url, supabaseKey: config.key, options: .init(
                db: .init(encoder: JSONEncoder(), decoder: JSONDecoder()),
                auth: .init(storage: KeychainLocalStorage(), redirectToURL: Self.authCallback, flowType: .pkce, emitLocalSessionAsInitialSession: true)
            ))
        } else { client = nil; restoringSession = false }
    }
    func start() {
        guard authTask == nil, let client else { return }
        authTask = Task { [weak self] in
            for await (event, session) in client.auth.authStateChanges {
                guard let self else { return }
                if event == .passwordRecovery { self.recoveringPassword = true }
                let changed = self.user?.id != session?.user.id
                self.user = session?.user
                if changed {
                    self.error = nil
                    self.members = []; self.rooms = []; self.roomID = nil
                    if let id = session?.user.id {
                        if let data = UserDefaults.standard.data(forKey: "rooms-\(id)"), let cached = try? JSONDecoder().decode([HouseRoom].self, from: data) { self.rooms = cached }
                        self.roomID = UserDefaults.standard.string(forKey: "room-\(id)").flatMap(UUID.init(uuidString:))
                        if !self.rooms.contains(where: { $0.id == self.roomID }) { self.roomID = nil }
                    }
                    HouseStore.shared.activateAccount(self.user?.id, room: self.roomID)
                }
                self.restoringSession = false
                if changed || self.rooms.isEmpty, self.user != nil { await self.refreshRooms() }
            }
        }
    }
    func requireClient() throws -> SupabaseClient { guard let client else { throw BackendError.notConfigured }; return client }
    func signInGoogle() async { await signInOAuth(.google) }
    func signInApple() async { await signInOAuth(.apple) }
    private func signInOAuth(_ provider: Provider) async {
        guard !working else { return }; working = true; defer { working = false }
        do { try await requireClient().auth.signInWithOAuth(provider: provider, redirectTo: Self.authCallback) }
        catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin { }
        catch { self.error = error.localizedDescription }
    }
    func signInEmail(_ email: String, password: String, createAccount: Bool) async -> String? {
        guard !working else { return nil }; working = true; defer { working = false }
        do {
            let client = try requireClient()
            if createAccount {
                let response = try await client.auth.signUp(email: email, password: password, redirectTo: Self.authCallback)
                return response.session == nil ? "Check your email to confirm your account, then return here and sign in." : nil
            }
            _ = try await client.auth.signIn(email: email, password: password)
            return nil
        } catch { self.error = error.localizedDescription; return nil }
    }
    func sendEmailLink(_ email: String) async -> Bool {
        guard !working else { return false }; working = true; defer { working = false }
        do { try await requireClient().auth.signInWithOTP(email: email, redirectTo: Self.authCallback); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func handleCallback(_ url: URL) async {
        guard url.scheme == "fgotrack", url.host == "auth", url.path == "/callback" else { return }
        do { _ = try await requireClient().auth.session(from: url) } catch { self.error = error.localizedDescription }
    }
    func signOut() async {
        guard !working, !HouseStore.shared.syncing else { error = "Wait for the current operation to finish before signing out."; return }
        working = true; defer { working = false }
        do { try await requireClient().auth.signOut(scope: .local); clearSession() } catch { self.error = error.localizedDescription }
    }
    private func clearSession() {
        user = nil; rooms = []; members = []; roomID = nil; recoveringPassword = false; error = nil
        HouseStore.shared.activateAccount(nil, room: nil)
    }
    func loadProviders() async {
        struct Settings: Decodable { let external: [String: Bool] }
        guard let config = Self.config else { return }
        do {
            var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/settings")); request.setValue(config.key, forHTTPHeaderField: "apikey"); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            appleEnabled = settings.external["apple"] == true
            // Offer equivalent Apple login before exposing Google in a distribution build.
            googleEnabled = settings.external["google"] == true && appleEnabled
        } catch { } // Email remains available when provider discovery is offline.
    }
    func resetPassword(_ email: String) async -> Bool {
        guard !working else { return false }; working = true; defer { working = false }
        do { try await requireClient().auth.resetPasswordForEmail(email, redirectTo: Self.authCallback); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func updatePassword(_ password: String) async -> Bool {
        guard !working, user != nil else { return false }; working = true; defer { working = false }
        do { _ = try await requireClient().auth.update(user: UserAttributes(password: password)); recoveringPassword = false; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func transferOwnership(to member: RoomMember) async {
        struct Params: Encodable { let p_room: UUID; let p_user: UUID }
        await roomAction { _ = try await self.requireClient().rpc("transfer_room_ownership", params: Params(p_room: member.room_id, p_user: member.user_id)).execute(); await self.refreshRooms() }
    }
    func deleteAccount() async -> Bool {
        guard let user, !working, !HouseStore.shared.syncing else { error = "Wait for sync to finish before deleting your account."; return false }
        working = true; defer { working = false }
        do {
            struct Reply: Decodable { let deleted: Bool }
            let reply: Reply = try await requireClient().functions.invoke("delete-account", options: FunctionInvokeOptions(body: ["confirm": true]))
            guard reply.deleted else { throw BackendError.deletionFailed }
            try? await requireClient().auth.signOut(scope: .local)
            clearSession()
            try HouseStore.shared.eraseAccountCache(user.id)
            return true
        } catch { self.error = "Could not delete your account. \(error.localizedDescription) Contact business@knoworganization.com if this persists."; return false }
    }
    func refreshRooms() async {
        guard let user else { return }; let expected = user.id
        do {
            let fetched: [HouseRoom] = try await requireClient().from("rooms").select("id,name,owner_id").order("name").execute().value
            guard self.user?.id == expected else { return }
            rooms = fetched
            UserDefaults.standard.set(try JSONEncoder().encode(fetched), forKey: "rooms-\(expected)")
            if !fetched.contains(where: { $0.id == roomID }) { selectRoom(fetched.first?.id, refresh: false) }
            await refreshMembers()
            await HouseStore.shared.sync()
        } catch { if self.user?.id == expected { HouseStore.shared.recordSyncFailure(error.localizedDescription) } }
    }
    func selectRoom(_ id: UUID?, refresh: Bool = true) {
        guard let user, id == nil || rooms.contains(where: { $0.id == id }) else { return }
        roomID = id; members = []
        UserDefaults.standard.set(id?.uuidString, forKey: "room-\(user.id)")
        HouseStore.shared.activateAccount(user.id, room: id)
        if refresh { Task { await refreshMembers(); await HouseStore.shared.sync() } }
    }
    func refreshMembers() async {
        guard let roomID, let user else { members = []; return }
        do {
            let fetched: [RoomMember] = try await requireClient().from("room_members").select("room_id,user_id,display_name").eq("room_id", value: roomID.uuidString).order("display_name").execute().value
            guard self.user?.id == user.id, self.roomID == roomID else { return }
            members = fetched
        } catch { } // Offline: keep the last known members; the sync notice reports connectivity.
    }
    @discardableResult func createRoom(_ name: String, displayName: String) async -> Bool {
        struct Params: Encodable { let p_name: String; let p_display_name: String }
        return await roomAction {
            let id: UUID = try await self.requireClient().rpc("create_room", params: Params(p_name: name, p_display_name: displayName)).execute().value
            await self.refreshRooms(); self.selectRoom(id)
        }
    }
    @discardableResult func joinRoom(_ token: String, displayName: String) async -> Bool {
        struct Params: Encodable { let p_token: UUID; let p_display_name: String }
        guard let id = RoomInvitation.token(from: token) else { error = "Use a FGOTrack invitation link or code."; return false }
        return await roomAction {
            let room: UUID = try await self.requireClient().rpc("join_room", params: Params(p_token: id, p_display_name: displayName)).execute().value
            await self.refreshRooms(); self.selectRoom(room)
        }
    }
    func invitationLink(room: UUID) async throws -> RoomInviteLink {
        struct Params: Encodable { let p_room: UUID }
        return try await requireClient().rpc("get_or_create_room_invite", params: Params(p_room: room)).execute().value
    }
    func invitationPreview(token: UUID) async throws -> RoomInvitePreview {
        struct Params: Encodable { let p_token: UUID }
        return try await requireClient().rpc("preview_room_invitation", params: Params(p_token: token)).execute().value
    }
    /// Revokes the room's current invitations and issues a new one.
    func replaceInvitation(room: UUID) async throws {
        struct Params: Encodable { let p_room: UUID }
        guard !working else { return }
        working = true; defer { working = false }
        let _: UUID = try await requireClient().rpc("create_room_invite", params: Params(p_room: room)).execute().value
    }
    func removeMember(_ member: RoomMember) async {
        struct Params: Encodable { let p_room: UUID; let p_user: UUID }
        await roomAction { _ = try await self.requireClient().rpc("remove_room_member", params: Params(p_room: member.room_id, p_user: member.user_id)).execute(); await self.refreshMembers() }
    }
    /// Runs a room change exclusively. On failure `error` holds the reason.
    @discardableResult private func roomAction(_ action: () async throws -> Void) async -> Bool {
        guard !working, !HouseStore.shared.syncing, user != nil else { error = "Wait for the current sync to finish, then try again."; return false }
        working = true; error = nil; defer { working = false }
        do { try await action(); return true } catch { self.error = error.localizedDescription; return false }
    }
    func fetchEntries(room: UUID?) async throws -> [LedgerEntry] {
        let client = try requireClient()
        var result: [LedgerEntry] = []
        // Page both scopes; never rely on the default 1,000-row limit.
        for personal in [true, false] {
            if !personal && room == nil { continue }
            var offset = 0
            while true {
                var query = client.from("ledger_entries").select("payload")
                if personal { query = query.is("room_id", value: nil) }
                else { query = query.eq("room_id", value: room!.uuidString) }
                let page: [RemoteLedgerRow] = try await query.order("id").range(from: offset, to: offset + 499).execute().value
                result += page.map(\.payload)
                if page.count < 500 { break }; offset += 500
            }
        }
        return result
    }
    func mergeEntry(_ entry: LedgerEntry, room: UUID?) async throws -> LedgerEntry {
        struct Params: Encodable { let p_entry: LedgerEntry; let p_room: UUID? }
        return try await requireClient().rpc("merge_ledger_entry", params: Params(p_entry: entry, p_room: room)).execute().value
    }
    func uploadReceipt(_ data: Data, path: String) async throws {
        do { try await requireClient().storage.from("receipts").upload(path, data: data, options: FileOptions(contentType: "image/jpeg", upsert: false)) }
        catch let error as StorageError where error.statusCode == "409" || error.error == "Duplicate" {
            // A retry after an interrupted upload is safe only if the immutable object matches.
            let existing = try await requireClient().storage.from("receipts").download(path: path)
            guard existing == data else { throw BackendError.receiptCollision }
        }
    }
    func downloadReceipt(_ path: String) async throws -> Data { try await requireClient().storage.from("receipts").download(path: path) }
}
enum BackendError: LocalizedError {
    case notConfigured, chooseRoom, missingReceipt, receiptCollision, signInRequired, deletionFailed
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to FGOTrack to continue."
        case .deletionFailed: "Account deletion could not be completed."
        case .notConfigured: "Add your Supabase project URL and publishable key to Info.plist."
        case .chooseRoom: "Create or join a room before adding pooled bills, budgets, or contributions."
        case .missingReceipt: "The receipt photo is missing on this device. Reattach it or remove the attachment to sync this bill."
        case .receiptCollision: "A different receipt already exists at this path. Reattach the photo and try again."
        }
    }
}
