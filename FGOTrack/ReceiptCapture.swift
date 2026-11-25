import SwiftUI
import UIKit
import Vision
import PhotosUI

struct ReceiptCamera: UIViewControllerRepresentable {
    var captured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ReceiptCamera
        init(parent: ReceiptCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { if let image = info[.originalImage] as? UIImage { parent.captured(image) }; parent.dismiss() }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
enum ReceiptImages {
    /// Downscales to 2000px and flattens onto white so OCR and uploads stay small and consistent.
    static func jpeg(_ image: UIImage) -> Data? {
        let scale = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.jpegData(compressionQuality: 0.82)
    }
    static func load(_ item: PhotosPickerItem) async throws -> UIImage {
        guard let bytes = try await item.loadTransferable(type: Data.self), let image = UIImage(data: bytes) else { throw ReceiptImageError.unreadable }
        return image
    }
}
enum ReceiptImageError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This photo could not be opened. Choose another photo." }
}

/// Receipt photo section of the expense editor. Scanning reports suggestions to the editor,
/// which fills only the fields the user has not changed.
struct ReceiptAttachment: View {
    @EnvironmentObject var store: HouseStore
    @Binding var data: Data?
    @Binding var changed: Bool
    let existing: LedgerEntry?
    var onSuggestions: (ReceiptSuggestions) -> Void
    var onLoadingChanged: (Bool) -> Void
    var onViewPhoto: () -> Void
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var cameraDenied = false
    @State private var scanID: UUID?
    @State private var scanning = false
    @State private var improving = false
    @State private var loading = false
    @State private var recognizedText = ""
    @State private var message: String?
    private var downloadFailed: Bool { !loading && data == nil && !changed && existing?.receiptFilename != nil }
    var body: some View {
        Section {
            if let data, let image = UIImage(data: data) {
                Button(action: onViewPhoto) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).frame(maxWidth: .infinity) }
                    .accessibilityLabel("Receipt photo").accessibilityHint("Opens the photo full screen")
                HStack {
                    Button("Read details from photo") { scanID = UUID() }.disabled(scanning)
                    Spacer()
                    Button("Remove", role: .destructive) { self.data = nil; changed = true; resetScan() }
                }.buttonStyle(.borderless)
            }
            HStack {
                if cameraDenied { Button(action: openAppSettings) { Label("Allow camera", systemImage: "gear") } }
                else { Button { Task { await openCamera() } } label: { Label(data == nil ? "Camera" : "Retake", systemImage: "camera") }.disabled(loading || !UIImagePickerController.isSourceTypeAvailable(.camera)) }
                Spacer()
                PhotosPicker(selection: $photo, matching: .images) { Label(data == nil ? "Photos" : "Replace", systemImage: "photo") }.disabled(loading)
            }.buttonStyle(.borderless)
            if loading { ProgressView("Loading receipt…") }
            if downloadFailed { Button("Retry photo download") { Task { await loadStoredPhoto() } } }
            if scanning { ProgressView(improving ? "Improving details on this iPhone…" : "Reading receipt…") }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !recognizedText.isEmpty { DisclosureGroup("Recognized text") { Text(recognizedText).font(.caption).textSelection(.enabled) } }
        } header: { Text(existing?.kind == .receipt ? "Receipt photo" : "Receipt photo · optional") }
        footer: { if data == nil { Text("Add a photo and FGOTrack fills empty fields on this iPhone. Personal photos stay private.") } }
        .fullScreenCover(isPresented: $camera) { ReceiptCamera { image in receive(image) }.ignoresSafeArea() }
        .task { await loadStoredPhoto() }
        .onChange(of: loading) { _, value in onLoadingChanged(value) }
        .onDisappear { onLoadingChanged(false) }
        .task(id: photo) {
            guard let selection = photo else { return }
            loading = true; message = nil
            defer { if photo == selection { loading = false; photo = nil } }
            do {
                let image = try await ReceiptImages.load(selection)
                guard !Task.isCancelled, photo == selection else { return }
                receive(image)
            } catch is CancellationError { }
            catch { if photo == selection { message = error.localizedDescription } }
        }
        .task(id: scanID) { await scan() }
    }
    private func openCamera() async {
        if await ReceiptCameraPermission.allowed() { camera = true }
        else { cameraDenied = true; message = "Camera access is off. Allow it in Settings, or choose a photo." }
    }
    private func resetScan() { scanID = nil; scanning = false; improving = false; recognizedText = ""; message = nil }
    private func scan() async {
        guard let expected = scanID, let data else { return }
        scanning = true; improving = false; recognizedText = ""; message = nil
        defer { if scanID == expected { scanning = false; improving = false } }
        do {
            let text = try await ReceiptOCR.recognize(data)
            guard !Task.isCancelled, scanID == expected else { return }
            recognizedText = text
            let fallback = ReceiptSuggestions.fallback(text)
            onSuggestions(fallback)
            improving = true
            let ai = await ReceiptIntelligence.suggestions(for: text, captured: Date())
            guard !Task.isCancelled, scanID == expected else { return }
            let merged = fallback.overridden(by: ai)
            if ai != nil { onSuggestions(merged) }
            message = merged.amount == nil ? "No clear total found. Enter the amount from the photo." : "Details filled from the photo. Check them before saving."
        } catch is CancellationError { }
        catch { if scanID == expected { message = "Could not read this photo. You can still save it and enter the amount." } }
    }
    private func loadStoredPhoto() async {
        guard let existing, existing.receiptFilename != nil, !changed, !loading else { return }
        loading = true; message = nil; defer { loading = false }
        do { let original = try await store.receiptData(for: existing); if !Task.isCancelled && !changed { data = original } }
        catch is CancellationError { }
        catch { message = "Could not download the photo. Check your connection and retry. \(error.localizedDescription)" }
    }
    private func receive(_ image: UIImage) {
        guard let bytes = ReceiptImages.jpeg(image) else { message = ReceiptImageError.unreadable.localizedDescription; return }
        data = bytes; changed = true; message = nil; scanID = UUID()
    }
}

import AVFoundation
enum ReceiptCameraPermission {
    static func allowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

struct ZoomableReceiptPhoto: UIViewControllerRepresentable {
    let image: UIImage
    func makeUIViewController(context: Context) -> ReceiptPhotoController { ReceiptPhotoController(image: image) }
    func updateUIViewController(_ controller: ReceiptPhotoController, context: Context) { controller.imageView.image = image }
}
final class ReceiptPhotoController: UIViewController, UIScrollViewDelegate {
    let scroll = UIScrollView()
    let imageView: UIImageView
    private var layoutSize = CGSize.zero
    init(image: UIImage) { imageView = UIImageView(image: image); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func loadView() {
        view = scroll; scroll.backgroundColor = .systemBackground
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true; imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true; imageView.accessibilityLabel = "Receipt photo"
        scroll.addSubview(imageView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:))); tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.size != layoutSize, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        layoutSize = scroll.bounds.size; scroll.setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: layoutSize); scroll.contentSize = layoutSize
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        imageView.center = CGPoint(x: max(scrollView.bounds.width, scrollView.contentSize.width) / 2, y: max(scrollView.bounds.height, scrollView.contentSize.height) / 2)
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.1 { scroll.setZoomScale(1, animated: true); return }
        let point = gesture.location(in: imageView), size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }
}
