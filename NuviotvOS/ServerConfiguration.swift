import Foundation

struct ServerCapabilities: Codable, Equatable {
    var emailPasswordAuth: Bool
    var tvLogin: Bool
}

/// Backend coordinates for a Nuvio deployment. Everything here is discovered
/// from the server's `/.well-known/nuvio` document, so no keys are baked in.
struct ServerConfiguration: Codable, Equatable {
    var backendURL: String
    var publishableKey: String
    var capabilities: ServerCapabilities
    var isCustom: Bool
    var tvLoginWebBaseURL: String
    var deviceLinkWebBaseURL: String

    /// The Nuvio-hosted backend, used unless the user points at their own.
    static let officialBackendURL = "https://api.nuvio.tv"

    /// Official deployments send TV users to nuvio.tv; self-hosted ones serve
    /// the page from the backend itself, matching Android's discovery parse.
    static func tvLoginBase(for backendURL: String, isCustom: Bool) -> String {
        isCustom ? "\(backendURL)/tv-login" : "https://nuvio.tv/tv-login"
    }

    /// Where the phone sends the user to approve a link code.
    static func deviceLinkBase(for backendURL: String, isCustom: Bool) -> String {
        isCustom ? "\(backendURL)/link" : "https://nuvio.tv/link"
    }
}

// MARK: - Discovery

enum ServerDiscoveryFailure: LocalizedError, Equatable {
    case invalidURL
    case connectionFailed
    case httpError(Int)
    case responseTooLarge
    case invalidDocument
    case unsupportedVersion
    case wrongService
    case missingConfiguration
    case noSupportedAuth

    var errorDescription: String? {
        switch self {
        case .invalidURL: "That doesn't look like a valid server address."
        case .connectionFailed: "Couldn't reach that server."
        case .httpError(let code): "The server responded with \(code)."
        case .responseTooLarge: "The server's response was too large."
        case .invalidDocument: "That server didn't return a Nuvio configuration."
        case .unsupportedVersion: "That server uses an unsupported configuration version."
        case .wrongService: "That address isn't a Nuvio server."
        case .missingConfiguration: "That server's configuration is incomplete."
        case .noSupportedAuth: "That server has no supported sign-in method."
        }
    }
}

private struct DiscoveryDocument: Decodable {
    let version: Int
    let service: String
    let selfHosted: Bool
    let backendURL: String
    let publishableKey: String
    let capabilities: Capabilities

    struct Capabilities: Decodable {
        var emailPasswordAuth: Bool = false
        var tvLogin: Bool = false

        enum CodingKeys: String, CodingKey {
            case emailPasswordAuth = "email_password_auth"
            case tvLogin = "tv_login"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            emailPasswordAuth = try c.decodeIfPresent(Bool.self, forKey: .emailPasswordAuth) ?? false
            tvLogin = try c.decodeIfPresent(Bool.self, forKey: .tvLogin) ?? false
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, service, capabilities
        case selfHosted = "self_hosted"
        case backendURL = "backend_url"
        case publishableKey = "publishable_key"
    }
}

enum ServerDiscovery {
    private static let maxDocumentBytes = 64 * 1024

    /// Turns a user-typed address into its `/.well-known/nuvio` URL, defaulting
    /// to https and stripping any credentials, query, or fragment.
    static func discoveryURL(for input: String) throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerDiscoveryFailure.invalidURL }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil
        else { throw ServerDiscoveryFailure.invalidURL }

        let suffix = "/.well-known/nuvio"
        var base = components.path
        if base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        while base.hasSuffix("/") { base.removeLast() }

        components.path = base.isEmpty ? suffix : base + suffix
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { throw ServerDiscoveryFailure.invalidURL }
        return url
    }

    static func discover(
        _ input: String,
        session: URLSession = .shared
    ) async throws -> ServerConfiguration {
        let url = try discoveryURL(for: input)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServerDiscoveryFailure.connectionFailed
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServerDiscoveryFailure.httpError(http.statusCode)
        }
        // Reject an https address that got downgraded somewhere in the chain.
        if url.scheme == "https", response.url?.scheme != "https" {
            throw ServerDiscoveryFailure.connectionFailed
        }
        guard data.count <= maxDocumentBytes else {
            throw ServerDiscoveryFailure.responseTooLarge
        }
        return try parse(data, requestedURL: url)
    }

    static func parse(_ data: Data, requestedURL: URL) throws -> ServerConfiguration {
        guard let document = try? JSONDecoder().decode(DiscoveryDocument.self, from: data) else {
            throw ServerDiscoveryFailure.invalidDocument
        }
        guard document.version == 1 else { throw ServerDiscoveryFailure.unsupportedVersion }
        guard document.service.caseInsensitiveCompare("nuvio") == .orderedSame else {
            throw ServerDiscoveryFailure.wrongService
        }

        let backend = try normalizeBackendURL(document.backendURL)
        let key = document.publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ServerDiscoveryFailure.missingConfiguration }
        guard document.capabilities.emailPasswordAuth || document.capabilities.tvLogin else {
            throw ServerDiscoveryFailure.noSupportedAuth
        }

        let isCustom = !matchesOfficial(backend)
        return ServerConfiguration(
            backendURL: backend,
            publishableKey: key,
            capabilities: ServerCapabilities(
                emailPasswordAuth: document.capabilities.emailPasswordAuth,
                tvLogin: document.capabilities.tvLogin
            ),
            isCustom: isCustom,
            tvLoginWebBaseURL: ServerConfiguration.tvLoginBase(
                for: backend,
                isCustom: isCustom
            ),
            deviceLinkWebBaseURL: ServerConfiguration.deviceLinkBase(
                for: backend,
                isCustom: isCustom
            )
        )
    }

    static func matchesOfficial(_ backendURL: String) -> Bool {
        guard let candidate = URLComponents(string: backendURL),
              let official = URLComponents(string: ServerConfiguration.officialBackendURL)
        else { return false }
        return candidate.host?.lowercased() == official.host?.lowercased()
            && candidate.port == official.port
    }

    private static func normalizeBackendURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { throw ServerDiscoveryFailure.missingConfiguration }

        var normalized = trimmed
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}

// MARK: - Persistence

/// Remembers the server the user last discovered so a self-hosted box sticks.
enum ServerConfigurationStore {
    private static let key = "server.configuration"

    static func load(defaults: UserDefaults = .standard) -> ServerConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: data)
    }

    static func save(_ configuration: ServerConfiguration, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
