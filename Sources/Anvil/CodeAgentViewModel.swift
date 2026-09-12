import Foundation
import AnvilCore

/// "Code" — a chat that can actually read/write files and run terminal
/// commands in one folder the user picks, gated by the same three-tier
/// permission model requested directly ("assim como você"): Manual
/// (prepares a change/command for the user to copy and run themselves),
/// Semi-Auto (asks once per new command/write, remembers approvals for
/// the rest of the launch), Auto (runs immediately). Reading/listing
/// files never asks, whatever the level — only writes and commands are
/// gated, mirroring how Claude Code's own Read tool needs no approval
/// while Edit/Bash do.
///
/// Plain `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the `@State` toolchain note in README.
@MainActor
final class CodeAgentViewModel: ObservableObject {
    enum GenerationPhase: Equatable {
        case idle
        case thinking
        case responding
        case runningTool
        case waitingForApproval
        case failed
        case cancelled

        var label: String {
            switch self {
            case .idle: return ""
            case .thinking: return "Thinking…"
            case .responding: return "Writing…"
            case .runningTool: return "Working with tools…"
            case .waitingForApproval: return "Waiting for approval…"
            case .failed: return "Generation failed"
            case .cancelled: return "Generation stopped"
            }
        }
    }

    @Published var currentThread: ChatThread
    @Published private(set) var allThreads: [ChatThread] = []
    @Published var selectedModelID: String?
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published private(set) var generationPhase: GenerationPhase = .idle
    @Published var errorMessage: String?
    @Published var settings = GenerationSettings.default
    @Published var isExportPresented = false

    // MARK: - Settings (persisted to AppSettings)

    @Published private(set) var workingDirectoryPath: String?
    @Published var allowFullDiskAccess: Bool {
        didSet { persistSettings() }
    }
    @Published var permissionLevel: CodeAgentPermissionLevel {
        didSet { persistSettings() }
    }
    @Published var enabledFeatures: Set<CodeAgentFeature> {
        didSet { persistSettings() }
    }

    // MARK: - Approval / manual-mode state

    struct PendingApproval: Identifiable {
        let id = UUID()
        let summary: String
        let rememberKey: String
    }

    enum ManualProposal: Identifiable, Equatable {
        case writeFile(path: String, content: String)
        case runTerminalCommand(String)

        var id: String {
            switch self {
            case .writeFile(let path, _): return "write:\(path)"
            case .runTerminalCommand(let command): return "run:\(command)"
            }
        }
    }

    @Published private(set) var pendingApproval: PendingApproval?
    /// The most recent Manual-mode proposal, shown in a side panel with
    /// a Copy button until the user's next message clears it.
    @Published private(set) var manualProposal: ManualProposal?

    private let sessions: ModelSessionManager
    private let threadStore: ChatThreadStore
    private let requirements: RequirementsManager
    private let client = ChatClient()
    private var hasLoadedInitialState = false
    /// Approved once this launch — "write_file:<path>" or
    /// "run_terminal_command:<command>" — never persisted across
    /// relaunches; a fresh launch asks again.
    private var rememberedApprovals: Set<String> = []
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    init(sessions: ModelSessionManager, threadStore: ChatThreadStore, requirements: RequirementsManager) {
        self.sessions = sessions
        self.threadStore = threadStore
        self.requirements = requirements
        self.currentThread = ChatThread(title: "New Code Chat")

        let saved = AppSettings.load()
        self.workingDirectoryPath = saved.codeAgentWorkingDirectory?.path
        self.allowFullDiskAccess = saved.codeAgentAllowFullDiskAccess
        self.permissionLevel = saved.codeAgentPermissionLevel
        self.enabledFeatures = saved.codeAgentEnabledFeatures
    }

    var messages: [ChatMessage] { currentThread.messages }

    /// Tool-call plumbing (the assistant's own tool-call message, the
    /// `.tool` result answering it) stays in `messages`/history for the
    /// model's context but isn't meant for a human to read as a chat
    /// bubble — `CodeAgentView` renders those specially instead.
    var visibleMessages: [ChatMessage] {
        currentThread.messages.filter {
            $0.role != .tool && !($0.role == .assistant && $0.content.isEmpty && $0.toolCalls != nil)
        }
    }

