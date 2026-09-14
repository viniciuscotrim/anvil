import Foundation

/// A durable fact or preference intentionally shared with future turns.
/// The store is local-only and independent from transcript history so a
/// long conversation can be compacted without losing important memory.
public enum ChatMemoryKind: String, Codable, CaseIterable, Sendable {
    case fact
    case preference
    case date
    case number
    case impression
    /// A consolidated recap of a whole excerpt's decisions and logical
    /// flow — what `ContextShiftCoordinator`'s compaction pipeline
    /// produces, as opposed to the single atomic facts/preferences
    /// "Suggest from Thread" extracts. Both land in the same
    /// suggestion queue and need the same explicit approval before
    /// becoming a real `ChatMemory`.
    case summary

    public var label: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .date: return "Date"
        case .number: return "Number"
        case .impression: return "Impression"
        case .summary: return "Summary"
        }
    }
}

public enum ChatMemorySource: String, Codable, CaseIterable, Sendable {
    case explicit
    case inferred

    public var label: String {
        switch self {
        case .explicit: return "You told Anvil"
        case .inferred: return "Inferred"
        }
    }
}

public struct ChatMemory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var kind: ChatMemoryKind
    public var source: ChatMemorySource
    public var confidence: Double?
    public var profileID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    /// Which device this memory was first created on — see
    /// `ChatThread.originDeviceName`'s doc comment for the same purpose
    /// and contract.
    public var originDeviceName: String?
    /// Which `ChatMessage` this memory was created from, when it was
    /// created via "Suggest from thread" (tied to the last message in
    /// the thread at accept-time) — nil for a memory added directly via
    /// the "Remember" field, which isn't tied to any one message. Lets
    /// deleting/editing a message cascade to memories that only exist
    /// because of it and whatever came after, instead of leaving orphaned
    /// "facts" behind that trace back to a question that no longer exists.
    public var createdFromMessageID: UUID?
    /// The thread this memory was actually generated in — set once,
    /// immutably, at creation time (both an explicit "Remember" and an
    /// accepted "Suggest from Thread" suggestion record whichever
    /// thread was open at that moment). Independent of `isGlobal`,
    /// which controls whether that origin currently *restricts* where
    /// the memory applies — toggling Global off always restores
    /// exactly this thread, never guesses at a different one. `nil`
    /// only for a memory persisted before this field existed, or one
    /// somehow created with no thread context at all; such a memory is
    /// treated as global regardless of `isGlobal`'s own value, since
    /// there's no thread left to scope it back down to.
    public var originThreadID: UUID?
    /// Requested live: "memórias por thread/conversa... geradas e
    /// consumidas dentro do thread que foram geradas" — `true` means
    /// usable from any conversation (matching every memory's behavior
    /// before this field existed, and still the default for anything
    /// decoded without it); `false` restricts it to `originThreadID`
    /// alone. A button next to each memory in the Memory screen flips
    /// this — "transformar ela em Global ou voltar apenas pra
    /// conversa onde foi gerada."
    public var isGlobal: Bool
    /// How worth remembering this actually is, `0`–`1` — distinct from
    /// `confidence` (how sure the *extraction* was this is accurate).
    /// Requested live, after a first real digest surfaced 100+
    /// suggestions in one pass: "ao revisar manualmente algumas eram
    /// triviais, outras interessantes e algumas imperdíveis. Então ao
    /// invés de simplesmente aceitar ou recusar temos que ter uma
    /// avaliação da IA do quão relevante a memória parece ser, e me
    /// deixar editar essa relevancia." Always editable — see
    /// `ChatViewModel.setMemoryRelevance` — and defaults to `0.5`
    /// (`aiRelevance`'s own default) for anything saved before this
    /// existed or added through a path that doesn't score it at all
    /// (an explicit "Remember").
    public var relevance: Double
    /// The AI's own original relevance score, from whichever pipeline
    /// produced this — immutable once set, `nil` when nothing ever
    /// scored it (an explicit "Remember", or a memory saved before
    /// this existed). Kept separate from the editable `relevance`
    /// above specifically so a later edit can be compared against
    /// what the AI actually guessed — see `RelevanceFeedbackStore`,
    /// "para que a IA possa aprender com a relevancia que eu dou."
    public var aiRelevance: Double?

    public init(
        id: UUID = UUID(),
        content: String,
        kind: ChatMemoryKind = .fact,
        source: ChatMemorySource = .explicit,
        confidence: Double? = nil,
        profileID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceName: String? = nil,
        createdFromMessageID: UUID? = nil,
        originThreadID: UUID? = nil,
        isGlobal: Bool = true,
        relevance: Double = 0.5,
        aiRelevance: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.profileID = profileID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceName = originDeviceName
        self.createdFromMessageID = createdFromMessageID
        self.originThreadID = originThreadID
        self.isGlobal = isGlobal
        self.relevance = relevance
        self.aiRelevance = aiRelevance
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, kind, source, confidence, profileID, createdAt, updatedAt, originDeviceName, createdFromMessageID
        case originThreadID, isGlobal, relevance, aiRelevance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        kind = try container.decodeIfPresent(ChatMemoryKind.self, forKey: .kind) ?? .fact
        source = try container.decodeIfPresent(ChatMemorySource.self, forKey: .source) ?? .explicit
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        originDeviceName = try container.decodeIfPresent(String.self, forKey: .originDeviceName)
        createdFromMessageID = try container.decodeIfPresent(UUID.self, forKey: .createdFromMessageID)
        originThreadID = try container.decodeIfPresent(UUID.self, forKey: .originThreadID)
        // Absent only on a memory saved before thread-scoping existed
        // at all — treated as global, exactly how it already behaved.
        isGlobal = try container.decodeIfPresent(Bool.self, forKey: .isGlobal) ?? true
        // Absent only on a memory saved before relevance existed —
        // "neutral" rather than assuming trivial or unmissable.
        relevance = try container.decodeIfPresent(Double.self, forKey: .relevance) ?? 0.5
        aiRelevance = try container.decodeIfPresent(Double.self, forKey: .aiRelevance)
    }

    /// Whether this memory should be pulled into a request being sent
    /// from `threadID` — the one check both platforms' own context
    /// filters call, so "global or scoped to this thread" is decided
    /// in exactly one place. A memory with no recorded origin at all
    /// (`originThreadID == nil`, e.g. persisted before this field
    /// existed) always applies, matching how every memory behaved
    /// before thread-scoping existed regardless of `isGlobal`'s own
    /// value — there's no thread left to restrict it back down to.
    public func appliesTo(threadID: UUID) -> Bool {
        isGlobal || originThreadID == nil || originThreadID == threadID
    }
}

