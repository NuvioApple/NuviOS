import SwiftUI
import Combine
import AVFoundation

// MARK: - Settings

/// What plays before a movie: a reel of other titles' trailers (a "trailer
/// tape"), then an intro, then the feature. Both are off until asked for.
@MainActor
final class PreRollSettings: ObservableObject {
    static let shared = PreRollSettings()

    private static let introEnabledKey = "nuvio.preroll.introEnabled"
    private static let introURLsKey = "nuvio.preroll.introURLs"
    private static let bundledIntroIDsKey = "nuvio.preroll.bundledIntroIDs"
    private static let introBagKey = "nuvio.preroll.introBag"
    private static let lastIntroKey = "nuvio.preroll.lastIntro"
    private static let trailersEnabledKey = "nuvio.preroll.trailersEnabled"
    private static let trailerCountKey = "nuvio.preroll.trailerCount"

    private let defaults: UserDefaults

    @Published var introEnabled: Bool {
        didSet { defaults.set(introEnabled, forKey: Self.introEnabledKey) }
    }

    /// One address per line; one is picked at random each time.
    @Published var introURLs: String {
        didSet { defaults.set(introURLs, forKey: Self.introURLsKey) }
    }

    @Published var trailersEnabled: Bool {
        didSet { defaults.set(trailersEnabled, forKey: Self.trailersEnabledKey) }
    }

    @Published var trailerCount: Int {
        didSet { defaults.set(trailerCount, forKey: Self.trailerCountKey) }
    }

    /// The cinema intros shipped in the app (same set as Trailer Tape).
    struct BundledIntro: Identifiable, Hashable {
        let file: String
        let title: String
        let brand: String
        var id: String { file }
        var url: URL? { Bundle.main.url(forResource: file, withExtension: "mp4") }
    }

    static let bundledIntros: [BundledIntro] = [
        BundledIntro(file: "IMAXCountdown", title: "Countdown", brand: "IMAX"),
        BundledIntro(file: "IMAXNeverCompromise", title: "Never Compromise", brand: "IMAX"),
        BundledIntro(file: "IMAXPreShow", title: "Pre-Show", brand: "IMAX"),
        BundledIntro(file: "DolbyCinema", title: "Dolby Cinema", brand: "Dolby"),
        BundledIntro(file: "DolbyUniverse", title: "Dolby Universe", brand: "Dolby"),
        BundledIntro(file: "InfinityVision", title: "Infinity Vision", brand: "Infinity Vision"),
    ].filter { $0.url != nil }

    /// Which bundled intros are in the random pool. All of them to start.
    @Published var bundledIntroIDs: Set<String> {
        didSet { defaults.set(Array(bundledIntroIDs), forKey: Self.bundledIntroIDsKey) }
    }

    var introCandidates: [URL] {
        let custom = introURLs
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { $0.scheme == "https" || $0.scheme == "http" || $0.isFileURL }
        let bundled = Self.bundledIntros.filter { bundledIntroIDs.contains($0.id) }.compactMap(\.url)
        return bundled + custom
    }

    /// The next intro, shuffle-bag style: every intro in the pool plays once,
    /// in random order, before any repeats, and a fresh round never opens with
    /// the one that just played. Plain random picks repeat far too often for
    /// a handful of clips. The bag is kept, so it carries on across launches.
    func nextIntro() -> URL? {
        let pool = introCandidates
        guard !pool.isEmpty else { return nil }
        let byKey = Dictionary(pool.map { ($0.absoluteString, $0) }, uniquingKeysWith: { a, _ in a })
        let last = defaults.string(forKey: Self.lastIntroKey)

        // Drop anything no longer in the pool (switched off, or removed).
        var bag = (defaults.stringArray(forKey: Self.introBagKey) ?? []).filter { byKey[$0] != nil }
        if bag.isEmpty {
            bag = Array(byKey.keys).shuffled()
            if bag.count > 1, bag.first == last { bag.swapAt(0, Int.random(in: 1..<bag.count)) }
        }
        let next = bag.removeFirst()
        defaults.set(bag, forKey: Self.introBagKey)
        defaults.set(next, forKey: Self.lastIntroKey)
        return byKey[next]
    }

