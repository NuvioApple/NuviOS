#if os(iOS) || os(macOS) || os(tvOS)
import Foundation

/// A cast member with a photo, resolved from TMDB.
///
/// Addons only ever send cast as a bare list of names (see `MetaDetail.cast`
/// in AddonClient.swift) — no photos, no character names. TMDB is the best
/// source of those, but only once the viewer has supplied their own key,
/// since this port ships without one baked in (see Trailers.swift's
/// `TrailerService` for the full story on why). `WikipediaCastService` below
/// covers everyone else, key-free, so the cast strip has photos out of the
/// box either way.
struct CastMember: Identifiable, Equatable {
    var id: Int
    var name: String
    var character: String?
    var profileURL: URL?
}

actor CastService {
    static let shared = CastService()

    private static let base = "https://api.themoviedb.org/3"
    private static let imageBase = "https://image.tmdb.org/t/p/w300"

    /// `nil` means "looked, found nothing" — worth remembering so a title
    /// with no TMDB match isn't re-queried every time its page is opened.
    private var cache: [String: [CastMember]?] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func cast(for item: MetaItem, apiKey: String) async -> [CastMember]? {
        let key = apiKey.trimmed
        guard !key.isEmpty else { return nil }

        let cacheKey = "\(item.type)|\(item.id)"
        if let cached = cache[cacheKey] { return cached }

        guard let tmdbID = await tmdbID(for: item, apiKey: key) else {
            cache[cacheKey] = nil
            return nil
        }
        let resolved = await credits(tmdbID: tmdbID, mediaType: Self.mediaType(for: item.type), apiKey: key)
        cache[cacheKey] = resolved
        return resolved
    }

    /// Same resolution `TrailerService` uses: a `tmdb:` id, a bare numeric
    /// id, or (the common case) TMDB's `/find` against the addon's IMDb id.
    private func tmdbID(for item: MetaItem, apiKey: String) async -> Int? {
        let id = item.id.trimmed

        if id.lowercased().hasPrefix("tmdb:"), let value = Int(id.dropFirst(5)) { return value }
        if !id.hasPrefix("tt"), let value = Int(id) { return value }

        // Series ids arrive as `tt123:1:4` when a specific episode is meant.
        let imdbID = id.split(separator: ":").first.map(String.init) ?? id
        guard imdbID.hasPrefix("tt") else { return nil }

        struct FindResponse: Decodable {
            struct Hit: Decodable { let id: Int }
            let movieResults: [Hit]
            let tvResults: [Hit]

            enum CodingKeys: String, CodingKey {
                case movieResults = "movie_results"
                case tvResults = "tv_results"
            }
        }

        guard let response: FindResponse = await get(
            "/find/\(imdbID)",
            query: ["external_source": "imdb_id"],
            apiKey: apiKey
        ) else { return nil }

        return Self.mediaType(for: item.type) == "tv"
            ? (response.tvResults.first?.id ?? response.movieResults.first?.id)
            : (response.movieResults.first?.id ?? response.tvResults.first?.id)
    }

    private func credits(tmdbID: Int, mediaType: String, apiKey: String) async -> [CastMember]? {
        struct CreditsResponse: Decodable {
            struct Cast: Decodable {
                let id: Int
                let name: String
                let character: String?
                let order: Int?
                let profilePath: String?

                enum CodingKeys: String, CodingKey {
                    case id, name, character, order
                    case profilePath = "profile_path"
                }
            }
            let cast: [Cast]
        }

        guard let response: CreditsResponse = await get(
            "/\(mediaType)/\(tmdbID)/credits",
            query: [:],
            apiKey: apiKey
        ) else { return nil }

        return response.cast
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .map { entry in
                CastMember(
                    id: entry.id,
                    name: entry.name,
                    character: entry.character?.trimmed,
                    profileURL: entry.profilePath.flatMap { URL(string: Self.imageBase + $0) }
                )
            }
    }

    private static func mediaType(for type: String) -> String {
        switch type.lowercased() {
        case "series", "tv", "show": "tv"
        default: "movie"
        }
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String],
        apiKey: String
    ) async -> T? {
        var components = URLComponents(string: Self.base + path)
        components?.queryItems = ([("api_key", apiKey)] + query.map { ($0.key, $0.value) })
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Key-free fallback for cast photos.
///
/// `CastService` above is the accurate path — a real cast/credits link — but
/// it only fires once the viewer has supplied their own TMDB key, since this
/// port can't ship one baked in. Wikipedia's API needs no key or account at
/// all, so it's what fills the cast strip out of the box: a name search
/// whose top few hits carry their thumbnail right in the same response, so
/// a hit with no photo (a filmography or discography page, say — these
/// consistently outrank the actor's own bio page on the word alone, so
/// biasing the query with "actor" made this worse, not better) is skipped
/// for the next-best-ranked one that has one. It's a name match rather than
/// a real id, so it's wrong far more often than TMDB — good enough for a
/// photo, not a source of truth — and English Wikipedia only, so it favours
/// cast better known there.
actor WikipediaCastService {
    static let shared = WikipediaCastService()

    private static let base = "https://en.wikipedia.org/w/api.php"
    /// Wikimedia asks every API client to identify itself; this is that
    /// identification, not a credential.
    private static let userAgent = "NuviOS/1.0 (unofficial Stremio client; cast photo lookup)"

    /// `nil` means "looked, found nothing" — worth remembering so the same
    /// name isn't re-queried every time a page it's in comes round.
    private var cache: [String: URL?] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func photo(forName name: String) async -> URL? {
        let key = name.trimmed.lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached }

        let resolved = await lookUp(name: name.trimmed)
        cache[key] = resolved
        return resolved
    }

    /// One request gets the top few hits for the plain name *and* their lead
    /// images together (`generator=search` feeding `prop=pageimages`), so
    /// there's no need to inspect a page before knowing whether it has a
    /// photo worth following up on.
    private func lookUp(name: String) async -> URL? {
        guard let json = await get([
            "action": "query",
            "generator": "search",
            "gsrsearch": name,
            "gsrlimit": "3",
            "prop": "pageimages",
            "piprop": "thumbnail",
            "pithumbsize": "300",
            "format": "json",
        ]) else { return nil }

        guard let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any]
        else { return nil }

        // The dictionary itself isn't in result order, but each page carries
        // its search rank in `index` — take the best-ranked page that
        // actually has a thumbnail rather than assuming the top hit does.
        let best = pages.values
            .compactMap { $0 as? [String: Any] }
            .filter { ($0["thumbnail"] as? [String: Any])?["source"] is String }
            .min { (($0["index"] as? Int) ?? .max) < (($1["index"] as? Int) ?? .max) }

        guard let source = (best?["thumbnail"] as? [String: Any])?["source"] as? String else { return nil }
        return URL(string: source)
    }

    private func get(_ query: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: Self.base)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}
#endif
