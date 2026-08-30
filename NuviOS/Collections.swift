import Foundation

// Collections are the user's own shelves: a named group of folders, each
// folder a bundle of catalogs from the addons they have installed. They are
// authored on Android (CollectionsDataStore) and synced to the backend as one
// JSON blob per profile, which is what this file reads.

// MARK: - Model

/// How a folder's tiles are cropped. Android's `PosterShape`.
enum PosterShape: String, Equatable {
    case poster, landscape, square

    init(json: String?) {
        switch json?.lowercased() {
        case "landscape", "wide": self = .landscape
        case "square": self = .square
        default: self = .poster
        }
    }

    var aspectRatio: CGFloat {
        switch self {
        case .poster: 0.675
        case .landscape: 1.78
        case .square: 1
        }
    }
}

/// One catalog a folder pulls from. Android also stores TMDB and Trakt
/// sources; those need provider credentials this app doesn't hold, so they
/// are kept as `.unsupported` and reported rather than silently dropped.
enum CollectionSource: Equatable {
    case addon(addonID: String, type: String, catalogID: String, genre: String?)
    case unsupported(provider: String, title: String)

    var addonCatalog: (addonID: String, type: String, catalogID: String, genre: String?)? {
        if case .addon(let addonID, let type, let catalogID, let genre) = self {
            return (addonID, type, catalogID, genre)
        }
        return nil
    }
}

struct CollectionFolder: Identifiable, Equatable {
    let id: String
    let title: String
    let coverImageURL: String?
    /// An animation the author attached, played over the cover while the tile
    /// is focused (TV) or on screen (phone). Android's `focusGifUrl`.
    let focusGifURL: String?
    let focusGifEnabled: Bool
    let coverEmoji: String?
    let tileShape: PosterShape
    let hideTitle: Bool
    let heroBackdropURL: String?
    let titleLogoURL: String?
    let sources: [CollectionSource]

    /// The animation to play, if the author attached one and left it on.
    var animatedCoverURL: URL? {
        guard focusGifEnabled, let value = focusGifURL else { return nil }
        return URL(string: value)
    }

    var addonSources: [CollectionSource] { sources.filter { $0.addonCatalog != nil } }
    /// A folder whose every source needs TMDB or Trakt can't be opened here.
    var isResolvable: Bool { !addonSources.isEmpty }
}

/// Named `MediaCollection` because `Collection` is a standard-library protocol.
struct MediaCollection: Identifiable, Equatable {
    let id: String
    let title: String
    let backdropImageURL: String?
    let pinToTop: Bool
    let showAllTab: Bool
    let folders: [CollectionFolder]

    /// Folders nothing can be loaded for are dropped: Android shows the tile
    /// and then an empty screen, which is worse than not offering it.
    var visibleFolders: [CollectionFolder] { folders.filter(\.isResolvable) }
}

// MARK: - Wire format

/// The shape `CollectionsDataStore` writes with Gson. Every field is optional
/// on purpose — the blob is written by whichever Android version the user
/// happens to run, and one unknown key shouldn't lose the whole shelf.
private struct WireCollection: Decodable {
    let id: String?
    let title: String?
    let backdropImageUrl: String?
    let pinToTop: Bool?
    let showAllTab: Bool?
    let folders: [WireFolder]?
}

private struct WireFolder: Decodable {
    let id: String?
    let title: String?
    let coverImageUrl: String?
    let focusGifUrl: String?
    let focusGifEnabled: Bool?
    let coverEmoji: String?
    let tileShape: String?
    let hideTitle: Bool?
    let heroBackdropUrl: String?
    let titleLogoUrl: String?
    let sources: [WireSource]?
    /// The pre-`sources` format, kept for blobs written by older builds.
    let catalogSources: [WireCatalogSource]?
}

private struct WireSource: Decodable {
    let provider: String?
    let addonId: String?
    let type: String?
    let catalogId: String?
    let genre: String?
    let title: String?
}

private struct WireCatalogSource: Decodable {
    let addonId: String?
    let type: String?
    let catalogId: String?
    let genre: String?
}

extension MediaCollection {
    /// Decodes the array `sync_pull_collections` returns. Anything malformed
    /// is skipped rather than throwing: a shelf missing one folder still beats
    /// a home screen missing every collection.
    static func decodeList(from data: Data) -> [MediaCollection] {
        let wire = (try? JSONDecoder().decode([WireCollection].self, from: data)) ?? []
        return wire.compactMap(make)
    }

