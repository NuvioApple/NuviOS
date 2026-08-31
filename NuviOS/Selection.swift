import SwiftUI

// Small pieces both platforms' screens need.

// MARK: - Selection

/// Identifies which addon a poster came from, so its detail can be fetched
/// from the addon that knows about it.
struct MetaSelection: Identifiable, Equatable, Hashable {
    let item: MetaItem
    let addonBaseURL: String
    /// The rest of the row this title was opened from, so the detail page can
    /// offer "More Like This" without a second round trip.
    var related: [MetaItem] = []

    var id: String { "\(addonBaseURL)|\(item.type)|\(item.id)" }

    /// `MetaItem` isn't `Hashable`, and doesn't need to be: the identity of a
    /// selection is entirely its `id`, which `navigationDestination(item:)`
    /// needs to key a pushed screen off.
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
