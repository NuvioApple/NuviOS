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
    /// Episodes, for a series. Movies leave this empty.
    let videos: [MetaVideo]

    /// YouTube ids for the title's trailers, best first.
    ///
    /// Cinemeta and the addons that follow it already carry these, which is
    /// why trailers need no API key: the meta response the detail screen
    /// fetches anyway is the same one that names the trailer.
    let trailerYouTubeIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo
        case imdbRating, runtime, genres, genre, cast, director, videos
        case trailers, trailerStreams
    }

    /// `trailerStreams` is the newer shape and names the id outright;
    /// `trailers` is the older one, where `source` is the id and the entry may
    /// be a clip or a featurette rather than a trailer.
    private struct TrailerStream: Decodable {
        let ytId: String?
    }

    private struct TrailerEntry: Decodable {
        let source: String?
        let type: String?
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
        videos = ((try? c.decodeIfPresent([MetaVideo].self, forKey: .videos)) ?? []) ?? []

        let streams = (try? c.decodeIfPresent([TrailerStream].self, forKey: .trailerStreams)) ?? []
        let entries = (try? c.decodeIfPresent([TrailerEntry].self, forKey: .trailers)) ?? []
        // Anything that isn't a trailer is dropped rather than ranked: a hero
        // that silently plays a behind-the-scenes clip reads as a bug.
        let fromEntries = entries
            .filter { ($0.type ?? "Trailer").caseInsensitiveCompare("Trailer") == .orderedSame }
            .compactMap { $0.source }
        var seen = Set<String>()
        trailerYouTubeIDs = (streams.compactMap { $0.ytId } + fromEntries)
            .map { $0.trimmed }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Episodes grouped by season, seasons in order, specials (season 0) last
    /// — the order every streaming app's episode picker uses.
    var seasons: [(season: Int, episodes: [MetaVideo])] {
        let numbered = videos.filter { $0.season != nil && $0.episode != nil }
        guard !numbered.isEmpty else { return [] }
        return Dictionary(grouping: numbered) { $0.season ?? 0 }
            .map { (season: $0.key, episodes: $0.value.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }) }
            .sorted { lhs, rhs in
                if lhs.season == 0 { return false }
                if rhs.season == 0 { return true }
                return lhs.season < rhs.season
            }
    }
}

/// One episode (or, for a movie, one entry) a `meta` response lists under
/// `videos`. Series need this: a stream request for an episode is keyed by
/// `tt123:1:4`, not by the series id.
struct MetaVideo: Decodable, Identifiable, Equatable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let released: String?
    let thumbnail: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, season, episode, number, released
        case releaseDate = "firstAired"
        case thumbnail, overview, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? c.decodeIfPresent(String.self, forKey: .name)
        season = try c.decodeIfPresent(Int.self, forKey: .season)
        episode = try c.decodeIfPresent(Int.self, forKey: .episode)
            ?? c.decodeIfPresent(Int.self, forKey: .number)
        released = try c.decodeIfPresent(String.self, forKey: .released)
            ?? c.decodeIfPresent(String.self, forKey: .releaseDate)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
            ?? c.decodeIfPresent(String.self, forKey: .description)
    }

    /// `S01E04`, when the addon numbered it. Specials arrive as season 0.
    var code: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    var displayTitle: String {
        title?.trimmed.nilWhenEmpty ?? code ?? id
    }
}

/// One playable — or at least offered — result from an addon's `stream`
/// resource. Addons describe the same field in several ways, so the label a
/// row shows is assembled rather than read from one key.
struct Stream: Decodable, Identifiable, Equatable {
    let url: String?
    let externalURL: String?
    let ytID: String?
    let infoHash: String?
    let name: String?
    let title: String?
    let description: String?
    /// Headers the source insists on, and the filename it advertises — both
    /// live under `behaviorHints`, and both decide whether a stream opens.
    let behaviorHints: StreamBehaviorHints
    /// Present when the addon returns no address of its own and expects the
    /// client to ask the debrid service for the download itself. See
    /// `StreamClientResolve` — this is the shape that cannot go stale, because
    /// the address is minted at the moment of playing.
    let clientResolve: StreamClientResolve?
    /// Only set once a fan-out has attributed the result to an addon.
    var addonName: String = ""

