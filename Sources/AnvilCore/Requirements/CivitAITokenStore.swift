import Foundation

/// Stores the user's CivitAI API key in the keychain, synced via
/// iCloud Keychain under a shared keychain access group — same
/// pattern and same reasoning as `HFTokenStore`, see its own header
/// comment for the full rationale (why keychain sync rather than
/// `CloudSyncEngine`'s private database, why a *shared* access group
/// is required across Mac's and iOS's different bundle identifiers,
/// and why `keychain-access-groups` specifically is required just to
/// write a `kSecAttrSynchronizable` item at all). Most public CivitAI
/// models download fine without one, but some (NSFW-gated, or
/// creator-restricted) need it, and it raises rate limits either way.
///
/// The actual keychain access lives in `KeychainSyncedTokenStore`,
/// shared with `HFTokenStore` — this type just names which credential.
public enum CivitAITokenStore {
    private static let service = "com.viniciuscotrim.anvil.civitai-token"
    private static let accessGroup = "U3H5DHZP65.com.viniciuscotrim.anvil.credentials"

    public static func load() -> String? {
        KeychainSyncedTokenStore.load(service: service, accessGroup: accessGroup)
    }

    public static func save(_ token: String) {
        KeychainSyncedTokenStore.save(token, service: service, accessGroup: accessGroup)
    }

    public static func clear() {
        KeychainSyncedTokenStore.clear(service: service, accessGroup: accessGroup)
    }
}
