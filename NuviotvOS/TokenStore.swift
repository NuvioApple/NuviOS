import Foundation
import Security

/// Supabase session tokens as returned by `tv-logins-exchange`.
struct AuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }

    /// Refresh a little early so a request never rides an about-to-die token.
    var needsRefresh: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Keychain-backed persistence for the signed-in session.
enum TokenStore {
    private static let service = "tv.nuvio.unofficial.nuviotvos"
    private static let account = "supabase.session"

    static func load() -> AuthTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    static func save(_ tokens: AuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if targetEnvironment(macCatalyst)
        // Catalyst defaults generic passwords to the old file-based keychain,
        // which a sandboxed app can't reach without a keychain-access-group
        // (it fails with errSecMissingEntitlement). Opting in to the data
        // protection keychain gives the same behaviour as the tvOS/iOS builds.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

/// Stable per-install identifier sent as `p_device_nonce`. Generated once and
/// kept in the keychain so a re-login from the same box reuses it.
enum DeviceNonce {
    private static let key = "device.nonce"

    static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }
}
