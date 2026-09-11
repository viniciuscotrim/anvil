import Foundation
import Security

/// Stores the user's Hugging Face access token in the macOS keychain —
/// unlike everything `AppSettings` holds, this is a real credential
/// (read/write access to the user's gated and private repos on
/// huggingface.co), so it doesn't belong in a plain JSON file on disk.
public enum HFTokenStore {
    private static let service = "com.viniciuscotrim.anvil.huggingface-token"
    private static let account = "default"

    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
