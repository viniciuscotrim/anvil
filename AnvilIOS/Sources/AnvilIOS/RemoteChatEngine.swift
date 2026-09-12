import AnvilCore
import Foundation
import UIKit

/// The "talk to a Mac instead of on-device" half of Chat — the remote
/// analog of `NativeChatEngine`, built on the same fully cross-platform
/// `ChatClient`/`ChatContextBuilder`/`ChatMemory` types the Mac app's own
/// `ChatViewModel` uses, so a remote conversation gets the same bounded-
/// context and memory-injection behavior a Mac chat already has — not
/// just a bare network pass-through.
///
/// Mutates a `ChatThreadsViewModel`'s `currentThread` directly (the same
/// class already owns persistence/threading for the local path too), so
/// switching Chat's source mid-thread only changes which engine answers
/// the *next* message — the thread itself doesn't change shape.
@MainActor
final class RemoteChatEngine: ObservableObject {
    /// Mirrors the Mac app's own `ChatViewModel.GenerationPhase` — real
    /// signal that something is happening over the network, not just a
    /// bare spinner, the same lesson the Code tab's own streaming fix
    /// already established for this project.
    enum GenerationPhase: Equatable {
        case idle
        case preparing
        case reasoning
        case generating
        case generatingImage
        case cancelled
        case failed

        var label: String? {
            switch self {
            case .idle: return nil
            case .preparing: return "Preparing…"
            case .reasoning: return "Thinking…"
            case .generating: return "Generating response…"
            case .generatingImage: return "Generating image…"
            case .cancelled: return "Generation stopped"
            case .failed: return "Generation failed"
            }
        }
    }

    @Published private(set) var generationPhase: GenerationPhase = .idle
    @Published private(set) var lastTokensPerSecond: Double?
    @Published var errorMessage: String?

    private let client = ChatClient()
    private let imageClient = RemoteImageClient()
    private let imageStore = GeneratedImageStore()
    private var generationTask: Task<Void, Never>?
    /// Carries the previous `generate_image` call's prompt + seed
    /// forward within a thread, the same fix the Mac app already needed
    /// for character consistency across consecutive generations ("same
    /// character, different clothes") — without it, consecutive remote
    /// generations would drift the same way the Mac's used to.
    private var lastImageGenerationByThread: [UUID: (seed: Int, prompt: String)] = [:]

    var isSending: Bool { generationTask != nil }

