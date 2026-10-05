import SwiftUI

struct AccountSections: View {
    @EnvironmentObject var backend: SupabaseService
    @EnvironmentObject var store: HouseStore
    @State private var signingIn = false
    @State private var roomEditor: RoomEditorMode?
    @State private var inviting = false
    @State private var removing: RoomMember?
    @State private var importing = false
    @State private var deleting = false
    @State private var transferring: RoomMember?
    var body: some View {
        Group {
            if let user = backend.user {
                Section("Your account") {
                    Label(user.email ?? backend.displayName, systemImage: "person.crop.circle.fill")
                    Button("Delete account", role: .destructive) { deleting = true }.disabled(backend.working || store.syncing)
                    Button("Sign out", role: .destructive) { Task { await backend.signOut() } }.disabled(backend.working || store.syncing)
                }
                Section("Shared rooms") {
                    if !backend.rooms.isEmpty {
                        Picker("Active room", selection: Binding(get: { backend.roomID }, set: { backend.selectRoom($0) })) {
                            Text("Personal only").tag(Optional<UUID>.none)
                            ForEach(backend.rooms) { Text($0.name).tag(Optional($0.id)) }
                        }.disabled(backend.working)
                    }
                    Button("Create a room") { roomEditor = .create }.disabled(backend.working || store.syncing)
                    Button("Open an invitation") { roomEditor = .join }.disabled(backend.working || store.syncing)
                    if let room = backend.currentRoom {
                        Text("\(room.name) · pooled bills and budgets are shared with its members.").font(.caption).foregroundStyle(.secondary)
                        if backend.isOwner {
                            Button { inviting = true } label: { Label("Invite people", systemImage: "person.badge.plus") }.disabled(backend.working || store.syncing)
                        }
                    } else { Text("Create or join a room to share a pool. Personal expenses work without a room.").font(.caption).foregroundStyle(.secondary) }
                }
                if backend.currentRoom != nil {
                    Section("People in this room") {
                        ForEach(backend.members) { member in
                            VStack(alignment: .leading) {
                            HStack { Label(member.display_name, systemImage: "person.crop.circle"); Spacer(); if member.user_id == backend.currentRoom?.owner_id { Text("Owner").font(.caption).foregroundStyle(.secondary) }; if member.user_id == user.id { Text("You").font(.caption).foregroundStyle(.secondary) }; if backend.isOwner, member.user_id != user.id { Button(role: .destructive) { removing = member } label: { Image(systemName: "person.badge.minus") }.accessibilityLabel("Remove \(member.display_name)").disabled(backend.working) } }
                            if backend.isOwner, member.user_id != user.id { Button("Make room owner") { transferring = member }.font(.caption).disabled(backend.working) }
                            }
                        }
                        Button("Refresh people & rooms") { Task { await backend.refreshRooms() } }.disabled(backend.working || store.syncing)
                    }
                    if store.canImportLocalLedger {
                        Section("Existing bills on this iPhone") {
                            Button("Import existing local ledger") { importing = true }.disabled(store.syncing)
                            Text("Your previous local ledger stays on this iPhone until you choose to import it. Pooled entries will be visible to this room; personal entries remain private.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .sheet(item: $roomEditor) { RoomEditor(mode: $0) }
        .sheet(isPresented: $inviting) { if let room = backend.currentRoom { InvitePeopleView(room: room) } }
        .alert("Account or room needs attention", isPresented: Binding(get: { backend.error != nil && !signingIn && roomEditor == nil }, set: { if !$0 { backend.error = nil } })) { Button("OK") { backend.error = nil } } message: { Text(backend.error ?? "") }
        .confirmationDialog("Remove \(removing?.display_name ?? "member") from this room?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) { Button("Remove member", role: .destructive) { if let removing { Task { await backend.removeMember(removing); inviting = false } }; removing = nil } } message: { Text("They will lose access to the shared room and receipt photos. Any active invitation code will also be revoked.") }
        .confirmationDialog("Import this iPhone's existing bills into \(backend.currentRoom?.name ?? "this room")?", isPresented: $importing, titleVisibility: .visible) { Button("Import ledger") { do { try store.importLocalLedger() } catch { store.error = error.localizedDescription } } } message: { Text("This adds previous pooled bills, contributions, and budgets to the room. Personal bills stay private. You can do this once per account.") }
        .confirmationDialog("Delete your FGOTrack account?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete account permanently", role: .destructive) { Task { _ = await backend.deleteAccount() } } } message: { Text("This deletes your account and private ledger/photos. Shared rooms remain with their members. Transfer ownership first if your room has housemates. This cannot be undone.") }
        .confirmationDialog("Make \(transferring?.display_name ?? "member") the room owner?", isPresented: Binding(get: { transferring != nil }, set: { if !$0 { transferring = nil } }), titleVisibility: .visible) { Button("Transfer ownership") { if let member = transferring { Task { await backend.transferOwnership(to: member) } }; transferring = nil } } message: { Text("They will manage invitations and membership. You will stay in the room as a member.") }
        .onChange(of: backend.roomID) { _, _ in inviting = false }
        .onChange(of: backend.user?.id) { _, _ in inviting = false }
    }
}
struct SignInView: View {
    @EnvironmentObject private var backend: SupabaseService
    @ObservedObject private var invitation = RoomInvitationRouter.shared
    @State private var email = ""
    @State private var password = ""
    @State private var creating = true
    @State private var showPassword = false
    @State private var message: String?
    @State private var privacy = false
    @FocusState private var focused: Field?
    private enum Field { case email, password }
    private var validEmail: Bool { email.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image("BrandLogo").resizable().frame(width: 80, height: 80).clipShape(RoundedRectangle(cornerRadius: 22))
                        Text("FGOTrack").font(.largeTitle.bold())
                        Text("Your money. Your people.").font(.title2.weight(.medium))
                        Text("Track personal expenses privately and share a pool with your housemates. Create an account to keep everything backed up.").foregroundStyle(.secondary)
                    }.padding(.top, 28)
                    if let token = invitation.pending { VStack(alignment: .leading, spacing: 12) { Label("Your room invitation is ready. Sign in or create an account to join.", systemImage: "person.badge.plus").font(.callout); Button("Dismiss invitation") { invitation.clear(token) }.font(.caption) }.padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)) }
                    Picker("Account", selection: $creating) { Text("Create account").tag(true); Text("Sign in").tag(false) }.pickerStyle(.segmented).onChange(of: creating) { _, _ in message = nil; backend.error = nil }
                    VStack(spacing: 14) {
                        TextField("Email address", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email).submitLabel(.next).onSubmit { focused = .password }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        HStack {
                            Group { if showPassword { TextField("Password", text: $password) } else { SecureField("Password", text: $password) } }.textContentType(creating ? .newPassword : .password).focused($focused, equals: .password).submitLabel(.go).onSubmit { submit() }
                            Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 44, height: 44) }.accessibilityLabel(showPassword ? "Hide password" : "Show password")
                        }.padding(.leading, 16).padding(.trailing, 6).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        if creating { Text("Use at least 8 characters.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        Button(action: submit) { HStack { if backend.working { ProgressView().tint(.white) }; Text(creating ? "Create account" : "Sign in").font(.headline) }.frame(maxWidth: .infinity).padding(.vertical, 14) }.buttonStyle(.borderedProminent).disabled(backend.working || !validEmail || password.count < (creating ? 8 : 1))
                    }
                    if let error = backend.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).accessibilityLabel("Account error: \(error)") }
                    if let message { Label(message, systemImage: "envelope.badge").font(.callout).foregroundStyle(accent) }
                    if !creating {
                        HStack { Button("Forgot password?") { Task { backend.error = nil; if await backend.resetPassword(email.trimmingCharacters(in: .whitespacesAndNewlines)) { message = "Check your email for a password reset link. Open it on this iPhone." } } }; Spacer(); Button("Email a sign-in link") { Task { backend.error = nil; if await backend.sendEmailLink(email.trimmingCharacters(in: .whitespacesAndNewlines)) { message = "Check your email and open the sign-in link on this iPhone." } } } }.font(.subheadline).disabled(!validEmail || backend.working)
                    }
                    if backend.appleEnabled { Button { Task { backend.error = nil; await backend.signInApple() } } label: { Label("Continue with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.bordered).disabled(backend.working) }
                    if backend.googleEnabled { Button { Task { backend.error = nil; await backend.signInGoogle() } } label: { Label("Continue with Google", systemImage: "globe").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.bordered).disabled(backend.working) }
                    Button("Privacy & internal-use information") { privacy = true }.font(.footnote)
                    Text("Account access is required for private backup and shared rooms. For help: business@knoworganization.com").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(canvas).tint(accent).scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $privacy) { NavigationStack { PrivacyPolicyView().toolbar { Button("Done") { privacy = false } } } }
        }
    }
    private func submit() {
        guard !backend.working, validEmail, password.count >= (creating ? 8 : 1) else { return }
        focused = nil; message = nil; backend.error = nil
        Task { message = await backend.signInEmail(email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, createAccount: creating) }
    }
}
struct PasswordRecoveryView: View {
    @EnvironmentObject private var backend: SupabaseService
    @State private var password = ""
    @State private var confirm = ""
    var body: some View {
        NavigationStack { Form { Section("Choose a new password") { SecureField("New password", text: $password).textContentType(.newPassword); SecureField("Confirm password", text: $confirm).textContentType(.newPassword); Text("Use at least 8 characters.").font(.caption) }; if let error = backend.error { Text(error).foregroundStyle(.red) } }.navigationTitle("Reset password").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save password") { Task { backend.error = nil; _ = await backend.updatePassword(password) } }.disabled(backend.working || password.count < 8 || password != confirm) } } }
    }
}
struct PrivacyPolicyView: View {
    var body: some View {
        List {
            Section("FGOTrack · Internal use") { Text("FGOTrack helps you track personal expenses and manage a pooled room budget. Account access is required. This build is distributed internally through TestFlight.") }
            Section("Information we store") { Text("Your account email, optional display name, user identifier, room membership, expense amounts and labels, budgets, dates, notes and any receipt photos you choose to attach. Your password is handled by Supabase Authentication; it is not stored in the app's ledger.") }
            Section("Personal and pooled data") { Text("Personal expenses, budgets and photos are visible only to your account through database access rules. Pooled expenses, budgets and photos are visible to members of your room. Anyone invited to a room can edit its pooled ledger. Room owners manage membership.") }
            Section("Backup and receipt AI") { Text("Supabase provides authentication, database and private photo storage. Changes first save on your device, then sync to Supabase. Text recognition and optional Apple Intelligence receipt extraction run on device. AI suggestions are not expenses until you confirm them. We do not send receipt text to a cloud AI provider.") }
            Section("Permissions and tracking") { Text("Camera permission is used only to capture receipts. The photo picker gives the app access only to photos you select. FGOTrack does not use advertising, cross-app tracking, location collection or analytics. Widgets show a local summary; they do not receive your password or authentication tokens.") }
            Section("Retention and deletion") { Text("Your account data is retained while you use FGOTrack. You can export your ledger from Settings. You can initiate account deletion from Settings → Your account. Transfer any room you own to another member first if it has housemates. Shared room records and photos remain with the room after you leave; your private ledger and photos are removed on completed deletion. Copies already exported by you or other room members are outside the app's control. Downloaded copies on other devices remain until their cache is removed. Deleting individual bills hides their attachments but does not automatically purge old photo files. Service backups may expire according to Supabase retention settings.") }
            Section("Your choices and support") { Text("You can correct or delete individual entries, remove receipt attachments, manage room access and contact us about account data. Contact: business@knoworganization.com."); Link("Email support", destination: URL(string: "mailto:business@knoworganization.com")!) }
            Section("Use of this internal build") { Text("Keep invitation links and QR codes private and only invite intended housemates. Check receipt totals and budgets against your records. FGOTrack records expenses; it does not transfer money or provide financial advice. Internal TestFlight builds may change or expire.") }
        }.navigationTitle("Privacy & information").navigationBarTitleDisplayMode(.inline)
    }
}
enum RoomEditorMode: String, Identifiable { case create, join; var id: String { rawValue } }
struct RoomEditor: View {
    let mode: RoomEditorMode
    @EnvironmentObject var backend: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var name = ""
    var body: some View {
        if mode == .join { InvitationEntryView() } else { NavigationStack {
            Form {
                Section(mode == .create ? "Your new room" : "Room invitation") {
                    TextField(mode == .create ? "Room name" : "Paste invitation link or code", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Your name in this room", text: $name).textContentType(.name)
                    Text(mode == .create ? "You will own this room and can invite or remove members." : "Joining gives you access to this room's pooled ledger and receipts. Your current room's data stays in its own ledger.").font(.caption).foregroundStyle(.secondary)
                }
                if backend.working { ProgressView() }
            }.navigationTitle(mode == .create ? "Create room" : "Join room")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(backend.working) }; ToolbarItem(placement: .confirmationAction) { Button(mode == .create ? "Create" : "Join") { Task { backend.error = nil; if mode == .create { await backend.createRoom(value.trimmingCharacters(in: .whitespacesAndNewlines), displayName: name.trimmingCharacters(in: .whitespacesAndNewlines)) } else { await backend.joinRoom(value, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines)) }; if backend.error == nil { dismiss() } } }.disabled(backend.working || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || (mode == .create && value.count > 80)) } }
            .onAppear { name = backend.displayName }
            .alert("Could not update room", isPresented: Binding(get: { backend.error != nil }, set: { if !$0 { backend.error = nil } })) { Button("OK") { backend.error = nil } } message: { Text(backend.error ?? "") }
        }
    }
    }
}
