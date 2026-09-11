import Foundation
import Testing
@testable import AnvilCore

@Suite("GenerationSettings")
struct GenerationSettingsTests {
    @Test
    func defaultsToUnlimitedUnlessExplicitlySet() {
        // A real reported bug: the old fixed default (1024) let a
        // reasoning model burn its whole budget on thinking and get cut
        // off before ever answering. Unless the user types a number,
        // `maxTokens` stays nil and the wire value is a large sentinel —
        // the model's own stopping point (or the hardware) is the only
        // real limit, not an app-imposed cap.
        #expect(GenerationSettings.default.maxTokens == nil)
        #expect(GenerationSettings.default.wireMaxTokens == GenerationSettings.effectivelyUnlimited)
    }

    @Test
    func anExplicitLimitIsSentAsIs() {
        var settings = GenerationSettings.default
        settings.maxTokens = 256
        #expect(settings.wireMaxTokens == 256)
    }
}
