#if os(macOS)
import Combine
import Sparkle
import SwiftUI

/// The Mac build's over-the-air updater.
///
/// The Mac is the one Apple platform where the app can genuinely update
/// itself: it ships as a DMG rather than through a sideloader, so nothing
/// stops it downloading a new build and swapping itself out. Sparkle is what
/// every Mac app outside the App Store uses for that, so this is a thin shell
/// around `SPUStandardUpdaterController` rather than a hand-rolled downloader
/// like Android's `ApkDownloader` — Sparkle already handles the parts that are
/// easy to get wrong: signature checks, installing on quit, and not asking the
/// same question twice.
///
/// iOS, iPadOS and tvOS get nothing here, deliberately. Neither has an API
/// that installs a binary, so a sideloaded build can only be replaced by the
/// sideloader that put it there; see `distribution/README.md`.
@MainActor
final class SoftwareUpdater: ObservableObject {
    static let shared = SoftwareUpdater()

    /// Sparkle drives its own UI, so the controller is started at launch and
    /// left to check on its own schedule. The app only reaches in for the two
    /// things a user can ask for: check now, and stop checking.
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own readiness so the menu item and the button can
    /// disable themselves while a check is already running.
    @Published private(set) var canCheckForUpdates = false

    /// The automatic-check preference, surfaced on the profile screen the way
    /// Android surfaces its update banner toggle. Sparkle persists this in
    /// user defaults itself, so there is nothing to store alongside it.
    @Published var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    private var readiness: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        checksAutomatically = controller.updater.automaticallyChecksForUpdates

        // `canCheckForUpdates` is KVO, not Combine, but Sparkle publishes it
        // on the main thread and SwiftUI needs it as a `@Published`.
        readiness = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    /// The version the running app reports, for the "you're on x" line.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// When Sparkle last looked. `nil` before the first check of the install.
    var lastCheckedAt: Date? {
        controller.updater.lastUpdateCheckDate
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

// MARK: - Menu

/// The standard Mac menu item, in the standard place: the app menu, directly
/// under About. Mac users look for it there before they look anywhere else.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = SoftwareUpdater.shared

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

// MARK: - Profile screen

/// The same controls inside the app, for anyone who never opens the menu bar.
struct SoftwareUpdateControls: View {
    @ObservedObject private var updater = SoftwareUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Version \(updater.currentVersion)")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))

            if let checked = updater.lastCheckedAt {
                Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                .toggleStyle(.switch)
                .tint(.accentColor)

            Button("Check for updates", systemImage: "arrow.down.circle") {
                updater.checkForUpdates()
            }
            .buttonStyle(.glass)
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
#endif
