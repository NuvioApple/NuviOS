import Foundation

// MARK: - Wire models

/// A Stremio-protocol addon manifest. Only the parts the home screen needs.
struct AddonManifest: Decodable, Equatable {
    let id: String
    let name: String
    let catalogs: [AddonCatalog]

    enum CodingKeys: String, CodingKey {
        case id, name, catalogs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        catalogs = try c.decodeIfPresent([AddonCatalog].self, forKey: .catalogs) ?? []
    }
}

/// One catalog a manifest advertises — a row on the home screen.
struct AddonCatalog: Decodable, Equatable {
    let type: String
    let id: String
    let name: String?
    let extra: [Extra]

    struct Extra: Decodable, Equatable {
        let name: String
        let isRequired: Bool
        /// The values this extra accepts — the genre list, for `genre`.
        let options: [String]

        enum CodingKeys: String, CodingKey { case name, isRequired, options }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
            options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, id, name, extra, extraRequired
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)

        var declared = try c.decodeIfPresent([Extra].self, forKey: .extra) ?? []
        // Older manifests list required extras in a separate string array.
        let legacyRequired = try c.decodeIfPresent([String].self, forKey: .extraRequired) ?? []
        for name in legacyRequired where !declared.contains(where: { $0.name == name }) {
            declared.append(Extra(name: name, isRequired: true))
        }
        extra = declared
    }

    /// A catalog that can't be loaded without user input (search terms, a
    /// genre pick) has no place in an unattended home row.
    var needsUserInput: Bool { extra.contains { $0.isRequired } }

    /// Whether this catalog answers `search=` queries. Every streaming app
    /// leads with a search field, so the Search tab fans a query out across
    /// each addon catalog that advertises one.
    var supportsSearch: Bool {
        extra.contains { $0.name.caseInsensitiveCompare("search") == .orderedSame }
    }

    /// The genres this catalog can be filtered by, when it advertises any.
    var genres: [String] {
        extra.first { $0.name.caseInsensitiveCompare("genre") == .orderedSame }?.options ?? []
    }
}

extension AddonCatalog.Extra {
    init(name: String, isRequired: Bool, options: [String] = []) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
    }
}

/// A poster-level content item. `MetaDetail` adds the fields a detail screen
/// wants; both come off the same JSON shape.
struct MetaItem: Decodable, Identifiable, Equatable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    /// A transparent title treatment. Streaming services lead with these
    /// instead of typeset titles, and several addons ship them.
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, imdbRating
        case genres, genre
        case releaseInfoAlt = "year"
    }

    /// Rebuilds an item from something other than an addon response — a saved
    /// list entry, or a preview.
    init(
        id: String,
        type: String,
        name: String,
        poster: String? = nil,
        background: String? = nil,
        logo: String? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        imdbRating: String? = nil,
        genres: [String] = []
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.genres = genres
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
            ?? c.decodeIfPresent([String].self, forKey: .genre)
            ?? []
        // `releaseInfo` is a string in Cinemeta but a number in some addons.
        if let text = try? c.decodeIfPresent(String.self, forKey: .releaseInfo) {
            releaseInfo = text
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .releaseInfo) {
            releaseInfo = String(number)
        } else if let year = try? c.decodeIfPresent(String.self, forKey: .releaseInfoAlt) {
            releaseInfo = year
        } else {
            releaseInfo = nil
        }
        if let text = try? c.decodeIfPresent(String.self, forKey: .imdbRating) {
            imdbRating = text
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .imdbRating) {
            imdbRating = String(number)
        } else {
            imdbRating = nil
        }
    }
}

struct MetaDetail: Decodable, Equatable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let runtime: String?
    let genres: [String]
    let cast: [String]
    let director: [String]

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo
        case imdbRating, runtime, genres, genre, cast, director
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)

        if let text = try? c.decodeIfPresent(String.self, forKey: .releaseInfo) {
            releaseInfo = text
        } else if let number = try? c.decodeIfPresent(Int.self, forKey: .releaseInfo) {
            releaseInfo = String(number)
        } else {
            releaseInfo = nil
        }
        if let text = try? c.decodeIfPresent(String.self, forKey: .imdbRating) {
            imdbRating = text
        } else if let number = try? c.decodeIfPresent(Double.self, forKey: .imdbRating) {
            imdbRating = String(number)
        } else {
            imdbRating = nil
        }

        // Newer manifests use `genres`; Cinemeta still sends `genre`.
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
            ?? c.decodeIfPresent([String].self, forKey: .genre)
            ?? []
        cast = try c.decodeIfPresent([String].self, forKey: .cast) ?? []
        director = try c.decodeIfPresent([String].self, forKey: .director) ?? []
    }
}