/// A not-yet-approved candidate from "Suggest from Thread" — existing
/// (persisted, synced) is deliberately a separate fact from being
/// usable by the AI (only a real `ChatMemory`, created by explicitly
/// accepting one of these, is ever read into a chat request). Synced
/// like `ChatThread`/`ChatProfile`/`ChatMemory` via
/// `ChatMemorySuggestionStore`/`CloudSyncEngine` so a suggestion
/// generated on one device can be reviewed — accepted or dismissed —
/// from any other, not just the one that ran the analysis.
public struct ChatMemorySuggestion: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var kind: ChatMemoryKind
    public var confidence: Double
    public var rationale: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Which device generated this suggestion — see
    /// `ChatThread.originDeviceName`'s doc comment for the same purpose.
    public var originDeviceName: String?
    /// The thread this was extracted from, captured at generation
    /// time — not "whichever thread happens to be open" at accept
    /// time, which could be a different one entirely once suggestions
    /// sync across devices and get reviewed somewhere else.
    public var sourceThreadID: UUID?
    /// Carried straight through to the resulting `ChatMemory` on
    /// accept, exactly like `ChatMemory.createdFromMessageID` — lets
    /// deleting the source conversation cascade to a memory that only
    /// exists because of it, even for one accepted well after the fact
    /// on a different device.
    public var createdFromMessageID: UUID?
    /// When set, accepting this suggestion rewrites the *existing*
    /// `ChatMemory` with this id instead of creating a new, separate
    /// one — requested live: a freshly re-extracted bullet that's a
    /// reworded version of a memory already saved (not identical, but
    /// not a new fact either) should show up "como precisando de
    /// aprovação, mas mostre que é um update e mostrando o antigo e o
    /// novo em um formato de texto hachurado se algo for deletado e
    /// negrito se for acrescentado" — see `MemoryDiff`, which both the
    /// classification decision and the diff rendering are built on.
    /// `nil` (the common case) means this is an ordinary new-memory
    /// suggestion, exactly as before this field existed.
    public var supersedesMemoryID: UUID?
    /// The AI's own relevance rating for this specific bullet, `0`–`1`,
    /// editable before ever accepting (`ChatViewModel
    /// .setSuggestionRelevance`) — see `ChatMemory.relevance`'s own
    /// doc comment for the full request. `nil` only for a suggestion
    /// from a path that doesn't score relevance at all (the older
    /// JSON-array extraction, still iOS's own mechanism) — shown as
    /// unscored rather than assumed trivial.
    public var relevance: Double?
    /// The AI's *original* relevance rating — set once, at creation,
    /// never touched again, specifically so an edit to `relevance`
    /// above can still be compared against what the AI actually
    /// guessed. Mirrors `ChatMemory.aiRelevance` exactly, and is what
    /// both `relevance` and `aiRelevance` get seeded from on the
    /// resulting `ChatMemory` when this suggestion is accepted.
    public var aiRelevance: Double?

    public init(
        id: UUID = UUID(),
        content: String,
        kind: ChatMemoryKind,
        confidence: Double,
        rationale: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        originDeviceName: String? = nil,
        sourceThreadID: UUID? = nil,
        createdFromMessageID: UUID? = nil,
        supersedesMemoryID: UUID? = nil,
        relevance: Double? = nil,
        aiRelevance: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.confidence = confidence
        self.rationale = rationale
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceName = originDeviceName
        self.sourceThreadID = sourceThreadID
        self.createdFromMessageID = createdFromMessageID
        self.supersedesMemoryID = supersedesMemoryID
        self.relevance = relevance
        self.aiRelevance = aiRelevance
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, kind, confidence, rationale, createdAt, updatedAt
        case originDeviceName, sourceThreadID, createdFromMessageID, supersedesMemoryID, relevance, aiRelevance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        kind = try container.decode(ChatMemoryKind.self, forKey: .kind)
        confidence = try container.decode(Double.self, forKey: .confidence)
        rationale = try container.decode(String.self, forKey: .rationale)
        // Both default to "now" — absent only on a suggestion created
        // before this field existed (a brief in-memory-only window
        // this same change closes), never on one actually persisted
        // by this version of the store.
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        originDeviceName = try container.decodeIfPresent(String.self, forKey: .originDeviceName)
        sourceThreadID = try container.decodeIfPresent(UUID.self, forKey: .sourceThreadID)
        createdFromMessageID = try container.decodeIfPresent(UUID.self, forKey: .createdFromMessageID)
        relevance = try container.decodeIfPresent(Double.self, forKey: .relevance)
        aiRelevance = try container.decodeIfPresent(Double.self, forKey: .aiRelevance)
        supersedesMemoryID = try container.decodeIfPresent(UUID.self, forKey: .supersedesMemoryID)
    }
}

