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
    @State private var loading = false
    @State private var message: String?
    @State private var sharing = false
    @State private var replacing = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "person.badge.plus").font(.system(size: 44)).foregroundStyle(accent)
                    Text("Invite to \(room.name)").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("They open your invitation, sign in, and tap Join room. Their personal spending stays private.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let link {
                        if let qr = invitationQR(link.url) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Room invitation QR code")
                            Text("Housemate nearby? Scan this with the iPhone Camera.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { sharing = true } label: { Label("Share invitation", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent)
                        ShareLink("Share QR image", item: Image(uiImage: invitationQR(link.url) ?? UIImage()), preview: SharePreview("Join \(room.name) in FGOTrack", image: Image("BrandLogo")))
                        Text("Invite only your housemates. This link lets them access and edit pooled bills and receipts. It expires after 7 days or 20 new joins.").font(.caption).foregroundStyle(.secondary)
                        Text("Install FGOTrack from your internal TestFlight invitation first.").font(.caption).foregroundStyle(.secondary)
                        Button("Replace invitation") { replacing = true }.font(.footnote).disabled(backend.working || loading)
                    } else if loading { ProgressView("Preparing invitation…") }
                    if let message { Text(message).font(.callout).foregroundStyle(.red); Button("Try again") { Task { await load() } } }
                }.padding(24)
            }.background(canvas).navigationTitle("Invite people").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(accent)
        .task { await load(); if link != nil && shareImmediately { sharing = true } }
        .sheet(isPresented: $sharing) { if let link { InvitationShareSheet(room: room.name, url: link.url).presentationDetents([.medium, .large]) } }
        .confirmationDialog("Replace the current invitation?", isPresented: $replacing, titleVisibility: .visible) { Button("Replace invitation", role: .destructive) { Task { backend.error = nil; if await backend.inviteCode() != nil { await load() } else { message = backend.error } } } } message: { Text("Previous invitations and QR codes stop working. Current members stay in the room.") }
    }
    private func load() async {
        guard !loading else { return }; loading = true; message = nil; defer { loading = false }
        do { let result = try await backend.invitationLink(room: room.id); guard backend.currentRoom?.id == room.id else { return }; link = result }
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image("BrandLogo").resizable().frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 20))
                    if let preview {
                        Text(preview.already_member ? "You're already in \(preview.room_name)" : "Join \(preview.room_name)").font(.title.bold()).multilineTextAlignment(.center)
                        Label("\(preview.member_count) \(preview.member_count == 1 ? "housemate" : "housemates")", systemImage: "person.3.fill").foregroundStyle(.secondary)
                        Text("Share one pool, budgets and receipt photos. Your personal expenses stay private.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if !preview.already_member { VStack(alignment: .leading, spacing: 8) { Text("Your name in the room").font(.caption).foregroundStyle(.secondary); TextField("Name", text: $name).textContentType(.name).padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14)) } }
                        Button { Task { await join() } } label: { HStack { if backend.working || store.syncing { ProgressView().tint(.white) }; Text(preview.already_member ? "Open room" : "Join room").font(.headline) }.frame(maxWidth: .infinity).padding(14) }.buttonStyle(.borderedProminent).disabled(backend.working || store.syncing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                    } else if loading { ProgressView("Opening invitation…") }
                    if let message { Text(message).foregroundStyle(.red).multilineTextAlignment(.center); Button("Try again") { Task { await load() } } }
                }.padding(24).padding(.top, 24)
            }.background(canvas).navigationTitle("Room invitation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now", action: finished).disabled(backend.working) } }
        }.tint(accent).task { name = backend.displayName; await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; message = nil; defer { loading = false }
        do { preview = try await backend.invitationPreview(token: token) }
        catch { message = error.localizedDescription }
    }
    private func join() async {
        guard await backend.joinRoom(token.uuidString, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines)) else { message = backend.error; return }
        finished()
    }
}

struct InvitationEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Label("Open your housemate's invitation", systemImage: "person.badge.plus").font(.title2.bold())
                Text("Tap the invitation link you received, or scan their QR code with your iPhone Camera. You’ll see the room before joining.").foregroundStyle(.secondary)
                TextField("Invitation link or code", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                PasteButton(payloadType: String.self) { values in if let text = values.first { value = text } }.buttonBorderShape(.capsule)
                Button { if let token = RoomInvitation.token(from: value) { _ = RoomInvitationRouter.shared.open(RoomInvitation.url(token: token)); dismiss() } } label: { Text("Open invitation").font(.headline).frame(maxWidth: .infinity).padding(14) }.buttonStyle(.borderedProminent).disabled(RoomInvitation.token(from: value) == nil)
                Spacer()
            }.padding(24).background(canvas).navigationTitle("Room invitation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(accent)
    }
}
