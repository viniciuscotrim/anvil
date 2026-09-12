import Foundation
import Testing
@testable import AnvilCore

@Suite("AppSettings")
struct AppSettingsTests {
    @Test
    func preservesChatMessageWaitSeconds() throws {
        let settings = AppSettings(
            chatMessageWaitSeconds: 12.5,
            chatMaxEstimatedContextTokens: 32_000,
            chatRecentMessageCount: 18
        )
        let data = try JSONEncoder.anvil.encode(settings)
        let decoded = try JSONDecoder.anvil.decode(AppSettings.self, from: data)

        #expect(decoded.chatMessageWaitSeconds == 12.5)
        #expect(decoded.chatMaxEstimatedContextTokens == 32_000)
        #expect(decoded.chatRecentMessageCount == 18)
    }

    @Test
    func oldSettingsDefaultToTenSeconds() throws {
        let data = Data(#"{"modelsRootPath":null}"#.utf8)
        let decoded = try JSONDecoder.anvil.decode(AppSettings.self, from: data)

        #expect(decoded.chatMessageWaitSeconds == 10)
        #expect(decoded.chatMaxEstimatedContextTokens == 24_000)
        #expect(decoded.chatRecentMessageCount == 12)
    }
}
