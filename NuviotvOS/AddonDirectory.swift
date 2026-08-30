import Foundation

/// Where the home screen's rows come from. A signed-in user's addons live in
/// the backend's `addons` table (the same rows Android's AddonSyncService
/// reads); guests and unreachable backends fall back to the defaults Android
/// ships with.
enum AddonDirectory {
    /// Android's `AddonPreferences.getDefaultAddons()`. OpenSubtitles serves
    /// subtitles only, so it contributes no catalogs and is left out here.
    static let defaultAddonURLs = ["https://v3-cinemeta.strem.io"]

    /// Addon rows are profile-scoped. Callers pass the profile whose list to
    /// read — see `Profile.effectiveAddonProfileID`, which redirects a profile
    /// that borrows the primary's addons back to profile 1.
    static let primaryProfileID = Profile.primaryIndex

    private struct Row: Decodable {
        let url: String
        let name: String?
        let enabled: Bool
        let sortOrder: Int

        enum CodingKeys: String, CodingKey {
            case url, name, enabled
            case sortOrder = "sort_order"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        }
    }

    /// Reads the user's enabled addons, in their chosen order. Returns the
    /// defaults when the account has none so the home screen is never empty.
    static func addons(
        configuration: ServerConfiguration,
        userID: String,
        accessToken: String,
        profileID: Int = Profile.primaryIndex,
        session: URLSession = .shared
    ) async throws -> [String] {
        var backend = configuration.backendURL
        while backend.hasSuffix("/") { backend.removeLast() }

        var components = URLComponents(string: "\(backend)/rest/v1/addons")
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "profile_id", value: "eq.\(profileID)"),
            URLQueryItem(name: "order", value: "sort_order.asc")
        ]
        guard let url = components?.url else { return defaultAddonURLs }

        var request = URLRequest(url: url)
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let rows = try JSONDecoder().decode([Row].self, from: data)
        let urls = rows
            .filter(\.enabled)
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { AddonClient.canonicalize($0.url) }

        return urls.isEmpty ? defaultAddonURLs : deduplicated(urls)
    }

    private static func deduplicated(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.lowercased()).inserted }
    }
}
