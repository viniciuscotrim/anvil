import AnvilCore
import Foundation
import UIKit

/// "Mac" — talks to a model already loaded on a Mac on the same
/// network, over the exact same `/v1/chat/completions`/
/// `/v1/images/generations` endpoints the Mac app's own `ChatClient`/
/// image server already expose. Nothing on the Mac needs to change for
/// this to work: a loaded model's own "Server Settings" gear icon
/// already has a Local-only/Network toggle and a port — set to
/// Network, and it's reachable here.
///
/// Streaming + a real Stop button, same shape as the Code tab's own
/// fix for "looks stopped but is still running forever": `ChatClient`
/// (fully cross-platform already, no changes needed) drives
/// `streamSend`, and `stopGeneration()` cancels the owning `Task`
/// directly rather than leaving no way to interrupt a stuck request.
@MainActor
final class RemoteMacViewModel: ObservableObject {
    @Published private(set) var connections: [RemoteMacConnection] = []
    @Published var selectedTextConnectionID: UUID?
    @Published var selectedImageConnectionID: UUID?
    /// Which saved connections answered when last checked — `nil` means
    /// "not checked yet this launch", not "offline". Checked first, fast
    /// (a handful of exact host:port pings), before the broader subnet
    /// scan even starts.
    @Published private(set) var reachableConnectionIDs: Set<UUID> = []
    @Published private(set) var isVerifyingSaved = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    /// Live servers found on the network that aren't already saved —
    /// each just needs one tap ("Remote") to start using, never typing
    /// an IP or port.
    @Published private(set) var discoveredModels: [DiscoveredMacModel] = []

    // Chat
    @Published var currentThread = ChatThread(title: "Mac Chat")
    @Published private(set) var allThreads: [ChatThread] = []
    @Published var inputText = ""
    @Published private(set) var isSending = false
    @Published private(set) var currentRoundStartedAt: Date?
    @Published var errorMessage: String?

    // Images
    @Published var imagePrompt = "a photo of an astronaut riding a horse on the moon"
    @Published private(set) var isGenerating = false
    @Published private(set) var lastImage: UIImage?
    @Published var imageSettings = ImageGenerationSettings.default

    private let store = RemoteMacConnectionStore()
    private let threadStore = ChatThreadStore(
        fileURL: RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("remote_mac", isDirectory: true)
            .appendingPathComponent("threads.json")
    )
    private let chatClient = ChatClient()
    private let imageClient = RemoteImageClient()
    private var generationTask: Task<Void, Never>?
    private var hasLoadedInitialState = false

    var selectedTextConnection: RemoteMacConnection? {
        connections.first { $0.id == selectedTextConnectionID && $0.kind == .text }
    }
    var selectedImageConnection: RemoteMacConnection? {
        connections.first { $0.id == selectedImageConnectionID && $0.kind == .image }
    }
    var textConnections: [RemoteMacConnection] { connections.filter { $0.kind == .text } }
    var imageConnections: [RemoteMacConnection] { connections.filter { $0.kind == .image } }