public actor ChatMemorySuggestionStore {
    private let fileURL: URL

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("memory_suggestions.json")
    ) {
        self.fileURL = fileURL
    }

    public func all() -> [ChatMemorySuggestion] {
        load().sorted { $0.createdAt > $1.createdAt }
    }

    /// Local-generation entry point — stamps `updatedAt` to now. See
    /// `ChatThreadStore.upsert`/`upsertPreservingTimestamp` for why a
    /// sync/merge write must use the other method below instead.
    @discardableResult
    public func upsert(_ suggestion: ChatMemorySuggestion) throws -> ChatMemorySuggestion {
        var updated = suggestion
        updated.updatedAt = Date()
        return try store(updated)
    }

    /// Sync/merge entry point — keeps the caller-supplied `updatedAt`
    /// exactly as given.
    @discardableResult
    public func upsertPreservingTimestamp(_ suggestion: ChatMemorySuggestion) throws -> ChatMemorySuggestion {
        try store(suggestion)
    }

    private func store(_ suggestion: ChatMemorySuggestion) throws -> ChatMemorySuggestion {
        var suggestions = load()
        if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            suggestions[index] = suggestion
        } else {
            suggestions.append(suggestion)
        }
        try persist(suggestions)
        return suggestion
    }

    public func delete(id: UUID) throws {
        var suggestions = load()
        suggestions.removeAll { $0.id == id }
        try persist(suggestions)
        try recordDeletion(id: id)
    }

    /// See `ChatThreadStore.deletionTimestamps` — same tombstone
    /// mechanism: without it, accepting or dismissing a suggestion on
    /// one device would have it silently resurface from another
    /// device's next periodic sync/merge.
    public func deletionTimestamps() -> [UUID: Date] {
        loadTombstones()
    }

    private var tombstoneFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("memory_suggestions_deleted.json")
    }

    private func recordDeletion(id: UUID) throws {
        var tombstones = loadTombstones()
        tombstones[id] = Date()
        try persistTombstones(tombstones)
    }

    private func loadTombstones() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: tombstoneFileURL) else { return [:] }
        return (try? JSONDecoder.anvil.decode([UUID: Date].self, from: data)) ?? [:]
    }

    private func persistTombstones(_ tombstones: [UUID: Date]) throws {
        let data = try JSONEncoder.anvil.encode(tombstones)
        try data.write(to: tombstoneFileURL, options: .atomic)
    }

    private func load() -> [ChatMemorySuggestion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ChatMemorySuggestion].self, from: data)) ?? []
    }

    private func persist(_ suggestions: [ChatMemorySuggestion]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(suggestions)
        try data.write(to: fileURL, options: .atomic)
    }
}