    var isActive: Bool {
        (introEnabled && !introCandidates.isEmpty) || (trailersEnabled && trailerCount > 0)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        introEnabled = defaults.object(forKey: Self.introEnabledKey) as? Bool ?? false
        introURLs = defaults.string(forKey: Self.introURLsKey) ?? ""
        bundledIntroIDs = Set(defaults.stringArray(forKey: Self.bundledIntroIDsKey)
            ?? Self.bundledIntros.map(\.id))
        trailersEnabled = defaults.object(forKey: Self.trailersEnabledKey) as? Bool ?? false
        let count = defaults.object(forKey: Self.trailerCountKey) as? Int ?? 2
        trailerCount = min(max(count, 1), 3)
    }
}

// MARK: - Upcoming

/// A title that hasn't come out yet, from TMDB.
struct UpcomingTitle: Sendable {
    let imdbID: String
    let type: String      // "movie" or "series"
    let name: String
    let date: Date
}

/// What opens in the next six months, from TMDB's discover endpoint,
/// matched to the feature's genres. Trailer files still come from the
/// trailer addon, by IMDb id, so they play on every platform.
actor UpcomingTitles {
    static let shared = UpcomingTitles()

    private let session = URLSession.shared
    private var genreIDs: [String: [String: Int]] = [:]   // media → name → id
    private var imdbCache: [String: String?] = [:]

    private static let base = "https://api.themoviedb.org/3"
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Shuffled, best genre match first, up to `limit`.
    func candidates(genres: [String], limit: Int, apiKey: String) async -> [(tmdbID: Int, media: String, name: String, date: Date)] {
        guard !apiKey.isEmpty else { return [] }
        let wanted = Set(genres.map { $0.lowercased() })
        var all: [(tmdbID: Int, media: String, name: String, date: Date, overlap: Int)] = []
        for media in ["movie", "tv"] {
            let ids = await genreMap(media: media, apiKey: apiKey)
            let matchIDs = ids.filter { wanted.contains($0.key.lowercased()) }.map(\.value)
            var found = await discover(media: media, genreIDs: matchIDs, apiKey: apiKey)
            if found.count < limit, !matchIDs.isEmpty {
                found += await discover(media: media, genreIDs: [], apiKey: apiKey)
            }
            let matchSet = Set(matchIDs)
            for hit in found where !all.contains(where: { $0.tmdbID == hit.id && $0.media == media }) {
                all.append((hit.id, media, hit.name, hit.date, Set(hit.genreIDs).intersection(matchSet).count))
            }
        }
        return all.shuffled()
            .sorted { $0.overlap > $1.overlap }
            .prefix(limit)
            .map { ($0.tmdbID, $0.media, $0.name, $0.date) }
    }

    func imdbID(tmdbID: Int, media: String, apiKey: String) async -> String? {
        let key = "\(media)/\(tmdbID)"
        if let cached = imdbCache[key] { return cached }
        struct IDs: Decodable { let imdb_id: String? }
        let ids: IDs? = await get("/\(media)/\(tmdbID)/external_ids", query: [:], apiKey: apiKey)
        let id = ids?.imdb_id.flatMap { $0.hasPrefix("tt") ? $0 : nil }
        // Only a real answer is remembered. A request that failed or was
        // cancelled says nothing about the title, and caching it as "no IMDb
        // id" emptied the hero on the next try.
        if ids != nil { imdbCache[key] = id }
        return id
    }

    /// Titles TMDB recommends off one the viewer watched, as items the app
    /// can open: each carries its IMDb id, so any Cinemeta-style addon serves
    /// its page. Only ones with a backdrop, since they front the hero.
    func similar(toIMDb imdbID: String, media: String, apiKey: String, limit: Int = 8) async -> [MetaItem] {
        guard !apiKey.isEmpty else { return [] }
        let tmdbMedia = media == "movie" ? "movie" : "tv"
        struct Found: Decodable {
            struct Hit: Decodable { let id: Int }
            let movie_results: [Hit]?
            let tv_results: [Hit]?
        }
        let found: Found? = await get("/find/\(imdbID)", query: ["external_source": "imdb_id"], apiKey: apiKey)
        guard let tmdbID = (tmdbMedia == "movie" ? found?.movie_results : found?.tv_results)?.first?.id else { return [] }

        struct Page: Decodable {
            struct Result: Decodable {
                let id: Int
                let title: String?
                let name: String?
                let overview: String?
                let backdrop_path: String?
                let poster_path: String?
                let release_date: String?
                let first_air_date: String?
                let vote_average: Double?
            }
            let results: [Result]
        }
        // Only newer titles: out in the last ten years, or still to come.
                let cutoff = Calendar.current.date(byAdding: .year, value: -10, to: Date()) ?? Date()
        var results: [Page.Result] = []
        // Recommendations first, then TMDB's "similar", a few pages each:
        // the date filter leaves only a handful of any one list.
        for list in ["recommendations", "similar"] {
            for number in 1...3 {
                let page: Page? = await get("/\(tmdbMedia)/\(tmdbID)/\(list)", query: ["page": "\(number)"], apiKey: apiKey)
                results += page?.results ?? []
            }
        }
        var seenIDs = Set<Int>()
        results = results.filter { seenIDs.insert($0.id).inserted }
        let picks = results.filter { r in
            guard r.backdrop_path != nil,
                  let raw = r.release_date ?? r.first_air_date,
                  let date = Self.day.date(from: raw) else { return false }
            return date >= cutoff
        }.prefix(limit)

        return await withTaskGroup(of: (Int, MetaItem?).self) { group in
            for (index, r) in picks.enumerated() {
                group.addTask {
                    guard let imdb = await self.imdbID(tmdbID: r.id, media: tmdbMedia, apiKey: apiKey) else { return (index, nil) }
                    let year = (r.release_date ?? r.first_air_date).map { String($0.prefix(4)) }
                    return (index, MetaItem(
                        id: imdb,
                        type: media == "movie" ? "movie" : "series",
                        name: r.title ?? r.name ?? "",
                        poster: r.poster_path.map { "https://image.tmdb.org/t/p/w500\($0)" },
                        background: r.backdrop_path.map { "https://image.tmdb.org/t/p/original\($0)" },
                        description: r.overview,
                        releaseInfo: year,
                        imdbRating: r.vote_average.map { String(format: "%.1f", $0) }
                    ))
                }
            }
            var out: [Int: MetaItem] = [:]
            for await (i, item) in group { if let item { out[i] = item } }
            return out.keys.sorted().compactMap { out[$0] }
        }
    }

    private struct Hit { let id: Int; let name: String; let date: Date; let genreIDs: [Int] }

    private func discover(media: String, genreIDs: [Int], apiKey: String) async -> [Hit] {
        struct Page: Decodable {
            struct Result: Decodable {
                let id: Int
                let title: String?
                let name: String?
                let release_date: String?
                let first_air_date: String?
                let genre_ids: [Int]?
            }
            let results: [Result]
        }
        let today = Date()
        let end = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
        let dateField = media == "movie" ? "primary_release_date" : "first_air_date"
        var query = [
            "\(dateField).gte": Self.day.string(from: today),
            "\(dateField).lte": Self.day.string(from: end),
            "sort_by": "popularity.desc",
            "include_adult": "false",
            "with_original_language": "en",
        ]
        if media == "movie" { query["with_release_type"] = "2|3" }
        if !genreIDs.isEmpty { query["with_genres"] = genreIDs.map(String.init).joined(separator: "|") }
        guard let page: Page = await get("/discover/\(media)", query: query, apiKey: apiKey) else { return [] }
        return page.results.compactMap { r in
            guard let name = r.title ?? r.name,
                  let raw = r.release_date ?? r.first_air_date,
                  let date = Self.day.date(from: raw), date >= Calendar.current.startOfDay(for: today)
            else { return nil }
            return Hit(id: r.id, name: name, date: date, genreIDs: r.genre_ids ?? [])
        }
    }

    private func genreMap(media: String, apiKey: String) async -> [String: Int] {
        if let cached = genreIDs[media] { return cached }
        struct List: Decodable { struct G: Decodable { let id: Int; let name: String }; let genres: [G] }
        guard let list: List = await get("/genre/\(media)/list", query: [:], apiKey: apiKey) else { return [:] }
        var map: [String: Int] = [:]
        for g in list.genres {
            map[g.name] = g.id
            // TMDB's TV list folds genres together ("Action & Adventure",
            // "Sci-Fi & Fantasy"); each half should still match.
            for part in g.name.components(separatedBy: " & ") { map[part] = g.id }
        }
        if map["Sci-Fi"] != nil { map["Science Fiction"] = map["Sci-Fi"] }
        genreIDs[media] = map
        return map
    }

    private func get<T: Decodable>(_ path: String, query: [String: String], apiKey: String) async -> T? {
        guard var components = URLComponents(string: Self.base + path) else { return nil }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let isBearer = apiKey.count > 40
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: apiKey)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 6)
        if isBearer { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Queue

struct PreRollClip: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let label: String
    /// The line above the title, e.g. "Coming soon · In theaters May 8".
    var kicker: String = ""

    static func kicker(for date: Date, media: String) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM d")
        let when = f.string(from: date)
        return media == "movie" ? "Coming soon · In theaters \(when)" : "Coming soon · Premieres \(when)"
    }
}