    func loadInitialState() async {
        connections = store.load()
        if selectedTextConnectionID == nil { selectedTextConnectionID = textConnections.first?.id }
        if selectedImageConnectionID == nil { selectedImageConnectionID = imageConnections.first?.id }
        allThreads = await threadStore.all()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread(title: "Mac Chat")
            hasLoadedInitialState = true
        }
    }

    // MARK: - Frictionless discovery

    /// The whole point: no IP, no port, ever typed for this to work.
    /// Called the moment the tab appears — first re-checks whatever's
    /// already saved (fast: a handful of exact addresses, in parallel),
    /// then scans the subnet for anything live and not already saved.
    /// Safe to call again (pull-to-refresh, reopening the tab): reuses
    /// whatever's already there rather than duplicating saved entries.
    func refreshConnections() async {
        await verifySavedConnections()
        await scanForNewConnections()
    }

    private func verifySavedConnections() async {
        guard !connections.isEmpty else { return }
        isVerifyingSaved = true
        defer { isVerifyingSaved = false }

        await withTaskGroup(of: (UUID, Bool).self) { group in
            for connection in connections {
                group.addTask {
                    guard case .success = await self.testConnection(connection) else {
                        return (connection.id, false)
                    }
                    return (connection.id, true)
                }
            }
            var reachable: Set<UUID> = []
            for await (id, isReachable) in group {
                if isReachable { reachable.insert(id) }
            }
            reachableConnectionIDs = reachable
        }
    }

    private func scanForNewConnections() async {
        isScanning = true
        scanProgress = 0
        defer { isScanning = false }

        let found = await LocalNetworkScanner.scan { [weak self] fraction in
            Task { @MainActor in self?.scanProgress = fraction }
        }
        let alreadySaved = Set(connections.map { "\($0.host):\($0.port)" })
        discoveredModels = found.filter { !alreadySaved.contains("\($0.host):\($0.port)") }
    }

    /// One tap, from a discovered model straight to "in use" — saves it
    /// (so next time it shows up under "Saved", verified, not scanned
    /// for again) and selects it immediately for its kind.
    func connect(to discovered: DiscoveredMacModel) {
        let connection = RemoteMacConnection(
            displayName: discovered.displayName, host: discovered.host, port: discovered.port, kind: discovered.kind)
        connections.append(connection)
        store.save(connections)
        reachableConnectionIDs.insert(connection.id)
        discoveredModels.removeAll { $0.id == discovered.id }
        switch discovered.kind {
        case .text: selectedTextConnectionID = connection.id
        case .image: selectedImageConnectionID = connection.id
        }
    }

    // MARK: - Connection management

    func addConnection(displayName: String, host: String, port: Int, kind: ModelKind) {
        let connection = RemoteMacConnection(displayName: displayName, host: host, port: port, kind: kind)
        connections.append(connection)
        store.save(connections)
        if kind == .text, selectedTextConnectionID == nil { selectedTextConnectionID = connection.id }
        if kind == .image, selectedImageConnectionID == nil { selectedImageConnectionID = connection.id }
    }

    func deleteConnection(_ connection: RemoteMacConnection) {
        connections.removeAll { $0.id == connection.id }
        store.save(connections)
        if selectedTextConnectionID == connection.id { selectedTextConnectionID = textConnections.first?.id }
        if selectedImageConnectionID == connection.id { selectedImageConnectionID = imageConnections.first?.id }
    }

    /// A cheap reachability check — `GET /v1/models`, the same endpoint
    /// the Mac's own per-model server already answers, so a real
    /// connectivity problem (wrong IP, model unloaded, phone on a
    /// different network/VPN) surfaces before the user ever types a
    /// message expecting a reply.
    func testConnection(_ connection: RemoteMacConnection) async -> Result<Void, Error> {
        guard let baseURL = connection.baseURL else {
            return .failure(RemoteImageClientError.requestFailed("Invalid host/port."))
        }
        do {
            let (_, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("v1/models"))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failure(RemoteImageClientError.requestFailed("No response from \(connection.host):\(connection.port)."))
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Threads

    func newThread() {
        currentThread = ChatThread(title: "Mac Chat")
    }

    func selectThread(_ thread: ChatThread) {
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        if isSending, currentThread.id == thread.id { return }
        try? await threadStore.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread(title: "Mac Chat")
        }
    }

    private func persistCurrentThread() {
        let threadToSave = currentThread
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if currentThread.id == saved.id { currentThread = saved }
            allThreads = await threadStore.all()
        }
    }

    private func persistCurrentThreadForDurability() {
        let threadToSave = currentThread
        Task { _ = try? await threadStore.upsert(threadToSave) }
    }

    // MARK: - Chat

    func send() {
        guard let connection = selectedTextConnection, let baseURL = connection.baseURL else {
            errorMessage = "Add and pick a Mac text connection first."
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil

        currentThread.messages.append(ChatMessage(role: .user, content: text))
        if currentThread.title == "Mac Chat", currentThread.messages.count == 1 {
            currentThread.title = String(text.prefix(48))
        }
        persistCurrentThreadForDurability()

        isSending = true
        generationTask = Task { [weak self] in
            await self?.runSend(baseURL: baseURL, modelDisplayName: connection.displayName)
            guard let self else { return }
            self.isSending = false
            self.currentRoundStartedAt = nil
            self.generationTask = nil
        }
    }

    func stopGeneration() {
        generationTask?.cancel()
    }

    private func runSend(baseURL: URL, modelDisplayName: String) async {
        currentRoundStartedAt = Date()
        currentThread.messages.append(ChatMessage(role: .assistant, content: "", modelDisplayName: modelDisplayName))
        let replyIndex = currentThread.messages.count - 1
        let historyForRequest = Array(currentThread.messages.dropLast())

        let stream = chatClient.streamSend(
            messages: historyForRequest,
            baseURL: baseURL,
            modelDisplayName: modelDisplayName
        )
        do {
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .contentDelta(let delta):
                    currentThread.messages[replyIndex].content += delta
                case .reasoningDelta:
                    break
                case .done(let message):
                    currentThread.messages[replyIndex] = message
                }
            }
            persistCurrentThread()
        } catch is CancellationError {
            if let last = currentThread.messages.last, last.role == .assistant, last.content.isEmpty {
                currentThread.messages.removeLast()
            }
            persistCurrentThread()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Images

    func generateImage() async {
        guard let connection = selectedImageConnection, let baseURL = connection.baseURL else {
            errorMessage = "Add and pick a Mac image connection first."
            return
        }
        let text = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        do {
            let result = try await imageClient.generate(prompt: text, baseURL: baseURL, settings: imageSettings)
            lastImage = result.image
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
