import Foundation

/// The debrid keys on the account, kept where a resolve can reach them.
///
/// The keys are not entered on this device and are not stored by it. The
/// Android client already syncs them into the user's account — one row per
/// service, filed as `debrid:realdebrid` / `debrid:torbox` with an `api_key`
/// inside — and this reads the same rows back through the same RPC that client
/// pushes them with. So a viewer who set Real-Debrid up on their TV finds it
/// already working on their iPad, with nothing to type in twice.
///
/// Held in memory only, for the life of the process: a key that is never
/// written to disk is one that cannot be read off it, and re-reading costs one
/// request at sign-in.
actor DebridCredentials {
    static let shared = DebridCredentials()

    private var keys: [DebridService: String] = [:]
    private var loadedIdentity: String?

    /// The key for one service, or nil when the account has none.
    func key(for service: DebridService) -> String? {
        keys[service]?.nilWhenEmpty
    }

    /// Whether any service is set up, which is what decides if a resolvable
    /// row is worth showing in the picker.
    var hasAnyKey: Bool { keys.values.contains { !$0.isEmpty } }

    /// Reads the account's credentials for one profile.
    ///
    /// Re-reads only when the account or profile changed, so this can be
    /// attached to the same lifecycle that reloads addons without asking the
    /// backend on every appearance.
    func load(
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        identity: String,
        force: Bool = false,
        session: URLSession = .shared
    ) async {
        guard force || loadedIdentity != identity else { return }
        loadedIdentity = identity

        var backend = configuration.backendURL
        while backend.hasSuffix("/") { backend.removeLast() }
        guard let url = URL(string: "\(backend)/rest/v1/rpc/sync_pull_provider_credentials") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["p_profile_id": profileID])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // A backend that can't answer leaves whatever was already read
                // in place; a failed read is not evidence the keys are gone.
                loadedIdentity = nil
                return
            }
            let decoder = JSONDecoder()
            // A set-returning RPC answers with an array, but a backend that
            // wraps it in a single object shouldn't cost the viewer their keys.
            let rows = (try? decoder.decode([Row].self, from: data))
                ?? (try? decoder.decode(Row.self, from: data)).map { [$0] }
                ?? []
            keys = Self.parse(rows: rows)
        } catch {
            loadedIdentity = nil
        }
    }

    /// Drops everything on sign-out.
    func clear() {
        keys = [:]
        loadedIdentity = nil
    }

    private struct Row: Decodable {
        let provider: String
        let credentialJSON: [String: String]

        enum CodingKeys: String, CodingKey {
            case provider
            case credentialJSON = "credential_json"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = try c.decode(String.self, forKey: .provider)
            // The column holds whatever each provider needs — an api key here,
            // a client id for others — so anything non-string is skipped
            // rather than failing the whole read.
            let raw = try c.decodeIfPresent([String: AnyCodableString].self, forKey: .credentialJSON) ?? [:]
            credentialJSON = raw.compactMapValues(\.value)
        }
    }

    /// Decodes a JSON value only when it is a string, since that is the only
    /// shape a key comes in.
    private struct AnyCodableString: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private static func parse(rows: [Row]) -> [DebridService: String] {
        var keys: [DebridService: String] = [:]
        for service in DebridService.allCases {
            let row = rows.first { $0.provider.lowercased() == service.credentialProvider }
            if let key = row?.credentialJSON["api_key"]?.trimmed, !key.isEmpty {
                keys[service] = key
            }
        }
        return keys
    }
}
