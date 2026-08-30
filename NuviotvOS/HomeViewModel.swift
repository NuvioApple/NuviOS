import SwiftUI
import Combine

/// One home row: a single catalog from a single addon.
struct CatalogRow: Identifiable, Equatable {
    enum Content: Equatable {
        case loading
        case loaded([MetaItem])
        case failed(String)
    }

    let id: String
    let title: String
    let addonName: String
    let addonBaseURL: String
    let type: String
    let catalogID: String
    var content: Content = .loading

    var items: [MetaItem] {
        if case .loaded(let items) = content { return items }
        return []
    }

    /// A row nobody can act on — loaded but empty — is worth hiding.
    var isEmptyAfterLoading: Bool {
        if case .loaded(let items) = content { return items.isEmpty }
        return false
    }
}

/// A title promoted into the hero carousel, tagged with the addon it came
/// from so its detail can still be fetched.
struct HeroItem: Identifiable, Equatable {
    let item: MetaItem
    let addonBaseURL: String

    var id: String { "\(addonBaseURL)|\(item.type)|\(item.id)" }
}

/// One catalog that can answer a search query, kept aside at load time so the
/// Search tab doesn't have to refetch every manifest.
struct SearchSource: Identifiable, Equatable {
    let addonName: String
    let addonBaseURL: String
    let type: String
    let catalogID: String

    var id: String { "\(addonBaseURL)|\(type)|\(catalogID)" }
}

@MainActor
final class HomeViewModel: ObservableObject {
    /// Enough to fill a TV screen several scrolls deep without hammering every
    /// addon the user has installed.
    private static let maxRows = 24

    /// How many titles the hero carousel rotates through.
    private static let maxHeroItems = 7

    @Published private(set) var rows: [CatalogRow] = []
    @Published private(set) var heroItems: [HeroItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    /// Every searchable catalog the loaded addons advertise.
    @Published private(set) var searchSources: [SearchSource] = []
    /// The user's own shelves, authored on Android and synced per profile.
    /// Pinned collections come first, as they do upstream.
    @Published private(set) var collections: [MediaCollection] = []
    /// The loaded manifests, keyed by id, so a collection source can be
    /// resolved back to the addon that serves it.
    @Published private(set) var addons = AddonIndex()

    /// The content types the loaded rows actually cover, in a stable order,
    /// so the filter bar only ever offers tabs that lead somewhere.
    var availableTypes: [String] {
        var seen = Set<String>()
        return rows.compactMap { row in
            let type = row.type.lowercased()
            guard !type.isEmpty, seen.insert(type).inserted else { return nil }
            return type
        }
    }

    func rows(matching type: String?) -> [CatalogRow] {
        guard let type else { return rows }
        return rows.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
    }

    private let client = AddonClient()
    private var hasLoaded = false

    /// Which profile's addons are currently on screen, so a profile switch
    /// can be told apart from an ordinary re-appearance.
    private var loadedProfileID: Int?

    /// Loads once per appearance; `refresh()` forces a reload.
    func loadIfNeeded(session: AppSession, profile: Profile) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load(session: session, profile: profile)
    }

    /// Reloads only when the profile actually changed. Profiles can share an
    /// addon list, so this compares the *effective* profile.
    func loadIfProfileChanged(session: AppSession, profile: Profile) async {
        guard hasLoaded, loadedProfileID != profile.effectiveAddonProfileID else { return }
        await load(session: session, profile: profile)
    }

    func refresh(session: AppSession, profile: Profile) async {
        await load(session: session, profile: profile)
    }

    private func load(session: AppSession, profile: Profile) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        loadedProfileID = profile.effectiveAddonProfileID
        let addonURLs = await resolveAddonURLs(session: session, profile: profile)
        let manifests = await manifests(for: addonURLs)

        guard !manifests.isEmpty else {
            rows = []
            loadError = "Couldn't reach any of your addons."
            return
        }

        addons = AddonIndex(manifests)
        searchSources = Self.buildSearchSources(from: manifests)
        await loadCollections(session: session, profile: profile)
        rows = Self.buildRows(from: manifests)
        guard !rows.isEmpty else {
            loadError = "None of your addons publish a browsable catalog."
            return
        }