    enum CodingKeys: String, CodingKey {
        case url, name, title, description, behaviorHints, clientResolve
        case externalURL = "externalUrl"
        case ytID = "ytId"
        case infoHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        externalURL = try c.decodeIfPresent(String.self, forKey: .externalURL)
        ytID = try c.decodeIfPresent(String.self, forKey: .ytID)
        infoHash = try c.decodeIfPresent(String.self, forKey: .infoHash)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        behaviorHints = (try? c.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints))
            .flatMap { $0 } ?? StreamBehaviorHints()
        clientResolve = (try? c.decodeIfPresent(StreamClientResolve.self, forKey: .clientResolve))
            .flatMap { $0 }
    }

    var id: String {
        url
            ?? externalURL
            ?? infoHash
            ?? ytID
            ?? clientResolve?.infoHash
            ?? "\(addonName)|\(name ?? "")|\(title ?? "")"
    }

    /// True when the addon gave no address but told the client how to ask for
    /// one. Such a row is playable — it just costs a resolve first.
    var needsResolve: Bool {
        directURL == nil && (clientResolve?.isResolvable ?? false)
    }

    /// The direct address, if the stream has one AVFoundation could dial.
    /// Whether it can *decode* what is on the other end is a separate
    /// question — see `unsupportedContainer`.
    var directURL: URL? {
        guard let url = url?.trimmed, !url.isEmpty,
              let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              Self.playableSchemes.contains(scheme)
        else { return nil }
        return parsed
    }

    /// Everything libvlc can dial. Addons mostly return HTTP, but live
    /// sources and IPTV lists routinely hand back RTSP, RTMP or a raw
    /// multicast address, and the player opens all of them — so the picker
    /// has no business refusing them on the way in.
    ///
    /// `magnet` is deliberately absent: libvlc has no torrent client, so a
    /// magnet link is offered as a torrent result rather than a stream.
    private static let playableSchemes: Set<String> = [
        "http", "https",
        "rtsp", "rtsps", "rtmp", "rtmpe", "rtmps", "rtp", "srt",
        "mms", "mmsh", "mmst", "udp", "rtcp",
        "hls", "dash", "ftp", "ftps", "sftp", "smb", "nfs", "file"
    ]

    /// Containers worth naming on a row. The player reads all of them — this
    /// is a label, not a gate — but knowing a result is an MKV before opening
    /// it is the kind of thing people choose a source on.
    private static let knownContainers: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m3u8", "flv", "wmv", "mpg", "mpeg"
    ]

    /// The container this result advertises, uppercased, when it names one.
    var container: String? {
        guard let hint = containerHint else { return nil }
        return hint == "m3u8" ? "HLS" : hint.uppercased()
    }

    /// The filename an addon advertises is more reliable than the path, which
    /// is often an opaque token on a debrid or proxy link.
    private var containerHint: String? {
        let candidates = [
            behaviorHints.filename,
            directURL?.lastPathComponent,
            title?.split(separator: "\n").first.map(String.init),
            name
        ]
        for candidate in candidates {
            guard let value = candidate?.trimmed.lowercased(), !value.isEmpty else { continue }
            let ext = (value as NSString).pathExtension
            if Self.knownContainers.contains(ext) { return ext }
        }
        return nil
    }

    /// The address the picker hands to the player.
    var playbackURL: URL? { directURL }

    /// A link the system browser can take when the stream itself isn't
    /// something AVPlayer can open.
    var openableURL: URL? {
        if let externalURL = externalURL?.trimmed, !externalURL.isEmpty,
           let parsed = URL(string: externalURL), parsed.scheme != nil {
            return parsed
        }
        if let ytID = ytID?.trimmed, !ytID.isEmpty {
            return URL(string: "https://www.youtube.com/watch?v=\(ytID)")
        }
        return nil
    }

    var isPlayable: Bool { playbackURL != nil || needsResolve }

    /// The bold line of a row. Addons put the quality either in `name` or in
    /// the first line of `title`.
    var headline: String {
        let candidates = [name, title?.split(separator: "\n").first.map(String.init), description]
        for candidate in candidates {
            if let value = candidate?.trimmed.nilWhenEmpty { return value }
        }
        return addonName.nilWhenEmpty ?? "Stream"
    }

    /// The rest of `title` — size, seeds, release group — as one tidy line.
    var detailLine: String? {
        let body = (title ?? description)?
            .split(separator: "\n")
            .dropFirst(name == nil ? 1 : 0)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
        return body?.nilWhenEmpty
    }
}

/// The `behaviorHints` object. Only the parts that decide whether a stream
/// opens: the headers a source requires, and the filename it advertises.
struct StreamBehaviorHints: Decodable, Equatable {
    var notWebReady: Bool = false
    var filename: String?
    /// Headers the source requires on the media request itself — a Referer or
    /// User-Agent, most often. Sent without them, such a link answers 403 and
    /// the player shows nothing.
    var requestHeaders: [String: String] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case notWebReady, filename, proxyHeaders, videoHash, bingeGroup
    }

    private struct ProxyHeaders: Decodable {
        let request: [String: String]?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notWebReady = (try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)) .flatMap { $0 } ?? false
        filename = try? c.decodeIfPresent(String.self, forKey: .filename)
        let proxy = (try? c.decodeIfPresent(ProxyHeaders.self, forKey: .proxyHeaders)).flatMap { $0 }
        requestHeaders = proxy?.request ?? [:]
    }
}

private struct StreamResponse: Decodable {
    let streams: [Stream]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed entry shouldn't lose an addon's whole answer.
        streams = (try c.decodeIfPresent([FailableStream].self, forKey: .streams) ?? [])
            .compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case streams }

    private struct FailableStream: Decodable {
        let value: Stream?
        init(from decoder: Decoder) throws { value = try? Stream(from: decoder) }
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

    /// One addon's answer for a title or episode. `id` is the meta id for a
    /// movie and the `series:season:episode` video id for an episode, which is
    /// what the protocol keys episode streams by.
    /// Stream results are the one response in this protocol that must never be
    /// read from a cache.
    ///
    /// Addons routinely answer `/stream/` with a `Cache-Control: max-age`, and
    /// `URLSession.shared` honours it — so a second ask inside that window
    /// returns the first ask's answer without touching the network. For a
    /// catalog that is a saving; for a list of signed, short-lived addresses it
    /// means the app hands back the very links that have since expired, and a
    /// re-request cannot produce anything the viewer doesn't already have.
    ///
    /// The addon is asked again for real: the stored response is ignored, and
    /// `no-cache` tells anything in between to revalidate rather than serve its
    /// own copy.
    func streams(baseURL: String, type: String, id: String) async throws -> [Stream] {
        let path = "/stream/\(Self.escape(type))/\(Self.escape(id)).json"
        return try await get(
            StreamResponse.self,
            url: Self.url(baseURL, path: path),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData
        ).streams
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

    private func get<T: Decodable>(
        _ type: T.Type,
        url: String,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> T {
        guard let target = URL(string: url) else { throw AddonError.invalidURL(url) }

        var request = URLRequest(url: target)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = cachePolicy
        if cachePolicy == .reloadIgnoringLocalAndRemoteCacheData {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AddonError.server(status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
