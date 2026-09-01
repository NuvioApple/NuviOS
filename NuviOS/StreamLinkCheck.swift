import Foundation

// Is the address still good?
//
// Addon results are signed, short-lived links. The one that was alive when the
// list was drawn is often dead by the time it is played: a debrid token
// expires, the audition's verdict goes stale while the viewer reads the rows,
// or a resume from the library replays an address minted an hour ago. libvlc
// cannot tell the difference between an expired link and a slow one — it takes
// whatever the host sends, so an expired link either errors with nothing to say
// or sits on the spinner until the twelve-second watchdog gives up.
//
// So the address is dialled before the engine is pointed at it, and the host's
// own answer is used: a link the provider has disowned is skipped immediately
// for the next source, and the viewer is told what actually happened rather
// than being read a list of things it might have been.

/// Addresses this launch has already had a good answer from.
///
/// A source is dialled by the audition, then dialled again by the link check
/// before it opens — the same question to the same host inside a few seconds,
/// which costs a round trip before the picture and is one more request for a
/// host that rate-limits to count against you. An address the audition just
/// found alive does not need asking twice.
actor StreamProbeLedger {
    static let shared = StreamProbeLedger()

    private var answeredAt: [String: Date] = [:]

    /// Short: this says "alive a moment ago", not "alive". A signed link can
    /// lapse in minutes, so anything older than this is asked again.
    private static let freshness: TimeInterval = 90

    func record(_ url: URL) {
        answeredAt[url.absoluteString] = Date()
    }

    func answeredRecently(_ url: URL) -> Bool {
        guard let at = answeredAt[url.absoluteString] else { return false }
        guard Date().timeIntervalSince(at) < Self.freshness else {
            answeredAt[url.absoluteString] = nil
            return false
        }
        return true
    }
}

/// What dialling an address said about the link itself.
enum StreamLinkCheck: Equatable, Sendable {
    /// The host served the request.
    case ok
    /// The host no longer honours this link — a lapsed signature or token.
    case expired
    /// The host has the link but not the file behind it.
    case gone
    /// No verdict: a timeout, a server fault, an address that can't be dialled
    /// this way. Play it — this check exists to catch the certain cases, not to
    /// stand between the viewer and a source it isn't sure about.
    case unknown

    /// Whether the source should be opened at all.
    var isPlayable: Bool { self == .ok || self == .unknown }

    /// What to tell the viewer once every source has been tried.
    var failureMessage: String? {
        switch self {
        case .ok, .unknown: nil
        case .expired: "This link expired, and asking the addons again didn't produce a live one. Try another source."
        case .gone: "This link is gone, and asking the addons again didn't produce another. Try another source."
        }
    }

    /// Reads the host's answer.
    ///
    /// 401, 403 and 410 all mean the same thing from a debrid host: the
    /// signature on the address is no longer honoured. 404 means the file
    /// behind it went away. Everything else is left alone on purpose — 405 and
    /// 416 are refusals of the *probe*, 429 is a busy host, 5xx is a host
    /// having a bad minute, and none of the three says the link is spent.
    static func verdict(forStatus status: Int) -> StreamLinkCheck {
        switch status {
        case 200..<400: .ok
        case 401, 403, 410: .expired
        case 404: .gone
        default: .unknown
        }
    }

    /// True when an address is worth dialling: a remote http(s) link. A local
    /// file, or a scheme this can't speak, has no signature to lapse.
    static func canCheck(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return !isLocal(host)
    }

    /// Addresses on the machine or the home network — a local media server —
    /// which are neither signed nor worth the wait.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172."),
           let second = Int(host.split(separator: ".").dropFirst().first ?? ""),
           (16...31).contains(second) {
            return true
        }
        return false
    }

    /// Dials `url` and reports what the host said. Never throws: anything that
    /// isn't a clear answer comes back `.unknown` and plays as before.
    ///
    /// A one-byte range request rather than a HEAD, because debrid hosts
    /// routinely refuse HEAD on links that serve perfectly well — the same
    /// request `StreamProber` uses to audition a source.
    static func verify(
        url: URL,
        headers: [String: String],
        timeout: Double = timeoutSeconds
    ) async -> StreamLinkCheck {
        guard canCheck(url) else { return .unknown }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            // The body is not wanted; dropping the iterator ends the transfer.
            _ = bytes
            guard let http = response as? HTTPURLResponse else { return .unknown }
            return verdict(forStatus: http.statusCode)
        } catch {
            return .unknown
        }
    }

    /// Short on purpose: this runs before the first frame, and a host that
    /// needs longer than this to answer at all is a failover's problem, not
    /// this check's.
    static let timeoutSeconds: Double = 4

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()
}
