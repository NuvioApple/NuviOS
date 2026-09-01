import Foundation
import Combine

// Picking a source without making the viewer read a list of them.
//
// Addon results advertise a quality in their name, but the name is a claim,
// not a promise: half of the 4K rows are dead links, rate-limited debrid
// tokens, or a host too slow to keep a 4K bitrate fed. So the label is only
// the starting point — every candidate is actually dialled, and the winner is
// the most *desirable* quality that also answered and moved bytes fast enough
// to play — which is not the same as the highest. See `StreamQuality.preferred`.

// MARK: - What a claim is worth

/// The advertised quality of a result, read out of whatever text the addon
/// chose to put it in.
enum StreamQuality: Int, Comparable, CaseIterable {
    case unknown = 0
    case sd = 1
    case hd720 = 2
    case hd1080 = 3
    case qhd1440 = 4
    case uhd2160 = 5

    static func < (lhs: StreamQuality, rhs: StreamQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .unknown: "SD"
        case .sd: "480p"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .qhd1440: "1440p"
        case .uhd2160: "4K"
        }
    }

    /// What the app aims for, rather than the most pixels it can find.
    ///
    /// 4K is the heaviest thing the player can be asked to do, and on the Mac
    /// it is also the least reliable: libvlc renders HDR and Dolby Vision
    /// through an OpenGL tone-mapping pass that runs on a legacy GL context,
    /// which is where playback both burns the most power and dies on
    /// `GL_INVALID_FRAMEBUFFER_OPERATION`. 1080p SDR plays everywhere without
    /// any of that.
    static let preferred: StreamQuality = .hd1080

    /// How much the app wants this quality, highest first.
    ///
    /// Deliberately not `rawValue`, which only says how many pixels a source
    /// claims. Anything above `preferred` ranks *below* everything at or under
    /// it: a 4K source is a last resort, not a prize.
    var desirability: Int {
        switch self {
        case .hd1080: 5
        case .hd720: 4
        case .sd: 3
        case .unknown: 2
        case .qhd1440: 1
        case .uhd2160: 0
        }
    }

    /// Roughly what this quality needs to run without stalling, in megabits
    /// per second. Deliberately generous: a source that can only just keep up
    /// on a probe won't keep up for two hours.
    var sustainedMegabits: Double {
        switch self {
        case .unknown, .sd: 2
        case .hd720: 4
        case .hd1080: 8
        case .qhd1440: 14
        case .uhd2160: 20
        }
    }
}

