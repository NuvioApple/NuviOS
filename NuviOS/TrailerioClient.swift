import Foundation

// MARK: - Model

/// One direct trailer file from a Trailerio-style addon.
///
/// The addon answers a `meta` request with `links`, and every link that has a
/// `trailers` field is a plain HTTP(S) address to an MP4 or HLS playlist. No
/// WebKit, no extraction — which is exactly why this works on tvOS, where the
/// YouTube embed can't run.
struct DirectTrailer: Equatable, Sendable {
    let url: URL
    /// The addon's own label, e.g. "Apple TV 4K IMAX Atmos". Everything the
    /// ranking knows about the file comes from reading this.
    let provider: String

    var isHLS: Bool { url.pathExtension.lowercased() == "m3u8" }

    var isIMAX: Bool { provider.range(of: "imax", options: .caseInsensitive) != nil }

    /// Only a label that says so counts: the contract asks addons to write
    /// "Atmos" or "5.1" only where the stream really carries it.
    var soundRank: Int {
        let label = provider.lowercased()
        if label.contains("atmos") { return 3 }
        if label.contains("7.1") || label.contains("5.1") { return 2 }
        return 1
    }

    /// Vertical resolution the label claims, or 0 when it names none.
    var height: Int {
        let label = provider.lowercased()
        if label.contains("4k") || label.contains("2160") { return 2160 }
        if label.contains("1080") { return 1080 }
        if label.contains("720") { return 720 }
        if label.contains("480") || label.contains("sd") { return 480 }
        return 0
    }

    /// The addon's own pick.
    var isStarred: Bool { provider.contains("⭐") }
}

/// What the trailer is for. A card preview is muted and a few seconds long, so
/// it wants a file that starts fast; a trailer the viewer asked for wants the
/// best picture and sound the TV can be fed.
enum TrailerPurpose: Sendable {
    case preview
    case feature
    /// The trailer tape: downloaded whole before it plays, so a light MP4
    /// beats a studio master or an HLS ladder that can't be saved as one file.
    case tape
}

// MARK: - Client

