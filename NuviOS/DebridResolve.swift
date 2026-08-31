import Foundation

// Asking the debrid service for the download, rather than reusing an address
// somebody else asked for.
//
// Addons answer a `/stream/` request in one of two shapes. The plain shape
// carries a `url`, already minted, already ageing — and by the time a viewer
// has read the list and pressed a row, it may well be spent. The other shape
// carries no address at all: a `clientResolve` block naming the debrid service
// and the torrent, on the understanding that the client will ask for the
// download itself, at the moment of playing.
//
// The second shape is the one that can't go stale. A resolve mints a fresh
// address on every call, so an expired link stops being something to recover
// from and becomes something that cannot happen. This file models the block;
// `RealDebridResolver` and `TorboxResolver` do the asking.

/// The addon's instructions for minting a playable address.
///
/// Only the fields the two supported services need are read; the block carries
/// a good deal more that neither asks for.
struct StreamClientResolve: Decodable, Equatable, Sendable {
    /// `debrid` for the resolve this file performs.
    var type: String?
    /// Which service to ask — `realdebrid` or `torbox`.
    var service: String?
    var infoHash: String?
    var magnetUri: String?
    /// Which file inside the torrent, when the addon knows.
    var fileIdx: Int?
    var sources: [String]?
    var torrentName: String?
    var filename: String?
    var season: Int?
    var episode: Int?
    /// The addon's claim that the service already holds this. A resolve of
    /// something uncached would mean waiting on a download, which is not what
    /// pressing play asks for.
    var isCached: Bool?

    var debridService: DebridService? {
        DebridService(rawValue: service?.trimmed.lowercased() ?? "")
    }

    /// Whether this block is one the app can act on: a cached torrent, on a
    /// service it can speak to.
    var isResolvable: Bool {
        type?.lowercased() == "debrid" && debridService != nil && isCached == true
    }

    /// The magnet to hand the service, built from the hash when the addon
    /// didn't spell one out.
    var magnet: String? {
        if let magnetUri, !magnetUri.isEmpty { return magnetUri }
        guard let hash = infoHash?.trimmed, !hash.isEmpty else { return nil }
        var magnet = "magnet:?xt=urn:btih:\(hash)"
        for source in sources ?? [] where !source.isEmpty {
            let escaped = source.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? source
            magnet += "&tr=\(escaped)"
        }
        return magnet
    }
}

/// The services this client can ask for a download. The ids are the addon's
/// own spelling, matching the Android client's `DebridProviders`.
enum DebridService: String, CaseIterable, Sendable {
    case realDebrid = "realdebrid"
    case torbox

    var displayName: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .torbox: "Torbox"
        }
    }

    /// The key this service's credential is filed under in the account, as the
    /// Android client writes it.
    var credentialProvider: String { "debrid:\(rawValue)" }
}

/// What came back from asking.
enum DebridResolveResult: Equatable, Sendable {
    case resolved(url: URL, filename: String?)
    /// No key for this service on the account.
    case missingKey
    /// The service doesn't hold this after all, whatever the addon claimed.
    case notCached
    /// The service answered, but with nothing playable — an incomplete
    /// torrent, no video inside, a file list that doesn't match the episode.
    case unavailable
    /// The ask itself failed: network, or a rejected key.
    case failed

    var url: URL? {
        if case .resolved(let url, _) = self { return url }
        return nil
    }
}

// MARK: - Which file inside the torrent

/// One file as either service describes it, so the picking below is written
/// once rather than twice.
struct DebridFile: Sendable {
    let id: Int?
    let name: String
    let bytes: Int64
    /// Torbox says so outright; Real-Debrid leaves it to the extension.
    let isVideo: Bool?
}

/// Picks the file to play out of a torrent's contents.
///
/// A season pack is the case that matters: the torrent holds a dozen episodes
/// and only one of them is the one being played. The order is the Android
/// client's, which is ordered by how much each signal is worth — the addon's
/// own filename first, then the episode number, then the index it gave, then
/// simply the largest video, which is right far more often than it is wrong.
enum DebridFileSelection {
    static func select(
        from files: [DebridFile],
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?
    ) -> DebridFile? {
        let playable = files.filter(isPlayableVideo)
        guard !playable.isEmpty else { return nil }

        let patterns = episodePatterns(season: season ?? resolve.season, episode: episode ?? resolve.episode)

        let names = specificNames(resolve: resolve, patterns: patterns)
        if !names.isEmpty,
           let match = playable.first(where: { file in
               let normalized = normalize(file.name)
               return names.contains { $0.contains(normalized) || normalized.contains($0) }
           }) {
            return match
        }

        if !patterns.isEmpty,
           let match = playable.first(where: { file in
               let lower = file.name.lowercased()
               return patterns.contains { lower.contains($0) }
           }) {
            return match
        }

        if let index = resolve.fileIdx {
            // The index counts every file in the torrent, not just the videos —
            // and some addons count from one where the service counts from zero.
            if let file = files[safe: index], isPlayableVideo(file) { return file }
            if index > 0, let file = files[safe: index - 1], isPlayableVideo(file) { return file }
            if let file = playable.first(where: { $0.id == index }) { return file }
        }

        return playable.max { $0.bytes < $1.bytes }
    }

    static func isPlayableVideo(_ file: DebridFile) -> Bool {
        if file.isVideo == true { return true }
        return hasVideoExtension(file.name.lowercased())
    }

    /// `s01e04`, and the two `1x04` spellings release names also use.
    static func episodePatterns(season: Int?, episode: Int?) -> [String] {
        guard let season, let episode else { return [] }
        let s = String(format: "%02d", season)
        let e = String(format: "%02d", episode)
        return ["s\(s)e\(e)", "\(season)x\(e)", "\(season)x\(episode)"]
    }

    /// The names worth matching against, normalised.
    ///
    /// A torrent name is only usable when it names one episode rather than the
    /// pack — otherwise every file in a season pack matches it equally.
    static func specificNames(resolve: StreamClientResolve, patterns: [String]) -> [String] {
        [
            resolve.filename,
            resolve.torrentName.flatMap { looksSpecific($0, patterns: patterns) ? $0 : nil }
        ]
        .compactMap { $0 }
        .map(normalize)
        .filter { !$0.isEmpty }
    }

    private static func looksSpecific(_ value: String, patterns: [String]) -> Bool {
        let lower = value.lowercased()
        return hasVideoExtension(lower) || patterns.contains { lower.contains($0) }
    }

    /// Strips the path, the extension and every separator, so
    /// `Show.S01E04.1080p-GRP.mkv` and `Show S01E04 1080p GRP` are the same
    /// name written twice.
    static func normalize(_ value: String) -> String {
        let base = value.split(separator: "/").last.map(String.init) ?? value
        let withoutExtension = base.contains(".")
            ? String(base[base.startIndex..<(base.lastIndex(of: ".") ?? base.endIndex)])
            : base
        let flattened = withoutExtension.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(flattened).split(separator: " ").joined(separator: " ")
    }

    static func hasVideoExtension(_ lowercasedName: String) -> Bool {
        videoExtensions.contains { lowercasedName.hasSuffix($0) }
    }

    private static let videoExtensions = [
        ".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4v", ".ts", ".m2ts", ".wmv", ".flv"
    ]
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
