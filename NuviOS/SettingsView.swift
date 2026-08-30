import SwiftUI

/// Appearance, account and server, in one place reachable from the home
/// screen's top bar.
struct SettingsView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss

    let subtitle: String
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var showingServer = false
    @State private var showingSignIn = false

    var body: some View {
        Screen { metrics in
            VStack(alignment: .leading, spacing: metrics.lerp(30, 52)) {
                header(metrics)
                appearance(metrics)
                account(metrics)
                server(metrics)
                about(metrics)
            }
        }
        .preferredColorScheme(.dark)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
        .fullScreenCover(isPresented: $showingServer) {
            ServerView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
        .fullScreenCover(isPresented: $showingSignIn) {
            SignInView()
                .environmentObject(theme)
                .environment(\.palette, theme.palette)
        }
    }

    // MARK: Sections

    private func header(_ metrics: LayoutMetrics) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 10) {
                Wordmark(size: metrics.wordmarkSize * 0.8)
                Text("Settings")
                    .font(.system(size: metrics.screenTitleSize, weight: .black))
                    .tracking(-1)
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 20)

            Button("Done") { dismiss() }
                .buttonStyle(
                    NuvioButtonStyle(kind: .glass, icon: "xmark", compact: metrics.isCompact)
                )
        }
    }

    private func appearance(_ metrics: LayoutMetrics) -> some View {
        SettingsSection(title: "Appearance", metrics: metrics) {
            VStack(alignment: .leading, spacing: metrics.lerp(12, 20)) {
                Text("Accent")
                    .font(.system(size: metrics.lerp(13, 20), weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: metrics.lerp(12, 22)) {
                        ForEach(NuvioPalette.all) { option in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    theme.paletteID = option.id
                                }
                            } label: {
                                Text(option.name)
                            }
                            .buttonStyle(
                                SwatchStyle(
                                    option: option,
                                    isSelected: theme.paletteID == option.id,
                                    metrics: metrics
                                )
                            )
                        }
                    }
                    .padding(.vertical, metrics.lerp(6, 16))
                    .padding(.horizontal, 4)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func account(_ metrics: LayoutMetrics) -> some View {
        SettingsSection(title: "Account", metrics: metrics) {
            VStack(alignment: .leading, spacing: metrics.lerp(14, 22)) {
                Text(subtitle)
                    .font(.system(size: metrics.lerp(15, 24), weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                AdaptiveStack(isVertical: metrics.isCompact, spacing: metrics.stackSpacing) {
                    Button(isRefreshing ? "Refreshing…" : "Refresh catalogs") {
                        onRefresh()
                        dismiss()
                    }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .glass, icon: "arrow.clockwise", compact: metrics.isCompact)
                    )
                    .disabled(isRefreshing)

                    if case .signedIn = session.state {
                        Button("Sign out") { session.signOut(); dismiss() }
                            .buttonStyle(
                                NuvioButtonStyle(kind: .ghost, icon: "rectangle.portrait.and.arrow.right", compact: metrics.isCompact)
                            )
                    } else {
                        Button("Sign in with a code") { showingSignIn = true }
                            .buttonStyle(
                                NuvioButtonStyle(kind: .glass, icon: "qrcode", compact: metrics.isCompact)
                            )
                            .disabled(!session.canSignIn)
                    }
                }
            }
        }
    }

    private func server(_ metrics: LayoutMetrics) -> some View {
        SettingsSection(title: "Server", metrics: metrics) {
            VStack(alignment: .leading, spacing: metrics.lerp(14, 22)) {
                Text("Connected to \(session.backendDisplayName)")
                    .font(.system(size: metrics.lerp(15, 24), weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Change server") { showingServer = true }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .glass, icon: "server.rack", compact: metrics.isCompact)
                    )
            }
        }
    }

    private func about(_ metrics: LayoutMetrics) -> some View {
        Text("Unofficial Apple TV client · not affiliated with NuvioMedia")
            .font(.system(size: metrics.lerp(12, 18)))
            .foregroundStyle(.white.opacity(0.35))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled block on the settings page.
private struct SettingsSection<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let metrics: LayoutMetrics
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.lerp(14, 24)) {
            HStack(spacing: 12) {
                Capsule()
                    .fill(palette.accentBrush)
                    .frame(width: metrics.lerp(3, 5), height: metrics.lerp(18, 30))

                Text(title)
                    .font(.system(size: metrics.lerp(18, 30), weight: .bold))
                    .foregroundStyle(.white)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One accent choice: the palette's own gradient, with its name underneath.
private struct SwatchStyle: ButtonStyle {
    let option: NuvioPalette
    let isSelected: Bool
    let metrics: LayoutMetrics

    private var size: CGFloat { metrics.lerp(54, 100) }

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            VStack(spacing: metrics.lerp(6, 12)) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: option.accentGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: size, height: size)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.36, weight: .heavy))
                            .foregroundStyle(option.onAccent)
                    }
                }
                .overlay {
                    Circle().strokeBorder(
                        isFocused ? Color.white : Color.white.opacity(isSelected ? 0.85 : 0.12),
                        lineWidth: isFocused ? 4 : (isSelected ? 3 : 1)
                    )
                }
                .shadow(
                    color: isFocused ? option.accent.opacity(0.6) : .black.opacity(0.4),
                    radius: isFocused ? 24 : 8,
                    y: isFocused ? 12 : 4
                )

                configuration.label
                    .font(.system(size: metrics.lerp(11, 17), weight: .semibold))
                    .foregroundStyle(.white.opacity(isFocused || isSelected ? 0.95 : 0.5))
            }
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.12 : 1))
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
        }
    }
}
