import Foundation
import Security

/// Keychain storage for the paired puck.
///
/// The tag's identifier is the app's only authentication factor, so it belongs here rather
/// than in `UserDefaults` — not because a UID is a secret (it is trivially cloneable off
/// the tag itself), but because a plist that any file-level backup or debugging tool can
/// read is the wrong home for the one value that decides whether the alarm stops.
///
/// Shared between the app and the widget extension; only the app ever calls it.
enum PuckKeychain {
    private static let service = "com.bordencea.PuckAlarm.puck"
    private static let account = "paired-puck"

    static func save(_ puck: PairedPuck) {
        guard let data = try? JSONEncoder().encode(puck) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The alarm can fire before the first unlock after a reboot, and the scan has
            // to work then. `AfterFirstUnlock` is the strictest class that still allows it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func load() -> PairedPuck? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return try? JSONDecoder().decode(PairedPuck.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