/// Lets exactly one of several racers through.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func open() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// Trailers are played from local files, never streamed: a clip is downloaded
/// whole before it plays, the next one downloads while the current one plays,
/// and each file is deleted once its trailer is done. Nothing buffers on screen.
@MainActor
final class PreRollFiles {
    static let shared = PreRollFiles()

    private var downloads: [URL: Task<URL?, Never>] = [:]
    private let folder: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PreRoll", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)  // leftovers from a reel that was cut short
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A file small enough to download in a trailer's running time. Internet
    /// Video Archive (Plex) links name their bitrate: 8000 is a ~1 GB master,
    /// 5000 an ordinary ~100 MB 1080p file.
    nonisolated static func downloadable(_ url: URL) -> URL {
        guard url.host?.contains("internetvideoarchive") == true,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems,
              let rate = items.first(where: { $0.name == "videokbrate" })?.value.flatMap(Int.init),
              rate > 5000
        else { return url }
        parts.queryItems = items.map { $0.name == "videokbrate" ? URLQueryItem(name: $0.name, value: "5000") : $0 }
        return parts.url ?? url
    }

    /// Starts downloading `remote` if it isn't already. Safe to call again.
    func fetch(_ remote: URL) {
        guard downloads[remote] == nil else { return }
        let folder = folder
        downloads[remote] = Task.detached(priority: .userInitiated) {
            do {
                let (temp, response) = try await URLSession.shared.download(from: remote)
                // A playlist can't be played from disk without its segments.
                let mime = (response.mimeType ?? "").lowercased()
                if mime.contains("mpegurl") || remote.pathExtension.lowercased() == "m3u8" {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: temp)
                    return nil
                }
                let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
                let local = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try FileManager.default.moveItem(at: temp, to: local)
                return local
            } catch {
                return nil
            }
        }
    }

    /// The local file for `remote`, waiting up to `timeout` for its download.
    /// Nil when it couldn't be downloaded in time; the caller streams instead.
    func file(for remote: URL, timeout: Duration) async -> URL? {
        fetch(remote)
        guard let task = downloads[remote] else { return nil }
        // Whichever comes first: the file, or the deadline. A task group would
        // wait on the download anyway, since awaiting its value can't be cancelled.
        let gate = OnceGate()
        return await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            Task { let file = await task.value; if gate.open() { done.resume(returning: file) } }
            Task { try? await Task.sleep(for: timeout); if gate.open() { done.resume(returning: nil) } }
        }
    }

    /// Deletes the file for `remote` and forgets its download.
    func discard(_ remote: URL) {
        guard let task = downloads.removeValue(forKey: remote) else { return }
        Task.detached {
            if let local = await task.value { try? FileManager.default.removeItem(at: local) }
        }
    }
}

