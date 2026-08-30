import SwiftUI
import Combine

// MARK: - Model

/// A viewing profile, mirroring Android's `UserProfile`.
///
/// Profiles are an account-level feature on the Nuvio backend, not a local
/// convenience: they live in Postgres and are read and written with the
/// `sync_pull_profiles` / `sync_push_profiles` RPCs. A profile is identified by
/// its **index** (1...6) rather than a UUID, and index 1 is the primary profile.
struct Profile: Identifiable, Codable, Equatable, Hashable {
    /// 1...6. Index 1 is the primary profile and cannot be deleted.
    var index: Int
    var name: String
    /// `#RRGGBB`, from `Profile.avatarColors`.
    var avatarColorHex: String
    /// Non-primary profiles may borrow the primary profile's addon list
    /// instead of keeping their own.
    var usesPrimaryAddons: Bool = false
    var usesPrimaryPlugins: Bool = false
    var avatarID: String?
    var avatarURL: String?
    var backgroundID: String?
    var backgroundURL: String?

    var id: Int { index }
    var isPrimary: Bool { index == Profile.primaryIndex }

    /// Whose addon list this profile actually browses. Matches the rule in
    /// Android's `AddonSyncService`: a non-primary profile that borrows the
    /// primary's addons reads profile 1's rows.
    var effectiveAddonProfileID: Int {
        (!isPrimary && usesPrimaryAddons) ? Profile.primaryIndex : index
    }

    var tint: Color { Color(hex: avatarColorHex) ?? Profile.fallbackTint }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

extension Profile {
    static let primaryIndex = 1
    /// Android's `ProfileManager.MAX_PROFILES`.
    static let maxProfiles = 6

    /// Android's `PROFILE_AVATAR_COLORS`, in the same order so a profile made
    /// on either client shows the same colour on the other.
    static let avatarColors = [
        "#E53935", "#1E88E5", "#8E24AA", "#43A047",
        "#FFB300", "#D81B60", "#00ACC1", "#6D4C41",
    ]

    /// The server's own default when a row carries no colour.
    static let fallbackTint = Color(hex: "#1E88E5") ?? .blue

    static func makePrimary() -> Profile {
        Profile(index: primaryIndex, name: "Primary", avatarColorHex: avatarColors[1])
    }
}

extension Color {
    /// Parses `#RRGGBB` / `RRGGBB`. Returns nil rather than guessing, so a
    /// malformed value from the server falls back visibly to the default.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self = NuvioPalette.rgb(value)
    }
}

// MARK: - Remote

/// Reads and writes the account's profiles over PostgREST, the same two RPCs
/// Android's `ProfileSyncService` uses.
struct ProfileClient {
    let configuration: ServerConfiguration
    var session: URLSession = .shared

