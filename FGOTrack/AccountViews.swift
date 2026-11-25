import SwiftUI

/// Account, room and membership sections of Settings.
struct AccountSections: View {
    @EnvironmentObject private var backend: SupabaseService
    @EnvironmentObject private var store: HouseStore
    @State private var roomEditor: RoomEditorMode?
    @State private var inviting = false
    @State private var removing: RoomMember?
    @State private var transferring: RoomMember?
    @State private var importing = false
    @State private var signingOut = false
    private var busy: Bool { backend.working || store.syncing }
    var body: some View {
        if let user = backend.user {
            Section("Account") {
                LabeledContent { Text(user.email ?? "") } label: { Label(backend.displayName, systemImage: "person.crop.circle.fill") }
                Button("Sign out") { signingOut = true }.disabled(busy)
            }
            .confirmationDialog("Sign out of FGOTrack?", isPresented: $signingOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await backend.signOut() } }
            } message: { Text(store.syncError == nil ? "Your data stays backed up and on this iPhone." : "Some changes haven't been backed up yet. They stay on this iPhone and sync when you sign back in.") }
            .alert("Account or room needs attention", isPresented: Binding(get: { backend.error != nil && roomEditor == nil }, set: { if !$0 { backend.error = nil } })) { Button("OK") { backend.error = nil } } message: { Text(backend.error ?? "") }
            Section {
                if backend.rooms.count > 1 {
                    Picker("Active room", selection: Binding(get: { backend.roomID }, set: { backend.selectRoom($0) })) {
                        ForEach(backend.rooms) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(busy)
                } else if let room = backend.currentRoom {
                    LabeledContent("Room", value: room.name)
                }
                if backend.isOwner { Button { inviting = true } label: { Label("Invite people", systemImage: "person.badge.plus") }.disabled(busy) }
                Button { roomEditor = .join } label: { Label("Join with an invitation", systemImage: "envelope.open") }.disabled(busy)
                Button { roomEditor = .create } label: { Label("Create a room", systemImage: "plus.circle") }.disabled(busy)
            } header: { Text("Shared room") }
            footer: { Text(backend.currentRoom == nil ? "Create or join a room to share a pool. Personal expenses work without a room." : "Pooled expenses, budgets and photos are shared with this room's members.") }
            .sheet(item: $roomEditor) { RoomEditor(mode: $0) }
            .sheet(isPresented: $inviting) { if let room = backend.currentRoom { InvitePeopleView(room: room) } }
            .onChange(of: backend.roomID) { _, _ in inviting = false }
            .onChange(of: backend.user?.id) { _, _ in inviting = false }
            if backend.currentRoom != nil {
                Section("People") {
                    ForEach(backend.members) { member(row: $0, me: user.id) }
                }
                .confirmationDialog("Remove \(removing?.display_name ?? "member") from this room?", isPresented: Binding(present: $removing), titleVisibility: .visible) {
                    Button("Remove from room", role: .destructive) { if let member = removing { Task { await backend.removeMember(member) } }; removing = nil }
                } message: { Text("They lose access to the shared pool and receipt photos. Current invitation links stop working.") }
                .confirmationDialog("Make \(transferring?.display_name ?? "member") the room owner?", isPresented: Binding(present: $transferring), titleVisibility: .visible) {
                    Button("Transfer ownership") { if let member = transferring { Task { await backend.transferOwnership(to: member) } }; transferring = nil }
                } message: { Text("They will manage invitations and membership. You stay in the room as a member.") }
                if store.canImportLocalLedger {
                    Section {
                        Button("Import bills from this iPhone") { importing = true }.disabled(store.syncing)
                    } header: { Text("Earlier bills on this iPhone") } footer: { Text("Bills saved before you had an account stay on this iPhone until you import them. Pooled bills become visible to this room; personal bills stay private.") }
                    .confirmationDialog("Import this iPhone's earlier bills into \(backend.currentRoom?.name ?? "this room")?", isPresented: $importing, titleVisibility: .visible) {
                        Button("Import bills") { do { try store.importLocalLedger() } catch { backend.error = error.localizedDescription } }
                    } message: { Text("Adds earlier pooled bills, contributions and budgets to the room. Personal bills stay private. You can do this once per account.") }
                }
            }
        }
    }
    private func member(row member: RoomMember, me: UUID) -> some View {
        let isOwner = member.user_id == backend.currentRoom?.owner_id, isMe = member.user_id == me
        return HStack {
            Label(member.display_name, systemImage: "person.crop.circle")
            Spacer()
            if isOwner || isMe { Text([isMe ? "You" : nil, isOwner ? "Owner" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            if backend.isOwner && !isMe {
                Menu {
                    Button { transferring = member } label: { Label("Make room owner", systemImage: "crown") }
                    Button(role: .destructive) { removing = member } label: { Label("Remove from room", systemImage: "person.badge.minus") }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Manage \(member.display_name)").disabled(backend.working)
            }
        }
    }
}

/// Kept at the bottom of Settings, away from everyday actions.
struct DeleteAccountSection: View {
    @EnvironmentObject private var backend: SupabaseService
    @EnvironmentObject private var store: HouseStore
    @State private var deleting = false
    var body: some View {
        if backend.user != nil {
            Section {
                Button("Delete account", role: .destructive) { deleting = true }.disabled(backend.working || store.syncing)
            } footer: { Text("Permanently deletes your account, personal ledger and photos. Shared rooms stay with their members.") }
            .confirmationDialog("Delete your FGOTrack account?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete account permanently", role: .destructive) { Task { _ = await backend.deleteAccount() } }
            } message: { Text("This deletes your account and private ledger and photos. Shared rooms remain with their members; transfer ownership first if your room has housemates. This cannot be undone.") }
        }
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
    private var trimmedEmail: String { email.trimmed }
    private var validEmail: Bool { trimmedEmail.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil }
    private var canSubmit: Bool { !backend.working && validEmail && password.count >= (creating ? 8 : 1) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BrandMark(size: 80)
                        Text("FGOTrack").font(.largeTitle.bold())
                        Text("Your money. Your people.").font(.title2.weight(.medium))
                        Text("Track personal expenses privately and share a pool with your housemates. An account keeps everything backed up.").foregroundStyle(.secondary)
                    }.padding(.top, 28)
                    if let token = invitation.pending {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Your room invitation is ready. Sign in or create an account to join.", systemImage: "person.badge.plus").font(.callout)
                            Button("Dismiss invitation") { invitation.clear(token) }.font(.caption)
                        }.padding(14).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Picker("Account", selection: $creating) { Text("Create account").tag(true); Text("Sign in").tag(false) }
                        .pickerStyle(.segmented).onChange(of: creating) { _, _ in message = nil; backend.error = nil }
                    VStack(spacing: 14) {
                        TextField("Email address", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused, equals: .email).submitLabel(.next).onSubmit { focused = .password }.inputField()
                        HStack {
                            Group { if showPassword { TextField("Password", text: $password) } else { SecureField("Password", text: $password) } }
                                .textContentType(creating ? .newPassword : .password).focused($focused, equals: .password).submitLabel(.go).onSubmit(submit)
                            Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 44, height: 44) }
                                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                        }.padding(.leading, 16).padding(.trailing, 6).background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
                        if creating { Text("Use at least 8 characters.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        PrimaryButton(loading: backend.working, action: submit) { Text(creating ? "Create account" : "Sign in") }.disabled(!canSubmit)
                    }.disabled(backend.working)
                    if let error = backend.error { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                    if let message { Label(message, systemImage: "envelope.badge").font(.callout).foregroundStyle(controlAccent) }
                    if !creating {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Forgot password?") { emailAction(backend.resetPassword, sent: "Check your email for a password reset link. Open it on this iPhone.") }
                                Spacer()
                                Button("Email me a sign-in link") { emailAction(backend.sendEmailLink, sent: "Check your email and open the sign-in link on this iPhone.") }
                            }.font(.subheadline).disabled(!validEmail || backend.working)
                            if !validEmail { Text("Enter your email above to reset your password or get a sign-in link.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if backend.appleEnabled || backend.googleEnabled {
                        VStack(spacing: 10) {
                            if backend.appleEnabled { socialButton("Continue with Apple", icon: "apple.logo", backend.signInApple) }
                            if backend.googleEnabled { socialButton("Continue with Google", icon: "globe", backend.signInGoogle) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Privacy & information") { privacy = true }.font(.footnote)
                        Text("An account is required for private backup and shared rooms. Help: \(AppInfo.supportEmail)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }.background(canvas).tint(controlAccent).scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $privacy) { NavigationStack { PrivacyPolicyView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { privacy = false } } } } }
        }
    }
    private func socialButton(_ title: String, icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { backend.error = nil; await action() } } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity) }
            .buttonStyle(.bordered).controlSize(.large).disabled(backend.working)
    }
    private func emailAction(_ action: @escaping (String) async -> Bool, sent: String) {
        Task { backend.error = nil; message = nil; if await action(trimmedEmail) { message = sent } }
    }
    private func submit() {
        guard canSubmit else { return }
        focused = nil; message = nil; backend.error = nil
        Task { message = await backend.signInEmail(trimmedEmail, password: password, createAccount: creating) }
    }
}

struct PasswordRecoveryView: View {
    @EnvironmentObject private var backend: SupabaseService
    @State private var password = ""
    @State private var confirm = ""
    private var mismatch: Bool { !confirm.isEmpty && password != confirm }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password).textContentType(.newPassword)
                    SecureField("Confirm password", text: $confirm).textContentType(.newPassword)
                } header: { Text("Choose a new password") }
                footer: { Text(mismatch ? "Passwords don't match." : "Use at least 8 characters.").foregroundStyle(mismatch ? .red : .secondary) }
                if let error = backend.error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Reset password").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { backend.recoveringPassword = false }.disabled(backend.working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { backend.error = nil; _ = await backend.updatePassword(password) } }
                        .fontWeight(.semibold).disabled(backend.working || password.count < 8 || password != confirm)
                }
            }
        }
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
            Section("Retention and deletion") { Text("Your account data is retained while you use FGOTrack. You can export your ledger from Settings. You can delete your account at the bottom of Settings. Transfer any room you own to another member first if it has housemates. Shared room records and photos remain with the room after you leave; your private ledger and photos are removed on completed deletion. Copies already exported by you or other room members are outside the app's control. Downloaded copies on other devices remain until their cache is removed. Deleting individual bills hides their attachments but does not automatically purge old photo files. Service backups may expire according to Supabase retention settings.") }
            Section("Your choices and support") { Text("You can correct or delete individual entries, remove receipt attachments, manage room access and contact us about account data."); Link("Email \(AppInfo.supportEmail)", destination: AppInfo.supportURL) }
            Section("Use of this internal build") { Text("Keep invitation links and QR codes private and only invite intended housemates. Check receipt totals and budgets against your records. FGOTrack records expenses; it does not transfer money or provide financial advice. Internal TestFlight builds may change or expire.") }
        }.navigationTitle("Privacy & information").navigationBarTitleDisplayMode(.inline)
    }
}