extension Stream {
    /// Every scrap of text an addon might have hidden the quality in.
    private var descriptor: String {
        [name, title, description, behaviorHints.filename]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    /// The descriptor with the separators a release name uses — dots, dashes,
    /// underscores, brackets — turned into spaces, and padded at both ends, so
    /// a short tag can be matched as a whole word.
    ///
    /// `Obsession.2025.2160p.DV.HDR.HEVC-KiT.mkv` hides its tags between dots:
    /// a check for `" dv "` never fires, and a bare `"dv"` would just as
    /// happily match "dvd" or "advance".
    private var tokens: String {
        " " + String(descriptor.map { "._-/[]()+,".contains($0) ? " " : $0 }) + " "
    }

    private func hasTag(_ tags: [String]) -> Bool {
        let padded = tokens
        return tags.contains { padded.contains(" \($0) ") }
    }

    var advertisedQuality: StreamQuality {
        let text = descriptor
        func has(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }

        if has(["2160", "4k", "uhd", "ultrahd"]) { return .uhd2160 }
        if has(["1440", "2k", "qhd"]) { return .qhd1440 }
        if has(["1080", "fullhd", "fhd"]) { return .hd1080 }
        if has(["720", "hd "]) { return .hd720 }
        if has(["480", "360", "240", "sd "]) { return .sd }
        return .unknown
    }

    /// Sources worth preferring at equal resolution.
    var qualityBonus: Double {
        let text = descriptor
        var bonus = 0.0
        if text.contains("remux") { bonus += 5 }
        if text.contains("bluray") || text.contains("blu-ray") || text.contains("bdrip") { bonus += 3 }
        if text.contains("web-dl") || text.contains("webdl") { bonus += 2 }
        if text.contains("atmos") || text.contains("truehd") || text.contains("dts") { bonus += 2 }
        return bonus
    }

    /// A camera rip claiming 1080p is still a camera rip.
    ///
    /// High dynamic range is marked down here rather than up. It is the
    /// picture the player handles worst — see `StreamQuality.preferred` — and
    /// these weights are smaller than a full quality step, so they settle
    /// which of two equal-resolution sources to take rather than reaching past
    /// a whole rung of the ladder.
    var qualityPenalty: Double {
        let text = descriptor
        var penalty = 0.0
        if text.contains("dolby vision") || hasTag(["dv", "dovi", "dolbyvision"]) { penalty += 30 }
        if text.contains("hdr") { penalty += 20 }
        for marker in ["cam", "camrip", "hdcam", "hdts", "telesync", "tsrip", "screener", "scr ", "workprint"]
        where text.contains(marker) {
            penalty += 40
            break
        }
        if text.contains("hardcoded") || text.contains("hc ") { penalty += 6 }
        return penalty
    }
}

// MARK: - What the dial-up found

/// The result of actually opening a source: did it answer, how quickly, and
/// how fast did bytes arrive once it did.
struct StreamProbe: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case pending
        /// The host said, in so many words, that this link is no good.
        case unreachable(String)
        /// The probe learned nothing. A timeout, a busy host, a refusal of the
        /// *probe* rather than of the link — none of which is evidence that
        /// the source won't play. Debrid hosts in particular rate-limit a
        /// burst of range requests and answer none of them, which says
        /// everything about the burst and nothing about the files.
        case unproven(String)
        case reachable
    }

    var verdict: Verdict = .pending
    /// Time to the first byte — how long a viewer would stare at a spinner.
    var responseSeconds: Double?
    var megabitsPerSecond: Double?
    var byteSize: Int64?

    var isReachable: Bool { verdict == .reachable }

    /// Whether this source is still worth opening. Only a host's own refusal
    /// takes a source out of the running; everything else is worth a try,
    /// because the player has a queue to fall through if it is wrong.
    var isWorthTrying: Bool {
        switch verdict {
        case .reachable, .unproven, .pending: true
        case .unreachable: false
        }
    }

    /// The short line the source row shows once its test is in.
    var summary: String? {
        switch verdict {
        case .pending:
            return nil
        case .unreachable(let reason):
            return reason
        case .unproven:
            // Not worth alarming anyone with: the source may well be fine, and
            // saying "Timed out" on a row that then plays is just wrong.
            return "Untested"
        case .reachable:
            var parts: [String] = []
            if let megabitsPerSecond {
                parts.append(String(format: "%.1f Mbps", megabitsPerSecond))
            }
            if let responseSeconds {
                parts.append(String(format: "%.0f ms", responseSeconds * 1000))
            }
            if let byteSize, byteSize > 0 {
                parts.append(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
            }
            return parts.isEmpty ? "Reachable" : parts.joined(separator: " · ")
        }
    }
}