        await fillRows()
    }

    /// Collections live on the backend, not in a manifest, so a guest has
    /// none. A failure here is quiet: the home screen still has its catalogs.
    private func loadCollections(session: AppSession, profile: Profile) async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else {
            collections = []
            return
        }

        let fetched = try? await CollectionsDirectory.collections(
            configuration: configuration,
            accessToken: token,
            profileID: profile.effectiveAddonProfileID
        )
        // A collection whose folders all point at addons this profile no
        // longer has installed would open on an empty screen, so it is not
        // offered at all.
        collections = (fetched ?? [])
            .map { collection in
                MediaCollection(
                    id: collection.id,
                    title: collection.title,
                    backdropImageURL: collection.backdropImageURL,
                    pinToTop: collection.pinToTop,
                    showAllTab: collection.showAllTab,
                    folders: collection.visibleFolders.filter { folder in
                        folder.addonSources.contains { source in
                            source.addonCatalog.map { addons.entry($0.addonID) != nil } ?? false
                        }
                    }
                )
            }
            .filter { !$0.folders.isEmpty }
        // Partitioned rather than sorted: `sorted` isn't stable, and the
        // author's own order within each group is the point.
        collections = collections.filter(\.pinToTop) + collections.filter { !$0.pinToTop }
    }

    /// A signed-in user's own addon list, or the defaults for guests and for
    /// any backend that won't answer.
    private func resolveAddonURLs(session: AppSession, profile: Profile) async -> [String] {
        guard case .signedIn(let userID, _) = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else { return AddonDirectory.defaultAddonURLs }

        do {
            return try await AddonDirectory.addons(
                configuration: configuration,
                userID: userID,
                accessToken: token,
                profileID: profile.effectiveAddonProfileID
            )
        } catch {
            return AddonDirectory.defaultAddonURLs
        }
    }

    /// Fetches every manifest in parallel, keeping the user's addon order.
    private func manifests(for urls: [String]) async -> [(url: String, manifest: AddonManifest)] {
        let client = client
        let fetched: [Int: (String, AddonManifest)] = await withTaskGroup(
            of: (Int, String, AddonManifest?).self
        ) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    (index, url, try? await client.manifest(baseURL: url))
                }
            }
            var result: [Int: (String, AddonManifest)] = [:]
            for await (index, url, manifest) in group {
                if let manifest { result[index] = (url, manifest) }
            }
            return result
        }
        return fetched.keys.sorted().compactMap { fetched[$0] }
    }

    /// At most a couple of catalogs per addon: fanning a query out to twenty
    /// endpoints on every keystroke would be slower than it is useful.
    private static func buildSearchSources(
        from manifests: [(url: String, manifest: AddonManifest)]
    ) -> [SearchSource] {
        var sources: [SearchSource] = []
        for (url, manifest) in manifests {
            var perAddon = 0
            for catalog in manifest.catalogs where catalog.supportsSearch {
                sources.append(
                    SearchSource(
                        addonName: manifest.name,
                        addonBaseURL: url,
                        type: catalog.type,
                        catalogID: catalog.id
                    )
                )
                perAddon += 1
                if perAddon >= 4 { break }
            }
        }
        return sources
    }

    private static func buildRows(
        from manifests: [(url: String, manifest: AddonManifest)]
    ) -> [CatalogRow] {
        var rows: [CatalogRow] = []
        for (url, manifest) in manifests {
            for catalog in manifest.catalogs where !catalog.needsUserInput {
                rows.append(
                    CatalogRow(
                        id: "\(manifest.id)|\(catalog.type)|\(catalog.id)",
                        title: title(for: catalog),
                        addonName: manifest.name,
                        addonBaseURL: url,
                        type: catalog.type,
                        catalogID: catalog.id
                    )
                )
                if rows.count >= maxRows { return rows }
            }
        }
        return rows
    }

    /// Cinemeta names its movie and series catalogs identically, so the type
    /// goes in the title unless the addon already put it there.
    private static func title(for catalog: AddonCatalog) -> String {
        let base = catalog.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? catalog.id.capitalized
        let label = typeLabel(catalog.type)
        if base.localizedCaseInsensitiveContains(label)
            || base.localizedCaseInsensitiveContains(catalog.type) {
            return base
        }
        return "\(base) \(label)"
    }

    static func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie": "Movies"
        case "series": "Series"
        case "channel": "Channels"
        case "tv": "TV"
        default: type.capitalized
        }
    }

    /// Loads every row's first page in parallel, publishing each as it lands.
    private func fillRows() async {
        let client = client
        let descriptors = rows.map { ($0.id, $0.addonBaseURL, $0.type, $0.catalogID) }

        await withTaskGroup(of: (String, CatalogRow.Content).self) { group in
            for (id, baseURL, type, catalogID) in descriptors {
                group.addTask {
                    do {
                        let items = try await client.catalog(
                            baseURL: baseURL,
                            type: type,
                            catalogID: catalogID
                        )
                        return (id, .loaded(items))
                    } catch {
                        return (id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, content) in group {
                guard let index = rows.firstIndex(where: { $0.id == id }) else { continue }
                rows[index].content = content
            }
        }

        rows.removeAll(where: \.isEmptyAfterLoading)
        if rows.isEmpty { loadError = "Your addons didn't return anything to show." }
        heroItems = Self.pickHeroItems(from: rows)
    }
}

extension HomeViewModel {
    /// Builds the hero carousel. Only titles with a wide backdrop qualify —
    /// a stretched poster behind the title treatment looks broken — and one
    /// title per row keeps the rotation varied rather than showing the top
    /// five of the same catalog.
    static func pickHeroItems(from rows: [CatalogRow]) -> [HeroItem] {
        var seen = Set<String>()
        var picked: [HeroItem] = []

        // Round-robin across rows: first the best candidate from each row,
        // then the second from each, until the carousel is full.
        var depth = 0
        while picked.count < maxHeroItems, depth < 6 {
            var addedThisPass = false
            for row in rows {
                let candidates = row.items.filter { item in
                    item.background?.isEmpty == false
                }
                guard depth < candidates.count else { continue }
                let item = candidates[depth]
                guard seen.insert("\(item.type)|\(item.id)").inserted else { continue }
                picked.append(HeroItem(item: item, addonBaseURL: row.addonBaseURL))
                addedThisPass = true
                if picked.count >= maxHeroItems { break }
            }
            if !addedThisPass { break }
            depth += 1
        }
        return picked
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
