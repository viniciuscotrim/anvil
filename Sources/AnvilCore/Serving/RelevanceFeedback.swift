import Foundation

/// One correction: the AI's original relevance guess for a memory
/// versus what the user actually set it to — the raw material for
/// "improving the pipeline over time" without any real training
/// infrastructure. `ContextShiftScript.summarize` reads a sample of
/// these back as few-shot calibration examples in its own prompt, so
/// Phi-4 has concrete anchors for what "trivial" versus "unmissable"
/// actually means to this particular user, instead of guessing from a
/// bare rubric alone every time. Requested live, in the same breath as
/// relevance scoring itself: "Assim a IA pode aprender com a
/// relevancia que eu dou, e melhorar o pipeline com o tempo."
///
/// Explicit snake_case `CodingKeys`, unlike most of this file's
/// neighbors — this one is read directly by
/// `ContextShiftScript.swift`'s own Python (a fixed path under
/// Application Support, the same way it already reads/writes the
/// vector store), matching `ThreadExport`'s own convention for a type
/// crossing that same language boundary.
public struct RelevanceFeedback: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: String
    public let aiRelevance: Double
    public let userRelevance: Double
    public let correctedAt: Date

    public init(
        id: UUID = UUID(),
        content: String,
        aiRelevance: Double,
        userRelevance: Double,
        correctedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.aiRelevance = aiRelevance
        self.userRelevance = userRelevance
        self.correctedAt = correctedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, content
        case aiRelevance = "ai_relevance"
        case userRelevance = "user_relevance"
        case correctedAt = "corrected_at"
    }
}

/// Local-only, one JSON file — never synced via CloudKit, since a
/// correction is tied to calibrating this Mac's own Phi-4 pipeline,
/// not something meaningful to replay on another device.
public actor RelevanceFeedbackStore {
    private let fileURL: URL

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("relevance_feedback.json")
    ) {
        self.fileURL = fileURL
    }

    public func all() -> [RelevanceFeedback] {
        load().sorted { $0.correctedAt > $1.correctedAt }
    }

    /// Caps how large this ever grows — only the most recent
    /// `maxEntries` corrections are kept. Older ones are superseded by
    /// more recent calibration anyway, and this whole file is re-read
    /// in full on every compaction pass.
    private static let maxEntries = 200

    @discardableResult
    public func record(_ feedback: RelevanceFeedback) throws -> RelevanceFeedback {
        var entries = load()
        entries.append(feedback)
        entries.sort { $0.correctedAt > $1.correctedAt }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        try persist(entries)
        return feedback
    }

    private func load() -> [RelevanceFeedback] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([RelevanceFeedback].self, from: data)) ?? []
    }

    private func persist(_ entries: [RelevanceFeedback]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