/// Dials one address and reports back. Nothing here is kept: the probe is a
/// range request that is cancelled the moment enough has arrived to time it.
struct StreamProber: Sendable {
    /// A single byte is enough to learn whether a source answers at all.
    ///
    /// The timeout is short on purpose: every second spent here is a second of
    /// spinner before the picture, and a source that needs longer than this to
    /// produce one byte is not the source to open with anyway.
    func reach(url: URL, headers: [String: String]) async -> StreamProbe {
        var probe = StreamProbe()
        var request = URLRequest(url: url, timeoutInterval: Self.reachTimeout)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let started = Date()
        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            probe.responseSeconds = Date().timeIntervalSince(started)

            guard let http = response as? HTTPURLResponse else {
                // A non-HTTP source (rtsp, smb, udp) can't be probed this way;
                // it isn't broken, it just can't be measured.
                probe.verdict = .reachable
                return probe
            }
            guard (200..<400).contains(http.statusCode) else {
                probe.verdict = Self.verdict(forStatus: http.statusCode)
                return probe
            }
            probe.verdict = .reachable
            probe.byteSize = Self.totalSize(from: http)
            // Noted so the link check before playback doesn't ask this same
            // host the same question all over again.
            await StreamProbeLedger.shared.record(url)
            // The body is not wanted; dropping the iterator ends the transfer.
            _ = bytes
        } catch is CancellationError {
            probe.verdict = .pending
        } catch {
            probe.verdict = Self.verdict(for: error)
        }
        return probe
    }

    /// What a status code says about the *link*.
    ///
    /// Only the codes that name the link as the problem take a source out of
    /// the running. 405 and 416 are refusals of the probe's own range request,
    /// 429 is a host asking for less traffic, and 5xx is a host having a bad
    /// minute — a source behind any of those may play perfectly.
    static func verdict(forStatus status: Int) -> StreamProbe.Verdict {
        switch status {
        case 200..<400: .reachable
        case 401, 403: .unreachable("Link expired")
        case 404, 410: .unreachable("Gone")
        case 429: .unproven("Host busy")
        default: .unproven("HTTP \(status)")
        }
    }

    /// The same question of a transport error. A timeout is the important one:
    /// it is the most common answer from a rate-limited host and the least
    /// informative about the file.
    static func verdict(for error: Error) -> StreamProbe.Verdict {
        switch (error as NSError).code {
        case NSURLErrorTimedOut: .unproven("No answer")
        case NSURLErrorNetworkConnectionLost: .unproven("Connection lost")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: .unreachable("Host not found")
        case NSURLErrorNotConnectedToInternet: .unreachable("Offline")
        default: .unproven(reason(for: error))
        }
    }

    /// Pulls a slice of the real file and times it. Run one at a time, or the
    /// candidates share the line and all of them look slow.
    ///
    /// The budget buys just enough of the file to tell a line that can carry
    /// the picture from one that can't. It used to take two megabytes over as
    /// much as four seconds *per candidate*, which — sequential, by design —
    /// was most of the wait before anything appeared on screen.
    func measureThroughput(
        url: URL,
        headers: [String: String],
        byteBudget: Int = 600_000,
        secondsBudget: Double = 1.2
    ) async -> Double? {
        var request = URLRequest(url: url, timeoutInterval: Self.measureTimeout)
        request.setValue("bytes=0-\(byteBudget - 1)", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        do {
            let (bytes, response) = try await Self.session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                return nil
            }

            // Timed from the first byte, so a slow handshake is counted once
            // in `responseSeconds` rather than twice.
            var received = 0
            var started: Date?
            for try await _ in bytes {
                if started == nil { started = Date() }
                received += 1
                if received >= byteBudget { break }
                if received % 65_536 == 0,
                   let started, Date().timeIntervalSince(started) > secondsBudget { break }
            }

            guard let started, received > 0 else { return nil }
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            return (Double(received) * 8) / elapsed / 1_000_000
        } catch {
            return nil
        }
    }

    /// Ceiling on one reachability dial.
    static let reachTimeout: Double = 3
    /// Ceiling on one speed test, a little above its own seconds budget.
    static let measureTimeout: Double = 3

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// `Content-Range: bytes 0-0/734003200` carries the real length; a ranged
    /// response's `Content-Length` is only the size of the slice.
    private static func totalSize(from response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let size = Int64(total.trimmingCharacters(in: .whitespaces)), size > 0 {
            return size
        }
        let length = response.expectedContentLength
        return length > 1 ? length : nil
    }

    private static func reason(for error: Error) -> String {
        switch (error as NSError).code {
        case NSURLErrorTimedOut: "Timed out"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "Host not found"
        case NSURLErrorNotConnectedToInternet: "Offline"
        case NSURLErrorNetworkConnectionLost: "Connection lost"
        default: "Unreachable"
        }
    }
}

// MARK: - Choosing

/// Tests the candidates and picks one.
///
/// Two passes, because they measure different things. Every candidate is
/// dialled at once to find out which are alive — that costs nothing but a
/// byte each. Then the strongest few are speed-tested **one at a time**, since
/// parallel downloads split the same connection and would make every source
/// look equally poor.
@MainActor
final class StreamAutoSelector: ObservableObject {
    enum Status: Equatable {
        case idle
        /// Dialling every candidate.
        case reaching(done: Int, total: Int)
        /// Speed-testing the shortlist.
        case measuring(name: String)
        case chose(Stream)
        case noneUsable
        case cancelled
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var probes: [String: StreamProbe] = [:]

