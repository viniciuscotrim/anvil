import Testing
@testable import AnvilCore

@Suite("NamedLauncher")
struct NamedLauncherTests {
    @Test
    func prefixesWithAnvilAndKeepsTheDisplayName() {
        #expect(NamedLauncher.sanitize("SmolLM2-135M-Instruct-8bit") == "Anvil - SmolLM2-135M-Instruct-8bit")
    }

    @Test
    func replacesSlashesSoItStaysOneValidFilename() {
        // A raw filesystem path (imported models can have very
        // path-like display names) must never produce nested
        // directories when used as a symlink name.
        #expect(NamedLauncher.sanitize("org/model-name") == "Anvil - org-model-name")
    }

    @Test
    func trimsWhitespaceAndFallsBackForAnEmptyName() {
        #expect(NamedLauncher.sanitize("   ") == "Anvil - model")
        #expect(NamedLauncher.sanitize("  Qwen3  ") == "Anvil - Qwen3")
    }

    @Test
    func truncatesAnExtremelyLongDisplayName() {
        let long = String(repeating: "x", count: 500)
        let sanitized = NamedLauncher.sanitize(long)
        #expect(sanitized.count <= "Anvil - ".count + 64)
    }
}
