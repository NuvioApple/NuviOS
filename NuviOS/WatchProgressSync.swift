import Foundation

/// Sends this device's watch positions up to the account.
///
/// Reading the backend is half a feature: without this, an episode watched on
/// the iPad would never reach the Continue Watching shelf — here or on the
/// television — because the shelf is built from the rows the *other* devices
/// wrote. The player records locally on its own five-second tick; this carries
/// the same position outward, far less often, because a resume point is worth
/// keeping current but not worth a request every few seconds.
///
/// Credentials are handed in once, when the account is known, rather than
/// threaded through the player — which has no business knowing about sessions.
actor WatchProgressSync {
    static let shared = WatchProgressSync()

    private var configuration: ServerConfiguration?
    private var accessToken: String?
    private var profileID: Int = Profile.primaryIndex
    private var lastSent: [String: Date] = [:]

    /// The gap between writes for one title while it plays. A position that is
    /// half a minute stale still resumes to the right scene.
    private static let interval: Double = 30

    func configure(configuration: ServerConfiguration?, accessToken: String?, profileID: Int) {
        self.configuration = configuration
        self.accessToken = accessToken
        self.profileID = profileID
        if accessToken == nil { lastSent = [:] }
    }

    /// Records a position against the account.
    ///
    /// `resumeKey` is the player's own key — `series|tt0903747:2:7` — which
    /// carries everything the backend row needs, so nothing extra has to be
    /// plumbed through the player to get here.
    ///
    /// `force` skips the interval, for the write when playback stops: that one
    /// is the position that matters most and there is no later tick to carry it.
    func record(resumeKey: String, seconds: Double, duration: Double, force: Bool = false) async {
        guard let configuration, let accessToken, duration > 0, seconds > 0 else { return }

        if !force, let last = lastSent[resumeKey], Date().timeIntervalSince(last) < Self.interval {
            return
        }
        lastSent[resumeKey] = Date()

        guard let entry = Self.entry(resumeKey: resumeKey, seconds: seconds, duration: duration) else { return }
        await WatchProgressDirectory.push(
            entry,
            configuration: configuration,
            accessToken: accessToken,
            profileID: profileID
        )
    }

    /// Takes a resume key apart into the row the backend stores.
    ///
    /// A Stremio video id is `tt0903747:2:7` — meta id, season, episode — and
    /// a film is just the meta id, so the same split answers both.
    static func entry(resumeKey: String, seconds: Double, duration: Double) -> WatchProgressEntry? {
        let halves = resumeKey.split(separator: "|", maxSplits: 1).map(String.init)
        guard halves.count == 2, !halves[1].isEmpty else { return nil }
        let contentType = halves[0]
        let videoID = halves[1]

        let parts = videoID.split(separator: ":").map(String.init)
        let contentID = parts.first ?? videoID
        let season = parts.count >= 3 ? Int(parts[1]) : nil
        let episode = parts.count >= 3 ? Int(parts[2]) : nil

        return WatchProgressEntry(
            contentID: contentID,
            contentType: contentType,
            videoID: videoID,
            season: season,
            episode: episode,
            position: Int64(seconds * 1000),
            duration: Int64(duration * 1000),
            lastWatched: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
