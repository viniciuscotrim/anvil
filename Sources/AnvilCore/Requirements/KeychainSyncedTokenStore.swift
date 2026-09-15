import Foundation
import Security

/// Shared implementation behind `HFTokenStore`/`CivitAITokenStore` —
/// same keychain access pattern, differing only in which `service`
/// string names the credential. See `HFTokenStore`'s own header
/// comment for the full rationale (why keychain sync rather than
/// `CloudSyncEngine`'s private database, why a *shared* access group is
/// required across Mac's and iOS's different bundle identifiers, and
/// why `keychain-access-groups` specifically is required just to write
/// a `kSecAttrSynchronizable` item at all).
enum KeychainSyncedTokenStore {
    private static let account = "default"

    /// Checks, in order: the current shared+synced item; the same
    /// shared group without the sync flag (a transient state that
    /// shouldn't really persist, but cheap to also cover); and finally
    /// a token saved by a pre-sync version of Anvil, which used no
    /// explicit access group and no sync at all. Any fallback hit is
    /// migrated forward immediately via `save`, so the fallback only
    /// ever needs to run once per device.
    static func load(service: String, accessGroup: String) -> String? {
        if let value = query(service: service, accessGroup: accessGroup, synchronizable: true, sharedGroup: true) {
            return value
        }
        if let value = query(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: true) {
            save(value, service: service, accessGroup: accessGroup)
            return value
        }
        guard let legacy = query(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: false)
        else { return nil }
        save(legacy, service: service, accessGroup: accessGroup)
        return legacy
    }

    /// An empty or all-whitespace token clears the stored one instead
    /// of saving blank text — the natural way to "log out".
    static func save(_ token: String, service: String, accessGroup: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear(service: service, accessGroup: accessGroup)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes = baseAttributes(service: service, accessGroup: accessGroup, synchronizable: true, sharedGroup: true)
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
        // drift out of sync and `load` never needs its migration
        // fallbacks again on this device.
        deleteItem(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: true)
        deleteItem(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: false)
    }

    static func clear(service: String, accessGroup: String) {
        deleteItem(service: service, accessGroup: accessGroup, synchronizable: true, sharedGroup: true)
        deleteItem(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: true)
        deleteItem(service: service, accessGroup: accessGroup, synchronizable: false, sharedGroup: false)
    }

    private static func query(service: String, accessGroup: String, synchronizable: Bool, sharedGroup: Bool) -> String? {
        var query = baseAttributes(service: service, accessGroup: accessGroup, synchronizable: synchronizable, sharedGroup: sharedGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteItem(service: String, accessGroup: String, synchronizable: Bool, sharedGroup: Bool) {
        SecItemDelete(
            baseAttributes(service: service, accessGroup: accessGroup, synchronizable: synchronizable, sharedGroup: sharedGroup)
                as CFDictionary
        )
    }

    /// `sharedGroup: false` deliberately omits `kSecAttrAccessGroup`
    /// entirely rather than passing some other value — that's the
    /// exact shape a pre-sync save used (the app's own implicit default
    /// group), which is what the legacy-migration lookup in `load`
    /// needs to match.
    private static func baseAttributes(service: String, accessGroup: String, synchronizable: Bool, sharedGroup: Bool) -> [String: Any] {
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
