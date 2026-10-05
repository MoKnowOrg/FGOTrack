import SwiftUI
import PhotosUI

@MainActor final class QuickCaptureRouter: ObservableObject {
    static let shared = QuickCaptureRouter()
    @Published var action: String?
    var funding: Funding?
    func open(_ url: URL) -> Bool {
        guard url.scheme == "fgotrack", url.host == "quick", let action = url.path.split(separator: "/").first, ["photo", "manual", "inbox"].contains(String(action)) else { return false }
        funding = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source" }?.value.flatMap { $0 == "personal" ? .personal : $0 == "pooled" ? .pooled : nil }
        self.action = String(action); return true
    }
}

struct QuickReceiptCapture: View {
    var initialFunding: Funding = .pooled
    var onSaved: (Funding) -> Void = { _ in }
    @EnvironmentObject var store: HouseStore
    @Environment(\.dismiss) private var dismiss
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    @State private var loading = false
    @State private var message: String?
    @State private var funding: Funding = .pooled
    @State private var expectedAccount: UUID?
    @State private var expectedRoom: UUID?
    @State private var ready = false
    @State private var saved = false
    @State private var cameraDenied = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "camera.viewfinder").font(.system(size: 64)).foregroundStyle(accent)
                Text("One photo. Details later.").font(.title2.bold())
                Text("Your receipt saves immediately. We’ll suggest details using on-device text recognition and receipt AI when available. Review it later to add it to spending.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Label("Saving to \(funding.rawValue)", systemImage: funding == .pooled ? "person.3.fill" : "person.crop.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                if cameraDenied {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: { Label("Enable camera in Settings", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.bordered)
                } else {
                    Button { Task { await openCamera() } } label: { Label("Take photo", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent).disabled(loading || !UIImagePickerController.isSourceTypeAvailable(.camera))
                }
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose receipt photo", systemImage: "photo") }.disabled(loading)
                if loading { ProgressView("Saving receipt…") }
                if let message { Text(message).font(.callout).foregroundStyle(.red) }
                Spacer()
            }.padding(24).navigationTitle("Quick receipt").toolbar { Button("Close") { dismiss() } }
        }
        .fullScreenCover(isPresented: $camera) { ReceiptCamera { image in save(image) }.ignoresSafeArea() }
        .task {
            expectedAccount = store.accountID; expectedRoom = store.activeRoomID; ready = true
            funding = store.activeRoomID == nil ? .personal : initialFunding
            await openCamera()
        }
        .onChange(of: photo) { _, item in
            loading = true
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), photo == item, let image = UIImage(data: data) else { loading = false; return }
                    save(image)
                } catch { loading = false; message = error.localizedDescription }
            }
        }
    }
    private func openCamera() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        if await ReceiptCameraPermission.allowed() { if !loading && !saved && photo == nil && contextMatches { camera = true } }
        else { cameraDenied = true; message = "Enable camera access in Settings, or choose a receipt photo." }
    }
    private var contextMatches: Bool { ready && expectedAccount == store.accountID && expectedRoom == store.activeRoomID }
    private func save(_ image: UIImage) {
        guard contextMatches, !saved else { loading = false; return }
        do {
            guard let data = ReceiptImages.jpeg(image) else { throw CocoaError(.fileWriteUnknown) }
            let filename = try store.keepReceipt(data)
            let entry = LedgerEntry(kind: .receipt, title: "Receipt to review", amount: 0, date: Date(), funding: funding, receiptFilename: filename)
            guard store.save(entry) else { message = store.error; store.error = nil; loading = false; return }
            saved = true
            store.readQuickReceipt(entry, data: data)
            // Let the camera finish dismissing before closing its parent sheet.
            Task { try? await Task.sleep(for: .milliseconds(400)); if contextMatches { onSaved(funding); dismiss() } }
        } catch { loading = false; message = error.localizedDescription }
    }
}
