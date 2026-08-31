import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var theme = ThemeStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var library = LibraryStore()
    /// The backend's avatar catalogue, shared so a face can be drawn from any
    /// sheet or cover without the environment being threaded through it.
    @StateObject private var avatars = AvatarCatalog.shared
    @StateObject private var membership = MembershipStore()
    @StateObject private var tmdb = TmdbSettings.shared
    /// The addon list the Play button fans its stream request out across.
    @StateObject private var addons = AddonScope()
    @State private var didStart = false
    #if os(macOS)
    /// The Mac player is drawn here, at the root, rather than by the screen
    /// that started it — see `PlayerPresenter`.
    @StateObject private var player = PlayerPresenter.shared
    #endif

    var body: some View {
        Group {
            if !didStart {
                SplashView()
            } else {
                switch session.state {
                case .signedOut:
                    // Phones and Macs get NuvioMobile's email-and-password
                    // auth screen; the TV keeps the focus-driven QR layout,
                    // which exists because a remote can't type a password
                    // comfortably. A Mac has a keyboard, so it signs in the way
                    // the phone does. The TV can still reach the typed form
                    // from the profile tab once it is inside.
                    #if os(tvOS)
                    WelcomeView()
                    #else
                    AuthScreen()
                    #endif
                case .guest:
                    shell("Browsing as a guest · sign in to sync your library")
                case .signedIn(_, let email):
                    shell(email.map { "Signed in as \($0)" } ?? "Signed in")
                }
            }
        }
        #if os(macOS)
        // Over the sidebar, the toolbar and the title bar: on a Mac the player
        // owns the whole window, the way QuickTime and the TV app do.
        .overlay {
            if let request = player.request {
                NuvioPlayerScreen(request: request)
                    .environmentObject(session)
                    .environment(\.platformCoverDismiss) { player.close() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.request)
        #endif
        .environmentObject(theme)
        .environmentObject(profiles)
        .environmentObject(library)
        .environmentObject(membership)
        .environmentObject(tmdb)
        .environmentObject(addons)
        .environment(\.palette, theme.palette)
        .preferredColorScheme(.dark)
        // The app also runs in a resizable window on iPad and on Mac, so
        // the layout metrics key off the space a screen has rather than off a
        // guess at the device. On iOS the destinations sit in a bar over the
        // content, so the window is that space and one measurement here serves
        // every screen. The Mac's sidebar makes the window wider than the
        // column, so it measures inside the shell instead — see
        // `measuringContentViewport`.
        #if os(iOS) || os(tvOS)
        .measuringViewport()
        #endif
        .task {
            guard !didStart else { return }
            await session.start()
            withAnimation(.easeInOut(duration: 0.4)) { didStart = true }
        }
        // Avatars come from the backend, so they can only be fetched once
        // discovery has produced a server to ask.
        .task(id: session.configuration?.backendURL) {
            avatars.load(configuration: session.configuration)
        }
        // The accent palettes upstream reserves for supporters are reserved
        // here too, so a lapsed account falls back rather than keeping one.
        .task(id: sessionIdentity) {
            await membership.refresh(session: session)
            theme.reconcile(with: membership.access.entitlements)
        }
        // Addons are profile-scoped, so the stream sources follow whoever is
        // watching — and are re-read when the account itself changes.
        .task(id: "\(sessionIdentity)|\(profiles.current.effectiveAddonProfileID)") {
            await addons.refresh(session: session, profile: profiles.current, force: true)
            // The debrid keys are profile-scoped in the same way, and are read
            // off the account rather than typed in here: whatever the viewer
            // set up on the TV app is what plays on this device.
            await loadDebridCredentials()
            await configureWatchProgressSync()
        }
    }

    /// Reads the account's debrid keys, so a source that arrives as
    /// instructions rather than an address can be resolved at press-time.
    private func loadDebridCredentials() async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else {
            await DebridCredentials.shared.clear()
            return
        }
        await DebridCredentials.shared.load(
            configuration: configuration,
            accessToken: token,
            profileID: profiles.current.effectiveAddonProfileID,
            identity: "\(sessionIdentity)|\(profiles.current.effectiveAddonProfileID)"
        )
    }

    /// Hands the player's progress writer the account it should write to, so
    /// what is watched here reaches the Continue Watching shelf everywhere.
    private func configureWatchProgressSync() async {
        guard case .signedIn = session.state,
              let configuration = session.configuration,
              let token = await session.validAccessToken()
        else {
            await WatchProgressSync.shared.configure(
                configuration: nil,
                accessToken: nil,
                profileID: Profile.primaryIndex
            )
            return
        }
        await WatchProgressSync.shared.configure(
            configuration: configuration,
            accessToken: token,
            profileID: profiles.current.effectiveAddonProfileID
        )
    }

    /// Changes when the account does, so entitlements are re-read on sign-in
    /// and cleared on sign-out.
    private var sessionIdentity: String {
        switch session.state {
        case .signedIn(let userID, _): "signedIn-\(userID)"
        case .guest: "guest"
        case .signedOut: "signedOut"
        }
    }

    /// The signed-in shell: Home, Movies, Series, Search and the profile, on
    /// every platform. The phone hangs them off the Liquid Glass tab bar, the
    /// Mac off a sidebar, and the TV off the focusable bar across the top —
    /// but they are one set of screens, so a feature added anywhere shows up
    /// everywhere.
    private func shell(_ subtitle: String) -> some View {
        RootView(subtitle: subtitle)
    }
}

