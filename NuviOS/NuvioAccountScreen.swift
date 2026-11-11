#if os(iOS) || os(macOS)
import SwiftUI

// MARK: - Account page

/// nuvio.tv/account, native: the site's left nav and its TV Settings page,
/// pushed inside the app from Profile. Wide layouts (Mac, iPad) keep the
/// sidebar beside the content; an iPhone gets the sidebar as a list.
struct NuvioAccountScreen: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var profiles: ProfileStore
    @StateObject private var store = NuvioSettingsStore()
    @State private var tab: AccountTab? = .tvSettings

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass == .regular }
    #else
    private let isWide = true
    #endif

    var body: some View {
        ZStack {
            NuvioBackground(intensity: 0.8).ignoresSafeArea()
            if isWide {
                HStack(alignment: .top, spacing: 18) {
                    AccountSidebar(selection: $tab)
                        .frame(width: 230)
                    detail(for: tab ?? .tvSettings)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            } else {
                compactRoot
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Nuvio Account")
        .task(id: profiles.current.index) {
            await store.load(session: session, profileIndex: profiles.current.index)
        }
    }

    private var compactRoot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OverviewCard(store: store)
                AccountSidebar(selection: Binding(
                    get: { nil },
                    set: { tab = $0 }
                ), showsOverview: false)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
        .navigationDestination(item: compactTab) { selected in
            ZStack {
                NuvioBackground(intensity: 0.8).ignoresSafeArea()
                detail(for: selected)
            }
            .navigationTitle(selected.title)
        }
    }

    /// On iPhone the TV Settings tab starts selected for the wide layout;
    /// only a tap should push it.
    private var compactTab: Binding<AccountTab?> {
        Binding(
            get: { tab == .tvSettings && !pushedOnce ? nil : tab },
            set: { tab = $0; pushedOnce = true }
        )
    }
    @State private var pushedOnce = false

    @ViewBuilder
    private func detail(for tab: AccountTab) -> some View {
        switch tab {
        case .overview:
            ScrollView { OverviewCard(store: store).padding(.bottom, 40) }
        case .tvSettings:
            TVSettingsPage(store: store, isWide: isWide)
        case .membership:
            ScrollView { MembershipCard().padding(.bottom, 40) }
        default:
            WebFallbackCard(tab: tab)
        }
    }
}

// MARK: - Sidebar

enum AccountTab: String, CaseIterable, Identifiable, Hashable {
    case overview, profiles, mediaServers, plugins, addons, watchProgress, library
    case collections, watched, tvSettings, mobileSettings, membership, devices, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .profiles: "Profiles"
        case .mediaServers: "Media servers"
        case .plugins: "Plugins"
        case .addons: "Addons"
        case .watchProgress: "Watch Progress"
        case .library: "Library"
        case .collections: "Collections"
        case .watched: "Watched"
        case .tvSettings: "TV Settings"
        case .mobileSettings: "Mobile Settings"
        case .membership: "Membership"
        case .devices: "Devices"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .profiles: "person.2"
        case .mediaServers: "server.rack"
        case .plugins: "puzzlepiece.extension"
        case .addons: "shippingbox"
        case .watchProgress: "play.circle"
        case .library: "books.vertical"
        case .collections: "rectangle.stack"
        case .watched: "checkmark.circle"
        case .tvSettings: "tv"
        case .mobileSettings: "iphone"
        case .membership: "star"
        case .devices: "laptopcomputer.and.iphone"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// Built natively; the rest open that part of the website.
    var isNative: Bool { [.overview, .tvSettings, .membership].contains(self) }
}

private struct AccountSidebar: View {
    @Binding var selection: AccountTab?
    var showsOverview = true
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var profiles: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                ProfileAvatar(profile: profiles.current, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profiles.current.name).font(.subheadline.weight(.semibold))
                    Text("Active profile").font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            ForEach(AccountTab.allCases.filter { showsOverview || $0 != .overview }) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.symbol)
                            .frame(width: 20)
                            .foregroundStyle(selection == tab ? theme.palette.accent : .white.opacity(0.75))
                        Text(tab.title)
                        Spacer(minLength: 0)
                        if !tab.isNative {
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.palette.accent.opacity(0.18))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .glassCard(cornerRadius: 22)
    }
}

// MARK: - Overview & Membership

private struct OverviewCard: View {
    @ObservedObject var store: NuvioSettingsStore
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var profiles: ProfileStore

    private var email: String {
        if case .signedIn(_, let email) = session.state { return email ?? "Signed in" }
        return "Not signed in"
    }

