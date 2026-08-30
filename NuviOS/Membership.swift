import SwiftUI
import Combine

/// A cosmetic a Nuvio supporter tier unlocks. Names match the strings
/// `get_my_member_access` returns, and upstream's `CosmeticEntitlement`.
enum CosmeticEntitlement: String, Codable, CaseIterable {
    case goldTheme = "GOLD_THEME"
    case jadeTheme = "JADE_THEME"
    case roseGoldTheme = "ROSE_GOLD_THEME"
    case arcticBlueTheme = "ARCTIC_BLUE_THEME"
    case graphiteTheme = "GRAPHITE_THEME"
    case profileBackgrounds = "PROFILE_BACKGROUNDS"
    case profileAvatars = "PROFILE_AVATARS"
}

/// What the signed-in account has unlocked.
struct MemberAccess: Codable, Equatable {
    var tier: String?
    var entitlements: Set<CosmeticEntitlement>

    static let none = MemberAccess(tier: nil, entitlements: [])

    func includes(_ entitlement: CosmeticEntitlement) -> Bool {
        entitlements.contains(entitlement)
    }
}

/// Reads the account's supporter entitlements.
///
/// The five accent themes upstream reserves for supporters are reserved here
/// too — this port isn't a way around someone else's paywall.
struct MembershipClient {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    private struct Row: Decodable {
        let tier: String
        let entitlements: [String]
    }

    func memberAccess(accessToken: String) async throws -> MemberAccess {
        var base = configuration.backendURL
        while base.hasSuffix("/") { base.removeLast() }

        var request = URLRequest(url: URL(string: "\(base)/rest/v1/rpc/get_my_member_access")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        guard let row = try JSONDecoder().decode([Row].self, from: data).first else {
            return .none
        }
        return MemberAccess(
            tier: row.tier,
            entitlements: Set(row.entitlements.compactMap(CosmeticEntitlement.init(rawValue:)))
        )
    }
}

/// The account's entitlements, cached across launches.
@MainActor
final class MembershipStore: ObservableObject {
    private static let key = "nuvio.membership"

    @Published private(set) var access: MemberAccess

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.access = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(MemberAccess.self, from: $0) } ?? .none
    }

    var isSupporter: Bool { !access.entitlements.isEmpty }

    func includes(_ entitlement: CosmeticEntitlement) -> Bool { access.includes(entitlement) }

    /// A guest has no account, so nothing is unlocked — and anything cached
    /// from a previous sign-in is dropped rather than lingering.
    func refresh(session: AppSession) async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else {
            update(.none)
            return
        }

        guard let fetched = try? await MembershipClient(configuration: configuration)
            .memberAccess(accessToken: token)
        else { return }

        update(fetched)
    }

    private func update(_ value: MemberAccess) {
        guard value != access else { return }
        access = value
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
