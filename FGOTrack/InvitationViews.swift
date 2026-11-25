import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor final class RoomInvitationRouter: ObservableObject {
    static let shared = RoomInvitationRouter()
    @Published private(set) var pending: UUID?
    private let key = "pending-room-invitation"
    init() { pending = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) }
    func open(_ url: URL) -> Bool {
        guard let token = RoomInvitation.token(from: url.absoluteString) else { return false }
        pending = token; UserDefaults.standard.set(token.uuidString, forKey: key); return true
    }
    func clear(_ token: UUID) {
        guard pending == token else { return }
        pending = nil; UserDefaults.standard.removeObject(forKey: key)
    }
}
struct InvitationRoute: Identifiable { let token: UUID; var id: UUID { token } }

private func invitationQR(_ url: URL) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    // Keep the four-module quiet zone in the exported QR image too.
    let bounds = output.extent.insetBy(dx: -40, dy: -40)
    let bordered = output.composited(over: CIImage(color: .white).cropped(to: bounds))
    guard let image = CIContext().createCGImage(bordered, from: bounds) else { return nil }
    return UIImage(cgImage: image)
}
struct InvitationShareSheet: UIViewControllerRepresentable {
    let room: String
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: ["Join \(room) in FGOTrack. Open this invitation on your iPhone:", url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
struct InvitePeopleView: View {
    let room: HouseRoom
    var shareImmediately = true
    @EnvironmentObject private var backend: SupabaseService
    @Environment(\.dismiss) private var dismiss
    @State private var link: RoomInviteLink?
    @State private var qr: UIImage?
    @State private var loading = false
    @State private var message: String?
    @State private var sharing = false
    @State private var replacing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(controlAccent).accessibilityHidden(true)
                    Text("Invite to \(room.name)").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("They open your invitation, sign in, and tap Join room. Their personal spending stays private.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if link != nil {
                        if let qr {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240).padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Room invitation QR code")
                            Text("Housemate nearby? They can scan this with the iPhone Camera.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        PrimaryButton(action: { sharing = true }) { Label("Share invitation link", systemImage: "square.and.arrow.up") }
                        if let qr { ShareLink("Share QR image", item: Image(uiImage: qr), preview: SharePreview("Join \(room.name) in FGOTrack", image: Image(uiImage: qr))) }
                        Text("Only invite housemates: the link gives access to pooled bills and receipts. It expires after 7 days or 20 joins. They need FGOTrack installed from TestFlight first.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Replace invitation", role: .destructive) { replacing = true }.font(.footnote).disabled(backend.working || loading)
                    } else if loading { ProgressView("Preparing invitation…") }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }
                    }
                }.padding(24)
            }.background(canvas).navigationTitle("Invite people").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(controlAccent)
        .task { await load(); if link != nil && shareImmediately { sharing = true } }
        .sheet(isPresented: $sharing) { if let link { InvitationShareSheet(room: room.name, url: link.url).presentationDetents([.medium, .large]) } }
        .confirmationDialog("Replace the current invitation?", isPresented: $replacing, titleVisibility: .visible) {
            Button("Replace invitation", role: .destructive) { Task { await replace() } }
        } message: { Text("Links and QR codes you already shared stop working. Current members stay in the room.") }
    }
    private func load() async {
        guard !loading else { return }; loading = true; message = nil; defer { loading = false }
        do {
            let result = try await backend.invitationLink(room: room.id)
            guard backend.currentRoom?.id == room.id else { return }
            link = result; qr = invitationQR(result.url)
        } catch { message = error.localizedDescription }
    }
    private func replace() async {
        do { try await backend.replaceInvitation(room: room.id); await load() }
        catch { message = error.localizedDescription }
    }
}
struct JoinInvitationView: View {
    let token: UUID
    var finished: () -> Void
    @EnvironmentObject private var backend: SupabaseService
    @EnvironmentObject private var store: HouseStore
    @State private var preview: RoomInvitePreview?
    @State private var name = ""
    @State private var message: String?
    @State private var loading = false
    private var busy: Bool { backend.working || store.syncing }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    BrandMark()
                    if let preview {
                        Text(preview.already_member ? "You're already in \(preview.room_name)" : "Join \(preview.room_name)").font(.title.bold()).multilineTextAlignment(.center)
                        Label("\(preview.member_count) \(preview.member_count == 1 ? "housemate" : "housemates")", systemImage: "person.3.fill").foregroundStyle(.secondary)
                        Text("Share one pool, budgets and receipt photos. Your personal expenses stay private.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if !preview.already_member {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your name in the room").font(.caption).foregroundStyle(.secondary)
                                TextField("Name", text: $name).textContentType(.name).submitLabel(.join).onSubmit { Task { await join() } }.inputField()
                            }
                        }
                        PrimaryButton(loading: busy, action: { Task { await join() } }) { Text(preview.already_member ? "Open room" : "Join room") }
                            .disabled(busy || name.trimmed.isEmpty || name.count > 80)
                        if store.syncing { Text("Finishing a backup first…").font(.caption).foregroundStyle(.secondary) }
                    } else if loading { ProgressView("Opening invitation…") }
                    if let message {
                        Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                        if preview == nil { Button("Try again") { Task { await load() } } }
                    }
                }.padding(24).padding(.top, 24)
            }.background(canvas).navigationTitle("Room invitation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now", action: finished).disabled(backend.working) } }
        }.tint(controlAccent).task { if name.isEmpty { name = backend.displayName }; await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; message = nil; defer { loading = false }
        do { preview = try await backend.invitationPreview(token: token) }
        catch { message = error.localizedDescription }
    }
    private func join() async {
        guard !busy, !name.trimmed.isEmpty else { return }
        message = nil
        guard await backend.joinRoom(token.uuidString, displayName: name.trimmed) else { message = backend.error; backend.error = nil; return }
        finished()
    }
}

struct InvitationEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    private var token: UUID? { RoomInvitation.token(from: value) }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label("Open your housemate's invitation", systemImage: "person.badge.plus").font(.title2.bold())
                Text("Tap the invitation link you received, or scan their QR code with the iPhone Camera. You'll see the room before joining.").foregroundStyle(.secondary)
                TextField("Invitation link or code", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.go).onSubmit(open).inputField()
                if !value.trimmed.isEmpty && token == nil { Text("That doesn't look like an FGOTrack invitation link.").font(.caption).foregroundStyle(.red) }
                PasteButton(payloadType: String.self) { values in if let text = values.first { value = text } }.buttonBorderShape(.capsule)
                PrimaryButton(action: open) { Text("Open invitation") }.disabled(token == nil)
                Spacer()
            }.padding(24).background(canvas).navigationTitle("Room invitation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(controlAccent)
    }
    private func open() {
        guard let token else { return }
        _ = RoomInvitationRouter.shared.open(RoomInvitation.url(token: token)); dismiss()
    }
}
