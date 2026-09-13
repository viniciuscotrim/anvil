import Foundation
import Security

/// Stores the user's Hugging Face access token in the keychain, synced
/// via iCloud Keychain (`kSecAttrSynchronizable`) under a shared
/// keychain access group (`accessGroup`) common to both the Mac and
/// iOS targets — unlike everything `AppSettings` holds, this is a real
/// credential (read/write access to the user's gated and private
/// repos on huggingface.co), so it doesn't belong in a plain JSON file
/// on disk, and unlike `CloudSyncEngine`'s own private-database sync
/// (threads/profiles/memories), a real secret like this belongs in the
/// keychain's own end-to-end-encrypted sync rather than a CKRecord
/// field. Requested live: "vamos criar os campos onde as Keys do Huggs
/// e do Civitai ficam armazenadas e sincronizadas o iCloud assim não
/// preciso recadastrar elas depois de feito em um dos dois devices" —
/// set once on either Mac or iPhone, the same signed-in iCloud
/// account's Keychain carries it to the other, independent of (and not
/// gated behind) the app's own `isCloudSyncEnabled` toggle: this isn't
/// conversation data, and requiring that toggle first would just be
/// one more thing to remember to turn on.
///
/// The shared access group matters because Mac and iOS are two
/// different bundle identifiers (`com.viniciuscotrim.anvil` vs
/// `.anvil.ios`), which would otherwise each get their own separate
/// *default* keychain group — same iCloud account, but two unrelated
/// items that would each sync only among that one app's own installs,
/// never with each other. `accessGroup` (declared in both targets'
/// `.entitlements` under `keychain-access-groups`) makes both platforms
/// read and write the exact same underlying item.
///
/// Writing a `kSecAttrSynchronizable` item at all requires that
/// `keychain-access-groups` entitlement to be present (confirmed
/// directly: without it, `SecItemAdd` fails with
/// `errSecMissingEntitlement`/-34018) — plain, non-synced keychain
/// items don't have this requirement, which is exactly why this went
/// unnoticed before sync was ever attempted. Also requires each
/// device's own system-wide "iCloud Keychain" setting to be on (it is
/// by default for most users) — outside this app's control, same as
/// any other app relying on this exact same, standard Apple mechanism.
public enum HFTokenStore {
    private static let service = "com.viniciuscotrim.anvil.huggingface-token"
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

    /// An empty or all-whitespace token clears the stored one instead
    /// of saving blank text — the natural way to "log out".
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
