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
    static func jpeg(_ image: UIImage) -> Data? {
        let scale = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
        }
        return normalized.jpegData(compressionQuality: 0.82)
    }
    static func recognize(_ data: Data) async throws -> String {
        try await ReceiptOCR.recognize(data)
    }

}


struct ReceiptAttachment: View {
    @EnvironmentObject var store: HouseStore
    @Binding var data: Data?
    @Binding var changed: Bool
    @Binding var amount: String
    @Binding var title: String
    @Binding var date: Date
    @Binding var category: Category
    let existing: LedgerEntry?
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var scanID = UUID()
    @State private var shouldScan = false
    @State private var scanning = false
    @State private var loading = false
    @State private var suggestion: Int64?
    @State private var recognizedText = ""
    @State private var message: String?
    @State private var fullPhoto = false
    @State private var modelSuggestion: ReceiptSuggestions?
    @State private var improving = false
    var body: some View {
        Section("Receipt photo · optional") {
            if let data, let image = UIImage(data: data) {
                Button { fullPhoto = true } label: { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).frame(maxWidth: .infinity) }.accessibilityLabel("View receipt photo")
                HStack { Button("Read amount from photo") { shouldScan = true; scanID = UUID() }.disabled(scanning).buttonStyle(.borderless); Spacer(); Button("Remove", role: .destructive) { self.data = nil; changed = true; suggestion = nil; recognizedText = ""; scanID = UUID(); shouldScan = false; scanning = false; improving = false; modelSuggestion = nil }.buttonStyle(.borderless) }
            }
            HStack {
                Button { Task { if await ReceiptCameraPermission.allowed() { camera = true } else { message = "Camera access is disabled. Enable it in Settings, or choose a photo from your library." } } } label: { Label("Camera", systemImage: "camera") }.disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Spacer()
                PhotosPicker(selection: $photo, matching: .images) { Label("Photo library", systemImage: "photo") }
            }.buttonStyle(.borderless)
            if loading { ProgressView("Loading receipt…") }
            if scanning { ProgressView(improving ? "Improving details on this device…" : "Reading receipt on your iPhone…") }
            if let suggestion {
                Button("Use suggested amount: \(money(suggestion))") { amount = NSDecimalNumber(decimal: Decimal(suggestion) / 100).stringValue }
                Text("Check the total against the photo before saving.").font(.caption).foregroundStyle(.secondary)
            }
            if let modelSuggestion {
                Button("Use on-device AI details") {
                    if let merchant = modelSuggestion.merchant { title = merchant }
                    if let total = modelSuggestion.amount { amount = NSDecimalNumber(decimal: Decimal(total) / 100).stringValue }
                    if let suggestedDate = modelSuggestion.date { date = suggestedDate }
                    if let suggestedCategory = modelSuggestion.category { category = suggestedCategory }
                }
                Text("AI suggestions need a check against the photo. Missing details stay manual.").font(.caption).foregroundStyle(.secondary)
            }
            if !recognizedText.isEmpty { DisclosureGroup("Recognized receipt text") { Text(recognizedText).font(.caption).textSelection(.enabled) } }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("Keep the photo and enter the amount manually, or use free on-device text recognition. Personal receipt photos stay private.").font(.caption).foregroundStyle(.secondary)
        }
        .fullScreenCover(isPresented: $camera) { ReceiptCamera { image in receive(image) }.ignoresSafeArea() }
        .sheet(isPresented: $fullPhoto) { NavigationStack { if let data, let image = UIImage(data: data) { ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1200) }.navigationTitle("Receipt").toolbar { Button("Done") { fullPhoto = false } } } } }
        .task {
            guard let existing, existing.receiptFilename != nil else { return }
            loading = true; defer { loading = false }
            do { let original = try await store.receiptData(for: existing); if !changed { data = original } }
            catch is CancellationError { }
            catch { message = "Could not load the stored photo: \(error.localizedDescription)" }
        }
        .onChange(of: photo) { _, selection in
            Task { do { guard let bytes = try await selection?.loadTransferable(type: Data.self), let image = UIImage(data: bytes), photo == selection else { return }; receive(image) } catch { message = error.localizedDescription } }
        }
        .task(id: scanID) {
            guard shouldScan, let data else { return }
            let expected = scanID
            scanning = true; suggestion = nil; recognizedText = ""; modelSuggestion = nil; improving = false
            do {
                let text = try await ReceiptImages.recognize(data)
                guard !Task.isCancelled, scanID == expected else { return }
                recognizedText = text; suggestion = ReceiptAmountParser.suggestedAmount(in: text)
                message = suggestion == nil ? "No clear total was found. Enter the amount manually." : nil
                improving = true
                let enhanced = await ReceiptIntelligence.suggestions(for: text, captured: Date())
                guard !Task.isCancelled, scanID == expected else { return }
                modelSuggestion = enhanced
                improving = false
            } catch { if scanID == expected { message = "Could not read this photo. You can still save it and enter the amount manually." } }
            if scanID == expected { scanning = false }
        }
    }
    private func receive(_ image: UIImage) {
        guard let bytes = ReceiptImages.jpeg(image) else { message = "Could not read this image. Try another photo."; return }
        data = bytes; changed = true; message = nil; shouldScan = true; scanID = UUID()
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
