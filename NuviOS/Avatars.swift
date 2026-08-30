import SwiftUI
import Combine

// MARK: - Model

/// One avatar the backend offers. Mirrors Android's `AvatarCatalogItem`,
/// which is decoded from the `get_avatar_catalog` RPC.
///
/// A profile stores only the avatar's `id`; the picture is resolved through
/// this catalog, so an avatar picked on Android shows the same face here.
struct AvatarCatalogItem: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let storagePath: String
    let category: String
    let sortOrder: Int
    /// The colour the backend pairs with this artwork. Upstream stores it on
    /// the profile as `avatar_color_hex` when the avatar is chosen, so the
    /// ring and any fallback initial match the picture.
    let bgColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case storagePath = "storage_path"
        case category
        case sortOrder = "sort_order"
        case bgColor = "bg_color"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        storagePath = try c.decodeIfPresent(String.self, forKey: .storagePath) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        bgColor = try c.decodeIfPresent(String.self, forKey: .bgColor)
    }

    /// Public storage URL for this avatar. Android builds the same string from
    /// `avatarPublicBaseUrl`, which discovery sets to
    /// `<backend>/storage/v1/object/public/avatars`.
    func imageURL(backendURL: String) -> URL? {
        if storagePath.hasPrefix("http://") || storagePath.hasPrefix("https://") {
            return URL(string: storagePath)
        }
        var base = backendURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/storage/v1/object/public/avatars/\(storagePath)")
    }
}

// MARK: - Remote

/// Reads the avatar catalog over PostgREST.
///
/// Unlike the profile RPCs this one is readable with the publishable key
/// alone, so guests and the "who's watching" screen can show real faces
/// before anybody signs in.
struct AvatarCatalogClient {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    func fetch() async throws -> [AvatarCatalogItem] {
        var base = configuration.backendURL
        while base.hasSuffix("/") { base.removeLast() }

        var request = URLRequest(url: URL(string: "\(base)/rest/v1/rpc/get_avatar_catalog")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(configuration.publishableKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode([AvatarCatalogItem].self, from: data)
            .filter { !$0.storagePath.isEmpty }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - Store

/// The avatar catalog, cached across launches.
///
/// A singleton rather than an injected object: `ProfileAvatar` is drawn in
/// sheets and full-screen covers that don't inherit the shell's environment,
/// and a missing `@EnvironmentObject` is a crash rather than a blank face.
@MainActor
final class AvatarCatalog: ObservableObject {
    static let shared = AvatarCatalog()

    /// Android's `AvatarCatalogRefreshIntervalMs`.
    private static let refreshInterval: TimeInterval = 15 * 60
    private static let itemsKey = "nuvio.avatars.catalog"
    private static let fetchedKey = "nuvio.avatars.fetchedAt"
    private static let backendKey = "nuvio.avatars.backend"

    @Published private(set) var items: [AvatarCatalogItem] = []
    @Published private(set) var isLoading = false

    private let defaults: UserDefaults
    private var backendURL: String?
    private var fetchedAt: Date?
    private var inFlight: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURL = defaults.string(forKey: Self.backendKey)
        self.fetchedAt = defaults.object(forKey: Self.fetchedKey) as? Date
        if let data = defaults.data(forKey: Self.itemsKey),
           let cached = try? JSONDecoder().decode([AvatarCatalogItem].self, from: data) {
            self.items = cached
        }
    }

    /// The categories to offer as filter tabs, in Android's order: the pinned
    /// ones it knows about first, then whatever else the backend sent.
    private static let pinnedCategories = ["anime", "animation", "tv", "movie", "gaming"]

    var categories: [String] {
        let present = items
            .map { $0.category.trimmed }
            .filter { !$0.isEmpty }
        var ordered: [String] = []
        for pinned in Self.pinnedCategories
        where present.contains(where: { $0.caseInsensitiveCompare(pinned) == .orderedSame }) {
            ordered.append(pinned)
        }
        let rest = Set(present.map { $0.lowercased() })
            .subtracting(ordered.map { $0.lowercased() })
            .sorted()
        return ordered + rest
    }

    func items(in category: String?) -> [AvatarCatalogItem] {
        guard let category else { return items }
        return items.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
    }

    func item(id: String?) -> AvatarCatalogItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// The picture for a profile: its stored `avatarURL` if the account set an
    /// explicit one, otherwise the catalog entry its `avatarID` names.
    func imageURL(for profile: Profile) -> URL? {
        if let explicit = profile.avatarURL?.trimmed, !explicit.isEmpty,
           let url = URL(string: explicit) {
            return url
        }
        guard let backendURL else { return nil }
        return item(id: profile.avatarID)?.imageURL(backendURL: backendURL)
    }

    func imageURL(for item: AvatarCatalogItem) -> URL? {
        guard let backendURL else { return nil }
        return item.imageURL(backendURL: backendURL)
    }

    /// Fetches once, then at most every 15 minutes — the cached list is shown
    /// immediately so avatars never pop in on a warm launch.
    func load(configuration: ServerConfiguration?) {
        guard let configuration else { return }

        // A different backend has a different catalog; drop the old one.
        if backendURL != configuration.backendURL {
            items = []
            fetchedAt = nil
            backendURL = configuration.backendURL
            defaults.set(configuration.backendURL, forKey: Self.backendKey)
        }

        guard isRefreshDue else { return }
        guard inFlight == nil else { return }

        inFlight = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.inFlight = nil } }
            await self?.fetch(configuration: configuration)
        }
    }

    private var isRefreshDue: Bool {
        guard let fetchedAt, !items.isEmpty else { return true }
        let elapsed = Date().timeIntervalSince(fetchedAt)
        return elapsed < 0 || elapsed >= Self.refreshInterval
    }

    private func fetch(configuration: ServerConfiguration) async {
        isLoading = items.isEmpty
        defer { isLoading = false }

        guard let fetched = try? await AvatarCatalogClient(configuration: configuration).fetch(),
              !fetched.isEmpty
        else { return }

        items = fetched
        fetchedAt = Date()
        defaults.set(fetchedAt, forKey: Self.fetchedKey)
        if let data = try? JSONEncoder().encode(fetched) {
            defaults.set(data, forKey: Self.itemsKey)
        }
    }
}