    var body: some View {
        SettingsCard(title: "Overview", detail: "Manage synced data across web, mobile, and TV.") {
            VStack(alignment: .leading, spacing: 14) {
                stat("ACCOUNT", email)
                stat("ACTIVE PROFILE", profiles.current.name)
                stat("TV SETTINGS UPDATED", store.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Text("PROFILES").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(profiles.profiles) { profile in
                            VStack(spacing: 6) {
                                ProfileAvatar(profile: profile, size: 48, isActive: profile == profiles.current)
                                Text(profile.name).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.body)
        }
    }
}

private struct MembershipCard: View {
    @EnvironmentObject private var membership: MembershipStore

    var body: some View {
        SettingsCard(title: "Membership", detail: "Supporter themes and cosmetics on this account.") {
            VStack(alignment: .leading, spacing: 10) {
                Text(membership.access.tier?.capitalized ?? "Free")
                    .font(.title3.weight(.semibold))
                ForEach(CosmeticEntitlement.allCases, id: \.self) { item in
                    Label(
                        item.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                        systemImage: membership.access.includes(item) ? "checkmark.circle.fill" : "lock"
                    )
                    .foregroundStyle(.white.opacity(membership.access.includes(item) ? 0.95 : 0.45))
                }
            }
        }
    }
}

private struct WebFallbackCard: View {
    let tab: AccountTab
    @EnvironmentObject private var session: AppSession
    @State private var showBrowser = false

    var body: some View {
        ScrollView {
            SettingsCard(title: tab.title, detail: "This part of your account opens on nuvio.tv for now.") {
                Button("Open on nuvio.tv", systemImage: "safari") { open() }
                    .buttonStyle(.glass)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showBrowser) {
            if let url = session.dashboardURL { DashboardBrowser(url: url) {} }
        }
        #endif
    }

    private func open() {
        #if os(macOS)
        if let url = session.dashboardURL { DashboardBrowser.shared.open(url) {} }
        #else
        showBrowser = true
        #endif
    }
}

// MARK: - TV Settings

private enum TVSection: String, CaseIterable, Identifiable {
    case appearance, experience, layout, playback, integrations, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var subtitle: String {
        switch self {
        case .appearance: "Choose your color theme, font and language"
        case .experience: "Essential or Advanced"
        case .layout: "Home structure and poster styles"
        case .playback: "Player, subtitles, and auto-play"
        case .integrations: "Manage available integrations"
        case .advanced: "Performance, navigation, cache, and diagnostics"
        }
    }
}

private struct TVSettingsPage: View {
    @ObservedObject var store: NuvioSettingsStore
    let isWide: Bool
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var theme: ThemeStore
    @State private var section: TVSection = .appearance

    var body: some View {
        VStack(spacing: 0) {
            if isWide { header }
            sectionTabs
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isWide { header }
                    status
                    TVSectionContent(section: section, store: store)
                        .disabled(!store.canEdit)
                        .opacity(store.canEdit ? 1 : 0.55)
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, store.hasChanges && !isWide ? 110 : 40)
            }
            .refreshable { await reload() }
        }
        .overlay(alignment: .bottom) {
            if !isWide && store.hasChanges { saveBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy, value: store.hasChanges)
        .background {
            // ⌘S anywhere on the page.
            Button("") { Task { await store.save(session: session) } }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .disabled(!store.hasChanges)
        }
    }

    private func reload() async {
        await store.load(session: session, profileIndex: profiles.current.index)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TV Settings").font(.title2.weight(.bold))
                Text("\(profiles.current.name) · synced with the Android TV app · Updated \(updatedText)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            if isWide {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .buttonStyle(.glass)
                Button("Discard") { store.discard() }
                    .buttonStyle(.glass)
                    .disabled(!store.hasChanges)
                saveButton
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
    }

    private var saveButton: some View {
        Button {
            Task { await store.save(session: session) }
        } label: {
            if store.isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
        }
        .buttonStyle(.glassProminent)
        .tint(theme.palette.accent)
        .disabled(!store.hasChanges || store.isSaving)
    }

    private var updatedText: String {
        guard let date = store.updatedAt else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }

    private var sectionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TVSection.allCases) { item in
                    Button(item.title) { withAnimation(.snappy) { section = item } }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(section == item ? theme.palette.onAccent : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if section == item { Capsule().fill(theme.palette.accent) }
                        }
                        .glassPill()
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, isWide ? 0 : 16)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch store.phase {
        case .loading where store.updatedAt == nil:
            ProgressView().frame(maxWidth: .infinity).padding()
        case .noBlob:
            notice("Open Nuvio on your TV once with this profile. Its settings appear here after the first sync.", "tv")
        case .unsupportedVersion(let v):
            notice("These settings come from a newer Nuvio (version \(v)). They're shown read-only.", "exclamationmark.triangle")
        case .failed(let message):
            notice("Couldn't load the TV's settings: \(message)", "exclamationmark.triangle")
        default:
            EmptyView()
        }
        if let error = store.saveError {
            notice("Couldn't save: \(error)", "exclamationmark.triangle")
        }
    }

    private func notice(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.85))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
            .padding(.horizontal, isWide ? 0 : 16)
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            Text(store.edits.count == 1 ? "1 change" : "\(store.edits.count) changes")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Discard") { store.discard() }.buttonStyle(.glass)
            saveButton
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .sensoryFeedback(.success, trigger: store.updatedAt)
    }
}