    /// One full turn against `connection` — appends the user message,
    /// streams the reply into `threads.currentThread`, and (if
    /// `imageConnection` is given) can call `generate_image` against it
    /// mid-reply, exactly like the Mac app's own chat loop.
    func send(
        text: String,
        threads: ChatThreadsViewModel,
        connection: RemoteMacConnection,
        imageConnection: RemoteMacConnection?,
        profile: ChatProfile?,
        memories: [ChatMemory],
        settings: GenerationSettings,
        maxEstimatedContextTokens: Int = 24_000,
        recentMessageCount: Int = 12
    ) {
        guard let baseURL = connection.baseURL else {
            errorMessage = "This connection's host/port looks invalid."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, generationTask == nil else { return }
        // A real, reproduced failure mode (confirmed against a raw
        // persisted thread, distinct message IDs each with their own
        // reply — a genuine duplicate send, not a memory/context bug):
        // a flaky phone-to-Mac connection makes a send look like it
        // silently went nowhere, so the user retypes/resends the exact
        // same question, and nothing here caught that it was already
        // just asked. Block an exact repeat of the last thing the user
        // actually said instead of quietly creating a second turn.
        if threads.currentThread.messages.last(where: { $0.role == .user })?.content == trimmed {
            errorMessage = "You just sent this — give it a moment (or Stop and edit your message to send it again)."
            return
        }
        errorMessage = nil

        threads.currentThread.messages.append(ChatMessage(role: .user, content: trimmed))
        if threads.currentThread.title == "New Chat", threads.currentThread.messages.count == 1 {
            threads.currentThread.title = String(trimmed.prefix(48))
        }
        threads.persistCurrentThreadForDurability()

        let tools: [ChatTool] = imageConnection != nil ? [.generateImage] : []
        let contextBuilder = ChatContextBuilder(
            maxEstimatedTokens: maxEstimatedContextTokens, recentMessageCount: recentMessageCount)
        let activeProfileID = threads.currentThread.profileID
        let scopedMemories = memories.filter { $0.profileID == nil || $0.profileID == activeProfileID }
        let context = contextBuilder.build(messages: threads.currentThread.messages, memories: scopedMemories)
        let systemPrompt = Self.composedSystemPrompt(
            profile: profile, offeringTools: !tools.isEmpty, memoryPrompt: context.memoryPrompt)
        let modelDisplayName = connection.displayName
        let responderName = profile?.name

        generationPhase = .preparing
        generationTask = Task { [weak self] in
            await self?.runChatLoop(
                threads: threads,
                baseURL: baseURL,
                modelDisplayName: modelDisplayName,
                responderName: responderName,
                tools: tools,
                systemPrompt: systemPrompt,
                contextMessages: context.messages,
                memoryIDsUsed: context.memoryIDs,
                imageConnection: imageConnection,
                settings: settings,
                maxEstimatedContextTokens: maxEstimatedContextTokens,
                recentMessageCount: recentMessageCount,
                memories: memories
            )
            guard let self else { return }
            self.generationTask = nil
            if self.generationPhase == .preparing || self.generationPhase == .reasoning || self.generationPhase == .generating {
                self.generationPhase = .idle
            }
        }
    }

    func stopGeneration() {
        generationPhase = .cancelled
        generationTask?.cancel()
    }

    private func runChatLoop(
        threads: ChatThreadsViewModel,
        baseURL: URL,
        modelDisplayName: String,
        responderName: String?,
        tools: [ChatTool],
        systemPrompt: String?,
        contextMessages: [ChatMessage],
        memoryIDsUsed: [UUID],
        imageConnection: RemoteMacConnection?,
        settings: GenerationSettings,
        maxEstimatedContextTokens: Int,
        recentMessageCount: Int,
        memories: [ChatMemory]
    ) async {
        do {
            threads.currentThread.messages.append(ChatMessage(
                role: .assistant, content: "", modelDisplayName: modelDisplayName, responderName: responderName))
            let replyIndex = threads.currentThread.messages.count - 1
            // `contextMessages` already ends with the user's own current
            // message (`ChatContextBuilder.build` was called before the
            // assistant placeholder above existed) — no `dropLast()`
            // here. Confirmed for real against a running mlx_lm.server:
            // dropping it produces an empty `messages` array on a
            // thread's first turn, which the server rejects outright
            // ("Cannot apply chat template to an empty conversation").
            let historyForRequest = contextMessages
            let stream = client.streamSend(
                messages: historyForRequest, baseURL: baseURL, modelDisplayName: modelDisplayName,
                settings: settings, tools: tools, systemPrompt: systemPrompt,
                conversationID: threads.currentThread.id.uuidString)

            generationPhase = .reasoning
            var reply: ChatMessage?
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .contentDelta(let delta):
                    generationPhase = .generating
                    threads.currentThread.messages[replyIndex].content += delta
                case .reasoningDelta(let delta):
                    generationPhase = .reasoning
                    threads.currentThread.messages[replyIndex].reasoning =
                        (threads.currentThread.messages[replyIndex].reasoning ?? "") + delta
                case .done(let message):
                    reply = message
                }
            }
            guard var reply else { return }
            reply.responderName = responderName
            reply.memoryIDsUsed = memoryIDsUsed
            threads.currentThread.messages[replyIndex] = reply

            if let toolCall = reply.toolCalls?.first(where: { $0.name == "generate_image" }), let imageConnection {
                generationPhase = .generatingImage
                let (toolResult, generatedPath) = await runGenerateImageTool(
                    toolCall, threadID: threads.currentThread.id, imageConnection: imageConnection)
                threads.currentThread.messages.append(toolResult)

                let followUpBuilder = ChatContextBuilder(
                    maxEstimatedTokens: maxEstimatedContextTokens, recentMessageCount: recentMessageCount)
                let followUpMemories = memories.filter {
                    $0.profileID == nil || $0.profileID == threads.currentThread.profileID
                }
                let followUpContext = followUpBuilder.build(
                    messages: threads.currentThread.messages, memories: followUpMemories)
                let followUpStream = client.streamSend(
                    messages: followUpContext.messages, baseURL: baseURL, modelDisplayName: modelDisplayName,
                    settings: settings, systemPrompt: systemPrompt,
                    conversationID: threads.currentThread.id.uuidString)

                threads.currentThread.messages.append(ChatMessage(
                    role: .assistant, content: "", modelDisplayName: modelDisplayName, responderName: responderName))
                let followUpIndex = threads.currentThread.messages.count - 1
                var followUpReply: ChatMessage?
                for try await event in followUpStream {
                    try Task.checkCancellation()
                    switch event {
                    case .contentDelta(let delta):
                        generationPhase = .generating
                        threads.currentThread.messages[followUpIndex].content += delta
                    case .reasoningDelta(let delta):
                        threads.currentThread.messages[followUpIndex].reasoning =
                            (threads.currentThread.messages[followUpIndex].reasoning ?? "") + delta
                    case .done(let message):
                        followUpReply = message
                    }
                }
                if var followUpReply {
                    followUpReply.generatedImagePath = generatedPath
                    followUpReply.responderName = responderName
                    followUpReply.memoryIDsUsed = followUpContext.memoryIDs
                    threads.currentThread.messages[followUpIndex] = followUpReply
                }
            }

            if let finalMessage = threads.currentThread.messages.last(where: { $0.role == .assistant }) {
                lastTokensPerSecond = finalMessage.tokensPerSecond
            }
            await threads.persistCurrentThread()
        } catch is CancellationError {
            if let last = threads.currentThread.messages.last, last.role == .assistant, last.content.isEmpty, last.toolCalls == nil {
                threads.currentThread.messages.removeLast()
            }
            await threads.persistCurrentThread()
        } catch {
            if let last = threads.currentThread.messages.last, last.role == .assistant, last.content.isEmpty, last.toolCalls == nil {
                threads.currentThread.messages.removeLast()
            }
            generationPhase = .failed
            errorMessage = error.localizedDescription
            await threads.persistCurrentThread()
        }
    }

    /// Runs a `generate_image` tool call against a remote **image**
    /// connection — the phone-side analog of the Mac's own
    /// `ChatViewModel.runGenerateImageTool`, adapted to `RemoteImageClient`
    /// instead of a local `ImageSessionManager` since there's no on-
    /// device image session to load here.
    private func runGenerateImageTool(
        _ call: ChatMessage.ToolCall, threadID: UUID, imageConnection: RemoteMacConnection
    ) async -> (ChatMessage, String?) {
        struct Arguments: Decodable { let prompt: String }
        guard let baseURL = imageConnection.baseURL else {
            return (ChatMessage(role: .tool, content: "Error: invalid image connection.", toolCallID: call.id), nil)
        }
        guard let data = call.argumentsJSON.data(using: .utf8),
            let arguments = try? JSONDecoder().decode(Arguments.self, from: data)
        else {
            return (ChatMessage(role: .tool, content: "Error: could not parse tool arguments.", toolCallID: call.id), nil)
        }

        let previous = lastImageGenerationByThread[threadID]
        var effectivePrompt = arguments.prompt
        var seed: Int?
        if let previous {
            seed = previous.seed
            effectivePrompt = "\(previous.prompt). Keep the same character appearance — skin tone, hair "
                + "color and style, eye color, body type — unless this request clearly changes them: "
                + arguments.prompt
        }

        do {
            let result = try await imageClient.generate(
                prompt: effectivePrompt, baseURL: baseURL, settings: .default, seed: seed)
            lastImageGenerationByThread[threadID] = (seed: result.seed, prompt: arguments.prompt)

            let directory = RuntimePaths.applicationSupportDirectory.appendingPathComponent("images", isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let fileURL = directory.appendingPathComponent("\(UUID().uuidString).png")
            guard let pngData = result.image.pngData() else {
                return (ChatMessage(role: .tool, content: "Error: could not encode the generated image.", toolCallID: call.id), nil)
            }
            try pngData.write(to: fileURL, options: .atomic)

            let saved = try await imageStore.add(GeneratedImage(
                prompt: arguments.prompt,
                modelDisplayName: imageConnection.displayName,
                localPath: fileURL.path,
                width: result.width,
                height: result.height,
                seed: result.seed
            ))

            let toolMessage = ChatMessage(
                role: .tool,
                content: "Image generated successfully and is already displayed to the user in this chat. "
                    + "Do not include a URL or Markdown image syntax — just briefly acknowledge it in plain text.",
                toolCallID: call.id
            )
            return (toolMessage, saved.localPath)
        } catch {
            return (ChatMessage(
                role: .tool, content: "Error generating image: \(error.localizedDescription)", toolCallID: call.id), nil)
        }
    }

    /// Mirrors Mac's `ChatViewModel.composedSystemPrompt` — the active
    /// profile's prompt, plus (only when the image tool is on offer) the
    /// same tool-use discipline reminder, plus durable memory, in that
    /// order.
    private static func composedSystemPrompt(profile: ChatProfile?, offeringTools: Bool, memoryPrompt: String?) -> String? {
        var parts: [String] = []
        if let prompt = profile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        if offeringTools {
            parts.append(ChatTool.generateImageUsageDiscipline)
        }
        if let memoryPrompt, !memoryPrompt.isEmpty {
            parts.append(memoryPrompt)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
