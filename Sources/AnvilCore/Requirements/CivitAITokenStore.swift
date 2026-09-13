import Foundation
import Security

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
public enum CivitAITokenStore {
    private static let service = "com.viniciuscotrim.anvil.civitai-token"
    private static let account = "default"
    private static let accessGroup = "U3H5DHZP65.com.viniciuscotrim.anvil.credentials"

    /// Checks, in order: the current shared+synced item; the same
    /// shared group without the sync flag (a transient state that
    /// shouldn't really persist, but cheap to also cover); and finally
    /// a token saved by a pre-this-feature version of Anvil, which
    /// used no explicit access group and no sync at all. Any fallback
    /// hit is migrated forward immediately via `save`, so the fallback
    /// only ever needs to run once per device.
    public static func load() -> String? {
        if let value = query(synchronizable: true, sharedGroup: true) {
            return value
        }
        if let value = query(synchronizable: false, sharedGroup: true) {
            save(value)
            return value
        }
        guard let legacy = query(synchronizable: false, sharedGroup: false) else { return nil }
        save(legacy)
        return legacy
    }

    private static func query(synchronizable: Bool, sharedGroup: Bool) -> String? {
        var query = baseAttributes(synchronizable: synchronizable, sharedGroup: sharedGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }
        let data = Data(trimmed.utf8)
        let attributes = baseAttributes(synchronizable: true, sharedGroup: true)
        if SecItemCopyMatching(attributes as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var newItem = attributes
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
        // A device that saves after upgrading from an older version of
        // Anvil may still have a pre-sync or pre-shared-group copy
        // sitting alongside the new one — remove those so they can't
        // drift out of sync and `load()` never needs its migration
        // fallbacks again on this device.
        deleteItem(synchronizable: false, sharedGroup: true)
        deleteItem(synchronizable: false, sharedGroup: false)
    }

    public static func clear() {
        deleteItem(synchronizable: true, sharedGroup: true)
        deleteItem(synchronizable: false, sharedGroup: true)
        deleteItem(synchronizable: false, sharedGroup: false)
    }

    private static func deleteItem(synchronizable: Bool, sharedGroup: Bool) {
        SecItemDelete(baseAttributes(synchronizable: synchronizable, sharedGroup: sharedGroup) as CFDictionary)
    }

    /// `sharedGroup: false` deliberately omits `kSecAttrAccessGroup`
    /// entirely rather than passing some other value — that's the
    /// exact shape a pre-this-feature save used (the app's own
    /// implicit default group), which is what the legacy-migration
    /// lookup in `load()` needs to match.
    private static func baseAttributes(synchronizable: Bool, sharedGroup: Bool) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable
        ]
        if sharedGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        return attributes
    }
}
