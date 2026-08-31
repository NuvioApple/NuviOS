import Foundation

// What the account was part-way through, so the iPad knows what the TV knows.
//
// Watch progress lives on the backend, one row per title or episode, written by
// whichever device was last playing it. The Android client keeps it in step
// through `sync_pull_watch_progress` / `sync_push_watch_progress`, and this
// speaks the same two RPCs — so a film paused on the television is the first
// thing on the home screen here, at the minute it was left.

/// One title the account has started and not finished.
struct WatchProgressEntry: Equatable, Sendable {
    /// The meta id — `tt0111161` — shared by every episode of a series.
    let contentID: String
    /// `movie` or `series`.
    let contentType: String
    /// The Stremio video id: the meta id for a film, `tt0903747:2:7` for an
    /// episode. This is what a resume point is filed under.
    let videoID: String
    let season: Int?
    let episode: Int?
    /// Milliseconds, as the backend stores them.
    let position: Int64
    let duration: Int64
    /// Epoch milliseconds.
    var lastWatched: Int64

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(Double(position) / Double(duration), 0), 1)
    }

    /// The key the player files this position under locally, so a row and the
    /// resume it promises agree.
    var resumeKey: String { "\(contentType)|\(videoID.nilWhenEmpty ?? contentID)" }

    var positionSeconds: Double { Double(position) / 1000 }
    var durationSeconds: Double { Double(duration) / 1000 }

    /// Started, and not so nearly finished that it belongs in the past.
    /// The thresholds are the Android client's: `WatchProgress.STARTED_THRESHOLD`
    /// and `COMPLETED_THRESHOLD`.
    var isInProgress: Bool { fraction >= 0.02 && fraction < 0.90 }
}

enum WatchProgressDirectory {
    /// Reads what this profile is part-way through, most recent first.
    ///
    /// A series is folded down to one entry — its latest episode — because a
    /// row of six cards for one show is a row nobody wants.
    static func inProgress(
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        limit: Int = 40,
        session: URLSession = .shared
    ) async throws -> [WatchProgressEntry] {
        let rows = try await pull(
            configuration: configuration,
            accessToken: accessToken,
            profileID: profileID,
            limit: limit,
            session: session
        )

        print("[continue-watching] pulled \(rows.count) row(s), \(rows.filter(\.isInProgress).count) in progress")

        var latestByContent: [String: WatchProgressEntry] = [:]
        for row in rows where row.isInProgress {
            let key = "\(row.contentType)|\(row.contentID)"
            if let existing = latestByContent[key], existing.lastWatched >= row.lastWatched { continue }
            latestByContent[key] = row
        }
        return latestByContent.values.sorted { $0.lastWatched > $1.lastWatched }
    }

    /// Writes one position back, so what is watched here reaches the other
    /// devices — and the row itself, which is read from the same table.
    static func push(
        _ entry: WatchProgressEntry,
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        session: URLSession = .shared
    ) async {
        var row: [String: Any] = [
            "content_id": entry.contentID,
            "content_type": entry.contentType,
            "video_id": entry.videoID,
            "position": entry.position,
            "duration": entry.duration,
            "last_watched": entry.lastWatched,
            // The Android client's own key format, so the two write the same
            // row rather than two rows for one episode.
            "progress_key": entry.season != nil && entry.episode != nil
                ? "\(entry.contentID)_s\(entry.season!)e\(entry.episode!)"
                : entry.contentID
        ]
        if let season = entry.season { row["season"] = season }
        if let episode = entry.episode { row["episode"] = episode }

        // `p_origin_client_id` is not optional in practice: PostgREST picks the
        // function by its exact named arguments, and every Android write sends
        // this one — so a push without it doesn't match the function at all.
        // The id also lets the backend tell this device's own writes from
        // another's when it fans changes back out.
        guard let request = rpc(
            "sync_push_watch_progress",
            body: [
                "p_entries": [row],
                "p_profile_id": profileID,
                "p_origin_client_id": SyncClientIdentity.current
            ],
            configuration: configuration,
            accessToken: accessToken
        ) else { return }

        guard let (data, response) = try? await session.data(for: request) else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            print("[continue-watching] push failed: HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(240) ?? "")")
        }
    }

    private static func pull(
        configuration: ServerConfiguration,
        accessToken: String,
        profileID: Int,
        limit: Int,
        session: URLSession
    ) async throws -> [WatchProgressEntry] {
        // Only `p_profile_id` is sent. PostgREST resolves a function by its
        // exact set of named arguments, so passing an argument the SQL function
        // doesn't declare is not ignored — the whole call 404s. The Android
        // client has `p_limit` and `p_since_last_watched` in its builder but
        // never fills them in practice, so this asks the same way it does and
        // caps the list on this side instead.
        guard let request = rpc(
            "sync_pull_watch_progress",
            body: ["p_profile_id": profileID],
            configuration: configuration,
            accessToken: accessToken
        ) else { return [] }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            print("[continue-watching] pull failed: HTTP \(status) \(String(data: data, encoding: .utf8)?.prefix(240) ?? "")")
            throw AuthError.server(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return Array(rows.map(\.entry).prefix(limit))
        } catch {
            // A shape this side doesn't recognise is worth seeing once, rather
            // than silently becoming an empty shelf.
            print("[continue-watching] pull decode failed: \(error) — body: \(String(data: data, encoding: .utf8)?.prefix(240) ?? "")")
            throw error
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
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // A resume point that is minutes stale is worse than useless on a row
        // whose whole purpose is to be current.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    private struct Row: Decodable {
        let entry: WatchProgressEntry

        enum CodingKeys: String, CodingKey {
            case season, episode, position, duration
            case contentID = "content_id"
            case contentType = "content_type"
            case videoID = "video_id"
            case lastWatched = "last_watched"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entry = WatchProgressEntry(
                contentID: try c.decode(String.self, forKey: .contentID),
                contentType: try c.decodeIfPresent(String.self, forKey: .contentType) ?? "movie",
                videoID: try c.decodeIfPresent(String.self, forKey: .videoID) ?? "",
                season: try c.decodeIfPresent(Int.self, forKey: .season),
                episode: try c.decodeIfPresent(Int.self, forKey: .episode),
                position: try c.decodeIfPresent(Int64.self, forKey: .position) ?? 0,
                duration: try c.decodeIfPresent(Int64.self, forKey: .duration) ?? 0,
                lastWatched: try c.decodeIfPresent(Int64.self, forKey: .lastWatched) ?? 0
            )
        }
    }
}


/// This installation's own id, as the sync RPCs expect it.
///
/// The Android client generates `nuvio-tv-` plus a random tail once per install
/// and keeps it forever; the backend uses it to tell which device wrote a row,
/// so it must be stable across launches and unique to this device.
enum SyncClientIdentity {
    private static let defaultsKey = "nuvio.sync.clientId"

    static let current: String = {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey), isValid(stored) {
            return stored
        }
        let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        let generated = "nuvio-ios-" + String((0..<16).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }()

    /// The backend's own rule: 16–96 characters of letters, digits, dash or
    /// underscore.
    private static func isValid(_ id: String) -> Bool {
        (16...96).contains(id.count) && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
