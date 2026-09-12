import AnvilCore
import Foundation

/// Hugging Face/CivitAI credentials — same `HFTokenStore`/
/// `CivitAITokenStore` (Keychain-backed, cross-platform, no
/// macOS-specific API involved) the Mac app's Model Manager already
/// uses; there was simply no Settings screen on iOS to reach them from
/// before this.
@Observable @MainActor
final class SettingsViewModel {
    var hasStoredHFToken = false
    var hfTokenDraft = ""
    var hasStoredCivitAIToken = false
    var civitaiTokenDraft = ""

    func load() {
        hasStoredHFToken = HFTokenStore.load() != nil
        hasStoredCivitAIToken = CivitAITokenStore.load() != nil
    }

    func saveHFToken() {
        HFTokenStore.save(hfTokenDraft)
        hfTokenDraft = ""
        hasStoredHFToken = HFTokenStore.load() != nil
    }

    func clearHFToken() {
        HFTokenStore.clear()
        hasStoredHFToken = false
    }

    func saveCivitAIToken() {
        CivitAITokenStore.save(civitaiTokenDraft)
        civitaiTokenDraft = ""
        hasStoredCivitAIToken = CivitAITokenStore.load() != nil
    }

    func clearCivitAIToken() {
        CivitAITokenStore.clear()
        hasStoredCivitAIToken = false
    }
}
