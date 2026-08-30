import SwiftUI
import Combine

/// A title the viewer saved to their list.
///
/// Stores its own artwork rather than a reference to a catalog row: the list
/// has to render at launch, before any addon has answered.
struct SavedTitle: Codable, Identifiable, Equatable {
    let itemID: String
    let type: String
    let name: String
    let poster: String?
    let background: String?
    let logo: String?
    let releaseInfo: String?
    let imdbRating: String?
    let addonBaseURL: String
    let savedAt: Date

    var id: String { "\(type)|\(itemID)" }

    var item: MetaItem {
        MetaItem(
            id: itemID,
            type: type,
            name: name,
            poster: poster,
            background: background,
            logo: logo,
            releaseInfo: releaseInfo,
            imdbRating: imdbRating
        )
    }

    init(item: MetaItem, addonBaseURL: String, savedAt: Date = Date()) {
        self.itemID = item.id
        self.type = item.type
        self.name = item.name
        self.poster = item.poster
        self.background = item.background
        self.logo = item.logo
        self.releaseInfo = item.releaseInfo
        self.imdbRating = item.imdbRating
        self.addonBaseURL = addonBaseURL
        self.savedAt = savedAt
    }
}

/// "My List", per profile.
///
/// **Local only.** The backend does have library sync (`sync_pull_library` /
/// `sync_push_library`), but this build doesn't speak it yet, so a list saved
/// here stays on this device. Every profile keeps its own — a shared list
/// would defeat the point of profiles.
@MainActor
final class LibraryStore: ObservableObject {
    private static func key(profile: Int) -> String { "nuvio.library.\(profile)" }

    @Published private(set) var titles: [SavedTitle] = []

    private let defaults: UserDefaults
    private var profileIndex: Int = Profile.primaryIndex

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the store at a profile's list. Called whenever the active
    /// profile changes, including at launch.
    func activate(profile: Profile) {
        profileIndex = profile.index
        let data = defaults.data(forKey: Self.key(profile: profile.index))
        titles = data.flatMap { try? JSONDecoder().decode([SavedTitle].self, from: $0) } ?? []
    }

    func contains(_ item: MetaItem) -> Bool {
        titles.contains { $0.itemID == item.id && $0.type == item.type }
    }

    func toggle(_ item: MetaItem, addonBaseURL: String) {
        if contains(item) {
            titles.removeAll { $0.itemID == item.id && $0.type == item.type }
        } else {
            // Newest first, the order every streaming app shows a list in.
            titles.insert(SavedTitle(item: item, addonBaseURL: addonBaseURL), at: 0)
        }
        persist()
    }

    func remove(_ saved: SavedTitle) {
        titles.removeAll { $0.id == saved.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(titles) else { return }
        defaults.set(data, forKey: Self.key(profile: profileIndex))
    }
}
