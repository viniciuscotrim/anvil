import Foundation

/// Downloads a CivitAI checkpoint's primary file — a plain, native
/// `URLSessionDownloadTask` (CivitAI's redirect-to-a-pre-signed-CDN-URL
/// download needs nothing fancier than a GET with the redirect
/// followed, which `URLSession` already does by default), not a Python
/// subprocess — and registers the result the same way
/// `ModelImporter`/`ModelDownloader` do. Cooperatively cancellable, and
/// real progress throughout, matching the same pause/stop/progress
/// mechanism the Hugging Face downloader already has.
public struct CivitAIDownloader: Sendable {
    private let registry: ModelRegistry

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    /// Where `download(_:)` will place this model's file — exposed the
    /// same way `ModelDownloader.destinationDirectory` is, so a
    /// "Stop download" action can find and delete a partial download
    /// without duplicating this logic.
    public static func destinationDirectory(for summary: CivitAIModelSummary) -> URL {
        AppSettings.load().effectiveModelsRoot
            .appendingPathComponent("civitai--\(sanitize(summary.name))-\(summary.id)", isDirectory: true)
    }

    @discardableResult
    public func download(
        _ summary: CivitAIModelSummary,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelEntry {
        guard let file = summary.primaryFile else {
            throw ModelError.downloadFailed("This CivitAI model has no downloadable safetensors file.")
        }

        let destinationDir = Self.destinationDirectory(for: summary)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let destinationFile = destinationDir.appendingPathComponent(file.filename)

        var request = URLRequest(url: file.downloadURL)
        if let token = CivitAITokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let temporaryFileURL = try await Self.runDownload(request: request, onProgress: onProgress)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.moveItem(at: temporaryFileURL, to: destinationFile)

        let entry = ModelEntry(
            id: "civitai:\(summary.id)",
            displayName: summary.name,
            source: .imported(originalPath: destinationDir.standardizedFileURL.path),
            localPath: destinationDir.standardizedFileURL.path,
            sizeBytes: DirectorySize.of(destinationDir),
            kind: .image
        )
        return try await registry.upsert(entry)
    }

    /// Bridges `URLSessionDownloadTask`'s delegate-based progress API to
    /// `async`/`await`, cooperatively cancellable the same way
    /// `ProcessRunner.run` is: cancelling the calling `Task` cancels the
    /// download and this throws `CancellationError`.
    private static func runDownload(
        request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: (@Sendable (Double) -> Void)?
        private let lock = NSLock()
        private var _continuation: CheckedContinuation<URL, Error>?
        private var resumed = false

        var continuation: CheckedContinuation<URL, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return _continuation }
            set { lock.lock(); _continuation = newValue; lock.unlock() }
        }

        init(onProgress: (@Sendable (Double) -> Void)?) {
            self.onProgress = onProgress
        }

        private func resume(_ result: Result<URL, Error>) {
            lock.lock()
            guard !resumed, let continuation = _continuation else { lock.unlock(); return }
            resumed = true
            _continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file at `location` is deleted once this delegate
            // method returns, so move it somewhere durable right here
            // rather than after hopping back through the continuation.
            let temporaryDestination = FileManager.default.temporaryDirectory
                .appendingPathComponent("anvil-civitai-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: temporaryDestination)
                resume(.success(temporaryDestination))
            } catch {
                resume(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let error else { return }
            if (error as NSError).code == NSURLErrorCancelled {
                resume(.failure(CancellationError()))
            } else {
                resume(.failure(ModelError.downloadFailed(error.localizedDescription)))
            }
        }
    }
}