/// The reel is looked up while the source list is still being tested, not
/// after the viewer has a stream: by the time a source wins, the trailers are
/// usually found and the first one already downloading.
@MainActor
final class PreRollPrefetch {
    static let shared = PreRollPrefetch()

    private struct Entry {
        let task: Task<[PreRollClip], Never>
        let started: Date
        let fromBeginning: Bool
    }
    private var entries: [String: Entry] = [:]

    /// Starts the lookup for a movie whose sources are being fetched. Safe to
    /// call again; a lookup under ten minutes old is reused.
    func start(resumeKey: String, title: String, genres: [String], fromBeginning: Bool = false) {
        if let entry = entries[resumeKey], entry.fromBeginning == fromBeginning,
           Date().timeIntervalSince(entry.started) < 600 { return }
        let task = Task { @MainActor in
            await PreRollBuilder.clips(resumeKey: resumeKey, title: title, genres: genres,
                                       fromBeginning: fromBeginning)
        }
        entries[resumeKey] = Entry(task: task, started: Date(),
                                   fromBeginning: fromBeginning)
        // Once the reel is known, start downloading its first clip.
        Task { @MainActor in
            let clips = await task.value
            guard let first = clips.first, entries[resumeKey]?.task == task else { return }
            PreRollFiles.shared.fetch(first.url)
        }
    }