/// Asks the configured trailer addons for direct trailer files.
///
/// Follows the add-on contract in `TrailerAddonContract.md` (TrailerChannel):
/// `GET <base>/meta/<movie|series>/<imdb id>.json`, links ranked by their
/// `provider` label. Every addon is asked at once; addon order from Settings
/// breaks ties.
actor TrailerioClient {
    static let shared = TrailerioClient()

    private let session: URLSession
    /// `[]` means "asked, nothing there" — remembered so a title with no
    /// trailer isn't asked about again every time focus passes over it.
    private var cache: [String: [DirectTrailer]] = [:]
    private var inFlight: [String: Task<[DirectTrailer], Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Ranked best first. Empty when no addon has the title.
    func trailers(
        imdbID: String,
        type: String,
        bases: [String],
        purpose: TrailerPurpose
    ) async -> [DirectTrailer] {
        let id = imdbID.trimmed
        guard id.hasPrefix("tt"), type == "movie" || type == "series" else { return [] }
        let cleaned = bases.map { AddonClient.canonicalize($0) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }

        let key = "\(type)|\(id)|\(cleaned.joined(separator: ","))"
        let all: [DirectTrailer]
        if let cached = cache[key] {
            all = cached
        } else if let running = inFlight[key] {
            all = await running.value
        } else {
            let task = Task { await self.fetch(id: id, type: type, bases: cleaned) }
            inFlight[key] = task
            all = await task.value
            inFlight[key] = nil
            cache[key] = all
        }
        return Self.rank(all, purpose: purpose)
    }

    /// Kicks the lookup off without waiting for it, so the answer is already
    /// in the cache by the time focus has rested long enough to ask.
    func warm(imdbID: String, type: String, bases: [String]) {
        Task { _ = await trailers(imdbID: imdbID, type: type, bases: bases, purpose: .preview) }
    }

    private func fetch(id: String, type: String, bases: [String]) async -> [DirectTrailer] {
        let session = session
        return await withTaskGroup(of: (Int, [DirectTrailer]).self) { group in
            for (order, base) in bases.enumerated() {
                group.addTask { (order, await Self.request(base: base, type: type, id: id, session: session)) }
            }
            var byAddon: [Int: [DirectTrailer]] = [:]
            for await (order, links) in group { byAddon[order] = links }
            return byAddon.keys.sorted().flatMap { byAddon[$0] ?? [] }
        }
    }

    private static func request(
        base: String,
        type: String,
        id: String,
        session: URLSession
    ) async -> [DirectTrailer] {
        // A configured addon may carry a query string; the path goes before it.
        let queryStart = base.firstIndex(of: "?")
        let path = queryStart.map { String(base[base.startIndex..<$0]) } ?? base
        let query = queryStart.map { String(base[$0...]) } ?? ""
        guard let url = URL(string: "\(path)/meta/\(type)/\(id).json\(query)") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let parsed = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [] }

        let meta = parsed.meta ?? parsed.bare
        return (meta?.links ?? []).compactMap { link in
            guard let raw = link.trailers?.trimmed, !raw.isEmpty,
                  let url = URL(string: raw),
                  url.scheme == "https" || url.scheme == "http"
            else { return nil }
            // A YouTube page isn't a video file; AVPlayer can't open it.
            if let host = url.host?.lowercased(),
               host.contains("youtube.com") || host.contains("youtu.be") {
                return nil
            }
            return DirectTrailer(url: url, provider: link.provider?.trimmed ?? "")
        }
    }

    // MARK: Ranking

    static func rank(_ trailers: [DirectTrailer], purpose: TrailerPurpose) -> [DirectTrailer] {
        // Stable: equal scores keep the addon order they arrived in.
        let indexed = Array(trailers.enumerated())
        let sorted: [(offset: Int, element: DirectTrailer)]

        switch purpose {
        case .feature:
            sorted = indexed.sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a.soundRank != b.soundRank { return a.soundRank > b.soundRank }
                if a.height != b.height { return a.height > b.height }
                if a.isStarred != b.isStarred { return a.isStarred }
                return lhs.offset < rhs.offset
            }
        case .tape:
            func score(_ t: DirectTrailer) -> Int {
                var value = 0
                if !t.isHLS { value += 1000 }
                let path = t.url.absoluteString.lowercased()
                if !(path.contains("mezzanine") || path.contains("/source_")) { value += 200 }
                switch t.height {
                case 1080: value += 60
                case 720: value += 40
                case 2160: value += 20
                default: value += 30
                }
                if t.isStarred { value += 10 }
                return value
            }
            sorted = indexed.sorted { lhs, rhs in
                let x = score(lhs.element), y = score(rhs.element)
                return x != y ? x > y : lhs.offset < rhs.offset
            }
        case .preview:
            // A muted card preview: small, quick, and never the Atmos
            // rendition — that's an HLS ladder whose first frame is the
            // slowest thing on offer. MP4 at 720–1080 starts fastest.
            func score(_ t: DirectTrailer) -> Int {
                var value = 0
                if !t.isHLS { value += 100 }
                switch t.height {
                case 1080: value += 40
                case 720: value += 50
                case 2160: value += 10
                case 480: value += 20
                default: value += 30
                }
                if t.soundRank == 1 { value += 5 }
                return value
            }
            // The addon's own ⭐ pick comes first, whatever its format: it is
            // the addon vouching that this file is the title's trailer. An
            // addon can list other clips beside it — Trailerio's list for the
            // 2025 "The Housemaid" carries a MUBI 720p MP4 of the 1960 film —
            // and a speed preference must never outrank that.
            sorted = indexed.sorted { lhs, rhs in
                let a = lhs.element, b = rhs.element
                if a.isStarred != b.isStarred { return a.isStarred }
                let x = score(a), y = score(b)
                return x != y ? x > y : lhs.offset < rhs.offset
            }
        }

        let ranked = sorted.map(\.element)
        // IMAX cuts lead a feature trailer when the viewer has asked for them.
        guard case .feature = purpose, TrailerioPreferences.preferIMAX else { return ranked }
        return ranked.filter(\.isIMAX) + ranked.filter { !$0.isIMAX }
    }

    // MARK: Wire format

    private struct Envelope: Decodable {
        let meta: Meta?
        /// Some addons send the meta object bare.
        let bare: Meta?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
            bare = meta == nil ? try? Meta(from: decoder) : nil
        }

        enum Keys: String, CodingKey { case meta }
    }

    private struct Meta: Decodable {
        let links: [Link]?
    }

    private struct Link: Decodable {
        let trailers: String?
        let provider: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            // `links` also carries categories, actors and the like, whose
            // fields are not all strings; read leniently and skip what isn't ours.
            trailers = try? c.decodeIfPresent(String.self, forKey: .trailers)
            provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        }

        enum Keys: String, CodingKey { case trailers, provider }
    }
}

/// Read straight from defaults so the ranking, which runs off the main actor,
/// needn't hop to `TmdbSettings` for one flag.
enum TrailerioPreferences {
    static let preferIMAXKey = "nuvio.trailerio.preferIMAX"
    static var preferIMAX: Bool {
        UserDefaults.standard.object(forKey: preferIMAXKey) as? Bool ?? true
    }
}