enum RoomEditorMode: String, Identifiable { case create, join; var id: String { rawValue } }
struct RoomEditor: View {
    let mode: RoomEditorMode
    var body: some View { if mode == .join { InvitationEntryView() } else { CreateRoomView() } }
}

struct CreateRoomView: View {
    @EnvironmentObject private var backend: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var name = ""
    @FocusState private var focused: Bool
    private var valid: Bool { !roomName.trimmed.isEmpty && roomName.count <= 80 && !name.trimmed.isEmpty && name.count <= 80 }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Room name, e.g. Indiranagar house", text: $roomName).textInputAutocapitalization(.words).focused($focused).submitLabel(.next)
                    TextField("Your name in this room", text: $name).textContentType(.name).submitLabel(.done).onSubmit(create)
                } footer: { Text("You'll own this room and can invite or remove housemates.") }
            }
            .navigationTitle("Create room").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(backend.working) }
                ToolbarItem(placement: .confirmationAction) {
                    if backend.working { ProgressView() } else { Button("Create", action: create).fontWeight(.semibold).disabled(!valid) }
                }
            }
            .onAppear { if name.isEmpty { name = backend.displayName }; focused = true }
            .messageAlert("Could not create room", message: $backend.error)
        }
        .interactiveDismissDisabled(backend.working)
    }
    private func create() {
        guard valid, !backend.working else { return }
        Task { if await backend.createRoom(roomName.trimmed, displayName: name.trimmed) { dismiss() } }
    }
}
