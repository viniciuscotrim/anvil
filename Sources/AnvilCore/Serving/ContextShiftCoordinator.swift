import Foundation

// macOS-only: built around `Foundation.Process`, same as `LLMServer`/
// `ImageServer` — no subprocess mechanism exists on iOS, and iOS's own
// single in-process model (`NativeChatEngine`) doesn't face the
// "several gigabyte-scale processes competing for RAM at once"
// problem this exists to solve in the first place.
#if os(macOS)

/// Drives `ContextShiftScript` (the Python "Stop-and-Swap" compaction
/// pipeline — see that type's own header comment) as a long-running
/// subprocess, translating its JSON-lines events into the four things
/// Anvil itself has to actually do: pause the input bar, unload the
/// active model, reload it once compaction finishes, and route the
/// resulting summary through the same approval queue "Suggest from
/// Thread" already uses — requested live: "todos os resultados
/// gerados de memória devem ser alocados e solicitados aprovação como
/// já acontece hoje no menu Memórias."
///
/// Deliberately knows nothing about `ModelSessionManager`,
/// `ChatViewModel`, or `ChatMemorySuggestionStore` directly — every
/// reaction to an event is a closure the owner (`ChatViewModel`)
/// supplies via `configureCallbacks`, so this type stays a pure
/// process-and-protocol wrapper, testable on its own.
public actor ContextShiftCoordinator {
    public struct Status: Sendable, Equatable {
        /// `nil` when idle (watching, but no shift in progress), one of
        /// the Python script's own phase labels otherwise ("rag_text",
        /// "rag_code", "summarize") — matches `MemoryMonitor`'s `label`
        /// in `ContextShiftScript`.
        public var phase: String?
        public var isPaused = false
        public var processRSSBytes: Int64?
        public var systemUsedBytes: Int64?
        public var systemTotalBytes: Int64?
        public var stepCeilingBytes: Int64?
        public var lastError: String?

        public init(
            phase: String? = nil,
            isPaused: Bool = false,
            processRSSBytes: Int64? = nil,
            systemUsedBytes: Int64? = nil,
            systemTotalBytes: Int64? = nil,
            stepCeilingBytes: Int64? = nil,
            lastError: String? = nil
        ) {
            self.phase = phase
            self.isPaused = isPaused
            self.processRSSBytes = processRSSBytes
            self.systemUsedBytes = systemUsedBytes
            self.systemTotalBytes = systemTotalBytes
            self.stepCeilingBytes = stepCeilingBytes
            self.lastError = lastError
        }
    }

    /// The reconstructed payload Phase 4 builds from: `[System
    /// Instructions] + [Resumo gerado pelo Phi-4] + [Últimas 5
    /// mensagens intactas]` — assembling the actual replacement
    /// message list is left to the caller (`ChatViewModel`, which owns
    /// `ChatThread`), not done here.
    public struct ShiftResult: Sendable {
        public let systemPrompt: String?
        public let summary: String
        public let intactMessages: [ChatMessage]
        public let textChunksIndexed: Int
        public let codeChunksIndexed: Int
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var launcherURL: URL?
    private var lineBuffer = Data()

    private let statusFilePath: URL
    private let vectorStorePath: URL
    private let relevanceFeedbackPath: URL

    public private(set) var status = Status()

    private var onPauseRequested: (@Sendable () async -> Void)?
    private var onUnloadRequested: (@Sendable (String?) async -> Void)?
    private var onShiftReady: (@Sendable (ShiftResult) async -> Void)?
    private var onShiftFailed: (@Sendable (String) async -> Void)?
    /// Fired after every `status` mutation — how a UI (Chat's own
    /// hot-swap banner) stays live without polling an actor.
    private var onStatusChanged: (@Sendable (Status) async -> Void)?

    public init(
        statusFilePath: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("context_shift_status.json"),
        vectorStorePath: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("context_shift_vectors", isDirectory: false),
        relevanceFeedbackPath: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("relevance_feedback.json")
    ) {
        self.statusFilePath = statusFilePath
        self.vectorStorePath = vectorStorePath
        self.relevanceFeedbackPath = relevanceFeedbackPath
    }

    /// Set once, right after construction — `ChatViewModel` supplies
    /// what each event actually means for the rest of the app (unload
    /// a real `ModelSessionManager` entry, save a real
    /// `ChatMemorySuggestion`, etc.) without this type needing to know
    /// any of those types exist.
    public func configureCallbacks(
        onPauseRequested: @escaping @Sendable () async -> Void,
        onUnloadRequested: @escaping @Sendable (String?) async -> Void,
        onShiftReady: @escaping @Sendable (ShiftResult) async -> Void,
        onShiftFailed: @escaping @Sendable (String) async -> Void,
        onStatusChanged: (@Sendable (Status) async -> Void)? = nil
    ) {
        self.onPauseRequested = onPauseRequested
        self.onUnloadRequested = onUnloadRequested
        self.onShiftReady = onShiftReady
        self.onShiftFailed = onShiftFailed
        self.onStatusChanged = onStatusChanged
    }

    public var isWatching: Bool { process?.isRunning ?? false }

    /// Rewritten after every turn (`ChatViewModel.send()`) — the one
    /// piece of state the Python side's own monitoring loop actually
    /// watches (see `ContextShiftScript.watch_loop`'s own doc comment
    /// for why the *decision* to trigger still genuinely lives in
    /// Python: it reads the active model's real context window
    /// straight from that model's own `config.json`, not a number
    /// Swift would otherwise have to duplicate). `threadExportPath`
    /// points at a JSON dump of the current thread's messages this
    /// same call refreshes, so a trigger always compacts the thread as
    /// of the turn that crossed the threshold, not a stale snapshot.
    public func writeStatus(
        activeModelID: String,
        activeModelPath: String,
        estimatedTokens: Int,
        systemPrompt: String?,
        messages: [ChatMessage]
    ) {
        let threadExportPath = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("context_shift_thread.json")
        let export = ThreadExport(systemPrompt: systemPrompt, messages: messages)
        guard let threadData = try? JSONEncoder.anvil.encode(export) else { return }
        try? threadData.write(to: threadExportPath, options: .atomic)

        let status = StatusFile(
            activeModelID: activeModelID,
            activeModelPath: activeModelPath,
            estimatedTokens: estimatedTokens,
            threadExportPath: threadExportPath.path
        )
        guard let statusData = try? JSONEncoder.anvil.encode(status) else { return }
        try? statusData.write(to: statusFilePath, options: .atomic)
    }

    /// Starts the watcher if it isn't already running — safe to call
    /// on every model load; a no-op once one is already resident.
    /// Requires all three of nomic-embed-text-v2-moe, CodeRankEmbed,
    /// and Phi-4-mini-instruct to already be registered and downloaded
    /// (see `ChatViewModel`'s own resolution of these paths from
    /// `ModelRegistry`) — this coordinator has no way to download them
    /// itself, and starting the watcher without them would just mean
    /// every trigger fails at the RAG/summarize phase instead of
    /// failing clearly up front.
    public func startWatchingIfNeeded(
        nomicModelPath: String,
        coderankModelPath: String,
        phi4ModelPath: String,
        requirements: RequirementsManager
    ) async throws {
        guard process == nil else { return }
        guard await requirements.ensure(ContextShiftRuntimeDependency()) else {
            let reason = await requirements.lastError
            throw ServingError.serverFailedToStart(reason ?? "Could not set up conversation compaction")
        }

        let scriptURL = try ContextShiftScript.ensureWrittenToDisk()
        let arguments = [
            scriptURL.path,
            "--watch", statusFilePath.path,
            "--nomic-model", nomicModelPath,
            "--coderank-model", coderankModelPath,
            "--phi4-model", phi4ModelPath,
            "--vector-store", vectorStorePath.path,
            "--relevance-feedback", relevanceFeedbackPath.path,
        ]

        let launcher = await NamedLauncher.shared.makeLauncher(displayName: "Anvil - Context Shift")

        let proc = Process()
        proc.executableURL = launcher
        proc.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stdoutPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { await self.consume(data) }
        }

        do {
            try proc.run()
        } catch {
            await NamedLauncher.shared.removeLauncher(at: launcher)
            throw ServingError.serverFailedToStart(error.localizedDescription)
        }
        ProcessWatchdog.attach(toPID: proc.processIdentifier)

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        launcherURL = launcher
    }

    public func stopWatching() async {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process = nil
        stdinHandle = nil
        lineBuffer = Data()

        if let launcherURL {
            await NamedLauncher.shared.removeLauncher(at: launcherURL)
        }
        launcherURL = nil
    }

    /// Runs the same RAG-indexing + Phi-4 summarization pipeline a
    /// triggered shift uses (`run_compaction`) — but as a one-shot
    /// subprocess against an explicit thread snapshot, entirely
    /// separate from the persistent `--watch` process above, and
    /// without the automatic trigger's Phase 4 (this never replaces
    /// the caller's actual thread — the caller decides what to do with
    /// `ShiftResult.summary`). For on-demand "Suggest from Thread",
    /// not the automatic 90%-of-context trigger. Requested live: "Ao
    /// clicar no botão Suggest From Thread ... ele tem que rodar o
    /// novo workflow de memoria que temos."
    ///
    /// Never touches `statusFilePath`, the persistent watcher, or
    /// `status`/`onStatusChanged` at all — mutating those here would
    /// incorrectly show the automatic-compaction banner for a manual
    /// digest that isn't pausing or unloading anything through that
    /// mechanism. The caller is responsible for making sure nothing
    /// else heavy is resident first: this alone can need up to 17GB
    /// per phase, the same ceiling `run_triggered_shift` enforces on
    /// the Python side regardless of which mode invoked it.
    public func runManualSummarization(
        systemPrompt: String?,
        messages: [ChatMessage],
        nomicModelPath: String,
        coderankModelPath: String,
        phi4ModelPath: String,
        requirements: RequirementsManager
    ) async throws -> ShiftResult {
        guard await requirements.ensure(ContextShiftRuntimeDependency()) else {
            let reason = await requirements.lastError
            throw ServingError.serverFailedToStart(reason ?? "Could not set up conversation compaction")
        }

        let scriptURL = try ContextShiftScript.ensureWrittenToDisk()
        let threadPath = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("context_shift_manual_thread.json")
        let export = ThreadExport(systemPrompt: systemPrompt, messages: messages)
        let threadData = try JSONEncoder.anvil.encode(export)
        try threadData.write(to: threadPath, options: .atomic)

        let arguments = [
            scriptURL.path,
            "--run-once", threadPath.path,
            "--nomic-model", nomicModelPath,
            "--coderank-model", coderankModelPath,
            "--phi4-model", phi4ModelPath,
            "--vector-store", vectorStorePath.path,
            "--relevance-feedback", relevanceFeedbackPath.path,
        ]

        let launcher = await NamedLauncher.shared.makeLauncher(displayName: "Anvil - Memory Suggestions")

        // A plain `Process` + readability handler + termination handler
        // (not `async`/`await` all the way down — `Process` predates
        // structured concurrency) bridged into one `async throws` call
        // via a continuation, same shape `LLMServer`/`ImageServer` use
        // for their own one-shot subprocess calls.
        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = launcher
            proc.arguments = arguments
            let stdoutPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stdoutPipe

            final class OutputBox: @unchecked Sendable {
                var buffer = Data()
                var resumed = false
            }
            let box = OutputBox()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                box.buffer.append(chunk)
            }

            proc.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                Task { await NamedLauncher.shared.removeLauncher(at: launcher) }
                guard !box.resumed else { return }
                box.resumed = true

                for lineData in box.buffer.split(separator: 0x0A) {
                    guard let envelope = try? JSONDecoder.anvil.decode(EventEnvelope.self, from: Data(lineData)) else { continue }
                    switch envelope.event {
                    case "context_shift_ready":
                        guard let payload = try? JSONDecoder.anvil.decode(ContextShiftReadyEvent.self, from: Data(lineData)) else { continue }
                        continuation.resume(returning: ShiftResult(
                            systemPrompt: payload.systemPrompt,
                            summary: payload.summary,
                            intactMessages: payload.intactMessages,
                            textChunksIndexed: payload.textChunksIndexed,
                            codeChunksIndexed: payload.codeChunksIndexed
                        ))
                        return
                    case "context_shift_failed":
                        let payload = try? JSONDecoder.anvil.decode(ShiftFailedEvent.self, from: Data(lineData))
                        continuation.resume(throwing: ServingError.serverFailedToStart(payload?.reason ?? "unknown"))
                        return
                    default:
                        continue
                    }
                }
                continuation.resume(throwing: ServingError.serverFailedToStart("The memory pipeline exited without a result."))
            }

            do {
                try proc.run()
                ProcessWatchdog.attach(toPID: proc.processIdentifier)
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                Task { await NamedLauncher.shared.removeLauncher(at: launcher) }
                if !box.resumed {
                    box.resumed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Event parsing

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    /// Every line is JSON per `ContextShiftScript.emit`, but a
    /// misbehaving dependency printing a stray warning straight to
    /// stdout (seen for real from `transformers`/`huggingface_hub`
    /// during manual testing) is silently ignored here rather than
    /// treated as a protocol violation — this stream is best-effort
    /// status, not something a malformed line should ever crash.
    private func handleLine(_ data: Data) {
        guard let envelope = try? JSONDecoder.anvil.decode(EventEnvelope.self, from: data) else { return }

        switch envelope.event {
        case "pause_requested":
            status.isPaused = true
            notifyStatusChanged()
            let callback = onPauseRequested
            Task { await callback?() }

        case "unload_requested":
            let payload = try? JSONDecoder.anvil.decode(UnloadRequestedEvent.self, from: data)
            let modelID = payload?.modelID
            // Captures `self` strongly on purpose: this Task isn't stored
            // anywhere (no retain cycle to worry about), and the pending
            // unload handshake must always reach `sendControl` — a `weak`
            // self that happened to be nil here would silently drop the
            // ack and hang the Python side for a full 60s timeout.
            let callback = onUnloadRequested
            Task {
                await callback?(modelID)
                self.sendControl(event: "unload_complete")
            }

        case "memory_status":
            guard let payload = try? JSONDecoder.anvil.decode(MemoryStatusEvent.self, from: data) else { return }
            status.phase = payload.phase
            status.processRSSBytes = payload.processRSSBytes
            status.systemUsedBytes = payload.systemUsedBytes
            status.systemTotalBytes = payload.systemTotalBytes
            status.stepCeilingBytes = payload.stepCeilingBytes
            notifyStatusChanged()

        case "phase_completed", "model_unloaded":
            break // memory_status already carries live phase info; these are just log markers.

        case "context_shift_ready":
            guard let payload = try? JSONDecoder.anvil.decode(ContextShiftReadyEvent.self, from: data) else { return }
            status.isPaused = false
            status.phase = nil
            notifyStatusChanged()
            let result = ShiftResult(
                systemPrompt: payload.systemPrompt,
                summary: payload.summary,
                intactMessages: payload.intactMessages,
                textChunksIndexed: payload.textChunksIndexed,
                codeChunksIndexed: payload.codeChunksIndexed
            )
            let callback = onShiftReady
            Task { await callback?(result) }

        case "context_shift_failed":
            let payload = try? JSONDecoder.anvil.decode(ShiftFailedEvent.self, from: data)
            let reason = payload?.reason ?? "unknown"
            status.isPaused = false
            status.phase = nil
            status.lastError = reason
            notifyStatusChanged()
            let callback = onShiftFailed
            Task { await callback?(reason) }

        default:
            break
        }
    }

    private func notifyStatusChanged() {
        let current = status
        let callback = onStatusChanged
        Task { await callback?(current) }
    }

    /// Deliberately NOT `JSONEncoder.anvil` — that encoder applies
    /// `.prettyPrinted` formatting (see `ModelEntry.swift`), which is
    /// harmless for `writeStatus`'s whole-file writes (Python reads
    /// those with `Path.read_text()` + `json.loads()`) but fatal here:
    /// this goes over the stdin pipe using the same one-JSON-object-
    /// per-line protocol as `ContextShiftScript.emit`/`read_control_line`,
    /// which is a plain `sys.stdin.readline()`. A pretty-printed
    /// `{"event":"unload_complete"}` spans several lines, so Python
    /// would only ever see fragments like `"{"` on their own line, each
    /// failing `json.loads()` — `wait_for_control_event` then never
    /// recognizes the ack and always times out
    /// (`unload_not_acknowledged`), exactly as reported live after the
    /// v0.20.0 trigger-fix finally let a real shift reach this
    /// handshake. A bare, non-pretty-printed `JSONEncoder` always
    /// produces single-line output, matching what `emit()` itself
    /// writes in the other direction.
    private func sendControl(event: String) {
        guard let data = try? JSONEncoder().encode(ControlEvent(event: event)) else { return }
        stdinHandle?.write(data)
        stdinHandle?.write(Data([0x0A]))
    }
}

// MARK: - Wire types

/// What `writeStatus` writes and `ContextShiftScript.watch_loop` reads
/// back — field names matter here (Python reads them by exact key),
/// not just shape.
private struct StatusFile: Encodable {
    let activeModelID: String
    let activeModelPath: String
    let estimatedTokens: Int
    let threadExportPath: String

    enum CodingKeys: String, CodingKey {
        case activeModelID = "active_model_id"
        case activeModelPath = "active_model_path"
        case estimatedTokens = "estimated_tokens"
        case threadExportPath = "thread_export_path"
    }
}

private struct ThreadExport: Encodable {
    let systemPrompt: String?
    let messages: [ChatMessage]

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case messages
    }
}

private struct ControlEvent: Encodable {
    let event: String
}

private struct EventEnvelope: Decodable {
    let event: String
}

private struct UnloadRequestedEvent: Decodable {
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
    }
}

private struct MemoryStatusEvent: Decodable {
    let phase: String?
    let processRSSBytes: Int64?
    let systemUsedBytes: Int64?
    let systemTotalBytes: Int64?
    let stepCeilingBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case phase
        case processRSSBytes = "process_rss_bytes"
        case systemUsedBytes = "system_used_bytes"
        case systemTotalBytes = "system_total_bytes"
        case stepCeilingBytes = "step_ceiling_bytes"
    }
}

private struct ContextShiftReadyEvent: Decodable {
    let systemPrompt: String?
    let summary: String
    let intactMessages: [ChatMessage]
    let textChunksIndexed: Int
    let codeChunksIndexed: Int

    enum CodingKeys: String, CodingKey {
        case systemPrompt = "system_prompt"
        case summary
        case intactMessages = "intact_messages"
        case textChunksIndexed = "text_chunks_indexed"
        case codeChunksIndexed = "code_chunks_indexed"
    }
}

private struct ShiftFailedEvent: Decodable {
    let reason: String?
}

#endif