// MARK: - Section content

/// Feature keys and defaults mirror the Android DataStores.
private enum F {
    static let theme = "theme_settings"
    static let layout = "layout_settings"
    static let experience = "experience_settings"
    static let player = "player_settings"
    static let badges = "stream_badge_settings"
    static let trailer = "trailer_settings"
    static let tmdb = "tmdb_settings"
    static let mdblist = "mdblist_settings"
}

private struct TVSectionContent: View {
    let section: TVSection
    @ObservedObject var store: NuvioSettingsStore
    @EnvironmentObject private var membership: MembershipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case .appearance: appearance
            case .experience: experience
            case .layout: layout
            case .playback: playback
            case .integrations: integrations
            case .advanced: advanced
            }
        }
    }

    // Appearance

    @ViewBuilder private var appearance: some View {
        SettingsCard(title: "COLOR THEME", detail: "Pick the accent color used across the app") {
            ThemeSwatchGrid(
                selection: store.stringBinding(F.theme, "selected_theme", default: "CRIMSON"),
                isUnlocked: { swatch in swatch.entitlement.map(membership.access.includes) ?? true }
            )
            Divider().overlay(.white.opacity(0.1))
            ToggleRow(store: store, feature: F.theme, key: "amoled_mode", default: false,
                      title: "AMOLED Mode", detail: "Use pure black for app backgrounds")
        }
        SettingsCard(title: "FONT AND LANGUAGE", detail: "Choose the typeface and locale used throughout the app") {
            ChoiceRow(store: store, feature: F.theme, key: "selected_font", default: "INTER",
                      title: "App Font", detail: "Choose your preferred font",
                      options: [("INTER", "Inter"), ("DM_SANS", "DM Sans"), ("OPEN_SANS", "Open Sans")])
        }
        SettingsCard(title: "SETTINGS INTERFACE", detail: "Choose how the settings app is organized on TV") {
            ChoiceCards(store: store, feature: F.theme, key: "settings_ui_style", default: "CLASSIC", options: [
                .init(value: "CLASSIC", title: "Default", detail: "Standard settings layout with cards.", symbol: "rectangle.grid.1x2"),
                .init(value: "ZEN", title: "Minimal", detail: "A simple, flatter settings layout.", symbol: "list.bullet"),
                .init(value: "HORIZON", title: "Top Bar", detail: "Move settings navigation into tabs at the top.", symbol: "rectangle.topthird.inset.filled"),
            ])
        }
    }

    // Experience

    private var experience: some View {
        SettingsCard(title: "EXPERIENCE MODE", detail: "Start simple or unlock every customization. You can switch anytime.") {
            ChoiceCards(store: store, feature: F.experience, key: "mode", default: "ESSENTIAL", options: [
                .init(value: "ESSENTIAL", title: "Essential", detail: "Focused setup, add-ons, playback basics, Trakt, and account settings.", symbol: "sparkles"),
                .init(value: "ADVANCED", title: "Advanced", detail: "Full settings, layout controls, catalog order, collections, plug-ins, and diagnostics.", symbol: "slider.horizontal.3"),
            ])
        }
    }

    // Layout

    @ViewBuilder private var layout: some View {
        SettingsCard(title: "HOME LAYOUT", detail: "Choose structure and hero source.") {
            ChoiceCards(store: store, feature: F.layout, key: "selected_layout", default: "MODERN", options: [
                .init(value: "CLASSIC", title: "Classic View", detail: "Scroll through categories horizontally", symbol: "rectangle.split.3x1"),
                .init(value: "GRID", title: "Grid View", detail: "Browse everything in a vertical grid with a hero section", symbol: "square.grid.3x3"),
                .init(value: "MODERN", title: "Modern View", detail: "Fixed hero with a single active row for faster browsing", symbol: "rectangle.bottomhalf.inset.filled"),
            ])
            ToggleRow(store: store, feature: F.layout, key: "modern_landscape_posters_enabled", default: false,
                      title: "Landscape Posters", detail: "Switch between portrait and landscape cards for Modern view.")
            ToggleRow(store: store, feature: F.layout, key: "modern_hero_full_screen_backdrop", default: false,
                      title: "Fullscreen Hero Backdrop", detail: "Expand the hero backdrop to fill the entire screen.")
            ToggleRow(store: store, feature: F.layout, key: "classic_focus_gradient_enabled", default: false,
                      title: "Focused Item Gradient", detail: "Blend artwork colors into the right side of Classic home.")
        }
        SettingsCard(title: "HOME CONTENT", detail: "Control what appears on home and search.") {
            ToggleRow(store: store, feature: F.layout, key: "sidebar_collapsed_by_default", default: false,
                      title: "Collapse Sidebar", detail: "Hide sidebar by default; show when focused.")
            ToggleRow(store: store, feature: F.layout, key: "modern_sidebar_enabled", default: false,
                      title: "Modern Sidebar", detail: "Enable floating sidebar navigation.")
            ToggleRow(store: store, feature: F.layout, key: "hero_section_enabled", default: true,
                      title: "Show Hero Section", detail: "Display hero carousel at top of home.")
            ChoiceRow(store: store, feature: F.layout, key: "discover_location", default: "IN_SEARCH",
                      title: "Discover Location", detail: "Adds a Discover section for browsing.",
                      options: [("OFF", "Off"), ("IN_SEARCH", "Show in Search"), ("IN_SIDEBAR", "Show in Side Panel")])
            ToggleRow(store: store, feature: F.layout, key: "poster_labels_enabled", default: true,
                      title: "Show Poster Labels", detail: "Show titles under posters in rows, grid, and see-all.")
            ToggleRow(store: store, feature: F.layout, key: "catalog_addon_name_enabled", default: true,
                      title: "Show Addon Name", detail: "Show source name under catalog titles.")
            ToggleRow(store: store, feature: F.layout, key: "catalog_type_suffix_enabled", default: true,
                      title: "Show Catalog Type", detail: "Show type suffix next to catalog name (Movie/Series).")
            ToggleRow(store: store, feature: F.layout, key: "hide_unreleased_content", default: false,
                      title: "Hide Unreleased Content", detail: "Hide movies and shows that haven't been released yet.")
            ChoiceRow(store: store, feature: F.layout, key: "home_imdb_ratings_visibility", default: "SHOW_ALL",
                      title: "Home IMDb Ratings", detail: nil, options: [("SHOW_ALL", "Show"), ("HIDE_ALL", "Hide")])
        }
        SettingsCard(title: "DETAIL PAGE", detail: "Settings for the detail and episode screens.") {
            ChoiceRow(store: store, feature: F.layout, key: "episode_options_overlay_style", default: "ARTWORK",
                      title: "Episode Options Background", detail: nil,
                      options: [("BLUR", "Blur"), ("ARTWORK", "Artwork"), ("NONE", "None")])
            ToggleRow(store: store, feature: F.layout, key: "blur_unwatched_episodes", default: false,
                      title: "Blur Unwatched Episodes", detail: "Blur episode thumbnails until watched to avoid spoilers.")
            ToggleRow(store: store, feature: F.trailer, key: "trailer_enabled", default: true,
                      title: "Auto-play Trailers", detail: "Automatically play trailers on the detail screen after a period of inactivity")
            SliderRow(store: store, feature: F.trailer, key: "trailer_delay_seconds", default: 7,
                      range: 1...30, unit: "s", title: "Trailer Delay")
            ToggleRow(store: store, feature: F.layout, key: "detail_page_trailer_button_enabled", default: true,
                      title: "Show Trailer Button", detail: "Show trailer button on detail page (only when trailer is available).")
            ToggleRow(store: store, feature: F.layout, key: "prefer_external_meta_addon_detail", default: true,
                      title: "Prefer meta from external addon", detail: "Use metadata from external addon instead of catalog addon.")
            ToggleRow(store: store, feature: F.layout, key: "show_full_release_date", default: true,
                      title: "Show full release date", detail: "For movies, show full release date instead of year only.")
            ChoiceRow(store: store, feature: F.layout, key: "detail_imdb_ratings_visibility", default: "SHOW_ALL",
                      title: "Detail IMDb Ratings", detail: nil, options: [
                        ("SHOW_ALL", "Show all"), ("HIDE_EPISODES", "Hide episode ratings"),
                        ("HIDE_UNWATCHED_EPISODES", "Hide for unwatched episodes"), ("HIDE_ALL", "Hide all"),
                      ])
        }
        SettingsCard(title: "STREAMS", detail: "Display settings for stream results and player source panels.") {
            ToggleRow(store: store, feature: F.badges, key: "show_file_size_badges", default: true,
                      title: "Size badges", detail: "Show file size badges in stream results and player source panels.")
            ToggleRow(store: store, feature: F.badges, key: "show_addon_logo", default: true,
                      title: "Addon logo", detail: "Show addon logo and name next to stream sources.")
            ChoiceRow(store: store, feature: F.badges, key: "stream_badge_placement", default: "TOP",
                      title: "Badge position", detail: "Choose whether Fusion and size badges appear above or below stream cards.",
                      options: [("TOP", "Top"), ("BOTTOM", "Bottom")])
        }
        SettingsCard(title: "CONTINUE WATCHING", detail: "Settings for the Continue Watching section.") {
            ToggleRow(store: store, feature: F.layout, key: "continue_watching_enabled", default: true,
                      title: "Show Continue Watching", detail: nil)
            ChoiceCards(store: store, feature: F.layout, key: "continue_watching_card_style", default: "CARD", options: [
                .init(value: "CARD", title: "Card", detail: nil, symbol: "rectangle"),
                .init(value: "WIDE", title: "Wide", detail: nil, symbol: "rectangle.ratio.16.to.9"),
                .init(value: "POSTER", title: "Poster", detail: nil, symbol: "rectangle.portrait"),
            ])
            ToggleRow(store: store, feature: F.layout, key: "use_episode_thumbnails_in_cw", default: true,
                      title: "Use Episode Thumbnails", detail: "Use episode thumbnails as default image. When disabled, uses backdrop.")
            ToggleRow(store: store, feature: F.layout, key: "blur_continue_watching_next_up", default: false,
                      title: "Blur Unwatched in Continue Watching", detail: "Blur next episode thumbnails to avoid spoilers.")
            ToggleRow(store: store, feature: F.layout, key: "next_up_from_furthest_episode", default: true,
                      title: "Up Next From Furthest Episode", detail: "Disable for rewatches to use the most recently watched episode instead.")
            ToggleRow(store: store, feature: F.layout, key: "show_unaired_next_up", default: true,
                      title: "Show Unaired Next Up Episodes", detail: "Include upcoming episodes before they air.")
            ChoiceRow(store: store, feature: F.layout, key: "continue_watching_sort_mode", default: "DEFAULT",
                      title: "Sort Order", detail: "How Continue Watching items are arranged",
                      options: [("DEFAULT", "Default"), ("STREAMING_STYLE", "Streaming Style"), ("SPLIT_UPCOMING", "Split Upcoming")])
        }
        SettingsCard(title: "FOCUSED POSTER", detail: "Advanced behavior for focused poster cards.") {
            ToggleRow(store: store, feature: F.layout, key: "focused_poster_backdrop_expand_enabled", default: true,
                      title: "Expand Focused Poster to Backdrop", detail: "Expand focused poster after idle delay.")
            SliderRow(store: store, feature: F.layout, key: "focused_poster_backdrop_expand_delay_seconds", default: 3,
                      range: 1...10, unit: "s", title: "Backdrop Expand Delay")
            ToggleRow(store: store, feature: F.layout, key: "focused_poster_backdrop_trailer_enabled", default: false,
                      title: "Autoplay Trailer", detail: "Play trailer preview for focused content when available.")
        }
    }

    // Playback

    @ViewBuilder private var playback: some View {
        SettingsCard(title: "GENERAL", detail: "Core playback behavior.") {
            ToggleRow(store: store, feature: F.player, key: "loading_overlay_enabled", default: true,
                      title: "Loading Overlay", detail: "Show loading screen until first video frame appears.")
            ToggleRow(store: store, feature: F.player, key: "show_player_loading_status", default: true,
                      title: "Show loading status", detail: "Show source loading status while waiting for streams.")
            ToggleRow(store: store, feature: F.player, key: "pause_overlay_enabled", default: true,
                      title: "Pause Overlay", detail: "Show details overlay after 5 seconds while paused.")
            ToggleRow(store: store, feature: F.player, key: "osd_clock_enabled", default: true,
                      title: "OSD Clock", detail: "Show current time and end time while controls are visible.")
            ToggleRow(store: store, feature: F.player, key: "skip_intro_enabled", default: true,
                      title: "Skip Intro", detail: "Use introdb.app to detect intros and recaps.")
            ToggleRow(store: store, feature: F.player, key: "parental_guide_enabled", default: true,
                      title: "Content Warnings", detail: "Show parental guidance overlay when playback starts.")
        }
        SettingsCard(title: "PLAYER & STREAM SELECTION", detail: "Player preference, auto-play, and source filtering.") {
            ToggleRow(store: store, feature: F.player, key: "post_play_recommendations_enabled", default: true,
                      title: "Post-play Recommendations", detail: "Show recommendations after playback.")
            SliderRow(store: store, feature: F.player, key: "post_play_movie_threshold_percent", default: 90,
                      range: 50...100, unit: "%", title: "Movie Post-play Threshold")
            ToggleRow(store: store, feature: F.player, key: "stream_reuse_last_link_enabled", default: false,
                      title: "Reuse Last Link", detail: "Auto-play your last working stream for this same movie/episode when cache is still valid")
            ChoiceCards(store: store, feature: F.player, key: "stream_auto_play_mode", default: "MANUAL", options: [
                .init(value: "MANUAL", title: "Manual", detail: "Choose the stream", symbol: "hand.tap"),
                .init(value: "FIRST_STREAM", title: "First source", detail: "Auto-play first source", symbol: "play"),
                .init(value: "REGEX_MATCH", title: "Regex match", detail: "Auto-play a matching source", symbol: "text.magnifyingglass"),
            ])
            if store.string(F.player, "stream_auto_play_mode", default: "MANUAL") == "REGEX_MATCH" {
                TextRow(store: store, feature: F.player, key: "stream_auto_play_regex", title: "Regex", secret: false)
            }
            SliderRow(store: store, feature: F.player, key: "stream_auto_play_timeout_seconds", default: 3,
                      range: 0...30, unit: "s", title: "Stream Selection Timeout")
            ToggleRow(store: store, feature: F.player, key: "stream_auto_play_next_episode_enabled", default: false,
                      title: "Auto-play Next Episode", detail: "Start next episode automatically when prompt appears.")
            ToggleRow(store: store, feature: F.player, key: "stream_auto_play_prefer_bingegroup_next_episode", default: true,
                      title: "Prefer Binge Group (Next Episode)", detail: "Try the same source profile first before normal auto-play rules.")
            ToggleRow(store: store, feature: F.player, key: "stream_auto_play_reuse_binge_group", default: true,
                      title: "Reuse Binge Group", detail: "Remember and reuse the last binge group across sessions.")
            ChoiceRow(store: store, feature: F.player, key: "next_episode_threshold_mode", default: "PERCENTAGE",
                      title: "Next Episode Threshold Mode", detail: "Used when no outro timestamp is available.",
                      options: [("PERCENTAGE", "Percentage"), ("MINUTES_BEFORE_END", "Minutes before end")])
        }
        SettingsCard(title: "AUDIO & VIDEO", detail: "Audio controls and video compatibility.") {
            LanguageRow(store: store, feature: F.player, key: "preferred_audio_language", default: "device",
                        title: "Preferred Audio Language", extras: [("device", "Device default"), ("original", "Original audio"), ("default", "None")])
            LanguageRow(store: store, feature: F.player, key: "secondary_preferred_audio_language", default: "",
                        title: "Secondary Preferred Language", extras: [("", "None")])
            ToggleRow(store: store, feature: F.player, key: "frame_rate_matching", default: false,
                      title: "Frame Rate Matching", detail: "Switch the display refresh rate to match the video.")
            ToggleRow(store: store, feature: F.player, key: "tunneling_enabled", default: false,
                      title: "Tunneled Playback", detail: "Hand video straight to the display hardware.")
        }
    }

    // Integrations

    @ViewBuilder private var integrations: some View {
        SettingsCard(title: "TMDB ENRICHMENT", detail: "Choose which metadata fields should come from TMDB") {
            ToggleRow(store: store, feature: F.tmdb, key: "tmdb_enabled", default: false,
                      title: "Enable TMDB Enrichment", detail: "Use TMDB as a metadata source to enhance addon data")
            ToggleRow(store: store, feature: F.tmdb, key: "tmdb_modern_home_enabled", default: false,
                      title: "Enable on Modern Home", detail: "Also apply TMDB enrichment to Modern Home hero and focused cards")
            ToggleRow(store: store, feature: F.tmdb, key: "tmdb_enrich_continue_watching", default: true,
                      title: "Enrich Continue Watching", detail: "Apply TMDB enrichment to Continue Watching items")
            LanguageRow(store: store, feature: F.tmdb, key: "tmdb_language", default: "en", title: "Language", extras: [])
            ChipGroup(store: store, feature: F.tmdb, title: "Fields", chips: [
                ("tmdb_use_artwork", "Artwork", true), ("tmdb_use_basic_info", "Basic Info", true),
                ("tmdb_use_details", "Details", true), ("tmdb_use_release_dates", "Release Dates", false),
                ("tmdb_use_credits", "Credits", true), ("tmdb_use_productions", "Productions", true),
                ("tmdb_use_networks", "Networks", true), ("tmdb_use_episodes", "Episodes", true),
                ("tmdb_use_trailers", "Trailers", true), ("tmdb_use_more_like_this", "More Like This", true),
                ("tmdb_use_collections", "Collections", true),
            ])
        }
        SettingsCard(title: "MDBLIST RATINGS", detail: "Configure external ratings shown in the detail hero") {
            ToggleRow(store: store, feature: F.mdblist, key: "mdblist_enabled", default: false,
                      title: "Enable MDBList Ratings", detail: "Fetch ratings from external providers in metadata detail screen")
            TextRow(store: store, feature: F.mdblist, key: "mdblist_api_key", title: "API Key", secret: true)
            ChipGroup(store: store, feature: F.mdblist, title: "Show scores", chips: [
                ("mdblist_show_trakt", "Trakt", true), ("mdblist_show_imdb", "IMDb", true),
                ("mdblist_show_tmdb", "TMDB", true), ("mdblist_show_letterboxd", "Letterboxd", true),
                ("mdblist_show_tomatoes", "Rotten Tomatoes", true), ("mdblist_show_audience", "Audience", true),
                ("mdblist_show_metacritic", "Metacritic", true), ("mdblist_show_mal", "MyAnimeList", true),
            ])
        }
        SettingsCard(title: "CONNECTED SERVICES", detail: "Debrid accounts, stream rules and Trakt are set up on nuvio.tv for now.") {
            EmptyView()
        }
    }

    // Advanced

    private var advanced: some View {
        SettingsCard(title: "PERFORMANCE & NAVIGATION", detail: "Advanced layout behavior shared across devices.") {
            ToggleRow(store: store, feature: F.layout, key: "fast_horizontal_navigation_enabled", default: false,
                      title: "Fast Horizontal Navigation", detail: "Increase D-pad repeat speed in rows while keeping repeat throttling enabled.")
            ToggleRow(store: store, feature: F.layout, key: "smooth_bring_into_view_enabled", default: true,
                      title: "Nuvio Focus Scrolling", detail: "Use Nuvio's custom global focus scroll animation and positioning.")
            ToggleRow(store: store, feature: F.layout, key: "follow_addons_order", default: false,
                      title: "Follow addon order", detail: "Use installed addon order when arranging catalog rows.")
            ToggleRow(store: store, feature: F.layout, key: "compose_highlighter_enabled", default: false,
                      title: "Compose Highlighter", detail: "Flash borders around recomposing UI elements for performance debugging.")
            ToggleRow(store: store, feature: F.player, key: "playback_issue_reports_enabled", default: false,
                      title: "Playback Issue Reports", detail: "Show report buttons during playback, long loading, and playback errors.")
        }
    }
}