    /// Returns once the reel's first trailer is downloaded, or straight away
    /// when there's no reel. A download that never finishes is given up on
    /// after two minutes rather than holding the film forever.
    func firstClipReady(for request: PlaybackRequest) async {
        let settings = PreRollSettings.shared
        let resume = request.startsFromBeginning ? 0 : (PlaybackProgress.position(for: request.resumeKey) ?? 0)
        guard request.isFeature, settings.isActive, resume < 300 else { return }
        if entries[request.resumeKey]?.fromBeginning != request.startsFromBeginning {
            start(resumeKey: request.resumeKey, title: request.title, genres: request.genres,
                  fromBeginning: request.startsFromBeginning)
        }
        guard let first = await clips(for: request).first else { return }
        _ = await PreRollFiles.shared.file(for: first.url, timeout: .seconds(120))
    }

    /// The reel for this request: the prefetched one if there is one, waited
    /// on for whatever is left of its budget, or a fresh lookup.
    func clips(for request: PlaybackRequest) async -> [PreRollClip] {
        let settings = PreRollSettings.shared
        let resume = request.startsFromBeginning ? 0 : (PlaybackProgress.position(for: request.resumeKey) ?? 0)
        guard request.isFeature, settings.isActive, resume < 300 else { return [] }
        if let entry = entries[request.resumeKey], entry.fromBeginning == request.startsFromBeginning {
            return await entry.task.value
        }
        return await PreRollBuilder.clips(resumeKey: request.resumeKey, title: request.title, genres: request.genres,
                                          fromBeginning: request.startsFromBeginning)
    }

    /// The reel was played (or skipped); the next play looks up a fresh one.
    func consume(resumeKey: String) {
        entries[resumeKey] = nil
    }
}

enum PreRollBuilder {
    /// Trailers first, then the intro. Gives up quickly: the movie never waits
    /// more than a few seconds on lookups.
    @MainActor
    static func clips(resumeKey: String, title: String, genres: [String],
                      fromBeginning: Bool = false) async -> [PreRollClip] {
        let settings = PreRollSettings.shared
        // Only a real "carry on where I was" skips the reel, not a few
        // minutes left over from an earlier start, and never a Restart.
        let resume = fromBeginning ? 0 : (PlaybackProgress.position(for: resumeKey) ?? 0)
        guard settings.isActive, resume < 300 else { return [] }

        var clips: [PreRollClip] = []
        if settings.trailersEnabled {
            let wanted = settings.trailerCount
            let apiKey = TmdbSettings.shared.effectiveAPIKey
            let candidates = await UpcomingTitles.shared.candidates(
                genres: genres, limit: wanted * 4, apiKey: apiKey
            ).filter { $0.name != title }
            let bases = TmdbSettings.shared.trailerBases
            let found: [PreRollClip] = await withTaskGroup(of: (Int, PreRollClip?).self) { group in
                for (index, title) in candidates.enumerated() {
                    group.addTask {
                        guard let imdb = await UpcomingTitles.shared.imdbID(
                            tmdbID: title.tmdbID, media: title.media, apiKey: apiKey
                        ) else { return (index, nil) }
                        let trailers = await TrailerioClient.shared.trailers(
                            imdbID: imdb, type: title.media == "movie" ? "movie" : "series",
                            bases: bases, purpose: .tape
                        )
                        return (index, trailers.first.map {
                            PreRollClip(url: PreRollFiles.downloadable($0.url), label: title.name,
                                        kicker: PreRollClip.kicker(for: title.date, media: title.media))
                        })
                    }
                }
                // Lookup budget: whatever has answered in eight seconds.
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return (-1, nil)
                }
                var hits: [(Int, PreRollClip)] = []
                for await (index, clip) in group {
                    if index == -1 { group.cancelAll(); break }
                    if let clip { hits.append((index, clip)) }
                    if hits.count >= wanted { group.cancelAll(); break }
                }
                return hits.sorted { $0.0 < $1.0 }.prefix(wanted).map(\.1)
            }
            clips += found
        }
        if settings.introEnabled, let intro = settings.nextIntro() {
            clips.append(PreRollClip(url: intro, label: "Intro", kicker: "Up next: \(title)"))
        }
        return clips
    }
}

