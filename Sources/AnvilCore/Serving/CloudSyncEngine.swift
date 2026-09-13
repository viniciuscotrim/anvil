import Foundation
import CloudKit

/// Optional, opt-in sync of threads/profiles/memories through the
/// user's own private iCloud database — unlike `AnvilSyncServer` (same
/// local network only), this works from anywhere, on either platform,
/// with no Mac reachability required at all. The app works fully
/// without ever touching this: nothing here runs until
/// `CloudSyncSettings.isEnabled` is turned on, mirroring the same
/// "opt-in, off by default" rule every other network-facing feature in
/// this app already follows (`AnvilSyncServer`'s own toggle, every
/// model's own Local/Network access).
///
/// Built on `CKSyncEngine` (macOS 14 / iOS 17+, matching this project's
/// existing deployment targets) — Apple's own higher-level replacement
/// for hand-rolled `CKModifyRecordsOperation`/change-token bookkeeping,
/// verified against the real API in the installed SDK's own
/// `.swiftinterface` rather than assumed from memory. One private
/// record zone ("AnvilData") holds three record types (`ChatThread`,
/// `ChatProfile`, `ChatMemory`), each record's fields matching the
/// AnvilCore model it mirrors (`messages`/etc. stored as a single JSON
/// blob field — well within CloudKit's per-field size limits for chat-
/// length text, and far simpler than a normalized per-message record
/// scheme for what is still a single-user store).
///
/// Conflict handling matches the local-network merge's own rule for
/// consistency: last-write-wins by `updatedAt` — `CKSyncEngine` surfaces
/// a save failure with the server's current record on a genuine
/// conflict (`CKError.serverRecordChanged`), and this resolves it the
/// same way `ChatThreadsViewModel.mergeThreads` already does elsewhere,
/// rather than introducing a second, different conflict policy.
public actor CloudSyncEngine {
    public static let containerIdentifier = "iCloud.com.viniciuscotrim.anvil"
    private static let zoneName = "AnvilData"
    private static let zoneID = CKRecordZone.ID(zoneName: zoneName)

    private let threadStore: ChatThreadStore
    private let profileStore: ChatProfileStore
    private let memoryStore: ChatMemoryStore
    private let container: CKContainer
    private var engine: CKSyncEngine?
    private var delegateRef: EngineDelegate?

    public init(
        threadStore: ChatThreadStore = ChatThreadStore(),
        profileStore: ChatProfileStore = ChatProfileStore(),
        memoryStore: ChatMemoryStore = ChatMemoryStore()
    ) {
        self.threadStore = threadStore
        self.profileStore = profileStore
        self.memoryStore = memoryStore
        self.container = CKContainer(identifier: Self.containerIdentifier)
    }

    /// Checked before ever turning this on — `.available` is required;
    /// anything else (not signed in, restricted, etc.) means the
    /// feature stays off with a clear reason shown, never a silent
    /// failure the user has to guess at.
    public func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    public var isRunning: Bool { engine != nil }

    /// Starts the sync engine and makes sure the private zone exists.
    /// Safe to call repeatedly (a no-op once already running).
    public func start() async throws {
        guard engine == nil else { return }
        let delegate = EngineDelegate(owner: self)
        self.delegateRef = delegate
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        let newEngine = CKSyncEngine(configuration)
        newEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        self.engine = newEngine
        try await newEngine.sendChanges()
        try await newEngine.fetchChanges()
    }

    public func stop() {
        engine = nil
        delegateRef = nil
    }

    // MARK: - Queuing local changes for upload

    public func markThreadChanged(_ thread: ChatThread) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID(kind: .thread, id: thread.id))])
    }

    public func markThreadDeleted(id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(kind: .thread, id: id))])
    }

    public func markProfileChanged(_ profile: ChatProfile) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID(kind: .profile, id: profile.id))])
    }

    public func markProfileDeleted(id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(kind: .profile, id: id))])
    }

    public func markMemoryChanged(_ memory: ChatMemory) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(Self.recordID(kind: .memory, id: memory.id))])
    }

    public func markMemoryDeleted(id: UUID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(kind: .memory, id: id))])
    }

    /// Nudges a send/fetch cycle right away instead of waiting for
    /// `CKSyncEngine`'s own scheduling — used right after a local edit
    /// so a change reaches other devices in seconds, not whenever the
    /// system next decides to sync on its own.
    public func syncNow() async {
        try? await engine?.sendChanges()
        try? await engine?.fetchChanges()
    }

    // MARK: - Record kind / ID scheme

    private enum RecordKind: String {
        case thread = "ChatThread"
        case profile = "ChatProfile"
        case memory = "ChatMemory"
    }

    private static func recordID(kind: RecordKind, id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(kind.rawValue)-\(id.uuidString)", zoneID: zoneID)
    }

    /// Recovers which store a record ID belongs to, and its underlying
    /// UUID, from the naming scheme above — used when the server hands
    /// back a bare record ID (e.g. a deletion) with no record body to
    /// read a `recordType` from.
    private static func parse(_ recordID: CKRecord.ID) -> (RecordKind, UUID)? {
        let name = recordID.recordName
        for kind in [RecordKind.thread, .profile, .memory] {
            let prefix = "\(kind.rawValue)-"
            if name.hasPrefix(prefix), let id = UUID(uuidString: String(name.dropFirst(prefix.count))) {
                return (kind, id)
            }
        }
        return nil
    }

    // MARK: - Model <-> CKRecord mapping

    private func record(for pendingChange: CKRecord.ID) async -> CKRecord? {
        guard let (kind, id) = Self.parse(pendingChange) else { return nil }
        switch kind {
        case .thread:
            guard let thread = await threadStore.get(id: id) else { return nil }
            return Self.makeRecord(from: thread, recordID: pendingChange)
        case .profile:
            guard let profile = await profileStore.get(id: id) else { return nil }
            return Self.makeRecord(from: profile, recordID: pendingChange)
        case .memory:
            guard let memory = (await memoryStore.all()).first(where: { $0.id == id }) else { return nil }
            return Self.makeRecord(from: memory, recordID: pendingChange)
        }
    }

    private static func makeRecord(from thread: ChatThread, recordID: CKRecord.ID) -> CKRecord? {
        guard let messagesData = try? JSONEncoder.anvil.encode(thread.messages) else { return nil }
        let record = CKRecord(recordType: RecordKind.thread.rawValue, recordID: recordID)
        record["title"] = thread.title as CKRecordValue
        record["messagesJSON"] = String(decoding: messagesData, as: UTF8.self) as CKRecordValue
        record["createdAt"] = thread.createdAt as CKRecordValue
        record["updatedAt"] = thread.updatedAt as CKRecordValue
        if let profileID = thread.profileID { record["profileID"] = profileID.uuidString as CKRecordValue }
        if let origin = thread.originDeviceName { record["originDeviceName"] = origin as CKRecordValue }
        return record
    }

    private static func makeRecord(from profile: ChatProfile, recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: RecordKind.profile.rawValue, recordID: recordID)
        record["name"] = profile.name as CKRecordValue
        record["prompt"] = profile.prompt as CKRecordValue
        record["createdAt"] = profile.createdAt as CKRecordValue
        if let defaultForModelID = profile.defaultForModelID { record["defaultForModelID"] = defaultForModelID as CKRecordValue }
        if let origin = profile.originDeviceName { record["originDeviceName"] = origin as CKRecordValue }
        return record
    }

    private static func makeRecord(from memory: ChatMemory, recordID: CKRecord.ID) -> CKRecord {
        let record = CKRecord(recordType: RecordKind.memory.rawValue, recordID: recordID)
        record["content"] = memory.content as CKRecordValue
        record["kind"] = memory.kind.rawValue as CKRecordValue
        record["source"] = memory.source.rawValue as CKRecordValue
        record["createdAt"] = memory.createdAt as CKRecordValue
        record["updatedAt"] = memory.updatedAt as CKRecordValue
        if let confidence = memory.confidence { record["confidence"] = confidence as CKRecordValue }
        if let profileID = memory.profileID { record["profileID"] = profileID.uuidString as CKRecordValue }
        if let origin = memory.originDeviceName { record["originDeviceName"] = origin as CKRecordValue }
        if let sourceMessageID = memory.createdFromMessageID { record["createdFromMessageID"] = sourceMessageID.uuidString as CKRecordValue }
        return record
    }

    private static func thread(from record: CKRecord) -> ChatThread? {
        guard let (_, id) = parse(record.recordID) else { return nil }
        guard let title = record["title"] as? String,
            let messagesJSON = record["messagesJSON"] as? String,
            let createdAt = record["createdAt"] as? Date,
            let updatedAt = record["updatedAt"] as? Date,
            let messages = try? JSONDecoder.anvil.decode([ChatMessage].self, from: Data(messagesJSON.utf8))
        else { return nil }
        let profileID = (record["profileID"] as? String).flatMap(UUID.init(uuidString:))
        let originDeviceName = record["originDeviceName"] as? String
        return ChatThread(
            id: id, title: title, messages: messages, createdAt: createdAt, updatedAt: updatedAt,
            profileID: profileID, originDeviceName: originDeviceName)
    }

    private static func profile(from record: CKRecord) -> ChatProfile? {
        guard let (_, id) = parse(record.recordID) else { return nil }
        guard let name = record["name"] as? String,
            let prompt = record["prompt"] as? String,
            let createdAt = record["createdAt"] as? Date
        else { return nil }
        return ChatProfile(
            id: id, name: name, prompt: prompt,
            defaultForModelID: record["defaultForModelID"] as? String, createdAt: createdAt,
            originDeviceName: record["originDeviceName"] as? String)
    }

    private static func memory(from record: CKRecord) -> ChatMemory? {
        guard let (_, id) = parse(record.recordID) else { return nil }
        guard let content = record["content"] as? String,
            let kindRaw = record["kind"] as? String, let kind = ChatMemoryKind(rawValue: kindRaw),
            let sourceRaw = record["source"] as? String, let source = ChatMemorySource(rawValue: sourceRaw),
            let createdAt = record["createdAt"] as? Date,
            let updatedAt = record["updatedAt"] as? Date
        else { return nil }
        let profileID = (record["profileID"] as? String).flatMap(UUID.init(uuidString:))
        let createdFromMessageID = (record["createdFromMessageID"] as? String).flatMap(UUID.init(uuidString:))
        return ChatMemory(
            id: id, content: content, kind: kind, source: source,
            confidence: record["confidence"] as? Double, profileID: profileID,
            createdAt: createdAt, updatedAt: updatedAt,
            originDeviceName: record["originDeviceName"] as? String, createdFromMessageID: createdFromMessageID)
    }

    // MARK: - Applying remote changes locally

    /// Last-write-wins by `updatedAt`, same rule the local-network merge
    /// already uses — a genuinely-conflicting edit from two devices is
    /// rare enough for a single-user store that a second, different
    /// policy here isn't worth the inconsistency.
    private func applyRemote(_ record: CKRecord) async {
        switch record.recordType {
        case RecordKind.thread.rawValue:
            guard let remote = Self.thread(from: record) else { return }
            if let local = await threadStore.get(id: remote.id), local.updatedAt >= remote.updatedAt { return }
            _ = try? await threadStore.upsert(remote)
        case RecordKind.profile.rawValue:
            guard let remote = Self.profile(from: record) else { return }
            _ = try? await profileStore.upsert(remote)
        case RecordKind.memory.rawValue:
            guard let remote = Self.memory(from: record) else { return }
            let localAll = await memoryStore.all()
            if let local = localAll.first(where: { $0.id == remote.id }), local.updatedAt >= remote.updatedAt { return }
            _ = try? await memoryStore.upsert(remote)
        default:
            break
        }
    }

    private func applyRemoteDeletion(_ recordID: CKRecord.ID) async {
        guard let (kind, id) = Self.parse(recordID) else { return }
        switch kind {
        case .thread: try? await threadStore.delete(id: id)
        case .profile: try? await profileStore.delete(id: id)
        case .memory: try? await memoryStore.delete(id: id)
        }
    }

    // MARK: - Delegate

    /// A plain class (not the actor itself) because `CKSyncEngineDelegate`
    /// requires `AnyObject` — holds only a weak-ish handle back via
    /// `unowned`, safe because `CloudSyncEngine` owns this instance's
    /// only strong reference and clears it in `stop()`.
    private final class EngineDelegate: CKSyncEngineDelegate, Sendable {
        unowned let owner: CloudSyncEngine
        init(owner: CloudSyncEngine) { self.owner = owner }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            switch event {
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications {
                    await owner.applyRemote(modification.record)
                }
                for deletion in changes.deletions {
                    await owner.applyRemoteDeletion(deletion.recordID)
                }
            case .sentRecordZoneChanges(let changes):
                // A genuine conflict: retry with the server's own
                // current record queued instead — same last-write-wins
                // rule `applyRemote` already enforces, just entered via
                // the "my save was rejected" path instead of "I fetched
                // something newer."
                for failure in changes.failedRecordSaves {
                    guard failure.error.code == .serverRecordChanged, let serverRecord = failure.error.serverRecord
                    else { continue }
                    await owner.applyRemote(serverRecord)
                }
            default:
                break
            }
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            let scope = context.options.scope
            let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
            guard !changes.isEmpty else { return nil }
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
                await self.owner.record(for: recordID)
            }
        }
    }
}