// MARK: - Building blocks

struct SettingsCard<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.bold)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.65))
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.5))
                }
            }
            content()
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22)
    }
}

/// Title, help text and a dot while the value differs from what was pulled.
private struct RowLabel: View {
    let title: String
    let detail: String?
    let edited: Bool
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(theme.palette.accent).frame(width: 6, height: 6)
                .opacity(edited ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ToggleRow: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let `default`: Bool
    let title: String
    let detail: String?
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        Toggle(isOn: store.boolBinding(feature, key, default: `default`)) {
            RowLabel(title: title, detail: detail, edited: store.isEdited(feature, key))
        }
        .tint(theme.palette.accent)
    }
}

private struct ChoiceRow: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let `default`: String
    let title: String
    let detail: String?
    let options: [(String, String)]

    var body: some View {
        let binding = store.stringBinding(feature, key, default: `default`)
        if options.count <= 3 {
            VStack(alignment: .leading, spacing: 8) {
                RowLabel(title: title, detail: detail, edited: store.isEdited(feature, key))
                Picker(title, selection: binding) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } else {
            HStack {
                RowLabel(title: title, detail: detail, edited: store.isEdited(feature, key))
                Spacer()
                Picker(title, selection: binding) {
                    ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

private struct SliderRow: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let `default`: Int
    let range: ClosedRange<Int>
    let unit: String
    let title: String

    var body: some View {
        let value = store.int(feature, key, default: `default`)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                RowLabel(title: title, detail: nil, edited: store.isEdited(feature, key))
                Spacer()
                Text(value == 0 && unit == "s" ? "Instant" : "\(value)\(unit)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { store.set(feature, key, .int(Int($0.rounded()))) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
        }
    }
}

private struct TextRow: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let title: String
    let secret: Bool

    var body: some View {
        let binding = store.stringBinding(feature, key, default: "")
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(title: title, detail: nil, edited: store.isEdited(feature, key))
            Group {
                if secret { SecureField(title, text: binding) } else { TextField(title, text: binding) }
            }
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .platformNoAutocapitalization()
            .padding(10)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Toggleable chips for a set of on/off keys that read as one choice.
private struct ChipGroup: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String
    let title: String
    let chips: [(key: String, label: String, default: Bool)]
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body)
            FlowLayout(spacing: 8) {
                ForEach(chips, id: \.key) { chip in
                    let on = store.bool(feature, chip.key, default: chip.default)
                    Button {
                        store.set(feature, chip.key, .bool(!on))
                    } label: {
                        Label(chip.label, systemImage: on ? "checkmark" : "plus")
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(on ? theme.palette.onAccent : .white)
                            .background(Capsule().fill(on ? theme.palette.accent : .white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Large selectable cards for a mode choice.
private struct ChoiceCards: View {
    struct Option {
        let value: String
        let title: String
        let detail: String?
        let symbol: String
    }

    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let `default`: String
    let options: [Option]
    @EnvironmentObject private var theme: ThemeStore

    var body: some View {
        let selected = store.string(feature, key, default: `default`)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(options, id: \.value) { option in
                    let isOn = option.value == selected
                    Button {
                        store.set(feature, key, .string(option.value))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: option.symbol)
                                .font(.title2)
                                .foregroundStyle(isOn ? theme.palette.accent : .white.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(option.title).font(.subheadline.weight(.semibold))
                            if let detail = option.detail {
                                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(width: 180, alignment: .topLeading)
                        .background(.white.opacity(isOn ? 0.1 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isOn ? theme.palette.accent : .white.opacity(0.08), lineWidth: isOn ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// The accent themes Android offers; the first five are supporter-only.
private struct ThemeSwatch: Identifiable {
    let id: String
    let name: String
    let color: Color
    let entitlement: CosmeticEntitlement?

    static let all: [ThemeSwatch] = [
        .init(id: "CRIMSON", name: "Crimson", color: Color(red: 0.86, green: 0.15, blue: 0.24), entitlement: nil),
        .init(id: "OCEAN", name: "Ocean", color: Color(red: 0.12, green: 0.53, blue: 0.9), entitlement: nil),
        .init(id: "VIOLET", name: "Violet", color: Color(red: 0.55, green: 0.36, blue: 0.96), entitlement: nil),
        .init(id: "EMERALD", name: "Emerald", color: Color(red: 0.06, green: 0.73, blue: 0.51), entitlement: nil),
        .init(id: "AMBER", name: "Amber", color: Color(red: 0.96, green: 0.62, blue: 0.04), entitlement: nil),
        .init(id: "ROSE", name: "Rose", color: Color(red: 0.93, green: 0.28, blue: 0.6), entitlement: nil),
        .init(id: "WHITE", name: "White", color: Color(white: 0.95), entitlement: nil),
        .init(id: "GOLD", name: "Gold", color: Color(red: 1.0, green: 0.83, blue: 0.36), entitlement: .goldTheme),
        .init(id: "JADE", name: "Jade", color: Color(red: 0.48, green: 0.94, blue: 0.55), entitlement: .jadeTheme),
        .init(id: "ROSE_GOLD", name: "Rose Gold", color: Color(red: 1.0, green: 0.7, blue: 0.48), entitlement: .roseGoldTheme),
        .init(id: "ARCTIC_BLUE", name: "Arctic Blue", color: Color(red: 0.3, green: 0.89, blue: 1.0), entitlement: .arcticBlueTheme),
        .init(id: "GRAPHITE", name: "Graphite", color: Color(white: 0.45), entitlement: .graphiteTheme),
    ]
}

private struct ThemeSwatchGrid: View {
    @Binding var selection: String
    let isUnlocked: (ThemeSwatch) -> Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 12)], spacing: 14) {
            ForEach(ThemeSwatch.all) { swatch in
                let unlocked = isUnlocked(swatch)
                Button {
                    if unlocked { selection = swatch.id }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(swatch.color).frame(width: 40, height: 40)
                            if selection == swatch.id {
                                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 48, height: 48)
                            }
                            if !unlocked {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.black.opacity(0.7))
                            }
                        }
                        .frame(width: 50, height: 50)
                        Text(swatch.name).font(.caption)
                        if swatch.entitlement != nil {
                            Text("Supporter")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                    .opacity(unlocked ? 1 : 0.5)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A searchable language list, as a popover on the Mac and a pushed list on iOS.
private struct LanguageRow: View {
    @ObservedObject var store: NuvioSettingsStore
    let feature: String, key: String
    let `default`: String
    let title: String
    let extras: [(String, String)]
    @State private var picking = false
    @State private var query = ""

    private var options: [(String, String)] { extras + Languages.all }

    var body: some View {
        let current = store.string(feature, key, default: `default`)
        HStack {
            RowLabel(title: title, detail: nil, edited: store.isEdited(feature, key))
            Spacer()
            Button {
                picking = true
            } label: {
                HStack(spacing: 4) {
                    Text(options.first { $0.0 == current }?.1 ?? current)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.glass)
            .popover(isPresented: $picking) {
                list(current: current)
                    .frame(minWidth: 280, minHeight: 380)
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }

    private func list(current: String) -> some View {
        NavigationStack {
            List(options.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }, id: \.0) { option in
                Button {
                    store.set(feature, key, .string(option.0))
                    picking = false
                } label: {
                    HStack {
                        Text(option.1)
                        Spacer()
                        if option.0 == current { Image(systemName: "checkmark") }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle(title)
        }
    }
}

private enum Languages {
    /// ISO 639-1 codes, named in the user's language.
    static let all: [(String, String)] = {
        let codes = ["af", "sq", "am", "ar", "hy", "az", "eu", "be", "bn", "bs", "bg", "my", "ca", "zh",
                     "hr", "cs", "da", "nl", "en", "et", "fil", "fi", "fr", "gl", "ka", "de", "el", "gu",
                     "he", "hi", "hu", "is", "id", "ga", "it", "ja", "kn", "kk", "km", "ko", "lo", "lv",
                     "lt", "mk", "ms", "ml", "mt", "mr", "mn", "ne", "no", "pa", "fa", "pl", "pt", "pt-BR",
                     "ro", "ru", "sr", "si", "sk", "sl", "es", "es-419", "sw", "sv", "ta", "te", "th", "tr",
                     "uk", "ur", "uz", "vi", "cy", "zu"]
        return codes
            .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.1 < $1.1 }
    }()
}

/// Wraps chips onto as many lines as they need.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + lineHeight), points)
    }
}
#endif
