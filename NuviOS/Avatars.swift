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
    /// Supporter-only artwork, from `get_member_profile_avatar_catalog`.
    /// Not part of the RPC payload — set when the member catalog is merged in.
    var memberOnly: Bool = false

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
        memberOnly = false
    }

    /// The publicly-fetchable URL this avatar should be stored as on a
    /// profile, or `nil` when it resolves through the catalog by id instead.
    /// Only supporter artwork hosted at an absolute URL syncs this way.
    var syncableImageURL: String? {
        guard storagePath.hasPrefix("http://") || storagePath.hasPrefix("https://") else { return nil }
        return storagePath
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

/// Reads the supporter avatar catalog.
///
/// Unlike the public catalog this RPC is row-level-secured, so it needs the
/// account's JWT and returns nothing for a non-supporter.
///
/// Upstream also serves supporter artwork out of a private bucket, which it
/// downloads and caches per device. Those rows are skipped here: a device-local
/// file can't be stored on the profile as `avatar_url`, so only artwork hosted
/// at an absolute URL is offered.
struct MemberAvatarCatalogClient {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    func fetch(accessToken: String) async throws -> [AvatarCatalogItem] {
        var base = configuration.backendURL
        while base.hasSuffix("/") { base.removeLast() }

        var request = URLRequest(
            url: URL(string: "\(base)/rest/v1/rpc/get_member_profile_avatar_catalog")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try JSONDecoder().decode([AvatarCatalogItem].self, from: data)
            .filter { $0.syncableImageURL != nil }
            .map { item in
                var flagged = item
                flagged.memberOnly = true
                return flagged
            }
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
    private static let memberItemsKey = "nuvio.avatars.catalog.member"

    /// The category tab supporter artwork is filed under, matching Android.
    static let supporterCategory = "supporter"

    @Published private(set) var items: [AvatarCatalogItem] = []
    /// Supporter artwork, kept apart so it can be dropped the moment an
    /// account stops being one without refetching the public catalog.
    @Published private(set) var memberItems: [AvatarCatalogItem] = []
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
        if let data = defaults.data(forKey: Self.memberItemsKey),
           let cached = try? JSONDecoder().decode([AvatarCatalogItem].self, from: data) {
            self.memberItems = cached
        }
    }

    /// Everything the picker may show: the public catalog plus whatever
    /// supporter artwork the account has unlocked.
    var allItems: [AvatarCatalogItem] { items + memberItems }

    /// The categories to offer as filter tabs, in Android's order: the pinned
    /// ones it knows about first, then whatever else the backend sent.
    private static let pinnedCategories = ["anime", "animation", "tv", "movie", "gaming"]

    var categories: [String] {
        // Supporter artwork ships in packs of its own ("One Piece", "Marvel",
        // ...), so those become tabs too rather than collapsing into a single
        // "supporter" grid.
        let present = allItems
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
        let supporter = memberItems.isEmpty ? [] : [Self.supporterCategory]
        return supporter + ordered + rest
    }

    func items(in category: String?) -> [AvatarCatalogItem] {
        guard let category else { return allItems }
        if category.caseInsensitiveCompare(Self.supporterCategory) == .orderedSame {
            return memberItems
        }
        return allItems.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
    }

    func item(id: String?) -> AvatarCatalogItem? {
        guard let id else { return nil }
        return allItems.first { $0.id == id }
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
            setMemberItems([])
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

    /// Loads supporter artwork for an account that has unlocked it, and clears
    /// it for one that hasn't — a lapsed supporter stops being offered the
    /// avatars, though any already saved to a profile keeps rendering from its
    /// stored URL.
    func loadMemberAvatars(
        configuration: ServerConfiguration?,
        accessToken: String?,
        hasAccess: Bool
    ) async {
        guard hasAccess, let configuration, let accessToken else {
            setMemberItems([])
            return
        }
        guard let fetched = try? await MemberAvatarCatalogClient(configuration: configuration)
            .fetch(accessToken: accessToken)
        else { return }
        setMemberItems(fetched)
    }

    private func setMemberItems(_ value: [AvatarCatalogItem]) {
        guard value != memberItems else { return }
        memberItems = value
        if value.isEmpty {
            defaults.removeObject(forKey: Self.memberItemsKey)
        } else if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.memberItemsKey)
        }
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