/// Shown for the moment it takes to discover the backend. A breathing
/// wordmark rather than a bare spinner.
struct SplashView: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            NuvioBackground()

            Wordmark(size: 56)
                .scaleEffect(glow ? 1.03 : 0.98)
                .opacity(glow ? 1 : 0.7)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        glow = true
                    }
                }
        }
    }
}

/// The signed-out landing screen.
struct WelcomeView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var theme: ThemeStore
    @State private var showingSignIn = false
    @State private var showingServer = false

    var body: some View {
        GeometryReader { proxy in
            let metrics = LayoutMetrics(width: proxy.size.width, height: proxy.size.height)

            ZStack {
                NuvioBackground()
                AuroraLayer()

                VStack(alignment: .leading, spacing: metrics.isCompact ? 26 : 44) {
                    Spacer(minLength: 0)

                    Wordmark(size: metrics.isCompact ? 32 : 62)

                    VStack(alignment: .leading, spacing: metrics.isCompact ? 10 : 18) {
                        Text("Everything you watch,\non the big screen.")
                            .font(.system(size: metrics.isCompact ? 30 : 66, weight: .black))
                            .tracking(-1.5)
                            .lineSpacing(metrics.isCompact ? 0 : 6)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Unofficial Apple TV client · not affiliated with NuvioMedia")
                            .font(.system(size: metrics.isCompact ? 14 : 24))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AdaptiveStack(isVertical: metrics.isCompact, spacing: metrics.stackSpacing) {
                        Button("Sign in with a code") { showingSignIn = true }
                            .buttonStyle(
                                NuvioButtonStyle(kind: .prominent, icon: "qrcode", compact: metrics.isCompact)
                            )
                            .disabled(!session.canSignIn)

                        Button("Continue as guest") { session.continueAsGuest() }
                            .buttonStyle(
                                NuvioButtonStyle(kind: .glass, icon: "person.fill", compact: metrics.isCompact)
                            )

                        Button("Server") { showingServer = true }
                            .buttonStyle(
                                NuvioButtonStyle(kind: .ghost, icon: "server.rack", compact: metrics.isCompact)
                            )
                    }
                    .padding(.top, metrics.isCompact ? 4 : 12)

                    if !session.canSignIn {
                        Label(
                            session.discoveryError
                                ?? "Couldn't reach \(session.backendDisplayName). You can still browse as a guest.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: metrics.isCompact ? 13 : 20))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .frame(
                    maxWidth: metrics.isCompact ? .infinity : min(proxy.size.width * 0.62, 1400),
                    alignment: .leading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.pagePadding)
            }
        }
        .platformFullScreenCover(isPresented: $showingSignIn) {
            SignInView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
        .platformFullScreenCover(isPresented: $showingServer) {
            ServerView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
    }
}

/// Slow-moving accent blooms behind the landing screen. There's no artwork to
/// show before sign-in, so the screen supplies its own motion.
private struct AuroraLayer: View {
    @Environment(\.palette) private var palette
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                blob(palette.accent.opacity(0.20))
                    .frame(width: proxy.size.width * 0.7, height: proxy.size.width * 0.7)
                    .offset(
                        x: proxy.size.width * (drift ? 0.34 : 0.22),
                        y: proxy.size.height * (drift ? -0.18 : -0.05)
                    )

                blob(palette.accentVariant.opacity(0.18))
                    .frame(width: proxy.size.width * 0.55, height: proxy.size.width * 0.55)
                    .offset(
                        x: proxy.size.width * (drift ? 0.05 : 0.2),
                        y: proxy.size.height * (drift ? 0.3 : 0.16)
                    )
            }
            .blur(radius: 90)
            .onAppear {
                withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                    drift = true
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color) -> some View {
        Circle().fill(
            RadialGradient(colors: [color, .clear], center: .center, startRadius: 0, endRadius: 460)
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(AppSession())
}