private struct CatalogResponse: Decodable {
    let metas: [MetaItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed item shouldn't lose the whole row.
        metas = (try c.decodeIfPresent([FailableItem].self, forKey: .metas) ?? [])
            .compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case metas }

    private struct FailableItem: Decodable {
        let value: MetaItem?
        init(from decoder: Decoder) throws {
            value = try? MetaItem(from: decoder)
        }
    }
}

private struct MetaResponse: Decodable {
    let meta: MetaDetail
}

// MARK: - Errors

enum AddonError: LocalizedError {
    case invalidURL(String)
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "\(value) isn't a valid addon address."
        case .server(let status): "The addon responded with \(status)."
        }
    }
}

// MARK: - Client

/// Fetches manifests, catalogs and metadata over the Stremio addon protocol,
/// the same wire format the Android client's `AddonApi` speaks.
struct AddonClient {
    var session: URLSession = .shared

    /// Strips a trailing `/manifest.json` and any trailing slash, keeping the
    /// query string that configured addons carry — Android's canonicalizeUrl.
    static func canonicalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryStart = trimmed.firstIndex(of: "?")
        var path = queryStart.map { String(trimmed[trimmed.startIndex..<$0]) } ?? trimmed
        let query = queryStart.map { String(trimmed[$0...]) } ?? ""

        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/manifest.json") {
            path.removeLast("/manifest.json".count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        return path + query
    }

    func manifest(baseURL: String) async throws -> AddonManifest {
        try await get(AddonManifest.self, url: Self.url(baseURL, path: "/manifest.json"))
    }

    /// One catalog page. `genre` is the Stremio protocol's own filter extra,
    /// which collection folders lean on to narrow a shared catalog — the same
    /// `extraArgs` map Android's CatalogRepository builds its URLs from.
    func catalog(
        baseURL: String,
        type: String,
        catalogID: String,
        genre: String? = nil,
        skip: Int = 0
    ) async throws -> [MetaItem] {
        var args: [(String, String)] = []
        if let genre = genre?.trimmed, !genre.isEmpty { args.append(("genre", genre)) }
        if skip > 0 { args.append(("skip", String(skip))) }

        let root = "/catalog/\(Self.escape(type))/\(Self.escape(catalogID))"
        let suffix = args.isEmpty
            ? "\(root).json"
            : "\(root)/" + args
                .map { "\(Self.escapeArgument($0.0))=\(Self.escapeArgument($0.1))" }
                .joined(separator: "&") + ".json"
        let response = try await get(CatalogResponse.self, url: Self.url(baseURL, path: suffix))
        // Addons occasionally repeat an item across pages of the same row.
        var seen = Set<String>()
        return response.metas.filter { seen.insert($0.id).inserted }
    }

    /// Queries one catalog. `search=` is the Stremio protocol's own filter, so
    /// this is the same request the Android client makes from its search field.
    func search(
        baseURL: String,
        type: String,
        catalogID: String,
        query: String
    ) async throws -> [MetaItem] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return [] }
        let path = "/catalog/\(Self.escape(type))/\(Self.escape(catalogID))/search=\(Self.escape(trimmed)).json"
        let response = try await get(CatalogResponse.self, url: Self.url(baseURL, path: path))
        var seen = Set<String>()
        return response.metas.filter { seen.insert($0.id).inserted }
    }

    func meta(baseURL: String, type: String, id: String) async throws -> MetaDetail {
        let path = "/meta/\(Self.escape(type))/\(Self.escape(id)).json"
        return try await get(MetaResponse.self, url: Self.url(baseURL, path: path)).meta
    }

    /// Resolves a poster path that an addon gave relative to its own base.
    static func resolve(_ value: String?, relativeTo baseURL: String) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil { return absolute }
        return URL(string: url(baseURL, path: value.hasPrefix("/") ? value : "/\(value)"))
    }

    // MARK: Plumbing

    private static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }

    /// Extra values ride in the path, so `&` and `=` have to survive as
    /// separators while anything inside a value is encoded.
    private static func escapeArgument(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
            ?? value
    }

    /// Appends a path to a base that may already carry a configuration query.
    private static func url(_ baseURL: String, path: String) -> String {
        let canonical = canonicalize(baseURL)
        guard let queryStart = canonical.firstIndex(of: "?") else { return canonical + path }
        let base = String(canonical[canonical.startIndex..<queryStart])
        let query = String(canonical[queryStart...])
        return base + path + query
    }

    private func get<T: Decodable>(_ type: T.Type, url: String) async throws -> T {
        guard let target = URL(string: url) else { throw AddonError.invalidURL(url) }

        var request = URLRequest(url: target)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.server(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
