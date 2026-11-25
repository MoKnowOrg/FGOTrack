import SwiftUI
import PhotosUI

/// Routes widget links such as `fgotrack://quick/photo?source=pooled`.
@MainActor final class QuickCaptureRouter: ObservableObject {
    enum Action: String { case photo, manual }
    static let shared = QuickCaptureRouter()
    @Published var action: Action?
    var funding: Funding?
    func open(_ url: URL) -> Bool {
        guard url.scheme == "fgotrack", url.host == "quick", let segment = url.path.split(separator: "/").first, let action = Action(rawValue: String(segment)) else { return false }
        funding = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "source" }?.value.flatMap { Funding(rawValue: $0.capitalized) }
        self.action = action; return true
    }
}

/// Camera-first capture: the photo is saved as a receipt draft immediately and reviewed later.
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
    @State private var cancelLoading = false
    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "camera.viewfinder").font(.system(size: 64)).foregroundStyle(controlAccent).accessibilityHidden(true)
                Text("One photo. Details later.").font(.title2.bold())
                Text("Your receipt saves immediately. FGOTrack suggests the total on this iPhone; confirm it later to add it to spending.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Label("Saving to \(funding.rawValue)", systemImage: funding.icon).font(.subheadline.weight(.semibold)).foregroundStyle(controlAccent)
                if cameraDenied {
                    Button(action: openAppSettings) { Label("Allow camera in Settings", systemImage: "gear").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                } else if cameraAvailable {
                    PrimaryButton(action: { Task { await openCamera() } }) { Label("Take photo", systemImage: "camera.fill") }.disabled(loading)
                }
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose from Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).disabled(loading)
                if !cameraAvailable { Text("The camera isn't available on this device.").font(.footnote).foregroundStyle(.secondary) }
                if loading { ProgressView("Saving receipt…") }
                if let message { Text(message).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer()
            }.padding(24).navigationTitle("Scan receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if loading { cancelLoading = true } else { dismiss() } }.disabled(saved) } }
        }
        .fullScreenCover(isPresented: $camera) { ReceiptCamera { image in save(image) }.ignoresSafeArea() }
        .task {
            expectedAccount = store.accountID; expectedRoom = store.activeRoomID; ready = true
            funding = store.activeRoomID == nil ? .personal : initialFunding
            await openCamera()
        }
        .interactiveDismissDisabled(loading || saved)
        .confirmationDialog("Stop loading this receipt?", isPresented: $cancelLoading, titleVisibility: .visible) { Button("Stop and close", role: .destructive) { dismiss() }; Button("Keep loading", role: .cancel) {} } message: { Text("This photo has not been saved. You can select it again later.") }
        .task(id: photo) {
            guard let item = photo else { return }
            loading = true; message = nil
            defer { if photo == item { loading = false; photo = nil } }
            do {
                let image = try await ReceiptImages.load(item)
                guard !Task.isCancelled, photo == item, contextMatches else { return }
                save(image)
            } catch is CancellationError { }
            catch { if photo == item { message = error.localizedDescription } }
        }
    }
    private func openCamera() async {
        guard cameraAvailable else { return }
        if await ReceiptCameraPermission.allowed() { if !loading && !saved && photo == nil && contextMatches { camera = true } }
        else { cameraDenied = true; message = "Camera access is off. Allow it in Settings, or choose a photo instead." }
    }
    private var contextMatches: Bool { ready && expectedAccount == store.accountID && expectedRoom == store.activeRoomID }
    private func save(_ image: UIImage) {
        guard contextMatches, !saved else { loading = false; return }
        do {
            guard let data = ReceiptImages.jpeg(image) else { throw ReceiptImageError.unreadable }
            let filename = try store.keepReceipt(data)
            let entry = LedgerEntry(kind: .receipt, title: "Receipt to review", amount: 0, date: Date(), funding: funding, receiptFilename: filename)
            try store.save(entry)
            saved = true
            store.readQuickReceipt(entry, data: data)
            // Let the camera finish dismissing before closing its parent sheet.
            Task { try? await Task.sleep(for: .milliseconds(400)); if contextMatches { onSaved(funding); dismiss() } }
        } catch { loading = false; message = error.localizedDescription }
    }
}
