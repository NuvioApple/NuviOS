import Foundation

// MARK: - Wire models

/// `start_tv_login_session` returns a single-row array.
struct TVLoginStart: Decodable {
    let code: String
    let webURL: String
    let expiresAt: String
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case code
        case webURL = "web_url"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        webURL = try c.decode(String.self, forKey: .webURL)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 3
    }
}

/// Terminal and non-terminal states of `poll_tv_login_session`.
enum TVLoginStatus: String {
    case pending
    case approved
    case expired
    case used
    case cancelled

    var isTerminalFailure: Bool {
        switch self {
        case .expired, .used, .cancelled: true
        case .pending, .approved: false
        }
    }
}

struct TVLoginPoll: Decodable {
    let status: String
    let pollIntervalSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case pollIntervalSeconds = "poll_interval_seconds"
    }
}

/// `start_device_login_session` — the mobile counterpart of the TV flow. The
/// user types the short `user_code`; polling and exchange use `device_code`.
struct DeviceLinkStart: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURIComplete: String
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURIComplete = "verification_uri_complete"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try c.decode(String.self, forKey: .deviceCode)
        userCode = try c.decode(String.self, forKey: .userCode)
        verificationURIComplete = try c.decode(String.self, forKey: .verificationURIComplete)
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 3
    }
}

struct TVLoginExchange: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case notConfigured
    case emptyResponse(String)
    case server(status: Int, body: String)
    case loginFailed(TVLoginStatus)
    case missingExpiry
    case credentials(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No backend configured yet."
        case .emptyResponse(let endpoint):
            "Empty response from \(endpoint)."
        case .server(let status, let body):
            "Server returned \(status): \(body)"
        case .loginFailed(let status):
            switch status {
            case .expired: "That sign-in code expired. Start again."
            case .used: "That sign-in code was already used."
            case .cancelled: "Sign-in was cancelled."
            default: "Sign-in failed."
            }
        case .missingExpiry:
            "Token response did not include a valid expires_in."
        case .credentials(let message):
            message
        }
    }
}

// MARK: - Client

/// Talks to the same endpoints as the Android `AuthManager`.
struct AuthClient {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    private var base: String {
        var s = configuration.backendURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    // MARK: TV login

    func startLogin(deviceNonce: String, deviceName: String?) async throws -> TVLoginStart {
        var params: [String: String] = [
            "p_device_nonce": deviceNonce,
            "p_redirect_base_url": configuration.tvLoginWebBaseURL
        ]
        if let deviceName, !deviceName.isEmpty {
            params["p_device_name"] = deviceName
        }

        do {
            return try await rpcRow("start_tv_login_session", params)
        } catch AuthError.server(let status, let body) where isLegacySignature(status, body) {
            // Older backends reject p_device_name; retry with the legacy shape.
            params.removeValue(forKey: "p_device_name")
            return try await rpcRow("start_tv_login_session", params)
        }
    }

    func pollLogin(code: String, deviceNonce: String) async throws -> TVLoginPoll {
        try await rpcRow("poll_tv_login_session", [
            "p_code": code,
            "p_device_nonce": deviceNonce
        ])
    }

    func exchangeLogin(code: String, deviceNonce: String) async throws -> AuthTokens {
        let body = try JSONEncoder().encode([
            "code": code,
            "device_nonce": deviceNonce
        ])
        let data = try await send(
            path: "/functions/v1/tv-logins-exchange",
            body: body,
            endpoint: "tv-logins-exchange"
        )
        let result = try JSONDecoder().decode(TVLoginExchange.self, from: data)
        return try tokens(from: result)
    }

    /// Mobile link sign-in. `p_device_type` is "mobile", matching NuvioMobile.
    func startDeviceLink(deviceNonce: String, deviceName: String) async throws -> DeviceLinkStart {
        try await rpcRow("start_device_login_session", [
            "p_device_nonce": deviceNonce,
            "p_redirect_base_url": configuration.deviceLinkWebBaseURL,
            "p_device_name": deviceName,
            "p_device_type": "mobile"
        ])
    }

    // MARK: Email + password

    func signIn(email: String, password: String) async throws -> AuthTokens {
        try await passwordGrant(
            path: "/auth/v1/token?grant_type=password",
            email: email,
            password: password
        )
    }

    func signUp(email: String, password: String) async throws -> AuthTokens {
        try await passwordGrant(path: "/auth/v1/signup", email: email, password: password)
    }

    private func passwordGrant(
        path: String,
        email: String,
        password: String
    ) async throws -> AuthTokens {
        let body = try JSONEncoder().encode(["email": email, "password": password])
        do {
            let data = try await send(path: path, body: body, endpoint: path)
            let result = try JSONDecoder().decode(TVLoginExchange.self, from: data)
            return try tokens(from: result)
        } catch AuthError.server(_, let raw) {
            // Supabase reports credential problems in the body, not the status.
            throw AuthError.credentials(Self.readableAuthMessage(raw))
        } catch AuthError.missingExpiry {
            // A sign-up that needs email confirmation returns a user, no session.
            throw AuthError.credentials(
                "Check your email to confirm your account, then sign in."
            )
        }
    }

    /// Pulls the human-readable message out of a Supabase auth error body.
    static func readableAuthMessage(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return raw.isEmpty ? "Sign-in failed." : raw }

        for key in ["error_description", "msg", "message", "error"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return "Sign-in failed."
    }

    // MARK: Session lifetime

    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        let body = try JSONEncoder().encode(["refresh_token": tokens.refreshToken])
        let data = try await send(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: body,
            endpoint: "token refresh"
        )
        let result = try JSONDecoder().decode(TVLoginExchange.self, from: data)
        return try self.tokens(from: result)
    }

    func currentUser(accessToken: String) async throws -> SupabaseUser {
        var request = URLRequest(url: URL(string: base + "/auth/v1/user")!)
        request.httpMethod = "GET"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(SupabaseUser.self, from: data)
    }

    func signOut(accessToken: String) async {
        var request = URLRequest(url: URL(string: base + "/auth/v1/logout")!)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        // Best effort: local tokens are cleared regardless of the outcome.
        _ = try? await session.data(for: request)
    }

    // MARK: Plumbing

    private func tokens(from result: TVLoginExchange) throws -> AuthTokens {
        guard let lifetime = result.expiresIn, lifetime > 0 else {
            throw AuthError.missingExpiry
        }
        return AuthTokens(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    /// The RPCs return a one-row array; unwrap it or report an empty response.
    private func rpcRow<T: Decodable>(_ function: String, _ params: [String: String]) async throws -> T {
        let body = try JSONEncoder().encode(params)
        let data = try await send(
            path: "/rest/v1/rpc/\(function)",
            body: body,
            endpoint: function
        )
        let rows = try JSONDecoder().decode([T].self, from: data)
        guard let first = rows.first else { throw AuthError.emptyResponse(function) }
        return first
    }

    private func send(path: String, body: Data, endpoint: String) async throws -> Data {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue(
            "Bearer \(configuration.publishableKey)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }

    private func isLegacySignature(_ status: Int, _ body: String) -> Bool {
        status == 404 && body.contains("start_tv_login_session")
    }
}
