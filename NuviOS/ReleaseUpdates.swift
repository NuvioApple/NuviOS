#if os(iOS) || os(tvOS)
import Combine
import Foundation
import SwiftUI

// The sideloaded build's update notice.
//
// The Mac replaces itself with Sparkle; see `SoftwareUpdates.swift`. iOS,
// iPadOS and tvOS cannot — neither exposes an API that installs a binary, so
// whatever sideloaded the app is the only thing that can replace it. What the
// app *can* do is notice that a newer release exists and say so, which is what
// this does: it reads the repository's own releases, and if one is newer than
// the running build it points the viewer at it. Installing it is still their
// job, and the copy says so rather than implying a button will do it.
//
// GitHub is read directly, on purpose. Releases are published there already, so
// there is one source of truth and no second feed to keep in step with it.

// MARK: - Where releases come from

enum ReleaseSource {
    static let owner = "NuvioApple"
    static let repository = "NuviOS"

    /// `latest` excludes drafts and pre-releases, so a test build put up for a
    /// handful of people never alerts everyone.
    static let latestAPI = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!

    /// The fallback. GitHub's API allows 60 unauthenticated calls an hour *per
    /// address*, and behind CGNAT a lot of phones share one — the Atom feed has
    /// no such ceiling, so a rate-limited check still gets an answer instead of
    /// silently giving up.
    static let atom = URL(string: "https://github.com/\(owner)/\(repository)/releases.atom")!

    /// Where "Releases" on the profile screen goes.
    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repository)/releases")!
}

// MARK: - Versions

/// A release version, read from a tag.
///
/// Tags carry the marketing version (`v1.3`), which is what this compares
/// against `CFBundleShortVersionString` — not `CFBundleVersion`, which is
/// Sparkle's business and never appears in a tag name. Comparison is numeric
/// because string order gets `1.10` and `1.9` backwards.
struct ReleaseVersion: Comparable, CustomStringConvertible, Equatable {
    let components: [Int]
    let description: String

    /// Returns `nil` for anything that isn't a plain numeric version. An
    /// unreadable tag is treated as "no update" rather than guessed at: a
    /// false alarm sends people to re-sideload a build they already have.
    init?(tag: String) {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "v" || first == "V" {
            text.removeFirst()
        }

        // `1.3.1-beta.2` reads as 1.3.1; the suffix is decoration, and the API
        // has already filtered out the pre-releases that would rely on it.
        let numeric = String(text.prefix { $0.isNumber || $0 == "." })
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return nil }

        var values: [Int] = []
        for part in parts {
            guard let value = Int(part) else { return nil }
            values.append(value)
        }

        components = values
        description = values.map(String.init).joined(separator: ".")
    }

    /// `1.3` and `1.3.0` are the same release, so equality pads the same way
    /// comparison does rather than leaning on the synthesised member-wise one.
    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            // 1.3 and 1.3.0 are the same release, so the shorter one pads.
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// A published release, reduced to what the notice actually shows.
struct GitHubRelease: Equatable, Identifiable {
    let version: ReleaseVersion
    let title: String
    let notes: String?
    let pageURL: URL

    var id: String { version.description }

    /// The first paragraph of the release notes, for the alert body. The full
    /// text belongs on the release page, not in a modal.
    var summary: String? {
        guard let notes else { return nil }
        let firstParagraph = notes
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstParagraph, !firstParagraph.isEmpty else { return nil }
        return firstParagraph.count > 240
            ? String(firstParagraph.prefix(240)).trimmingCharacters(in: .whitespaces) + "…"
            : firstParagraph
    }
}

// MARK: - Reading the feed

enum ReleaseFeed {
    /// Asks the API, and falls back to the Atom feed when it won't answer.
    static func latest() async throws -> GitHubRelease? {
        do {
            if let release = try await fromAPI() { return release }
        } catch is DecodingError {
            // A shape we don't recognise is worth falling back on; a genuine
            // network failure below will surface on its own.
        } catch let error as URLError where error.code == .badServerResponse {
        }
        return try await fromAtom()
    }

