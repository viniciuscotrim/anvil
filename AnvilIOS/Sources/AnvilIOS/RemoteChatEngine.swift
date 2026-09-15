import AnvilCore
import Foundation
import UIKit
import Observation

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
@Observable
final class RemoteChatEngine {
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

    private(set) var generationPhase: GenerationPhase = .idle
    private(set) var lastTokensPerSecond: Double?
    var errorMessage: String?

    @ObservationIgnored
    private let client = ChatClient()
    @ObservationIgnored
    private let syncClient = AnvilSyncClient()
    @ObservationIgnored
    private let imageClient = RemoteImageClient()
    @ObservationIgnored
    private let imageStore = GeneratedImageStore()
    @ObservationIgnored
    private var generationTask: Task<Void, Never>?
    /// Carries the previous `generate_image` call's prompt + seed
    /// forward within a thread, the same fix the Mac app already needed
    /// for character consistency across consecutive generations ("same
    /// character, different clothes") — without it, consecutive remote
    /// generations would drift the same way the Mac's used to.
    @ObservationIgnored
    private var lastImageGenerationByThread: [UUID: (seed: Int, prompt: String)] = [:]

    var isSending: Bool { generationTask != nil }

    /// One full turn against `connection` — appends the user message,
    /// streams the reply into `threads.currentThread`, and (if
    /// `imageConnection` is given) can call `generate_image` against it
    /// mid-reply, exactly like the Mac app's own chat loop.
    /// `preferMacDrivenGeneration` (pass `threads.isMacSyncAvailable`):
    /// when true, the reply is triggered on the Mac itself via
    /// `AnvilSyncServer`'s `/generate` route instead of this phone
    /// holding its own streaming connection to the model server open —
    /// see `runMacDrivenGeneration`'s own doc comment for why that's
    /// what actually survives the phone backgrounding, closing, or
    /// losing its network connection mid-reply (a real, reported bug:
    /// the direct-streaming path dies the instant this phone's
    /// connection does, and the Mac's own server stops generating right
    /// along with it — there is no client left to write tokens to).
    func send(
        text: String,
        threads: ChatThreadsViewModel,
        connection: RemoteMacConnection,
        imageConnection: RemoteMacConnection?,
        profile: ChatProfile?,
        memories: [ChatMemory],
        settings: GenerationSettings,
        preferMacDrivenGeneration: Bool = false,
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
        // For the Mac-driven path, `runMacDrivenGeneration` does its own
        // *awaited* push before ever calling /generate — deliberately
        // not this fire-and-forget one, which raced against it (see
        // that method's own comment for the real, reproduced bug this
        // avoids). The direct-streaming path still wants this: it's the
        // only thing that saves the user's message before a possibly
        // long-running reply, independent of the request that follows.
        if !preferMacDrivenGeneration {
            threads.persistCurrentThreadForDurability()
        }

        let tools: [ChatTool] = imageConnection != nil ? [.generateImage] : []
        let contextBuilder = ChatContextBuilder(
            maxEstimatedTokens: maxEstimatedContextTokens, recentMessageCount: recentMessageCount)
        let activeProfileID = threads.currentThread.profileID
        let scopedMemories = memories.filter {
            ($0.profileID == nil || $0.profileID == activeProfileID) && $0.appliesTo(threadID: threads.currentThread.id)
        }
        let context = contextBuilder.build(messages: threads.currentThread.messages, memories: scopedMemories)
        let systemPrompt = Self.composedSystemPrompt(
            profile: profile, offeringTools: !tools.isEmpty, memoryPrompt: context.memoryPrompt)
        let modelDisplayName = connection.displayName
        let responderName = profile?.name

        generationPhase = .preparing
        generationTask = Task { [weak self] in
            guard let self else { return }
            if preferMacDrivenGeneration {
                await self.runMacDrivenGeneration(threads: threads, connection: connection)
            } else {
                // Only this path positionally mutates `currentThread`'s
                // messages while it runs, so only this path needs the
                // periodic Mac merge held off — see `isSendInFlight`'s
                // own doc comment. The Mac-driven path above never
                // holds it: it returns almost immediately, and the
                // ordinary periodic merge is exactly what picks up its
                // result once the Mac's background task finishes.
                threads.markSendStarted()
                await self.runChatLoop(
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
                threads.markSendFinished()
            }
            self.generationTask = nil
            if self.generationPhase == .preparing || self.generationPhase == .reasoning || self.generationPhase == .generating {
                self.generationPhase = .idle
            }
        }
    }

    /// Triggers the reply on the Mac itself (`AnvilSyncServer`'s
    /// `/v1/anvil/threads/{id}/generate`) instead of this phone holding
    /// its own streaming connection to the model server — the Mac's own
    /// background task keeps running against its own loopback address
    /// regardless of what happens to this phone afterward. Returns as
    /// soon as the Mac has accepted the request and appended its
    /// pending placeholder; the real content shows up once the ordinary
    /// periodic merge (`ChatThreadsViewModel`'s ongoing sync loop, still
    /// running since this never sets `isSendInFlight`) picks up the
    /// Mac's own completed write — not something this method waits for
    /// or polls itself, by design: the whole point is that this phone
    /// doesn't need to stay around for the answer to keep coming.
    private func runMacDrivenGeneration(threads: ChatThreadsViewModel, connection: RemoteMacConnection) async {
        do {
            // Must land on the Mac *before* /generate is called — that
            // route reads the thread straight off the Mac's own disk,
            // completely independent of whatever `send()`'s own
            // fire-and-forget `persistCurrentThreadForDurability()` is
            // doing concurrently. A real, reproduced bug: without this
            // explicit, awaited push first, /generate could (and did)
            // win the race and read a snapshot from *before* this
            // message was appended — the user's own new question
            // silently missing from what the model was ever asked to
            // reply to, appending its response placeholder right after
            // the *previous* turn instead. Awaiting this first makes
            // the ordering impossible to get wrong.
            await threads.persistCurrentThread()
            let sessions = try await syncClient.sessions(host: connection.host)
            guard let session = sessions.first(where: { $0.port == connection.port }) else {
                throw AnvilSyncClientError.requestFailed(
                    "Could not tell which model is running at \(connection.host):\(connection.port).")
            }
            let updated = try await syncClient.generate(
                threadID: threads.currentThread.id, modelID: session.modelID, host: connection.host)
            if updated.id == threads.currentThread.id {
                threads.currentThread = updated
            }
        } catch {
            errorMessage = error.localizedDescription
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
            let placeholder = ChatMessage(
                role: .assistant, content: "", modelDisplayName: modelDisplayName, responderName: responderName)
            threads.currentThread.messages.append(placeholder)
            let replyID = placeholder.id
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
                // Looked up by ID on every delta, not a captured array
                // index — `isSendInFlight` (set by `send()`) already
                // keeps the periodic Mac merge from replacing
                // `currentThread` mid-stream, but this is what makes a
                // delta a graceful no-op instead of a crash if the
                // placeholder ever goes missing for some other reason,
                // rather than indexing into an array that moved.
                guard let index = Self.index(of: replyID, in: threads.currentThread.messages) else { continue }
                switch event {
                case .contentDelta(let delta):
                    generationPhase = .generating
                    threads.currentThread.messages[index].content += delta
                case .reasoningDelta(let delta):
                    generationPhase = .reasoning
                    threads.currentThread.messages[index].reasoning =
                        (threads.currentThread.messages[index].reasoning ?? "") + delta
                case .done(let message):
                    reply = message
                }
            }
            // Same real bug fixed on the Mac side (`ChatViewModel`'s own
            // `runChatLoop`): silently returning here left an empty
            // assistant placeholder with no error and nothing to retry.
            guard var reply else {
                generationPhase = .failed
                errorMessage = "The response ended with no content — nothing to show. Try sending again."
                if let index = Self.index(of: replyID, in: threads.currentThread.messages) {
                    threads.currentThread.messages[index] = ChatMessage(
                        role: .assistant,
                        content: "⚠️ No response was received — the connection may have dropped. Try sending again.",
                        modelDisplayName: modelDisplayName,
                        responderName: responderName
                    )
                }
                await threads.persistCurrentThread()
                return
            }
            reply.responderName = responderName
            reply.memoryIDsUsed = memoryIDsUsed
            if let index = Self.index(of: replyID, in: threads.currentThread.messages) {
                threads.currentThread.messages[index] = reply
            }

            if let toolCall = reply.toolCalls?.first(where: { $0.name == "generate_image" }), let imageConnection {
                generationPhase = .generatingImage
                let (toolResult, generatedPath) = await runGenerateImageTool(
                    toolCall, threadID: threads.currentThread.id, imageConnection: imageConnection)
                threads.currentThread.messages.append(toolResult)

                let followUpBuilder = ChatContextBuilder(
                    maxEstimatedTokens: maxEstimatedContextTokens, recentMessageCount: recentMessageCount)
                let followUpMemories = memories.filter {
                    ($0.profileID == nil || $0.profileID == threads.currentThread.profileID)
                        && $0.appliesTo(threadID: threads.currentThread.id)
                }
                let followUpContext = followUpBuilder.build(
                    messages: threads.currentThread.messages, memories: followUpMemories)
                let followUpStream = client.streamSend(
                    messages: followUpContext.messages, baseURL: baseURL, modelDisplayName: modelDisplayName,
                    settings: settings, systemPrompt: systemPrompt,
                    conversationID: threads.currentThread.id.uuidString)

                let followUpPlaceholder = ChatMessage(
                    role: .assistant, content: "", modelDisplayName: modelDisplayName, responderName: responderName)
                threads.currentThread.messages.append(followUpPlaceholder)
                let followUpID = followUpPlaceholder.id
                var followUpReply: ChatMessage?
                for try await event in followUpStream {
                    try Task.checkCancellation()
                    guard let index = Self.index(of: followUpID, in: threads.currentThread.messages) else { continue }
                    switch event {
                    case .contentDelta(let delta):
                        generationPhase = .generating
                        threads.currentThread.messages[index].content += delta
                    case .reasoningDelta(let delta):
                        threads.currentThread.messages[index].reasoning =
                            (threads.currentThread.messages[index].reasoning ?? "") + delta
                    case .done(let message):
                        followUpReply = message
                    }
                }
                if var followUpReply, let index = Self.index(of: followUpID, in: threads.currentThread.messages) {
                    followUpReply.generatedImagePath = generatedPath
                    followUpReply.responderName = responderName
                    followUpReply.memoryIDsUsed = followUpContext.memoryIDs
                    threads.currentThread.messages[index] = followUpReply
                } else if let index = Self.index(of: followUpID, in: threads.currentThread.messages) {
                    // Same bug, same fix, one turn later — the
                    // follow-up reply after a `generate_image` tool
                    // call ended with no content.
                    generationPhase = .failed
                    errorMessage = "The follow-up response after generating the image ended with no content. Try sending again."
                    threads.currentThread.messages[index] = ChatMessage(
                        role: .assistant,
                        content: "⚠️ The image generated, but the follow-up reply never arrived — the connection may have dropped. Try sending again.",
                        modelDisplayName: modelDisplayName,
                        responderName: responderName
                    )
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

    private static func index(of messageID: UUID, in messages: [ChatMessage]) -> Int? {
        messages.firstIndex { $0.id == messageID }
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
