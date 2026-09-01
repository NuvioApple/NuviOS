import SwiftUI
import Combine

/// A title the viewer saved to their list.
///
/// Stores its own artwork rather than a reference to a catalog row: the list
/// has to render at launch, before any addon has answered.
struct SavedTitle: Codable, Identifiable, Equatable {
    let itemID: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let releaseInfo: String?
    let imdbRating: String?
    let addonBaseURL: String
    let savedAt: Date
    /// Carried so a title pushed from here comes back off the backend whole.
    /// Optional because lists saved by earlier builds don't have them.
    let description: String?
    let genres: [String]?

    var id: String { "\(type)|\(itemID)" }

    var item: MetaItem {
        MetaItem(
            id: itemID,
            type: type,
            name: name,
            poster: poster,
            background: background,
            logo: logo,
            description: description,
            releaseInfo: releaseInfo,
            imdbRating: imdbRating,
            genres: genres ?? []
        )
    }

    init(item: MetaItem, addonBaseURL: String, savedAt: Date = Date()) {
        self.itemID = item.id
        self.type = item.type
        self.name = item.name
        self.poster = item.poster
        self.background = item.background
        self.logo = item.logo
        self.releaseInfo = item.releaseInfo
        self.imdbRating = item.imdbRating
        self.addonBaseURL = addonBaseURL
        self.savedAt = savedAt
        self.description = item.description
        self.genres = item.genres
    }

    /// Epoch milliseconds, which is how the backend files `added_at`.
    var addedAt: Int64 { Int64(savedAt.timeIntervalSince1970 * 1000) }
}

/// "My List" — Nuvio's Library, per profile.
///
/// The device's copy is what the screens read: the list has to draw at launch,
/// offline, and before any addon or backend has answered. The backend is the
/// account's copy, and the two are reconciled on `sync` — so a title saved on
/// the television is in the list here, and one saved here is there.
///
/// Every profile keeps its own list, on both sides; a shared list would defeat
/// the point of profiles.
@MainActor
final class LibraryStore: ObservableObject {
    private static func key(profile: Int) -> String { "nuvio.library.\(profile)" }

    @Published private(set) var titles: [SavedTitle] = []

    private let defaults: UserDefaults
    private var profileIndex: Int = Profile.primaryIndex
    /// Held so a save made later can be pushed without the screen that made it
    /// having to know anything about the backend.
    private weak var session: AppSession?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the store at a profile's list. Called whenever the active
    /// profile changes, including at launch.
    func activate(profile: Profile) {
        profileIndex = profile.index
        let data = defaults.data(forKey: Self.key(profile: profile.index))
        titles = data.flatMap { try? JSONDecoder().decode([SavedTitle].self, from: $0) } ?? []
    }

    func contains(_ item: MetaItem) -> Bool {
        titles.contains { $0.itemID == item.id && $0.type == item.type }
    }

    func toggle(_ item: MetaItem, addonBaseURL: String) {
        if contains(item) {
            let removed = titles.filter { $0.itemID == item.id && $0.type == item.type }
            titles.removeAll { $0.itemID == item.id && $0.type == item.type }
            persist()
            push(deleting: removed)
        } else {
            // Newest first, the order every streaming app shows a list in.
            let saved = SavedTitle(item: item, addonBaseURL: addonBaseURL)
            titles.insert(saved, at: 0)
            persist()
            push(saving: [saved])
        }
    }

    func remove(_ saved: SavedTitle) {
        titles.removeAll { $0.id == saved.id }
        persist()
        push(deleting: [saved])
    }

    // MARK: Sync

