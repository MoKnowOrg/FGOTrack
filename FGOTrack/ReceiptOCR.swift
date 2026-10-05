import Foundation
import Vision

enum ReceiptOCR {
    static func recognize(_ data: Data) async throws -> String {
        let job = ReceiptOCRJob(data: data)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { job.start($0) }
        } onCancel: { job.cancel() }
    }
}

/// Vision's synchronous work runs off the main thread. A slow/unavailable model must
/// never trap the user in an endless spinner; manual entry remains available.
private final class ReceiptOCRJob: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private let request = VNRecognizeTextRequest()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    init(data: Data) {
        self.data = data; request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.recognitionLanguages = ["en-US"]
    }
    func start(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try VNImageRequestHandler(data: data, options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.35 }.map(\.string).joined(separator: "\n")
                finish(.success(text))
            } catch { finish(.failure(error)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [self] in
            finish(.failure(ReceiptOCRError.timedOut)); request.cancel()
        }
    }
    func cancel() { finish(.failure(CancellationError())); request.cancel() }
    private func finish(_ value: Result<String, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value)
    }
}
private enum ReceiptOCRError: LocalizedError {
    case timedOut
    var errorDescription: String? { "Text recognition took too long. Keep the photo and enter the amount manually." }
}
