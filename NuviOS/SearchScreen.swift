#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI
import Combine

/// One search hit, tagged with the addon that answered.
struct SearchResult: Identifiable, Equatable {
    let item: MetaItem
    let addonBaseURL: String

    var id: String { "\(item.type)|\(item.id)" }
}

/// Runs a query across every searchable catalog the loaded addons advertise.
@MainActor
final class SearchViewModel: ObservableObject {
    private static let recentsKey = "nuvio.search.recents"
    private static let maxRecents = 8

    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published private(set) var recents: [String] = []

    private let client = AddonClient()
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    /// Debounced: a query fires 350ms after the last keystroke, so typing a
    /// title doesn't queue a fan-out per letter.
    func search(_ query: String, sources: [SearchSource]) {
        task?.cancel()

        let trimmed = query.trimmed
        guard trimmed.count >= 2 else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }

        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.run(trimmed, sources: sources)
        }
    }

    private func run(_ query: String, sources: [SearchSource]) async {
        let client = client
        let found: [[SearchResult]] = await withTaskGroup(of: [SearchResult].self) { group in
            for source in sources {
                group.addTask {
                    let items = (try? await client.search(
                        baseURL: source.addonBaseURL,
                        type: source.type,
                        catalogID: source.catalogID,
                        query: query
                    )) ?? []
                    return items.map { SearchResult(item: $0, addonBaseURL: source.addonBaseURL) }
                }
            }
            var collected: [[SearchResult]] = []
            for await batch in group { collected.append(batch) }
            return collected
        }

        guard !Task.isCancelled else { return }

        // Addons overlap heavily — the same IMDb id comes back from several —
        // so the first answer for an id wins and the rest are dropped.
        var seen = Set<String>()
        var merged: [SearchResult] = []
        for batch in found {
            for result in batch where seen.insert(result.id).inserted {
                merged.append(result)
            }
        }

        results = merged
        hasSearched = true
        isSearching = false
        remember(query)
    }

    func clear() {
        task?.cancel()
        results = []
        hasSearched = false
        isSearching = false
    }

    private func remember(_ query: String) {
        var updated = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        updated.insert(query, at: 0)
        recents = Array(updated.prefix(Self.maxRecents))
        defaults.set(recents, forKey: Self.recentsKey)
    }

    func forgetRecents() {
        recents = []
        defaults.removeObject(forKey: Self.recentsKey)
    }
}

/// The Search tab.
///
/// Every streaming app leads with search, and the Stremio protocol already
/// answers `search=` on any catalog that advertises it — so this fans one
/// query out across the profile's own addons.
struct SearchScreen: View {
    @ObservedObject var model: HomeViewModel
    @StateObject private var search = SearchViewModel()

    @State private var query = ""
    @State private var selected: MetaSelection?
    @Environment(\.palette) private var palette

    /// Adaptive rather than a fixed count, so a wider window fills with more
    /// columns of the shelves' own poster size instead of stretched ones.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Phone.posterWidth * 0.88), spacing: Phone.posterSpacing)]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background.ignoresSafeArea()
                content(for: query.trimmed)
            }
            .navigationTitle("Search")
            .scrollEdgeEffectStyle(.soft, for: .top)
            // `navigationBarDrawer` is an iOS placement. macOS puts the field
            // in the toolbar and tvOS gives search its own focusable keyboard
            // screen; `.automatic` is right on both.
            #if !os(iOS)
            .searchable(text: $query, prompt: "Movies, series, people")
            #else
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Movies, series, people"
            )
            #endif
            .onChange(of: query) { _, new in
                search.search(new, sources: model.searchSources)
            }
            .navigationDestination(item: $selected) { selection in
                DetailView(selection: selection)
            }
        }
    }

    @ViewBuilder
    private func content(for trimmed: String) -> some View {
        if trimmed.count < 2 {
            idle
        } else if search.isSearching && search.results.isEmpty {
            grid(placeholders: 9)
        } else if search.results.isEmpty && search.hasSearched {
            EmptyState(
                message: "No addon had anything for “\(trimmed)”.",
                systemImage: "magnifyingglass"
            )
            .padding(.horizontal, Phone.pagePadding)
        } else {
            results
        }
    }

    private var results: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(search.results) { result in
                    PosterCard(
                        item: result.item,
                        addonBaseURL: result.addonBaseURL,
                        width: 104
                    ) {
                        selected = MetaSelection(
                            item: result.item,
                            addonBaseURL: result.addonBaseURL
                        )
                    }
                }
            }
            .padding(.horizontal, Phone.pagePadding)
            .padding(.bottom, Phone.tabBarClearance)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func grid(placeholders count: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(0..<count, id: \.self) { _ in
                    SkeletonBlock(cornerRadius: Phone.posterRadius)
                        .frame(width: 104, height: 156)
                }
            }
            .padding(.horizontal, Phone.pagePadding)
        }
        .allowsHitTesting(false)
    }

    /// Before anything is typed: what was searched before, then what the
    /// profile's own catalogs can answer.
    private var idle: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !search.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent searches")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Spacer()
                            Button("Clear") { search.forgetRecents() }
                                .font(.subheadline)
                                .tint(palette.accent)
                        }

                        ForEach(search.recents, id: \.self) { recent in
                            Button {
                                query = recent
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.white.opacity(0.4))
                                    Text(recent)
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                                .font(.subheadline)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 22)
                }

                Text(
                    model.searchSources.isEmpty
                        ? "None of your addons offer search."
                        : "Searching \(model.searchSources.count) catalog\(model.searchSources.count == 1 ? "" : "s") across your addons."
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Phone.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, Phone.tabBarClearance)
        }
    }
}
#endif