    private struct APIRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }

    private static func fromAPI() async throws -> GitHubRelease? {
        var request = URLRequest(url: ReleaseSource.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        // 403/429 is the rate limit, 404 is a repository with no published
        // release yet. Neither is worth an error in front of the viewer.
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let payload = try JSONDecoder().decode(APIRelease.self, from: data)
        guard let version = ReleaseVersion(tag: payload.tagName),
              let url = URL(string: payload.htmlURL)
        else { return nil }

        return GitHubRelease(
            version: version,
            title: payload.name?.isEmpty == false ? payload.name! : payload.tagName,
            notes: payload.body,
            pageURL: url
        )
    }

    /// The Atom feed carries the newest release first, with its tag as the
    /// entry title. It has no "is this a pre-release" flag, which is the one
    /// thing lost by falling back here.
    private static func fromAtom() async throws -> GitHubRelease? {
        var request = URLRequest(url: ReleaseSource.atom)
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let feed = String(data: data, encoding: .utf8),
              let entry = feed.range(of: "<entry>")
        else { return nil }

        let scope = feed[entry.upperBound...]
        guard let title = value(in: scope, tag: "title"),
              let version = ReleaseVersion(tag: title),
              let href = attribute(in: scope, after: "<link", named: "href"),
              let url = URL(string: href)
        else { return nil }

        return GitHubRelease(version: version, title: title, notes: nil, pageURL: url)
    }

    private static func value(in text: Substring, tag: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(in text: Substring, after element: String, named: String) -> String? {
        guard let element = text.range(of: element),
              let key = text.range(of: "\(named)=\"", range: element.upperBound..<text.endIndex),
              let close = text.range(of: "\"", range: key.upperBound..<text.endIndex)
        else { return nil }
        return String(text[key.upperBound..<close.lowerBound])
    }
}

// MARK: - The check

@MainActor
final class ReleaseUpdateChecker: ObservableObject {
    static let shared = ReleaseUpdateChecker()

    /// The release worth telling the viewer about: newer than what's running,
    /// and not one they've already waved away.
    @Published private(set) var pending: GitHubRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    /// Set only for a check the viewer asked for. A background check that fails
    /// says nothing — there is nothing they'd do about it.
    @Published var failure: String?

    private let defaults: UserDefaults
    private enum Key {
        static let lastChecked = "updates.github.lastCheckedAt"
        static let skipped = "updates.github.skippedVersion"
    }

    /// Once every six hours at most. The app is opened far more often than it
    /// is released, and an update notice that re-appears on every cold start
    /// is the fastest way to teach people to dismiss it without reading.
    private let interval: TimeInterval = 6 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastCheckedAt = defaults.object(forKey: Key.lastChecked) as? Date
    }

    /// What the running build reports, for the "you're on x" line.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// `force` is the profile screen's button: it ignores both the interval and
    /// a previous dismissal, because asking is an explicit request for an answer.
    func check(force: Bool = false) async {
        guard !isChecking else { return }

        if !force, let last = lastCheckedAt, Date().timeIntervalSince(last) < interval {
            return
        }

        isChecking = true
        failure = nil
        defer { isChecking = false }

        do {
            let release = try await ReleaseFeed.latest()
            let now = Date()
            lastCheckedAt = now
            defaults.set(now, forKey: Key.lastChecked)

            guard let release,
                  let running = ReleaseVersion(tag: currentVersion),
                  release.version > running
            else {
                pending = nil
                return
            }

            if !force, defaults.string(forKey: Key.skipped) == release.version.description {
                pending = nil
                return
            }

            pending = release
        } catch {
            if force {
                failure = "Couldn't reach GitHub. Check your connection and try again."
            }
        }
    }

    /// "Not now" — for this version. A later release alerts again.
    func skipPending() {
        if let pending {
            defaults.set(pending.version.description, forKey: Key.skipped)
        }
        pending = nil
    }

    /// Closes the notice without remembering the decision, for the viewer who
    /// opened the release page and will install it.
    func dismissPending() {
        pending = nil
    }
}

// MARK: - The notice
//
// iPhone and iPad only for now. The TV has no browser to send anyone to, so it
// gets the same check behind a QR code instead — that screen is the next piece.

#if os(iOS)
/// Alerts once, on the root view, when a newer release is published.
///
/// An alert rather than a banner because it is rare — a few times a year — and
/// because the action is genuinely elsewhere: the viewer leaves for Safari,
/// downloads the build, and re-sideloads it with whatever put the app on the
/// device in the first place.
private struct ReleaseUpdateAlert: ViewModifier {
    @ObservedObject private var checker = ReleaseUpdateChecker.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .alert(
                "NuviOS \(checker.pending?.version.description ?? "") is out",
                isPresented: Binding(
                    get: { checker.pending != nil },
                    set: { if !$0 { checker.dismissPending() } }
                ),
                presenting: checker.pending
            ) { release in
                Button("View release") {
                    openURL(release.pageURL)
                    checker.dismissPending()
                }
                Button("Not now", role: .cancel) {
                    checker.skipPending()
                }
            } message: { release in
                Text(message(for: release))
            }
            // On launch, and again when the app comes back after a while —
            // the six-hour interval inside the checker decides whether either
            // of those actually asks GitHub anything.
            .task { await checker.check() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await checker.check() }
            }
    }

    private func message(for release: GitHubRelease) -> String {
        var lines = ["You're on \(checker.currentVersion)."]
        if let summary = release.summary {
            lines.append(summary)
        }
        // Said plainly, because it is the part people get wrong: the app can't
        // install this itself, and installing over the top with the same
        // signing identity is what keeps their library where it is.
        lines.append(
            "NuviOS can't install this itself — download it from GitHub and sideload it the same way you did before, "
            + "signed with the same account, and your profiles and progress stay put."
        )
        return lines.joined(separator: "\n\n")
    }
}

extension View {
    /// Attached once, at the root.
    func githubUpdateAlert() -> some View {
        modifier(ReleaseUpdateAlert())
    }
}

// MARK: - Profile screen

/// The manual path, in the same place the Mac keeps its own update controls.
struct ReleaseUpdateControls: View {
    @ObservedObject private var checker = ReleaseUpdateChecker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Version \(checker.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            if let checked = checker.lastCheckedAt {
                Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }

            if let failure = checker.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A sideloaded build can't replace itself, so this says what it
            // does rather than promising an install.
            Text("Sideloaded builds don't update themselves. NuviOS checks GitHub for a newer release and points you at it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Check for updates", systemImage: "arrow.down.circle") {
                    Task { await checker.check(force: true) }
                }
                .buttonStyle(.glass)
                .disabled(checker.isChecking)

                Button("Releases", systemImage: "arrow.up.right") {
                    openURL(ReleaseSource.releasesPage)
                }
                .buttonStyle(.glass)
            }
        }
    }
}
#endif
#endif
