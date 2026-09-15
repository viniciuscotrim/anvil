import Foundation

#if os(iOS)
/// Keeps a model download transferring on iOS even after the screen
/// locks or the user switches to another app — requested live: "vamos
/// no iPhone atualizar pra que ele consiga continuar fazendo o
/// download do modelo mesmo que a tela bloquear ou trocar de app."
///
/// `URLDownloader`'s own plain `URLSession(configuration: .default, …)`
/// (still what Mac uses, and still what this falls back to if the
/// background session can't be created) is a *foreground* session —
/// iOS suspends its sockets the moment this process itself is
/// suspended, which is exactly the reported problem: a multi-gigabyte
/// GGUF stalls the instant the screen locks. A background session
/// (`URLSessionConfiguration.background(withIdentifier:)`) hands the
/// transfer to the system's own daemon instead, which keeps moving
/// bytes independent of whether this app's process is suspended,
/// backgrounded, or even terminated outright by jetsam — the same
/// mechanism Apple's own Podcasts/Music/App Store use for exactly this
/// kind of long transfer.
///
/// The one real wrinkle a *background* session adds over a foreground
/// one: if iOS fully terminates this app while a transfer is still
/// running, there's no live Swift `Task`/continuation left anywhere to
/// resume when it finishes — the next thing that runs is a fresh
/// process, reconnecting a session with the very same identifier (see
/// `reconnectIfNeeded()`, called from `AnvilIOSApp.init`, and
/// `AnvilIOSAppDelegate`'s `handleEventsForBackgroundURLSession`, which
/// wakes this app briefly in the background specifically to process
/// exactly that). To finish the job with *zero* reliance on any
/// in-memory state surviving, every task's own `taskDescription` — a
/// plain `String` iOS itself tracks alongside the transfer, restored
/// verbatim on reconnect — carries the one thing that's actually
/// needed: where the finished file belongs. The delegate moves it
/// there directly, whether or not anything is still waiting on a
/// continuation for that task.
public actor BackgroundDownloadCoordinator {
    public static let shared = BackgroundDownloadCoordinator()

    public static let sessionIdentifier = "com.viniciuscotrim.anvil.ios.background-downloads"

    /// The only state a relaunch-from-terminated can lean on — encoded
    /// into `URLSessionTask.taskDescription`, which iOS itself persists
    /// and restores for a background task, not this process's own
    /// memory.
    private struct TaskContext: Codable {
        let destinationPath: String
    }

    private var session: URLSession?
    private var delegate: Delegate?
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]
    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    private func makeSessionIfNeeded() -> URLSession {
        if let session { return session }
        let delegate = Delegate(owner: self)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Not discretionary — the user explicitly asked to download
        // this model right now, the same immediacy a foreground
        // session already implied; discretionary would let iOS delay
        // starting the transfer for its own power/network scheduling.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        return session
    }

    /// Called once, early at launch (`AnvilIOSApp.init`) — recreates
    /// the session under the same identifier so any transfer still in
    /// flight (or already finished) from before this launch reconnects
    /// and reports right away, rather than only the next time a
    /// download is actually requested.
    public func reconnectIfNeeded() {
        _ = makeSessionIfNeeded()
    }

    /// Stored by `AnvilIOSAppDelegate.application(_:handleEventsFor
    /// BackgroundURLSession:completionHandler:)` — called once every
    /// event this background wake-up was for has actually been
    /// processed, the documented signal telling iOS this process can
    /// be suspended again.
    public func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        backgroundCompletionHandler = handler
    }

    /// Downloads `request` straight to `destinationFile` (creating
    /// intermediate directories as needed) — unlike `URLDownloader
    /// .download`, there's no separate temp-file handoff for the
    /// caller to move afterward, since a relaunch-from-terminated has
    /// no caller left to do that second step; the delegate does the
    /// one and only move itself, whether or not anything is still
    /// awaiting this call when it happens.
    public func download(
        _ request: URLRequest,
        to destinationFile: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let session = makeSessionIfNeeded()
        let context = TaskContext(destinationPath: destinationFile.path)
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? JSONEncoder().encode(context)).flatMap { String(data: $0, encoding: .utf8) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(taskIdentifier: task.taskIdentifier, continuation: continuation, onProgress: onProgress)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func register(
        taskIdentifier: Int,
        continuation: CheckedContinuation<Void, Error>,
        onProgress: (@Sendable (Double) -> Void)?
    ) {
        continuations[taskIdentifier] = continuation
        if let onProgress {
            progressHandlers[taskIdentifier] = onProgress
        }
    }

    fileprivate func reportProgress(taskIdentifier: Int, fraction: Double) {
        progressHandlers[taskIdentifier]?(fraction)
    }

    /// Resolves the awaiting call (if this app is still the same
    /// process that started it) and always clears this task's own
    /// bookkeeping either way — a relaunch-from-terminated has nothing
    /// registered here at all, which is expected, not an error: the
    /// delegate's own file move already happened regardless.
    fileprivate func resume(taskIdentifier: Int, with result: Result<Void, Error>) {
        let continuation = continuations.removeValue(forKey: taskIdentifier)
        progressHandlers.removeValue(forKey: taskIdentifier)
        continuation?.resume(with: result)
    }

    fileprivate func finishBackgroundEvents() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        if let handler {
            DispatchQueue.main.async { handler() }
        }
    }

    /// `URLSessionDownloadDelegate` methods all land on this app's own
    /// process whenever iOS has anything to report for a task under
    /// `sessionIdentifier` — including a task started by a previous,
    /// since-terminated launch of this same app, which is exactly why
    /// every method here operates only on what `taskDescription`/the
    /// task itself carries, never on any other in-memory state.
    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private weak var owner: BackgroundDownloadCoordinator?
        // `didWriteData` fires on essentially every packet for a
        // multi-gigabyte GGUF — dozens to hundreds of times a second —
        // and used to spawn a brand-new unstructured `Task` on every
        // single call just to update a percentage. Throttled to at most
        // once per 1% or 200ms (whichever comes first), which is still
        // far more granular than the UI can visibly distinguish. Safe as
        // plain mutable state (no lock): `URLSession(configuration:
        // delegate:delegateQueue: nil)` gives this delegate its own
        // serial operation queue, so these methods never run
        // concurrently with each other.
        private var lastReportedProgress: [Int: (fraction: Double, date: Date)] = [:]
        private static let minimumFractionDelta = 0.01
        private static let minimumInterval: TimeInterval = 0.2

        init(owner: BackgroundDownloadCoordinator) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let identifier = downloadTask.taskIdentifier
            let now = Date()
            if let last = lastReportedProgress[identifier],
               fraction - last.fraction < Self.minimumFractionDelta,
               now.timeIntervalSince(last.date) < Self.minimumInterval,
               fraction < 1.0 {
                return
            }
            lastReportedProgress[identifier] = (fraction, now)
            Task { [owner] in await owner?.reportProgress(taskIdentifier: identifier, fraction: fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let identifier = downloadTask.taskIdentifier
            lastReportedProgress.removeValue(forKey: identifier)
            let result = Self.finish(downloadTask: downloadTask, at: location)
            Task { [owner] in await owner?.resume(taskIdentifier: identifier, with: result) }
        }

        /// Runs synchronously on the delegate's own queue, before this
        /// method returns — required for `didFinishDownloadingTo`
        /// regardless (the temp file at `location` is deleted the
        /// instant this method returns), and exactly what makes a
        /// relaunch-from-terminated able to finish the job with no
        /// other code ever running.
        private static func finish(downloadTask: URLSessionDownloadTask, at location: URL) -> Result<Void, Error> {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(ModelError.downloadFailed("Server returned HTTP \(http.statusCode) — authentication or file not found."))
            }
            // Same "200 OK with a tiny error body instead of the real
            // file" check `URLDownloader` itself makes — see its own
            // doc comment for the real, reported case this catches.
            let expectedBytes = downloadTask.countOfBytesExpectedToReceive
            if expectedBytes >= 0 {
                let actualBytes = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? nil
                if let actualBytes, actualBytes != expectedBytes {
                    return .failure(ModelError.downloadFailed(
                        "Download incomplete: expected \(expectedBytes) bytes but got \(actualBytes). "
                        + "This can happen when access to a gated model hasn't been granted yet — "
                        + "check the model's page on huggingface.co for a \"request access\" step."
                    ))
                }
            }
            guard let data = downloadTask.taskDescription?.data(using: .utf8),
                  let context = try? JSONDecoder().decode(TaskContext.self, from: data) else {
                return .failure(ModelError.downloadFailed("Lost track of where this download belongs."))
            }
            let destination = URL(fileURLWithPath: context.destinationPath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: location, to: destination)
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            lastReportedProgress.removeValue(forKey: task.taskIdentifier)
            guard let error else { return }
            let identifier = task.taskIdentifier
            let resolved: Error = (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error
            Task { [owner] in await owner?.resume(taskIdentifier: identifier, with: .failure(resolved)) }
        }

        /// The documented signal that every event a background wake-up
        /// (or a foreground reconnect) had queued up has now been
        /// delivered — tells `AnvilIOSAppDelegate`'s own stored
        /// completion handler it can let iOS suspend this process
        /// again.
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { [owner] in await owner?.finishBackgroundEvents() }
        }
    }
}
#endif