public actor ChatMemoryStore {
    private let fileURL: URL

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("memories.json")
    ) {
        self.fileURL = fileURL
    }

    public func all() -> [ChatMemory] {
        load().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Local-edit entry point — stamps `updatedAt` to now. See
    /// `ChatThreadStore.upsert`/`upsertPreservingTimestamp` for why a
    /// sync/merge write must use the other method below instead.
    @discardableResult
    public func upsert(_ memory: ChatMemory) throws -> ChatMemory {
        var updated = memory
        updated.updatedAt = Date()
        return try store(updated)
    }

    /// Sync/merge entry point — keeps the caller-supplied `updatedAt`
    /// exactly as given. See `ChatThreadStore.upsertPreservingTimestamp`
    /// for the full story of the bug this avoids.
    @discardableResult
    public func upsertPreservingTimestamp(_ memory: ChatMemory) throws -> ChatMemory {
        try store(memory)
    }

    private func store(_ memory: ChatMemory) throws -> ChatMemory {
        var memories = load()
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = memory
        } else {
            memories.append(memory)
        }
        try persist(memories)
        return memory
    }

    public func delete(id: UUID) throws {
        var memories = load()
        memories.removeAll { $0.id == id }
        try persist(memories)
        try recordDeletion(id: id)
    }

    /// See `ChatThreadStore.deletionTimestamps` — same tombstone
    /// mechanism, same reason: without it, a periodic union-style merge
    /// resurrects a deliberately-deleted memory.
    public func deletionTimestamps() -> [UUID: Date] {
        loadTombstones()
    }

    private var tombstoneFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("memories_deleted.json")
    }

    private func recordDeletion(id: UUID) throws {
        var tombstones = loadTombstones()
        tombstones[id] = Date()
        try persistTombstones(tombstones)
    }

    private func loadTombstones() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: tombstoneFileURL) else { return [:] }
        return (try? JSONDecoder.anvil.decode([UUID: Date].self, from: data)) ?? [:]
    }

    private func persistTombstones(_ tombstones: [UUID: Date]) throws {
        let data = try JSONEncoder.anvil.encode(tombstones)
        try data.write(to: tombstoneFileURL, options: .atomic)
    }

    private func load() -> [ChatMemory] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ChatMemory].self, from: data)) ?? []
    }

    private func persist(_ memories: [ChatMemory]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(memories)
        try data.write(to: fileURL, options: .atomic)
    }
}
