import SwiftUI
import Combine

/// The addons a profile has installed, keyed by manifest id — the id
/// collection sources are stored against on Android.
struct AddonIndex: Equatable {
    struct Entry: Equatable {
        let name: String
        let baseURL: String
        let manifest: AddonManifest
    }

    private(set) var entries: [String: Entry] = [:]

    init(_ manifests: [(url: String, manifest: AddonManifest)] = []) {
        for (url, manifest) in manifests where entries[manifest.id] == nil {
            entries[manifest.id] = Entry(name: manifest.name, baseURL: url, manifest: manifest)
        }
    }

    func entry(_ addonID: String) -> Entry? { entries[addonID] }

    /// The catalog's own name, so a tab reads "Netflix" rather than
    /// "netflix-movies" — the label Android's folder tabs show.
    func catalog(addonID: String, type: String, catalogID: String) -> AddonCatalog? {
        entries[addonID]?.manifest.catalogs.first {
            $0.id == catalogID && $0.type.caseInsensitiveCompare(type) == .orderedSame
        }
    }
}

/// One tab inside an opened folder: a single catalog, or the merged "All".
struct FolderTab: Identifiable, Equatable {
    enum Content: Equatable {
        case loading
        case loaded([MetaItem])
        case failed(String)
    }

    let id: String
    let label: String
    /// Which addon answered, for the poster's detail lookup. Empty on "All",
    /// where each item carries its own.
    let addonBaseURL: String
    var content: Content = .loading

    var items: [MetaItem] { if case .loaded(let items) = content { return items }; return [] }
}

/// Loads an opened folder's catalogs. One instance per presented folder, so
/// closing the screen cancels everything still in flight.
@MainActor
final class CollectionFolderModel: ObservableObject {
    @Published private(set) var tabs: [FolderTab] = []
    @Published private(set) var selection = 0
    /// Base URL per item id, so a poster in the merged tab still knows which
    /// addon to ask for its detail.
    @Published private(set) var origins: [String: String] = [:]
    @Published private(set) var isLoading = false
    /// TMDB and Trakt sources need credentials this app doesn't hold; the
    /// screen says so rather than pretending the folder is complete.
    @Published private(set) var skippedProviders: [String] = []

    private let client = AddonClient()
    private var hasLoaded = false

    func select(_ index: Int) { selection = index }

    func load(folder: CollectionFolder, showAllTab: Bool, addons: AddonIndex) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }

        skippedProviders = Array(
            Set(
                folder.sources.compactMap { source -> String? in
                    if case .unsupported(let provider, _) = source { return provider.capitalized }
                    return nil
                }
            )
        ).sorted()

        // A source pointing at an addon the profile no longer has installed is
        // dropped here rather than becoming a tab that can only ever fail.
        let resolved: [(source: CollectionSource, entry: AddonIndex.Entry, tab: FolderTab)] =
            folder.addonSources.compactMap { source in
                guard let catalog = source.addonCatalog,
                      let entry = addons.entry(catalog.addonID)
                else { return nil }

                let manifestCatalog = addons.catalog(
                    addonID: catalog.addonID,
                    type: catalog.type,
                    catalogID: catalog.catalogID
                )
                return (
                    source,
                    entry,
                    FolderTab(
                        id: "\(catalog.addonID)|\(catalog.type)|\(catalog.catalogID)|\(catalog.genre ?? "")",
                        label: Self.label(
                            catalog: manifestCatalog,
                            fallbackID: catalog.catalogID,
                            type: catalog.type,
                            genre: catalog.genre
                        ),
                        addonBaseURL: entry.baseURL
                    )
                )
            }

        guard !resolved.isEmpty else {
            tabs = []
            return
        }

        let showsAll = showAllTab && resolved.count > 1
        tabs = (showsAll ? [FolderTab(id: "__all", label: "All", addonBaseURL: "")] : [])
            + resolved.map(\.tab)

        let client = client
        let results: [(String, Result<[MetaItem], Error>, String)] = await withTaskGroup(
            of: (String, Result<[MetaItem], Error>, String).self
        ) { group in
            for (source, entry, tab) in resolved {
                guard let catalog = source.addonCatalog else { continue }
                group.addTask {
                    do {
                        let items = try await client.catalog(
                            baseURL: entry.baseURL,
                            type: catalog.type,
                            catalogID: catalog.catalogID,
                            genre: catalog.genre
                        )
                        return (tab.id, .success(items), entry.baseURL)
                    } catch {
                        return (tab.id, .failure(error), entry.baseURL)
                    }
                }
            }
            var collected: [(String, Result<[MetaItem], Error>, String)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (id, result, baseURL) in results {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            switch result {
            case .success(let items):
                tabs[index].content = .loaded(items)
                for item in items where origins[item.id] == nil { origins[item.id] = baseURL }
            case .failure(let error):
                tabs[index].content = .failed(error.localizedDescription)
            }
        }

        // A catalog that answered with nothing is not worth a tab. One that
        // failed keeps its tab, so the screen can say so.
        tabs.removeAll { tab in
            guard tab.id != "__all", case .loaded(let items) = tab.content else { return false }
            return items.isEmpty
        }

        if showsAll, let index = tabs.firstIndex(where: { $0.id == "__all" }) {
            if tabs.count <= 2 {
                // Only one catalog survived; "All" would just duplicate it.
                tabs.remove(at: index)
            } else {
                tabs[index].content = .loaded(Self.merge(tabs.filter { $0.id != "__all" }))
            }
        }

        selection = min(selection, max(tabs.count - 1, 0))
    }

    func baseURL(for item: MetaItem, tab: FolderTab) -> String {
        tab.addonBaseURL.isEmpty ? (origins[item.id] ?? "") : tab.addonBaseURL
    }

    /// Interleaves the catalogs rather than stacking them, so the merged tab
    /// opens on a spread of what the folder holds instead of the whole of its
    /// first catalog. Duplicates across catalogs are kept once.
    static func merge(_ tabs: [FolderTab]) -> [MetaItem] {
        var merged: [MetaItem] = []
        var seen = Set<String>()
        var depth = 0
        let deepest = tabs.map(\.items.count).max() ?? 0

        while depth < deepest {
            for tab in tabs where depth < tab.items.count {
                let item = tab.items[depth]
                if seen.insert("\(item.type)|\(item.id)").inserted { merged.append(item) }
            }
            depth += 1
        }
        return merged
    }

    /// "Popular Movies", "Netflix · Comedy" — the catalog's own name, with the
    /// genre when the source narrows one shared catalog into several tabs.
    static func label(
        catalog: AddonCatalog?,
        fallbackID: String,
        type: String,
        genre: String?
    ) -> String {
        let base = catalog?.name?.trimmed.nilIfBlank
            ?? fallbackID.replacingOccurrences(of: "-", with: " ").capitalized
        guard let genre = genre?.trimmed, !genre.isEmpty else { return base }
        return base.localizedCaseInsensitiveContains(genre) ? base : "\(base) · \(genre)"
    }
}
