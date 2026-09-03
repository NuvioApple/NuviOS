#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI

/// The tabs along the bottom. `profile` is deliberately last so it lands in
/// the trailing corner of the bar.
enum RootTab: Hashable {
    case home, movies, series, search, profile
}

/// The last press on the shell's bar. A screen pushed inside a tab watches
/// this and pops itself when its own tab is pressed.
struct ShellBarPress: Equatable {
    let tab: RootTab
    let count: Int
}

private struct ShellBarPressKey: EnvironmentKey {
    static let defaultValue = ShellBarPress(tab: .home, count: 0)
}

extension EnvironmentValues {
    var shellBarPress: ShellBarPress {
        get { self[ShellBarPressKey.self] }
        set { self[ShellBarPressKey.self] = newValue }
    }
}

/// The iPhone shell.
///
/// Android Nuvio navigates from a sidebar that expands on focus; a phone has
/// no focus engine and iOS 26 gives a Liquid Glass tab bar for free, so the
/// same destinations live along the bottom instead — Home, Movies, Series,
/// Search, and the profile switcher in the trailing corner, which is the
/// arrangement Netflix, Disney+ and the Apple TV app have all settled on.
///
/// The Mac takes the same destinations across the platform's own tab bar at
/// the top of the window, which keeps the full width of the window for the
/// artwork the app exists to show.
struct RootView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var library: LibraryStore

    /// One model for the whole shell: the Movies, Series and Search tabs are
    /// views of the same catalogs, so they must not each refetch them.
    @StateObject private var model = HomeViewModel()
    @State private var selection: RootTab = .home
    @State private var switchingProfile = false
    /// Bumped every time a destination is picked from the bar, so the screen
    /// behind it can return to its own root. Pressing Home while inside a
    /// folder means "take me home", not "you are already on Home".
    @State private var barPress = ShellBarPress(tab: .home, count: 0)

    let subtitle: String

    /// The bar's own binding: it selects the tab, and it records the press.
    /// SwiftUI hands a tab bar only the new value, and re-picking the tab you
    /// are already on doesn't change it — so the count is what a screen
    /// watches, not the tab.
    private var barSelection: Binding<RootTab> {
        Binding {
            selection
        } set: { tab in
            selection = tab
            barPress = ShellBarPress(tab: tab, count: barPress.count + 1)
        }
    }

    var body: some View {
        ProfileGate {
            TabView(selection: barSelection) {
                Tab("Home", systemImage: "play.house.fill", value: RootTab.home) {
                    BrowseScreen(model: model, tab: .home, filter: nil, title: "Home", showsHero: true)
                        .measuringContentViewport()
                }

                Tab("Movies", systemImage: "film.stack.fill", value: RootTab.movies) {
                    BrowseScreen(model: model, tab: .movies, filter: "movie", title: "Movies", showsHero: false)
                        .measuringContentViewport()
                }

                Tab("Series", systemImage: "tv.fill", value: RootTab.series) {
                    BrowseScreen(model: model, tab: .series, filter: "series", title: "Series", showsHero: false)
                        .measuringContentViewport()
                }

                // Deliberately not `role: .search`: that role pins the tab to
                // the trailing end of the bar, and the trailing corner belongs
                // to the profile switcher.
                Tab("Search", systemImage: "magnifyingglass", value: RootTab.search) {
                    SearchScreen(model: model)
                        .measuringContentViewport()
                }

                // The trailing tab, and the app's only profile control:
                // tap for the profile and its settings, press and hold to
                // switch who is watching.
                Tab(value: RootTab.profile) {
                    ProfileScreen(subtitle: subtitle, model: model)
                        .measuringContentViewport()
                } label: {
                    // Tab item images are template-rendered by UIKit, so the
                    // avatar artwork can't survive here; the profile's name
                    // carries the identity instead, and the face is drawn in
                    // the switcher and on the profile screen.
                    Label(profiles.current.name, systemImage: "person.crop.circle.fill")
                }
            }
            // Gets the glass bar out of the way while browsing artwork, the way
            // the Apple TV app hides its chrome as you scroll.
            // No glass behind the bar either: the artwork runs under it
            // uninterrupted rather than through a blurred slab.
            .platformShellTabViewStyle()
            .platformMinimizingTabBar()
            .tint(theme.palette.accent)
            // A tab item takes no gestures in SwiftUI, so the hold is caught
            // by a window-level recognizer that leaves the tap alone.
            // The long-press shortcut rides on a UIKit window recognizer, so
            // it is iOS-only; macOS reaches the switcher through the profile
            // tab itself.
            #if os(iOS)
            .background(TabBarLongPress { switchingProfile = true })
            #endif
            .sheet(isPresented: $switchingProfile) {
                ProfileSwitcherSheet()
                    .presentationDetents([.height(260)])
                    .presentationBackground(.thinMaterial)
                    // Detents are an iOS sheet's idea of height; the Mac
                    // ignores them and would size to the content instead.
                    .platformSheetSizing(minWidth: 520, minHeight: 300)
            }
        }
        .environment(\.shellBarPress, barPress)
        .task {
            await profiles.sync(session: session)
            PlaybackProgress.activate(profile: profiles.current)
            // Reads the device's copy of the list first and reconciles it with
            // the account's, so the list draws immediately and then catches up.
            await library.sync(session: session, profile: profiles.current)
            await model.loadIfNeeded(session: session, profile: profiles.current)
        }
        // Switching profile can switch addon lists, so the shelves reload and
        // the list follows the profile.
        .task(id: profiles.currentIndex) {
            PlaybackProgress.activate(profile: profiles.current)
            await library.sync(session: session, profile: profiles.current)
            await model.loadIfProfileChanged(session: session, profile: profiles.current)
        }
    }
}
#endif