    func loadInitialState() async {
        allThreads = await threadStore.all()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread(title: "New Code Chat")
            hasLoadedInitialState = true
        }
        syncSelectedModel()
    }

    func syncSelectedModel() {
        if let id = selectedModelID, sessions.isLoaded(modelID: id) { return }
        selectedModelID = sessions.readySessions.first?.id
    }

    // MARK: - Working folder

    func chooseWorkingDirectory(_ url: URL) {
        workingDirectoryPath = url.standardizedFileURL.path
        persistSettings()
    }

    func clearWorkingDirectory() {
        workingDirectoryPath = nil
        persistSettings()
    }

    private func persistSettings() {
        var saved = AppSettings.load()
        saved.codeAgentWorkingDirectoryPath = workingDirectoryPath
        saved.codeAgentAllowFullDiskAccess = allowFullDiskAccess
        saved.codeAgentPermissionLevel = permissionLevel
        saved.codeAgentEnabledFeatures = enabledFeatures
        try? saved.save()
    }

    private func makeRunner() -> CodeAgentToolRunner {
        let directory = workingDirectoryPath.flatMap { path -> URL? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return CodeAgentToolRunner(workingDirectory: directory, allowFullDiskAccess: allowFullDiskAccess)
    }

    // MARK: - Threads

    func newThread() {
        currentThread = ChatThread(title: "New Code Chat")
        manualProposal = nil
    }

    func selectThread(_ thread: ChatThread) {
        currentThread = thread
        manualProposal = nil
    }

    func deleteThread(_ thread: ChatThread) async {
        if isSending, currentThread.id == thread.id { return }
        try? await threadStore.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread(title: "New Code Chat")
        }
    }

    func clearCurrentConversation() {
        currentThread.messages.removeAll()
        manualProposal = nil
        persistCurrentThread()
    }

    /// A structured, traceable Markdown export — every tool call and
    /// its result gets its own timestamped section (see
    /// `TranscriptFormatter.codeAgentMarkdown`'s own doc comment for
    /// why the plain Chat-style narrative export would lose exactly the
    /// part worth exporting here), meant to be handed to a separate
    /// conversation as reference material.
    func exportMarkdown() -> String {
        TranscriptFormatter.codeAgentMarkdown(
            threadTitle: currentThread.title,
            workingDirectoryPath: workingDirectoryPath,
            messages: currentThread.messages
        )
    }

    private func persistCurrentThread() {
        let threadToSave = currentThread
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if currentThread.id == saved.id {
                currentThread = saved
            }
            allThreads = await threadStore.all()
        }
    }

    private func persistCurrentThreadForDurability() {
        let threadToSave = currentThread
        Task {
            _ = try? await threadStore.upsert(threadToSave)
        }
    }

    // MARK: - Sending

    /// Every user message can trigger several rounds of tool calls
    /// before the model gives a plain answer — a real agentic loop, not
    /// the Mac chat's own single tool-call-then-one-follow-up shape.
    /// Capped so a model that won't stop calling tools can't run away.
    private static let maxToolRounds = 8

    /// When set, a request is actually in flight — the current round's
    /// start time, so the UI can show real elapsed time ("Generating…
    /// 12s") instead of a plain spinner with no sense of whether
    /// anything is still happening. Reset at the start of every round
    /// (tool-call rounds included), not just once per `send()`.
    @Published private(set) var currentRoundStartedAt: Date?
    /// The whole agentic loop's own `Task` — `stopGeneration()` cancels
    /// this directly rather than relying on the streamed response's own
    /// cancellation alone, since cancellation also has to interrupt
    /// whatever's happening between rounds (a tool call in progress).
    private var generationTask: Task<Void, Never>?

    /// Not `async` — spawns and owns its own `Task` (`generationTask`)
    /// so the Send button in the view can fire-and-forget this the same
    /// way it always could, while `stopGeneration()` gets something real
    /// to cancel. The previous shape (a plain `await`-ed async function
    /// with no timeout shorter than the client's own 1800s and no way to
    /// interrupt it) was the actual mechanism behind a real reported
    /// bug: a generation that never stopped left no way to reclaim it
    /// short of unloading the whole model.
    func send() {
          guard let id = selectedModelID,
              let endpoint = sessions.gatewayEndpoint(for: id) ?? sessions.chatEndpoint(for: id) else {
            errorMessage = "Pick a loaded model first"
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil
        manualProposal = nil

        currentThread.messages.append(ChatMessage(role: .user, content: text))
        if currentThread.title == "New Code Chat", currentThread.messages.count == 1 {
            currentThread.title = String(text.prefix(48))
        }
        persistCurrentThreadForDurability()

        let modelDisplayName = sessions.sessions.first { $0.id == id }?.model.displayName ?? id
        let tools = availableTools()
        let systemPrompt = composedSystemPrompt(offeringTools: !tools.isEmpty)

        isSending = true
        generationPhase = .thinking
        generationTask = Task { [weak self] in
            await self?.runAgentLoop(
                endpoint: endpoint,
                modelID: id,
                modelDisplayName: modelDisplayName,
                tools: tools,
                systemPrompt: systemPrompt
            )
            guard let self else { return }
            self.isSending = false
            self.currentRoundStartedAt = nil
            if self.generationPhase == .thinking || self.generationPhase == .responding || self.generationPhase == .runningTool {
                self.generationPhase = .idle
            }
            self.generationTask = nil
        }
    }

    /// The same "Send" button becomes "Stop" while `isSending` — cancels
    /// the in-flight round (a real HTTP connection abort via
    /// `ChatClient.streamSend`'s own cooperative-cancellation handling,
    /// not just hiding a spinner) and, if one's in flight, a tool call.
    /// Whatever already streamed in before the cancel lands stays in the
    /// conversation rather than being discarded.
    func stopGeneration() {
        generationPhase = .cancelled
        generationTask?.cancel()
    }

    private func runAgentLoop(
        endpoint: URL, modelID: String, modelDisplayName: String, tools: [ChatTool], systemPrompt: String?
    ) async {
        do {
            for _ in 0..<Self.maxToolRounds {
                try Task.checkCancellation()
                currentRoundStartedAt = Date()

                // A visible, empty bubble from the moment a round starts
                // — real progress (it fills in as tokens actually
                // arrive), not a placeholder that only appears once
                // something has already happened.
                currentThread.messages.append(ChatMessage(role: .assistant, content: "", modelDisplayName: modelDisplayName))
                let replyIndex = currentThread.messages.count - 1
                let historyForRequest = Array(currentThread.messages.dropLast())

                let stream = client.streamSend(
                    messages: historyForRequest,
                    baseURL: endpoint,
                    model: endpoint.port == OpenAIGateway.port ? modelID : "default_model",
                    modelDisplayName: modelDisplayName,
                    settings: settings,
                    tools: tools,
                    systemPrompt: systemPrompt,
                    conversationID: currentThread.id.uuidString
                )

                var finalMessage: ChatMessage?
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .contentDelta(let delta):
                        generationPhase = .responding
                        currentThread.messages[replyIndex].content += delta
                    case .reasoningDelta(let delta):
                        generationPhase = .thinking
                        currentThread.messages[replyIndex].reasoning =
                            (currentThread.messages[replyIndex].reasoning ?? "") + delta
                    case .done(let message):
                        finalMessage = message
                    }
                }
                guard let finalMessage else { break }
                currentThread.messages[replyIndex] = finalMessage
                persistCurrentThreadForDurability()

                guard let toolCalls = finalMessage.toolCalls, !toolCalls.isEmpty else {
                    break
                }

                var haltedForManual = false
                for call in toolCalls {
                    try Task.checkCancellation()
                    generationPhase = .runningTool
                    currentRoundStartedAt = Date()
                    let resultMessage = await dispatch(call, haltedForManual: &haltedForManual)
                    currentThread.messages.append(resultMessage)
                }
                persistCurrentThreadForDurability()
                if haltedForManual { break }
            }
            persistCurrentThread()
        } catch is CancellationError {
            // Drop a still-empty placeholder bubble (nothing ever
            // streamed into it) rather than leaving a blank one sitting
            // in the conversation; a partially-streamed answer, or any
            // tool result already recorded, stays exactly as it was.
            if let last = currentThread.messages.last,
                last.role == .assistant, last.content.isEmpty, last.toolCalls == nil
            {
                currentThread.messages.removeLast()
            }
            persistCurrentThread()
        } catch {
            if let last = currentThread.messages.last,
               last.role == .assistant,
               last.content.isEmpty,
               last.toolCalls == nil {
                currentThread.messages.removeLast()
            }
            generationPhase = .failed
            errorMessage = error.localizedDescription
            persistCurrentThread()
        }
    }

    // MARK: - Tool dispatch

    private func availableTools() -> [ChatTool] {
        var tools: [ChatTool] = []
        if enabledFeatures.contains(.fileAccess) {
            tools.append(.readFile)
            tools.append(.listDirectory)
            tools.append(.writeFile)
        }
        if enabledFeatures.contains(.terminal) {
            tools.append(.runTerminalCommand)
        }
        return tools
    }

    private func composedSystemPrompt(offeringTools: Bool) -> String? {
        guard offeringTools else { return nil }
        let description = workingDirectoryPath.map { "the real folder at \($0)" }
            ?? "no working folder yet — tell the user to pick one in the Code tab's settings before attempting any file or terminal tool"
        return ChatTool.codeAgentUsageDiscipline(workingDirectoryDescription: description)
    }

    private func dispatch(_ call: ChatMessage.ToolCall, haltedForManual: inout Bool) async -> ChatMessage {
        switch call.name {
        case ChatTool.readFile.name:
            return runReadFile(call)
        case ChatTool.listDirectory.name:
            return runListDirectory(call)
        case ChatTool.writeFile.name:
            return await runWriteFile(call, haltedForManual: &haltedForManual)
        case ChatTool.runTerminalCommand.name:
            return await runTerminalCommandTool(call, haltedForManual: &haltedForManual)
        default:
            return ChatMessage(role: .tool, content: "Error: unknown tool \"\(call.name)\".", toolCallID: call.id)
        }
    }

    private func runReadFile(_ call: ChatMessage.ToolCall) -> ChatMessage {
        guard enabledFeatures.contains(.fileAccess) else {
            return ChatMessage(role: .tool, content: "Error: File Access is turned off in Settings.", toolCallID: call.id)
        }
        struct Args: Decodable { let path: String }
        guard let args = Self.decodeArgs(Args.self, from: call.argumentsJSON) else {
            return ChatMessage(role: .tool, content: "Error: could not parse arguments.", toolCallID: call.id)
        }
        do {
            let content = try makeRunner().readFile(atPath: args.path)
            return ChatMessage(role: .tool, content: content, toolCallID: call.id)
        } catch {
            return ChatMessage(role: .tool, content: "Error: \(error.localizedDescription)", toolCallID: call.id)
        }
    }

    private func runListDirectory(_ call: ChatMessage.ToolCall) -> ChatMessage {
        guard enabledFeatures.contains(.fileAccess) else {
            return ChatMessage(role: .tool, content: "Error: File Access is turned off in Settings.", toolCallID: call.id)
        }
        struct Args: Decodable { let path: String }
        guard let args = Self.decodeArgs(Args.self, from: call.argumentsJSON) else {
            return ChatMessage(role: .tool, content: "Error: could not parse arguments.", toolCallID: call.id)
        }
        do {
            let entries = try makeRunner().listDirectory(atPath: args.path)
            let content = entries.isEmpty ? "(empty directory)" : entries.joined(separator: "\n")
            return ChatMessage(role: .tool, content: content, toolCallID: call.id)
        } catch {
            return ChatMessage(role: .tool, content: "Error: \(error.localizedDescription)", toolCallID: call.id)
        }
    }

    private func runWriteFile(_ call: ChatMessage.ToolCall, haltedForManual: inout Bool) async -> ChatMessage {
        guard enabledFeatures.contains(.fileAccess) else {
            return ChatMessage(role: .tool, content: "Error: File Access is turned off in Settings.", toolCallID: call.id)
        }
        struct Args: Decodable { let path: String; let content: String }
        guard let args = Self.decodeArgs(Args.self, from: call.argumentsJSON) else {
            return ChatMessage(role: .tool, content: "Error: could not parse arguments.", toolCallID: call.id)
        }

        if permissionLevel == .manual {
            haltedForManual = true
            manualProposal = .writeFile(path: args.path, content: args.content)
            return ChatMessage(
                role: .tool,
                content: "Prepared, not applied — the user will copy \"\(args.path)\"'s proposed contents from "
                    + "the panel and apply it themselves, then continue the conversation.",
                toolCallID: call.id
            )
        }

        let key = "write_file:\(args.path)"
        if permissionLevel == .semiAuto, !rememberedApprovals.contains(key) {
            let approved = await requestApproval(summary: "Write \(args.path)", rememberKey: key)
            guard approved else {
                return ChatMessage(role: .tool, content: "The user denied this write.", toolCallID: call.id)
            }
        }

        do {
            try makeRunner().writeFile(atPath: args.path, content: args.content)
            return ChatMessage(role: .tool, content: "Wrote \(args.path).", toolCallID: call.id)
        } catch {
            return ChatMessage(role: .tool, content: "Error: \(error.localizedDescription)", toolCallID: call.id)
        }
    }

    private func runTerminalCommandTool(_ call: ChatMessage.ToolCall, haltedForManual: inout Bool) async -> ChatMessage {
        guard enabledFeatures.contains(.terminal) else {
            return ChatMessage(role: .tool, content: "Error: Terminal is turned off in Settings.", toolCallID: call.id)
        }
        struct Args: Decodable { let command: String }
        guard let args = Self.decodeArgs(Args.self, from: call.argumentsJSON) else {
            return ChatMessage(role: .tool, content: "Error: could not parse arguments.", toolCallID: call.id)
        }

        if permissionLevel == .manual {
            haltedForManual = true
            manualProposal = .runTerminalCommand(args.command)
            return ChatMessage(
                role: .tool,
                content: "Prepared, not run — the user will copy the command from the panel and run it "
                    + "themselves, then continue the conversation.",
                toolCallID: call.id
            )
        }

        let key = "run_terminal_command:\(args.command)"
        if permissionLevel == .semiAuto, !rememberedApprovals.contains(key) {
            let approved = await requestApproval(summary: args.command, rememberKey: key)
            guard approved else {
                return ChatMessage(role: .tool, content: "The user denied this command.", toolCallID: call.id)
            }
        }

        do {
            let (output, exitCode) = try await makeRunner().runTerminalCommand(args.command)
            let trimmedOutput = output.isEmpty ? "(no output)" : output
            return ChatMessage(role: .tool, content: "Exit code \(exitCode):\n\(trimmedOutput)", toolCallID: call.id)
        } catch {
            return ChatMessage(role: .tool, content: "Error: \(error.localizedDescription)", toolCallID: call.id)
        }
    }

    // MARK: - Approval

    private func requestApproval(summary: String, rememberKey: String) async -> Bool {
        generationPhase = .waitingForApproval
        pendingApproval = PendingApproval(summary: summary, rememberKey: rememberKey)
        let approved = await withCheckedContinuation { continuation in
            approvalContinuation = continuation
        }
        if approved {
            rememberedApprovals.insert(rememberKey)
        }
        pendingApproval = nil
        return approved
    }

    func approvePending() {
        approvalContinuation?.resume(returning: true)
        approvalContinuation = nil
    }

    func denyPending() {
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
    }

    private static func decodeArgs<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
