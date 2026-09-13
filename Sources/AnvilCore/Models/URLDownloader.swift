import Foundation

/// A single `URLSessionDownloadTask`, bridged to `async`/`await` with
/// real progress and cooperative cancellation — the mechanism behind
/// both `CivitAIDownloader` (a single file) and `HFRepoDownloader` (one
/// of these per file in a repo). Cross-platform: `URLSession` works
/// identically on iOS, unlike the macOS-only `Process`-based
/// `ModelDownloader`/`ProcessRunner` path — this is deliberately the
/// downloading mechanism the iOS port can actually use.
public enum URLDownloader {
    /// Downloads `request` to a temporary file and returns its URL —
    /// the caller is responsible for moving it somewhere durable
    /// (`didFinishDownloadingTo`'s file is deleted the moment the
    /// delegate method returns, so this already relocates it to a
    /// fresh temp file before resuming). Cancelling the calling `Task`
    /// cancels the underlying download and throws `CancellationError`.
    public static func download(
        _ request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)? = nil
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
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                resume(.failure(ModelError.downloadFailed("Server returned HTTP \(http.statusCode) — authentication or file not found.")))
                return
            }

            // A real, reported failure mode a bare status-code check
            // above doesn't catch: a gated/licensed Hugging Face repo
            // the caller isn't (yet) actually entitled to can answer a
            // multi-gigabyte file's resolve URL with `200 OK` and a
            // tiny HTML/JSON body (a "request access" or license page)
            // instead of a 401/403 — reported live as an expected ~8GB
            // GGUF landing as ~20KB. `countOfBytesExpectedToReceive` is
            // the server's own declared `Content-Length` for the
            // response `didFinishDownloadingTo` is actually reporting
            // on; a known (non-negative — servers that stream without
            // one, e.g. chunked transfer, report -1, and there's
            // nothing to check against then) value that doesn't match
            // what's actually on disk at `location` means the transfer
            // wasn't really what it claimed to be, whatever the status
            // code said.
            let expectedBytes = downloadTask.countOfBytesExpectedToReceive
            if expectedBytes >= 0 {
                let actualBytes = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? nil
                if let actualBytes, actualBytes != expectedBytes {
                    resume(.failure(ModelError.downloadFailed(
                        "Download incomplete: expected \(expectedBytes) bytes but got \(actualBytes). "
                        + "This can happen when access to a gated model hasn't been granted yet — "
                        + "check the model's page on huggingface.co for a \"request access\" step."
                    )))
                    return
                }
            }

            let temporaryDestination = FileManager.default.temporaryDirectory
                .appendingPathComponent("anvil-download-\(UUID().uuidString)")
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
                resume(.failure(error))
            }
        }
    }
}