    /// Reconciles this profile's list with the account's.
    ///
    /// Called at launch and whenever the active profile changes. Signed out,
    /// or with no backend configured, it does nothing at all and the list
    /// stays exactly as local as it was.
    func sync(session: AppSession, profile: Profile) async {
        self.session = session
        activate(profile: profile)

        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else { return }

        let syncingProfile = profile.index
        let remote: [SavedTitle]
        do {
            remote = try await LibraryDirectory.pull(
                configuration: configuration,
                accessToken: token,
                profileID: syncingProfile
            )
        } catch {
            print("[library] pull failed: \(error)")
            return
        }

        // The profile can change while a pull is in flight; a list merged into
        // the wrong profile would be worse than one that didn't arrive.
        guard profileIndex == syncingProfile else { return }

        let merged = Self.merge(local: titles, remote: remote)
        let unpushed = merged.filter { local in
            !remote.contains { $0.id == local.id }
        }

        titles = merged
        persist()

        // Anything this device had that the account didn't — saved offline, or
        // saved by a build that couldn't sync — belongs on the account now.
        if !unpushed.isEmpty {
            push(saving: unpushed)
        }
    }

    /// Union, newest first.
    ///
    /// A title on either side stays on both: the alternative is letting one
    /// device's copy silently delete titles the other saved while it was
    /// offline. The cost is that removing a title on one device while another
    /// is offline can be undone by that device's next sync — a title coming
    /// back is a smaller harm than a list quietly losing entries.
    static func merge(local: [SavedTitle], remote: [SavedTitle]) -> [SavedTitle] {
        var byID: [String: SavedTitle] = [:]
        for title in remote + local {
            // Whichever copy was saved first keeps the list's original order;
            // the local copy wins ties because it has artwork the backend
            // doesn't store, such as the logo.
            if let existing = byID[title.id], existing.savedAt <= title.savedAt { continue }
            byID[title.id] = title
        }

        return byID.values.sorted { $0.savedAt > $1.savedAt }
    }

    private func push(saving saved: [SavedTitle]) {
        guard !saved.isEmpty, let session else { return }
        let profile = profileIndex
        Task {
            guard case .signedIn = session.state,
                  let configuration = session.configuration,
                  let token = await session.validAccessToken()
            else { return }

            await LibraryDirectory.push(
                saved,
                configuration: configuration,
                accessToken: token,
                profileID: profile
            )
        }
    }

    private func push(deleting removed: [SavedTitle]) {
        guard !removed.isEmpty, let session else { return }
        let profile = profileIndex
        Task {
            guard case .signedIn = session.state,
                  let configuration = session.configuration,
                  let token = await session.validAccessToken()
            else { return }

            await LibraryDirectory.delete(
                removed,
                configuration: configuration,
                accessToken: token,
                profileID: profile
            )
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        defaults.set(data, forKey: Self.key(profile: profileIndex))
    }
}

// MARK: - The account's copy

/// Nuvio's Library, as the backend keeps it.
///
/// The Android client speaks `sync_pull_library` / `sync_push_library_items` /
/// `sync_delete_library_items`, and this speaks the same three — the same
/// column names, the same profile scoping, the same origin id — so a list is
/// one list whichever app is looking at it.
///
/// The snapshot is all this takes. Android also has a delta feed
/// (`sync_pull_library_delta` and a cursor) for keeping up with changes made
/// elsewhere while it runs; a list of a few hundred titles pulled once per
/// profile switch doesn't need one yet.
enum LibraryDirectory {
    /// Everything this profile has saved, oldest page first.
    static func pull(
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        pageSize: Int = 200,
        session: URLSession = .shared
    ) async throws -> [SavedTitle] {
        var collected: [SavedTitle] = []
        var offset = 0

        while true {
            guard let request = rpc(
                "sync_pull_library",
                body: [
                    "p_profile_id": profileID,
                    "p_limit": pageSize,
                    "p_offset": offset
                ],
                configuration: configuration,
                accessToken: accessToken
            ) else { return collected }

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                print("[library] pull failed: HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(240) ?? "")")
                throw AuthError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }

            let page = try JSONDecoder().decode([Row].self, from: data)
            collected.append(contentsOf: page.map(\.saved))
            // A short page is the last one, and a page that fills exactly is
            // followed by one more that comes back empty.
            if page.count < pageSize { break }
            offset += pageSize
        }

        return collected
    }

