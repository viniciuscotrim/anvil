import Foundation

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
///
/// The actual keychain access lives in `KeychainSyncedTokenStore`,
/// shared with `CivitAITokenStore` — this type just names which
/// credential.
public enum HFTokenStore {
    private static let service = "com.viniciuscotrim.anvil.huggingface-token"
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