    private static func make(_ wire: WireCollection) -> MediaCollection? {
        guard let id = wire.id?.trimmed.nilIfBlank,
              let title = wire.title?.trimmed.nilIfBlank
        else { return nil }

        return MediaCollection(
            id: id,
            title: title,
            backdropImageURL: wire.backdropImageUrl?.trimmed.nilIfBlank,
            pinToTop: wire.pinToTop ?? false,
            showAllTab: wire.showAllTab ?? true,
            folders: (wire.folders ?? []).compactMap(folder)
        )
    }

    private static func folder(_ wire: WireFolder) -> CollectionFolder? {
        guard let id = wire.id?.trimmed.nilIfBlank,
              let title = wire.title?.trimmed.nilIfBlank
        else { return nil }

        let sources: [CollectionSource]
        if let declared = wire.sources, !declared.isEmpty {
            sources = declared.compactMap(source)
        } else {
            sources = (wire.catalogSources ?? []).compactMap { legacy in
                guard let addonID = legacy.addonId?.trimmed.nilIfBlank,
                      let type = legacy.type?.trimmed.nilIfBlank,
                      let catalogID = legacy.catalogId?.trimmed.nilIfBlank
                else { return nil }
                return .addon(
                    addonID: addonID,
                    type: type,
                    catalogID: catalogID,
                    genre: legacy.genre?.trimmed.nilIfBlank
                )
            }
        }

        return CollectionFolder(
            id: id,
            title: title,
            coverImageURL: wire.coverImageUrl?.trimmed.nilIfBlank,
            focusGifURL: wire.focusGifUrl?.trimmed.nilIfBlank,
            focusGifEnabled: wire.focusGifEnabled ?? true,
            coverEmoji: wire.coverEmoji?.trimmed.nilIfBlank,
            tileShape: PosterShape(json: wire.tileShape),
            hideTitle: wire.hideTitle ?? false,
            heroBackdropURL: wire.heroBackdropUrl?.trimmed.nilIfBlank,
            titleLogoURL: wire.titleLogoUrl?.trimmed.nilIfBlank,
            sources: sources
        )
    }

    private static func source(_ wire: WireSource) -> CollectionSource? {
        switch (wire.provider ?? "addon").lowercased() {
        case "tmdb", "trakt":
            let provider = (wire.provider ?? "").lowercased()
            return .unsupported(
                provider: provider,
                title: wire.title?.trimmed.nilIfBlank ?? provider.capitalized
            )
        default:
            guard let addonID = wire.addonId?.trimmed.nilIfBlank,
                  let type = wire.type?.trimmed.nilIfBlank,
                  let catalogID = wire.catalogId?.trimmed.nilIfBlank
            else { return nil }
            return .addon(
                addonID: addonID,
                type: type,
                catalogID: catalogID,
                genre: wire.genre?.trimmed.nilIfBlank
            )
        }
    }
}

// MARK: - Backend

/// Reads a profile's collections from the backend. Android pushes and pulls
/// the same blob through the `sync_pull_collections` RPC, which is
/// SECURITY DEFINER so linked TV devices can read it too — that's why this
/// goes through the RPC rather than selecting the table directly.
enum CollectionsDirectory {
    private struct Blob: Decodable {
        let collectionsJSON: Data

        enum CodingKeys: String, CodingKey { case collections_json }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The column is jsonb; re-encode it so the collection decoder can
            // work from bytes rather than from a half-decoded tree.
            let raw = try c.decode(JSONValue.self, forKey: .collections_json)
            // Some backends hand the column back as a JSON *string* holding
            // the array rather than as the array itself.
            if case .string(let text) = raw {
                collectionsJSON = Data(text.utf8)
            } else {
                collectionsJSON = (try? JSONEncoder().encode(raw)) ?? Data("[]".utf8)
            }
        }
    }

    static func collections(
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int = Profile.primaryIndex,
        session: URLSession = .shared
    ) async throws -> [MediaCollection] {
        var backend = configuration.backendURL
        while backend.hasSuffix("/") { backend.removeLast() }

        guard let url = URL(string: "\(backend)/rest/v1/rpc/sync_pull_collections") else {
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["p_profile_id": profileID]
        )
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let rows = (try? JSONDecoder().decode([Blob].self, from: data)) ?? []
        guard let blob = rows.first else { return [] }
        return MediaCollection.decodeList(from: blob.collectionsJSON)
    }
}

/// Just enough of a JSON tree to carry a `jsonb` column through unchanged.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? c.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
