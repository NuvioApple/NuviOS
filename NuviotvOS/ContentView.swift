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
    @State private var didStart = false

    var body: some View {
        Group {
            if !didStart {
                SplashView()
            } else {
                switch session.state {
                case .signedOut:
                    // Phones get NuvioMobile's auth screen; the TV keeps the
                    // focus-driven QR layout.
                    #if os(iOS)
                    AuthScreen()
                    #else
                    WelcomeView()
                    #endif
                case .guest:
                    shell("Browsing as a guest · sign in to sync your library")
                case .signedIn(_, let email):
                    shell(email.map { "Signed in as \($0)" } ?? "Signed in")
                }
            }
        }
        .environmentObject(theme)
        .environmentObject(profiles)
        .environmentObject(library)
        .environmentObject(membership)
        .environmentObject(tmdb)
        .environment(\.palette, theme.palette)
        .preferredColorScheme(.dark)
        // The iOS build also runs in a resizable window on iPad and on Mac, so
        // the layout metrics key off the window rather than off a guess at the
        // device. Measured once, here, for every screen below.
        #if os(iOS)
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

    /// The signed-in shell. The phone gets the Liquid Glass tab bar with the
    /// profile switcher in its trailing corner; the TV keeps its focus-driven
    /// single-screen layout.
    @ViewBuilder
    private func shell(_ subtitle: String) -> some View {
        #if os(iOS)
        RootView(subtitle: subtitle)
        #else
        HomeView(subtitle: subtitle)
        #endif
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
        .fullScreenCover(isPresented: $showingSignIn) {
            SignInView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
        .fullScreenCover(isPresented: $showingServer) {
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