    private var base: String {
        var value = configuration.backendURL
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// One row of `sync_pull_profiles` / one element of `p_profiles`.
    private struct Row: Codable {
        let profileIndex: Int
        let name: String
        let avatarColorHex: String?
        let usesPrimaryAddons: Bool?
        let usesPrimaryPlugins: Bool?
        let avatarID: String?
        let avatarURL: String?
        let backgroundID: String?
        let backgroundURL: String?

        enum CodingKeys: String, CodingKey {
            case profileIndex = "profile_index"
            case name
            case avatarColorHex = "avatar_color_hex"
            case usesPrimaryAddons = "uses_primary_addons"
            case usesPrimaryPlugins = "uses_primary_plugins"
            case avatarID = "avatar_id"
            case avatarURL = "avatar_url"
            case backgroundID = "profile_background_id"
            case backgroundURL = "profile_background_url"
        }

        init(_ profile: Profile) {
            profileIndex = profile.index
            name = profile.name
            avatarColorHex = profile.avatarColorHex
            usesPrimaryAddons = profile.usesPrimaryAddons
            usesPrimaryPlugins = profile.usesPrimaryPlugins
            // Android sends one or the other, never both.
            avatarID = (profile.avatarURL?.isEmpty == false) ? nil : profile.avatarID
            avatarURL = profile.avatarURL?.nilWhenBlank
            backgroundID = profile.backgroundID
            backgroundURL = profile.backgroundURL?.nilWhenBlank
        }

        var profile: Profile {
            Profile(
                index: profileIndex,
                name: name,
                avatarColorHex: avatarColorHex?.nilWhenBlank ?? Profile.avatarColors[1],
                usesPrimaryAddons: usesPrimaryAddons ?? false,
                usesPrimaryPlugins: usesPrimaryPlugins ?? false,
                avatarID: avatarID,
                avatarURL: avatarURL,
                backgroundID: backgroundID,
                backgroundURL: backgroundURL
            )
        }
    }

    private struct PushParams: Encodable {
        let clientMaxProfiles: Int
        let profiles: [Row]

        enum CodingKeys: String, CodingKey {
            case clientMaxProfiles = "p_client_max_profiles"
            case profiles = "p_profiles"
        }
    }

    private struct DeleteParams: Encodable {
        let profileID: Int
        enum CodingKeys: String, CodingKey { case profileID = "p_profile_id" }
    }

    func pull(accessToken: String) async throws -> [Profile] {
        let data = try await call("sync_pull_profiles", body: Data("{}".utf8), accessToken: accessToken)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.map(\.profile).sorted { $0.index < $1.index }
    }

    func push(_ profiles: [Profile], accessToken: String) async throws {
        let params = PushParams(
            clientMaxProfiles: Profile.maxProfiles,
            profiles: profiles.map(Row.init)
        )
        _ = try await call(
            "sync_push_profiles",
            body: try JSONEncoder().encode(params),
            accessToken: accessToken
        )
    }

    /// Drops a deleted profile's server-side data (library, progress, addons).
    func deleteData(profileIndex: Int, accessToken: String) async throws {
        _ = try await call(
            "sync_delete_profile_data",
            body: try JSONEncoder().encode(DeleteParams(profileID: profileIndex)),
            accessToken: accessToken
        )
    }

    private func call(_ function: String, body: Data, accessToken: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(base)/rest/v1/rpc/\(function)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        // Profile RPCs are row-level-secured, so they need the user's JWT —
        // the publishable key alone is not enough.
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

// MARK: - Store

/// The account's profiles and which one is in use.
///
/// The local copy is a cache: it keeps guests working and shows something
/// immediately at launch, then `sync(session:)` replaces it with the account's
/// own profiles and every edit is pushed back.
@MainActor
final class ProfileStore: ObservableObject {
    private static let listKey = "nuvio.profiles"
    private static let currentKey = "nuvio.profiles.current"

    @Published private(set) var profiles: [Profile]
    @Published private(set) var currentIndex: Int
    /// Surfaced in the UI so a failed push isn't silent.
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false

    private let defaults: UserDefaults

    var current: Profile {
        profiles.first { $0.index == currentIndex } ?? profiles[0]
    }

    var canAdd: Bool { profiles.count < Profile.maxProfiles }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored: [Profile] = defaults.data(forKey: Self.listKey)
            .flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        let seeded = stored.isEmpty ? [Profile.makePrimary()] : stored
        self.profiles = seeded.sorted { $0.index < $1.index }

        let storedCurrent = defaults.object(forKey: Self.currentKey) as? Int
        self.currentIndex = seeded.contains { $0.index == storedCurrent }
            ? storedCurrent!
            : seeded[0].index

        if stored.isEmpty { persist() }
    }

    // MARK: Sync

    /// Pulls the account's profiles. A guest keeps the local set.
    func sync(session: AppSession) async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let remote = try await ProfileClient(configuration: configuration).pull(accessToken: token)
            guard !remote.isEmpty else {
                // A fresh account has no rows yet; seed it with what we have.
                await push(session: session)
                return
            }
            profiles = remote
            if !profiles.contains(where: { $0.index == currentIndex }) {
                select(profiles[0])
            }
            persist()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func push(session: AppSession) async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else { return }

        do {
            try await ProfileClient(configuration: configuration)
                .push(profiles, accessToken: token)
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: Mutations

    func select(_ profile: Profile) {
        guard profiles.contains(where: { $0.index == profile.index }) else { return }
        currentIndex = profile.index
        defaults.set(profile.index, forKey: Self.currentKey)
    }

    /// The next free index in 2...6, matching Android's allocation.
    private var nextIndex: Int? {
        let used = Set(profiles.map(\.index))
        return (2...Profile.maxProfiles).first { !used.contains($0) }
    }

    @discardableResult
    func add(
        name: String,
        colorHex: String,
        avatarID: String?,
        usesPrimaryAddons: Bool,
        usesPrimaryPlugins: Bool,
        session: AppSession
    ) async -> Profile? {
        guard let index = nextIndex else { return nil }
        let trimmed = name.trimmed
        let profile = Profile(
            index: index,
            name: trimmed.isEmpty ? "Profile \(index)" : trimmed,
            avatarColorHex: colorHex,
            usesPrimaryAddons: usesPrimaryAddons,
            usesPrimaryPlugins: usesPrimaryPlugins,
            avatarID: avatarID
        )
        profiles.append(profile)
        profiles.sort { $0.index < $1.index }
        persist()
        await push(session: session)
        return profile
    }

    func update(_ profile: Profile, session: AppSession) async {
        guard let position = profiles.firstIndex(where: { $0.index == profile.index }) else { return }
        profiles[position] = profile
        persist()
        await push(session: session)
    }

    /// The primary profile is permanent; removing the active one falls back to
    /// the primary.
    func remove(_ profile: Profile, session: AppSession) async {
        guard !profile.isPrimary, profiles.count > 1 else { return }
        profiles.removeAll { $0.index == profile.index }
        persist()
        if currentIndex == profile.index, let first = profiles.first { select(first) }

        await push(session: session)

        if case .signedIn = session.state,
           let configuration = session.configuration,
           let token = await session.validAccessToken() {
            // Best effort: the profile is already gone from the account's list.
            try? await ProfileClient(configuration: configuration)
                .deleteData(profileIndex: profile.index, accessToken: token)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.listKey)
    }
}

private extension String {
    var nilWhenBlank: String? { trimmed.isEmpty ? nil : self }
}
