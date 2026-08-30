import SwiftUI
import Combine

enum SessionState: Equatable {
    case signedOut
    case guest
    case signedIn(userID: String, email: String?)
}

/// Mobile link sign-in, mirroring NuvioMobile's DeviceLinkAuthState.
enum DeviceLinkState: Equatable {
    case idle
    case starting
    case waiting(code: String, verificationURL: String, isCompleting: Bool)
    case failed(String)
}

/// Live state of the QR / code sign-in flow.
enum LoginPhase: Equatable {
    case idle
    case starting
    case awaitingApproval(code: String, webURL: String)
    case exchanging
    case failed(String)
}

@MainActor
final class AppSession: ObservableObject {
    private static let modeKey = "session.mode"

    @Published private(set) var state: SessionState = .signedOut
    @Published private(set) var loginPhase: LoginPhase = .idle
    @Published private(set) var deviceLink: DeviceLinkState = .idle
    @Published private(set) var authError: String?
    @Published private(set) var isSubmitting = false

    /// nil until the backend's `/.well-known/nuvio` document has been read.
    @Published private(set) var configuration: ServerConfiguration?
    @Published private(set) var isDiscovering = false
    @Published private(set) var discoveryError: String?

    private let defaults: UserDefaults
    private var tokens: AuthTokens?
    private var loginTask: Task<Void, Never>?
    private var deviceLinkTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = ServerConfigurationStore.load(defaults: defaults)
    }

    var canSignIn: Bool { configuration?.capabilities.tvLogin == true }
    var canUseEmailPassword: Bool { configuration?.capabilities.emailPasswordAuth == true }

    var backendDisplayName: String {
        guard let configuration else { return ServerConfiguration.officialBackendURL }
        return configuration.backendURL
    }

    // MARK: Launch

    /// Discovers the backend (cached config first, then a refresh) and restores
    /// any stored session on top of it.
    func start() async {
        if configuration == nil {
            await discover(ServerConfiguration.officialBackendURL)
        }
        await restoreSession()
    }

    /// Points the app at a backend — the official one or a self-hosted address.
    @discardableResult
    func discover(_ address: String) async -> Bool {
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }

        do {
            let discovered = try await ServerDiscovery.discover(address)
            configuration = discovered
            ServerConfigurationStore.save(discovered, defaults: defaults)
            return true
        } catch {
            discoveryError = error.localizedDescription
            return false
        }
    }

    /// Switches backends. Any session belongs to the old server, so it is dropped.
    func useServer(_ address: String) async -> Bool {
        let previous = configuration
        guard await discover(address) else { return false }
        if previous?.backendURL != configuration?.backendURL {
            clearLocalSession()
        }
        return true
    }

    private func restoreSession() async {
        if let stored = TokenStore.load(), let client = client() {
            var live = stored
            if live.needsRefresh {
                guard let refreshed = try? await client.refresh(live) else {
                    TokenStore.clear()
                    applyGuestFlagOrSignedOut()
                    return
                }
                live = refreshed
                TokenStore.save(live)
            }
            tokens = live
            if let user = try? await client.currentUser(accessToken: live.accessToken) {
                state = .signedIn(userID: user.id, email: user.email)
                defaults.set("signedIn", forKey: Self.modeKey)
                return
            }
            TokenStore.clear()
        }
        applyGuestFlagOrSignedOut()
    }

    private func applyGuestFlagOrSignedOut() {
        state = defaults.string(forKey: Self.modeKey) == "guest" ? .guest : .signedOut
    }

    // MARK: Guest

    func continueAsGuest() {
        defaults.set("guest", forKey: Self.modeKey)
        state = .guest
    }

    // MARK: Sign in

    /// Runs the whole start → poll → exchange sequence. Cancel with `cancelLogin()`.
    func startLogin(deviceName: String? = nil) {
        guard let client = client() else {
            loginPhase = .failed(AuthError.notConfigured.localizedDescription)
            return
        }
        loginTask?.cancel()
        loginPhase = .starting

        loginTask = Task { [weak self] in
            guard let self else { return }
            let nonce = DeviceNonce.current(defaults: self.defaults)
            do {
                let start = try await client.startLogin(
                    deviceNonce: nonce,
                    deviceName: deviceName
                )
                self.loginPhase = .awaitingApproval(code: start.code, webURL: start.webURL)

                var interval = max(2, start.pollIntervalSeconds)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled { return }

                    let poll = try await client.pollLogin(code: start.code, deviceNonce: nonce)
                    if let next = poll.pollIntervalSeconds { interval = max(2, next) }

                    let status = TVLoginStatus(rawValue: poll.status.lowercased()) ?? .pending
                    if status.isTerminalFailure { throw AuthError.loginFailed(status) }
                    guard status == .approved else { continue }

                    self.loginPhase = .exchanging
                    let issued = try await client.exchangeLogin(
                        code: start.code,
                        deviceNonce: nonce
                    )
                    TokenStore.save(issued)
                    self.tokens = issued

                    let user = try await client.currentUser(accessToken: issued.accessToken)
                    self.defaults.set("signedIn", forKey: Self.modeKey)
                    self.state = .signedIn(userID: user.id, email: user.email)
                    self.loginPhase = .idle
                    return
                }
            } catch is CancellationError {
                self.loginPhase = .idle
            } catch {
                self.loginPhase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginPhase = .idle
    }

    // MARK: Email and password

    func clearAuthError() { authError = nil }

    func submit(email: String, password: String, isSignUp: Bool) async {
        guard !isSubmitting, let client = client() else { return }
        cancelDeviceLink()
        authError = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let issued = isSignUp
                ? try await client.signUp(email: email, password: password)
                : try await client.signIn(email: email, password: password)
            try await adopt(issued, client: client)
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: Device link (mobile)

    /// Starts the short-code flow: start -> poll -> exchange, as NuvioMobile does.
    func startDeviceLink(deviceName: String) {
        guard let client = client() else { return }
        deviceLinkTask?.cancel()
        authError = nil
        deviceLink = .starting

        deviceLinkTask = Task { [weak self] in
            guard let self else { return }
            let nonce = UUID().uuidString.lowercased()
            do {
                let session = try await client.startDeviceLink(
                    deviceNonce: nonce,
                    deviceName: deviceName
                )
                let shown = Self.formatLinkCode(session.userCode)
                self.deviceLink = .waiting(
                    code: shown,
                    verificationURL: session.verificationURIComplete,
                    isCompleting: false
                )

                let interval = min(10, max(2, session.pollIntervalSeconds))
                var attempts = 0
                var consecutiveFailures = 0

                while !Task.isCancelled, attempts < 120 {
                    try await Task.sleep(for: .seconds(interval))
                    attempts += 1

                    let poll: TVLoginPoll
                    do {
                        poll = try await client.pollLogin(
                            code: session.deviceCode,
                            deviceNonce: nonce
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        consecutiveFailures += 1
                        if consecutiveFailures >= 3 { throw error }
                        continue
                    }
                    consecutiveFailures = 0

                    switch TVLoginStatus(rawValue: poll.status.lowercased()) ?? .pending {
                    case .pending:
                        continue
                    case .approved:
                        self.deviceLink = .waiting(
                            code: shown,
                            verificationURL: session.verificationURIComplete,
                            isCompleting: true
                        )
                        let issued = try await client.exchangeLogin(
                            code: session.deviceCode,
                            deviceNonce: nonce
                        )
                        try await self.adopt(issued, client: client)
                        self.deviceLink = .idle
                        return
                    case .expired, .used, .cancelled:
                        throw AuthError.loginFailed(.expired)
                    }
                }
                throw AuthError.loginFailed(.expired)
            } catch is CancellationError {
                self.deviceLink = .idle
            } catch {
                self.deviceLink = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDeviceLink() {
        deviceLinkTask?.cancel()
        deviceLinkTask = nil
        deviceLink = .idle
    }

    /// `4M93XP` -> `4M9-3XP`, matching NuvioMobile's formatDeviceLinkCode.
    static func formatLinkCode(_ value: String) -> String {
        let normalized = String(
            value.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)
        )
        guard normalized.count > 3 else { return normalized }
        return "\(normalized.prefix(3))-\(normalized.dropFirst(3))"
    }

    /// Stores freshly issued tokens and moves the app into the signed-in state.
    private func adopt(_ issued: AuthTokens, client: AuthClient) async throws {
        TokenStore.save(issued)
        tokens = issued
        let user = try await client.currentUser(accessToken: issued.accessToken)
        defaults.set("signedIn", forKey: Self.modeKey)
        state = .signedIn(userID: user.id, email: user.email)
    }

    // MARK: Sign out

    func signOut() {
        let existing = tokens
        clearLocalSession()
        if let existing, let client = client() {
            Task { await client.signOut(accessToken: existing.accessToken) }
        }
    }

    private func clearLocalSession() {
        loginTask?.cancel()
        loginTask = nil
        deviceLinkTask?.cancel()
        deviceLinkTask = nil
        deviceLink = .idle
        authError = nil
        tokens = nil
        TokenStore.clear()
        defaults.removeObject(forKey: Self.modeKey)
        state = .signedOut
        loginPhase = .idle
    }

    // MARK: Authorized requests

    /// A valid access token for callers that need one, refreshing if due.
    func validAccessToken() async -> String? {
        guard var current = tokens, let client = client() else { return nil }
        if current.needsRefresh {
            guard let refreshed = try? await client.refresh(current) else {
                signOut()
                return nil
            }
            current = refreshed
            TokenStore.save(current)
            tokens = current
        }
        return current.accessToken
    }

    private func client() -> AuthClient? {
        configuration.map { AuthClient(configuration: $0) }
    }
}