    /// How many are dialled at once, how many answers are enough to stop
    /// dialling, and how many of those are worth the slower speed test.
    ///
    /// The burst size is the important one. Dialling a dozen links at a debrid
    /// host in one go is a burst it answers by rate-limiting all of them — the
    /// list then reads "Timed out" from top to bottom while every one of those
    /// sources would have played. A few at a time gets answers instead.
    private static let dialBatch = 4
    private static let enoughReachable = 4
    private static let measureLimit = 3

    /// The whole audition is worth this much of the viewer's time and no more.
    /// When it runs out, whatever has been measured so far decides — an
    /// unmeasured candidate still has its claim and its first-byte time, which
    /// is enough to rank it. Nothing here can hold up the picture longer than
    /// this plus the time to open the winner.
    private static let deadline: Double = 4

    /// The audition's full ranking, best first, including the winner. The
    /// player takes the tail of this as its fallback queue, so a source that
    /// dies has somewhere to go without asking the viewer.
    @Published private(set) var ranking: [Stream] = []

    private var job: Task<Void, Never>?

    var isRunning: Bool {
        switch status {
        case .reaching, .measuring: true
        default: false
        }
    }

    func probe(for stream: Stream) -> StreamProbe? { probes[stream.id] }

    /// Whether the list has anything to say about the audition at the moment.
    var showsBanner: Bool {
        switch status {
        case .reaching, .measuring, .noneUsable: true
        default: false
        }
    }

