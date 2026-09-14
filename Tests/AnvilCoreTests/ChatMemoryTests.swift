import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatMemory")
struct ChatMemoryTests {
    @Test
    func roundTripsAuditFields() throws {
        let profileID = UUID()
        let memory = ChatMemory(
            content: "Prefers concise answers",
            kind: .preference,
            source: .inferred,
            confidence: 0.75,
            profileID: profileID
        )
        let data = try JSONEncoder.anvil.encode(memory)
        let decoded = try JSONDecoder.anvil.decode(ChatMemory.self, from: data)

        #expect(decoded.id == memory.id)
        #expect(decoded.content == memory.content)
        #expect(decoded.kind == memory.kind)
        #expect(decoded.source == memory.source)
        #expect(decoded.confidence == memory.confidence)
        #expect(decoded.profileID == profileID)
    }

    @Test
    func legacyMemoryDefaultsToExplicitFact() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","content":"Likes Swift","createdAt":"2026-09-12T12:00:00.000Z","updatedAt":"2026-09-12T12:00:00.000Z"}"#.utf8)
        let decoded = try JSONDecoder.anvil.decode(ChatMemory.self, from: data)

        #expect(decoded.kind == .fact)
        #expect(decoded.source == .explicit)
        #expect(decoded.confidence == nil)
        #expect(decoded.profileID == nil)
    }

    @Test
    func legacyMemoryWithNoThreadFieldsAtAllAppliesEverywhere() throws {
        // The exact shape a memory saved before thread-scoping existed
        // has — no originThreadID, no isGlobal key at all.
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","content":"Likes Swift","createdAt":"2026-09-12T12:00:00.000Z","updatedAt":"2026-09-12T12:00:00.000Z"}"#.utf8)
        let decoded = try JSONDecoder.anvil.decode(ChatMemory.self, from: data)

        #expect(decoded.isGlobal == true)
        #expect(decoded.originThreadID == nil)
        #expect(decoded.appliesTo(threadID: UUID()))
    }

    @Test
    func threadScopedMemoryOnlyAppliesToItsOwnThread() {
        let originThreadID = UUID()
        let memory = ChatMemory(content: "Only in this thread", originThreadID: originThreadID, isGlobal: false)

        #expect(memory.appliesTo(threadID: originThreadID))
        #expect(!memory.appliesTo(threadID: UUID()))
    }

    @Test
    func globalMemoryAppliesToEveryThreadRegardlessOfItsOrigin() {
        let originThreadID = UUID()
        let memory = ChatMemory(content: "Follows me everywhere", originThreadID: originThreadID, isGlobal: true)

        #expect(memory.appliesTo(threadID: originThreadID))
        #expect(memory.appliesTo(threadID: UUID()))
    }

    @Test
    func aMemoryWithNoOriginAppliesEverywhereEvenIfMarkedNotGlobal() {
        // Nothing left to restrict it back down to — see
        // `ChatMemory.appliesTo`'s own doc comment.
        let memory = ChatMemory(content: "No recorded origin", originThreadID: nil, isGlobal: false)

        #expect(memory.appliesTo(threadID: UUID()))
    }

    @Test
    func threadScopingRoundTripsThroughEncoding() throws {
        let originThreadID = UUID()
        let memory = ChatMemory(content: "Scoped fact", originThreadID: originThreadID, isGlobal: false)
        let data = try JSONEncoder.anvil.encode(memory)
        let decoded = try JSONDecoder.anvil.decode(ChatMemory.self, from: data)

        #expect(decoded.originThreadID == originThreadID)
        #expect(decoded.isGlobal == false)
    }
}