    static func push(
        _ titles: [SavedTitle],
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        session: URLSession = .shared
    ) async {
        // The Android client batches its mutations, and the backend is happier
        // for it than with one call carrying a whole list.
        for batch in titles.chunked(into: 100) {
            guard let request = rpc(
                "sync_push_library_items",
                body: [
                    "p_items": batch.map(Self.row),
                    "p_profile_id": profileID,
                    // Not optional in practice: PostgREST picks the function by
                    // its exact named arguments, and every Android write sends
                    // this — so a push without it doesn't match the function.
                    "p_origin_client_id": SyncClientIdentity.current
                ],
                configuration: configuration,
                accessToken: accessToken
            ) else { return }

            await send(request, session: session, label: "push")
        }
    }

    static func delete(
        _ titles: [SavedTitle],
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        session: URLSession = .shared
    ) async {
        for batch in titles.chunked(into: 100) {
            guard let request = rpc(
                "sync_delete_library_items",
                body: [
                    "p_keys": batch.map { ["content_id": $0.itemID, "content_type": $0.type] },
                    "p_profile_id": profileID,
                    "p_origin_client_id": SyncClientIdentity.current
                ],
                configuration: configuration,
                accessToken: accessToken
            ) else { return }

            await send(request, session: session, label: "delete")
        }
    }

    /// One row, in the columns the backend files a saved title under.
    private static func row(_ title: SavedTitle) -> [String: Any] {
        var row: [String: Any] = [
            "content_id": title.itemID,
            "content_type": title.type,
            "name": title.name,
            // The Apple app draws portrait artwork everywhere a list appears;
            // the column exists for Android's landscape and square rows.
            "poster_shape": "POSTER",
            "genres": title.genres ?? [],
            "added_at": title.addedAt
        ]
        row["poster"] = title.poster
        row["background"] = title.background
        row["description"] = title.description
        row["release_info"] = title.releaseInfo
        row["addon_base_url"] = title.addonBaseURL
        // Stored as a number on the backend and as the string an addon sent it
        // as here, because that is what the badge on a poster draws.
        row["imdb_rating"] = title.imdbRating.flatMap(Double.init)
        return row
    }

    private static func send(_ request: URLRequest, session: URLSession, label: String) async {
        guard let (data, response) = try? await session.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            print("[library] \(label) failed: HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(240) ?? "")")
        }
    }

    private static func rpc(
        _ name: String,
        body: [String: Any],
        configuration: ServerConfiguration,
        accessToken: String
    ) -> URLRequest? {
        var backend = configuration.backendURL
        while backend.hasSuffix("/") { backend.removeLast() }
        guard let url = URL(string: "\(backend)/rest/v1/rpc/\(name)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.fragmentsAllowed]
        )
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    /// One row of `sync_pull_library`.
    private struct Row: Decodable {
        let saved: SavedTitle

        enum CodingKeys: String, CodingKey {
            case name, poster, background, description, genres
            case contentID = "content_id"
            case contentType = "content_type"
            case releaseInfo = "release_info"
            case imdbRating = "imdb_rating"
            case addonBaseURL = "addon_base_url"
            case addedAt = "added_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rating = try c.decodeIfPresent(Double.self, forKey: .imdbRating)
            let addedAt = try c.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
            let item = MetaItem(
                id: try c.decode(String.self, forKey: .contentID),
                type: try c.decodeIfPresent(String.self, forKey: .contentType) ?? "movie",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                poster: try c.decodeIfPresent(String.self, forKey: .poster),
                background: try c.decodeIfPresent(String.self, forKey: .background),
                // The backend has no column for a logo, so a title that came
                // from another device carries none until an addon re-supplies
                // one. It is artwork, not identity, and nothing depends on it.
                logo: nil,
                description: try c.decodeIfPresent(String.self, forKey: .description),
                releaseInfo: try c.decodeIfPresent(String.self, forKey: .releaseInfo),
                imdbRating: rating.map { String(format: "%.1f", $0) },
                genres: try c.decodeIfPresent([String].self, forKey: .genres) ?? []
            )

            saved = SavedTitle(
                item: item,
                addonBaseURL: try c.decodeIfPresent(String.self, forKey: .addonBaseURL) ?? "",
                savedAt: Date(timeIntervalSince1970: Double(addedAt) / 1000)
            )
        }
    }
}

extension Array {
    /// Mutations go up in batches, the way the Android client sends them.
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
