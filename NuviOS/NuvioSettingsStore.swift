#if os(iOS) || os(macOS)
import SwiftUI
import Combine

/// The Nuvio TV app's settings for one profile, as nuvio.tv/account's
/// "TV Settings" page edits them.
///
/// Android keeps every setting in a per-profile blob that it syncs through
/// `sync_pull_profile_settings_blob` / `sync_push_profile_settings_blob`:
///
///     { "version": 1, "features": { "<feature>": { "<key>": { "type": …, "value": … } } } }
///
/// Android's import *clears* each feature it receives before writing it, so a
/// key missing from a pushed feature is deleted on the TV. This store therefore
/// never builds a blob of its own: it keeps the pulled JSON as it came, pulls
/// again just before saving, lays only the edited keys over that fresh copy,
/// and pushes the whole thing back.
@MainActor
final class NuvioSettingsStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The TV has never synced this profile. Saving would create features
        /// holding only the edited keys, which Android would then treat as the
        /// whole feature, so editing stays off until the TV writes a blob.
        case noBlob
        /// A blob version this build doesn't understand: shown, not saved.
        case unsupportedVersion(Int)
        case failed(String)
    }

    /// The setting's identity in the blob.
    struct Key: Hashable {
        let feature: String
        let key: String
    }

    /// A pending edit, typed the way Android's `encodePreferenceValue` types it.
    enum Value: Equatable {
        case bool(Bool)
        case string(String)
        case int(Int)
        case float(Double)

        var typeTag: String {
            switch self {
            case .bool: "boolean"
            case .string: "string"
            case .int: "int"
            case .float: "float"
            }
        }

        var json: Any {
            switch self {
            case .bool(let v): v
            case .string(let v): v
            case .int(let v): v
            case .float(let v): v
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?
    @Published private(set) var edits: [Key: Value] = [:]

    private(set) var profileIndex: Int?
    /// The pulled `features` object, untouched.
    private var features: [String: [String: Any]] = [:]

    var hasChanges: Bool { !edits.isEmpty }
    var canEdit: Bool { phase == .loaded }

    // MARK: Reading

    private func stored(_ key: Key) -> Any? {
        (features[key.feature]?[key.key] as? [String: Any])?["value"]
    }

    func bool(_ feature: String, _ key: String, default fallback: Bool) -> Bool {
        let k = Key(feature: feature, key: key)
        if case .bool(let v)? = edits[k] { return v }
        if let n = stored(k) as? NSNumber { return n.boolValue }
        return fallback
    }

    func string(_ feature: String, _ key: String, default fallback: String) -> String {
        let k = Key(feature: feature, key: key)
        if case .string(let v)? = edits[k] { return v }
        return (stored(k) as? String) ?? fallback
    }

    func int(_ feature: String, _ key: String, default fallback: Int) -> Int {
        let k = Key(feature: feature, key: key)
        if case .int(let v)? = edits[k] { return v }
        return (stored(k) as? NSNumber)?.intValue ?? fallback
    }

    func float(_ feature: String, _ key: String, default fallback: Double) -> Double {
        let k = Key(feature: feature, key: key)
        if case .float(let v)? = edits[k] { return v }
        return (stored(k) as? NSNumber)?.doubleValue ?? fallback
    }

    func isEdited(_ feature: String, _ key: String) -> Bool {
        edits[Key(feature: feature, key: key)] != nil
    }

    // MARK: Writing (local until Save)

    func set(_ feature: String, _ key: String, _ value: Value) {
        guard canEdit else { return }
        let k = Key(feature: feature, key: key)
        // Setting a value back to what was pulled is not a change.
        if let original = stored(k), Self.matches(original, value) {
            edits[k] = nil
        } else {
            edits[k] = value
        }
    }

    private static func matches(_ stored: Any, _ value: Value) -> Bool {
        switch value {
        case .bool(let v): (stored as? NSNumber)?.boolValue == v
        case .string(let v): (stored as? String) == v
        case .int(let v): (stored as? NSNumber)?.intValue == v
        case .float(let v): (stored as? NSNumber)?.doubleValue == v
        }
    }

    // Bindings for the views.

    func boolBinding(_ feature: String, _ key: String, default d: Bool) -> Binding<Bool> {
        Binding { self.bool(feature, key, default: d) } set: { self.set(feature, key, .bool($0)) }
    }

    func stringBinding(_ feature: String, _ key: String, default d: String) -> Binding<String> {
        Binding { self.string(feature, key, default: d) } set: { self.set(feature, key, .string($0)) }
    }

    func intBinding(_ feature: String, _ key: String, default d: Int) -> Binding<Int> {
        Binding { self.int(feature, key, default: d) } set: { self.set(feature, key, .int($0)) }
    }

    func floatBinding(_ feature: String, _ key: String, default d: Double) -> Binding<Double> {
        Binding { self.float(feature, key, default: d) } set: { self.set(feature, key, .float($0)) }
    }

    // MARK: Sync

    func discard() {
        edits = [:]
        saveError = nil
    }

    func load(session: AppSession, profileIndex: Int) async {
        if self.profileIndex != profileIndex { edits = [:] }
        self.profileIndex = profileIndex
        phase = .loading
        saveError = nil
        do {
            let row = try await pull(session: session, profileIndex: profileIndex)
            apply(row)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func save(session: AppSession) async {
        guard let profileIndex, canEdit, hasChanges, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            // Fresh copy first, so a change the TV made meanwhile survives.
            guard let row = try await pull(session: session, profileIndex: profileIndex),
                  var blob = row.settings,
                  var fresh = blob["features"] as? [String: Any] else {
                saveError = "The TV's settings disappeared from the server. Reload and try again."
                return
            }
            for (k, value) in edits {
                var feature = (fresh[k.feature] as? [String: Any]) ?? [:]
                feature[k.key] = ["type": value.typeTag, "value": value.json]
                fresh[k.feature] = feature
            }
            blob["features"] = fresh
            try await push(session: session, profileIndex: profileIndex, blob: blob)
            edits = [:]
            apply(try await pull(session: session, profileIndex: profileIndex))
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func apply(_ row: PulledRow?) {
        guard let row, let blob = row.settings,
              let pulled = blob["features"] as? [String: Any] else {
            features = [:]
            updatedAt = nil
            phase = .noBlob
            return
        }
        features = pulled.compactMapValues { $0 as? [String: Any] }
        updatedAt = row.updatedAt
        let version = (blob["version"] as? NSNumber)?.intValue ?? 1
        phase = version == 1 ? .loaded : .unsupportedVersion(version)
    }

    // MARK: Network

    private struct PulledRow {
        var settings: [String: Any]?
        var updatedAt: Date?
    }

    private enum SyncError: LocalizedError {
        case signedOut
        var errorDescription: String? { "Sign in to your Nuvio account first." }
    }

    private func pull(session: AppSession, profileIndex: Int) async throws -> PulledRow? {
        let data = try await rpc(
            "sync_pull_profile_settings_blob",
            ["p_profile_id": profileIndex, "p_platform": "tv"],
            session: session
        )
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first else { return nil }
        return PulledRow(
            settings: first["settings_json"] as? [String: Any],
            updatedAt: (first["updated_at"] as? String).flatMap(Self.parseDate)
        )
    }

    private func push(session: AppSession, profileIndex: Int, blob: [String: Any]) async throws {
        _ = try await rpc(
            "sync_push_profile_settings_blob",
            [
                "p_profile_id": profileIndex,
                "p_settings_json": blob,
                "p_platform": "tv",
                "p_origin_client_id": SyncClientIdentity.current,
            ],
            session: session
        )
    }

    private func rpc(_ name: String, _ params: [String: Any], session: AppSession) async throws -> Data {
        guard let configuration = session.configuration,
              let token = await session.validAccessToken() else { throw SyncError.signedOut }
        var backend = configuration.backendURL
        while backend.hasSuffix("/") { backend.removeLast() }

        var request = URLRequest(url: URL(string: "\(backend)/rest/v1/rpc/\(name)")!)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.server(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
#endif