    /// Runs the whole audition, then hands back the winner.
    func start(streams: [Stream], onChoice: @escaping (Stream) -> Void) {
        job?.cancel()
        probes = [:]
        ranking = []

        // Every playable result is a candidate, in the order the list ranks
        // them by their own claims — not just the first handful. A list whose
        // first dozen rows are one dead release is exactly the list that used
        // to end in "none of these answered" while a working source sat at
        // number thirteen.
        let candidates = Self.deduplicated(streams.filter(\.isPlayable))
            .sorted { Self.claimScore($0) > Self.claimScore($1) }
        guard !candidates.isEmpty else {
            status = .noneUsable
            return
        }

        status = .reaching(done: 0, total: candidates.count)

        job = Task { [weak self] in
            // Unwrapped once, for the whole audition. The task is cancelled
            // whenever the selector starts again or is asked to stop, so the
            // reference lives no longer than the work does.
            guard let selector = self else { return }
            let prober = StreamProber()
            let expiry = Date().addingTimeInterval(Self.deadline)

            // Pass one: who answers. A few at a time, best claims first, and
            // only until enough of them have answered — so a list of two
            // hundred rows costs the same wait as a list of eight.
            var done = 0
            var reachable: [Stream] = []

            for batch in candidates.chunks(of: Self.dialBatch) {
                guard !Task.isCancelled else { return }
                if reachable.count >= Self.enoughReachable || Date() >= expiry { break }

                await withTaskGroup(of: (String, StreamProbe).self) { group in
                    for stream in batch {
                        let id = stream.id
                        guard let url = stream.playbackURL else {
                            // A debrid row has no address to dial yet: it is
                            // minted when it is played. Unmeasurable is not the
                            // same as dead, so it stands on its claim rather
                            // than being dropped from the audition entirely —
                            // which is what used to leave a debrid-only list
                            // with no winner.
                            group.addTask { (id, StreamProbe(verdict: .reachable)) }
                            continue
                        }
                        let headers = stream.behaviorHints.requestHeaders
                        group.addTask { (id, await prober.reach(url: url, headers: headers)) }
                    }

                    for await (id, probe) in group {
                        guard !Task.isCancelled else { return }
                        done += 1
                        selector.probes[id] = probe
                        selector.status = .reaching(done: done, total: candidates.count)
                    }
                }

                guard !Task.isCancelled else { return }
                reachable = candidates.filter { selector.probes[$0.id]?.isReachable == true }
            }

            guard !Task.isCancelled else { return }

            // Nothing answered is not the same as nothing works. A host that
            // rate-limits a probe still serves a player, so rather than
            // stopping at a wall of "none of these answered", the best source
            // that was never actually refused is opened — and if it turns out
            // to be wrong, the player falls through the rest of the ranking.
            let contenders = reachable.isEmpty
                ? candidates.filter { selector.probes[$0.id]?.isWorthTrying ?? true }
                : reachable
            guard !contenders.isEmpty else {
                selector.status = .noneUsable
                return
            }

            // Pass two: how fast, for the ones whose claims are worth testing.
            // Only the ones that actually answered are worth timing; timing a
            // source that never replied just spends the deadline twice.
            let shortlist = reachable
                .sorted { Self.claimScore($0) > Self.claimScore($1) }
                .prefix(Self.measureLimit)

            for stream in shortlist {
                // Out of time is not a failure: an unmeasured candidate still
                // ranks on its claim and its first-byte time. Better to open
                // the picture on a good-enough answer than to keep a viewer
                // waiting for a perfect one.
                guard !Task.isCancelled, Date() < expiry, let url = stream.playbackURL else { break }
                selector.status = .measuring(name: stream.headline)
                let megabits = await prober.measureThroughput(
                    url: url,
                    headers: stream.behaviorHints.requestHeaders
                )
                guard !Task.isCancelled else { return }
                selector.probes[stream.id]?.megabitsPerSecond = megabits
            }

            guard !Task.isCancelled else { return }

            // Ranked rather than just maximised, because everything below the
            // winner is the queue the player falls back through when the
            // winner dies mid-film.
            let ordered = contenders.sorted { selector.finalScore(for: $0) > selector.finalScore(for: $1) }
            guard let winner = ordered.first else {
                selector.status = .noneUsable
                return
            }

            selector.ranking = ordered
            selector.status = .chose(winner)
            onChoice(winner)
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        if isRunning { status = .cancelled }
    }

    /// One row per actual source.
    ///
    /// Addons repeat themselves — the same file behind the same address, listed
    /// once per tracker, per proxy, or per cache that has it. Dialling each
    /// copy asks the same host the same question several times over, which is
    /// both the slowest way to fill the list and the fastest way to be
    /// rate-limited by it.
    static func deduplicated(_ streams: [Stream]) -> [Stream] {
        var seen = Set<String>()
        return streams.filter { stream in
            let key = stream.playbackURL?.absoluteString
                ?? stream.infoHash?.lowercased()
                ?? "\(stream.addonName)|\(stream.headline)|\(stream.detailLine ?? "")"
            return seen.insert(key).inserted
        }
    }

    /// What the result claims about itself, before anything has been dialled.
    private static func claimScore(_ stream: Stream) -> Double {
        Double(stream.advertisedQuality.desirability) * 100
            + stream.qualityBonus
            - stream.qualityPenalty
    }

    /// The claim, corrected by what the test found. Preference leads — 1080p
    /// SDR over a heavier picture, not the most pixels going — but a source
    /// that can't sustain its own bitrate is still marked down to the quality
    /// it can actually carry, and a slow first byte breaks ties.
    private func finalScore(for stream: Stream) -> Double {
        guard let probe = probes[stream.id], probe.isWorthTrying else { return -.infinity }

        let claimed = stream.advertisedQuality
        var effective = claimed

        if let megabits = probe.megabitsPerSecond {
            // Demote until the measured line can actually feed the picture.
            while effective.rawValue > StreamQuality.sd.rawValue,
                  megabits < effective.sustainedMegabits,
                  let lower = StreamQuality(rawValue: effective.rawValue - 1) {
                effective = lower
            }
        }

        // Demotion above walks the pixel ladder, because that is what a slow
        // line actually costs you; the score is taken from how much the app
        // wants the rung it ended on.
        //
        // Never more than the claim was worth, though. Demotion moves *down*
        // the pixel ladder and 4K sits at the bottom of the preference order,
        // so without this floor a 4K source on a line too slow to carry it
        // would be marked down into 1080p and come out the most desirable
        // thing on the list — while still being the 4K file that made the
        // player fall over.
        var score = Double(min(effective.desirability, claimed.desirability)) * 100
        score += stream.qualityBonus
        score -= stream.qualityPenalty

        // Untested sources sit just below tested ones of the same quality, so
        // a measured winner is preferred to an unmeasured maybe.
        if let megabits = probe.megabitsPerSecond {
            score += min(megabits, 60) / 4
        } else {
            score -= 1
        }

        // And a source that answered is preferred to one that never did,
        // whatever either of them claims.
        if !probe.isReachable { score -= 50 }

        if let seconds = probe.responseSeconds {
            score -= min(seconds, 8) * 2
        }

        return score
    }
}


extension Array {
    /// Walks the array in fixed-size groups, so a burst of network calls can be
    /// let out a few at a time instead of all at once.
    fileprivate func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
