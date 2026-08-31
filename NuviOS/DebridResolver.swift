import Foundation

/// Asks a debrid service for a download, and hands back an address minted a
/// moment ago rather than one somebody else was given an hour ago.
///
/// Both services take the same three steps under different names: hand over the
/// magnet, read back what is inside it, then ask for a link to the one file
/// being played. Both are asked with the account's own key — see
/// `DebridCredentials` — and both are asked at the moment of playing, never in
/// advance, because an address minted early is an address already ageing.
enum DebridResolver {
    /// Mints a playable address for `resolve`, or explains why it couldn't.
    static func resolve(
        _ resolve: StreamClientResolve,
        season: Int?,
        episode: Int?
    ) async -> DebridResolveResult {
        guard resolve.isResolvable, let service = resolve.debridService else { return .unavailable }
        guard let key = await DebridCredentials.shared.key(for: service) else { return .missingKey }
        guard let magnet = resolve.magnet else { return .unavailable }

        switch service {
        case .realDebrid:
            return await RealDebridResolver.resolve(resolve, magnet: magnet, key: key, season: season, episode: episode)
        case .torbox:
            return await TorboxResolver.resolve(resolve, magnet: magnet, key: key, season: season, episode: episode)
        }
    }

    /// A service is asked at most this long for one step. Generous next to the
    /// link check, because this is the request that produces the picture — but
    /// bounded, because a viewer is watching a spinner throughout.
    static let stepTimeout: Double = 20

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = stepTimeout
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// One request, decoded. Returns the status alongside the body so each
    /// service can read its own meaning into a code.
    static func send<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type
    ) async -> (status: Int, value: T?) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, try? JSONDecoder().decode(T.self, from: data))
        } catch {
            return (0, nil)
        }
    }

    /// A request with no body worth decoding.
    @discardableResult
    static func send(_ request: URLRequest) async -> Int {
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }

    static func form(_ fields: [String: String]) -> Data {
        fields
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Real-Debrid

/// `https://api.real-debrid.com/rest/1.0/`, keyed by a bearer token.
///
/// Four steps, and the last one is the point: `unrestrict/link` turns the
/// account's copy of the file into a download address, and does so afresh every
/// time it is called. The torrent added along the way is deleted again unless
/// the walk succeeded, so a failed attempt leaves nothing behind in the
/// account's torrent list.
enum RealDebridResolver {
    private static let base = "https://api.real-debrid.com/rest/1.0"

    static func resolve(
        _ resolve: StreamClientResolve,
        magnet: String,
        key: String,
        season: Int?,
        episode: Int?
    ) async -> DebridResolveResult {
        let added = await DebridResolver.send(
            post("torrents/addMagnet", key: key, fields: ["magnet": magnet]),
            as: AddTorrent.self
        )
        guard let torrentID = added.value?.id?.nilWhenEmpty, (200..<300).contains(added.status) else {
            return added.status == 401 || added.status == 403 ? .failed : .unavailable
        }

        var succeeded = false
        defer {
            if !succeeded {
                Task { await DebridResolver.send(delete("torrents/delete/\(torrentID)", key: key)) }
            }
        }

        let before = await DebridResolver.send(get("torrents/info/\(torrentID)", key: key), as: TorrentInfo.self)
        guard let files = before.value?.files, !files.isEmpty else { return .unavailable }

        guard let file = DebridFileSelection.select(
            from: files.map { DebridFile(id: $0.id, name: $0.displayName, bytes: $0.bytes ?? 0, isVideo: nil) },
            resolve: resolve,
            season: season,
            episode: episode
        ), let fileID = file.id else { return .unavailable }

        // 202 means the selection was accepted and is being acted on, which is
        // as good as 200 here.
        let selected = await DebridResolver.send(
            post("torrents/selectFiles/\(torrentID)", key: key, fields: ["files": String(fileID)])
        )
        guard (200..<300).contains(selected) || selected == 202 else { return .unavailable }

        let after = await DebridResolver.send(get("torrents/info/\(torrentID)", key: key), as: TorrentInfo.self)
        // Anything short of `downloaded` means the account does not actually
        // hold this yet, whatever the addon advertised.
        guard after.value?.status?.lowercased() == "downloaded" else { return .notCached }
        guard let link = after.value?.links?.first(where: { !$0.isEmpty }) else { return .unavailable }

        let unrestricted = await DebridResolver.send(
            post("unrestrict/link", key: key, fields: ["link": link]),
            as: Unrestricted.self
        )
        guard let download = unrestricted.value?.download?.nilWhenEmpty,
              let url = URL(string: download) else { return .unavailable }

        succeeded = true
        return .resolved(url: url, filename: unrestricted.value?.filename?.nilWhenEmpty ?? file.name)
    }

    private static func request(_ path: String, key: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func get(_ path: String, key: String) -> URLRequest {
        request(path, key: key, method: "GET")
    }

    private static func delete(_ path: String, key: String) -> URLRequest {
        request(path, key: key, method: "DELETE")
    }

    private static func post(_ path: String, key: String, fields: [String: String]) -> URLRequest {
        var request = self.request(path, key: key, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = DebridResolver.form(fields)
        return request
    }

    private struct AddTorrent: Decodable {
        var id: String?
    }

    private struct TorrentInfo: Decodable {
        var status: String?
        var files: [File]?
        var links: [String]?

        struct File: Decodable {
            var id: Int?
            var path: String?
            var bytes: Int64?

            /// The path is relative to the torrent root, so the name is its
            /// last component.
            var displayName: String {
                let path = path ?? ""
                return path.split(separator: "/").last.map(String.init) ?? path
            }
        }
    }

    private struct Unrestricted: Decodable {
        var filename: String?
        var filesize: Int64?
        var download: String?
    }
}

// MARK: - Torbox

/// `https://api.torbox.app/`, keyed by a bearer token that is also passed as a
/// query parameter on the download request — the API wants it both ways.
///
/// `add_only_if_cached` is what keeps this honest: rather than starting a
/// download the viewer would wait out, a torrent the account doesn't already
/// hold is refused outright with a 409, and the player moves on to another
/// source.
enum TorboxResolver {
    private static let base = "https://api.torbox.app"

    static func resolve(
        _ resolve: StreamClientResolve,
        magnet: String,
        key: String,
        season: Int?,
        episode: Int?
    ) async -> DebridResolveResult {
        let created = await DebridResolver.send(
            createTorrent(magnet: magnet, key: key),
            as: Envelope<CreateData>.self
        )
        if created.status == 409 { return .notCached }
        if created.status == 401 || created.status == 403 { return .failed }
        guard (200..<300).contains(created.status),
              created.value?.success != false,
              let torrentID = created.value?.data?.resolvedID else {
            return .unavailable
        }

        let torrent = await DebridResolver.send(
            get("v1/api/torrents/mylist", key: key, query: [
                URLQueryItem(name: "id", value: String(torrentID)),
                URLQueryItem(name: "bypass_cache", value: "true")
            ]),
            as: Envelope<TorrentData>.self
        )
        let files = torrent.value?.data?.files ?? []
        guard !files.isEmpty else { return .unavailable }

        guard let file = DebridFileSelection.select(
            from: files.map {
                DebridFile(
                    id: $0.id,
                    name: $0.displayName,
                    bytes: $0.size ?? 0,
                    isVideo: $0.mimeType?.lowercased().hasPrefix("video/")
                )
            },
            resolve: resolve,
            season: season,
            episode: episode
        ), let fileID = file.id else { return .unavailable }

        let link = await DebridResolver.send(
            get("v1/api/torrents/requestdl", key: key, query: [
                URLQueryItem(name: "token", value: key),
                URLQueryItem(name: "torrent_id", value: String(torrentID)),
                URLQueryItem(name: "file_id", value: String(fileID)),
                URLQueryItem(name: "zip_link", value: "false"),
                URLQueryItem(name: "redirect", value: "false"),
                URLQueryItem(name: "append_name", value: "false")
            ]),
            as: Envelope<String>.self
        )
        guard let address = link.value?.data?.nilWhenEmpty, let url = URL(string: address) else {
            return .unavailable
        }
        return .resolved(url: url, filename: file.name)
    }

    private static func get(_ path: String, key: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(string: "\(base)/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The create endpoint takes multipart form data, which is three fields and
    /// a boundary rather than a dependency.
    private static func createTorrent(magnet: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(base)/v1/api/torrents/createtorrent")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let boundary = "nuvio.\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = ""
        for (field, value) in [
            ("magnet", magnet),
            ("add_only_if_cached", "true"),
            ("allow_zip", "false")
        ] {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"\(field)\"\r\n\r\n"
            body += "\(value)\r\n"
        }
        body += "--\(boundary)--\r\n"
        request.httpBody = body.data(using: .utf8)
        return request
    }

    /// Every Torbox response is wrapped like this.
    private struct Envelope<T: Decodable>: Decodable {
        var success: Bool?
        var data: T?
        var error: String?
    }

    private struct CreateData: Decodable {
        var torrentID: Int?
        var id: Int?

        enum CodingKeys: String, CodingKey {
            case torrentID = "torrent_id"
            case id
        }

        var resolvedID: Int? { torrentID ?? id }
    }

    private struct TorrentData: Decodable {
        var id: Int?
        var name: String?
        var files: [File]?

        struct File: Decodable {
            var id: Int?
            var name: String?
            var shortName: String?
            var mimeType: String?
            var size: Int64?

            enum CodingKeys: String, CodingKey {
                case id, name, size
                case shortName = "short_name"
                case mimeType = "mimetype"
            }

            var displayName: String {
                shortName?.nilWhenEmpty
                    ?? name?.split(separator: "/").last.map(String.init)
                    ?? ""
            }
        }
    }
}