// MARK: - Surface

#if os(macOS)
private final class PreRollLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { nil }
}

private struct PreRollSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PreRollLayerView {
        let view = PreRollLayerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: PreRollLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#else
private final class PreRollLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PreRollSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PreRollLayerView {
        let view = PreRollLayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: PreRollLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif

// MARK: - Player

/// Plays the pre-roll, then hands over to the real player.
struct PreRollPlayer: View {
    let request: PlaybackRequest

    private enum Phase: Equatable { case preparing, clips([PreRollClip], Int), feature }

    @State private var phase: Phase
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var watchdog: Task<Void, Never>?
    @State private var loading: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.platformCoverDismiss) private var coverDismiss

    init(request: PlaybackRequest) {
        self.request = request
        let wantsPreRoll = request.isFeature && PreRollSettings.shared.isActive
        _phase = State(initialValue: wantsPreRoll ? .preparing : .feature)
    }

    var body: some View {
        switch phase {
        case .feature:
            NuvioPlayerScreen(request: request)
        case .preparing:
            Color.black.ignoresSafeArea()
                .overlay { ProgressView().tint(.white) }
                .task {
                    let clips = await PreRollPrefetch.shared.clips(for: request)
                    if clips.isEmpty {
                        PreRollPrefetch.shared.consume(resumeKey: request.resumeKey)
                        phase = .feature
                    } else { start(clips, at: 0) }
                }
                .onExitCommandIfAvailable { close() }
        case .clips(let clips, let index):
            ZStack(alignment: .bottomTrailing) {
                Color.black.ignoresSafeArea()
                if let player {
                    PreRollSurface(player: player).ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(clips[index].kicker)
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(clips[index].label).font(.headline).foregroundStyle(.white)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 16) {
                    if index < clips.count - 1 {
                        Button("Skip") { advance() }
                    }
                    Button("Skip to movie") { finish() }
                }
                .padding(28)
            }
            .onExitCommandIfAvailable { close() }
            .onDisappear { teardown() }
        }
    }

    private func start(_ clips: [PreRollClip], at index: Int) {
        teardown()
        if index > 0 { PreRollFiles.shared.discard(clips[index - 1].url) }
        guard index < clips.count else { finish(); return }
        if index == 0 { PreRollPrefetch.shared.consume(resumeKey: request.resumeKey) }
        phase = .clips(clips, index)
        loading = Task { @MainActor in
            // Wait for the whole file; only a download that stalls falls back
            // to streaming, so the reel never hangs on one trailer.
            let local = await PreRollFiles.shared.file(for: clips[index].url, timeout: .seconds(20))
            guard !Task.isCancelled, case .clips(_, let current) = phase, current == index else { return }
            // The next trailer downloads while this one plays.
            if index + 1 < clips.count { PreRollFiles.shared.fetch(clips[index + 1].url) }
            play(local ?? clips[index].url, clips: clips, index: index)
        }
    }

    private func play(_ url: URL, clips: [PreRollClip], index: Int) {
        let next = AVPlayer(playerItem: AVPlayerItem(url: url))
        next.isMuted = runsInSimulator
        guard let item = next.currentItem else { advance(); return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in Task { @MainActor in advance() } }
        // A clip that never starts or fails is skipped rather than waited on.
        watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, case .clips(_, let current) = phase, current == index else { return }
            if item.status != .readyToPlay || next.currentTime().seconds < 0.5 { advance() }
        }
        player = next
        next.play()
    }

    private func advance() {
        guard case .clips(let clips, let index) = phase else { return }
        start(clips, at: index + 1)
    }

    private func finish() {
        teardown()
        discardFiles()
        phase = .feature
    }

    private func close() {
        teardown()
        discardFiles()
        if let coverDismiss { coverDismiss() } else { dismiss() }
    }

    /// Every trailer file of this reel, played or not, is removed.
    private func discardFiles() {
        guard case .clips(let clips, _) = phase else { return }
        for clip in clips { PreRollFiles.shared.discard(clip.url) }
    }

    private func teardown() {
        loading?.cancel()
        loading = nil
        watchdog?.cancel()
        watchdog = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }
}

private extension View {
    @ViewBuilder
    func onExitCommandIfAvailable(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS) || os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
