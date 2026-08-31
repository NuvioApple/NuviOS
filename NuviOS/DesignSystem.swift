import SwiftUI
import Combine

// MARK: - Palette

/// A colour theme. Mirrors NuvioMobile's `ThemeColors` palettes so the TV app
/// looks like the same product as the phone app, and lets the user pick the
/// same accents they already know.
struct NuvioPalette: Identifiable, Equatable {
    let id: String
    let name: String
    /// The supporter entitlement this palette needs, if any.
    ///
    /// Upstream's five supporter themes are gated behind `CosmeticEntitlement`
    /// (see `ThemeAccess.kt`); the rest are open to everyone, and the default
    /// is `AppTheme.WHITE`. This port keeps that arrangement rather than
    /// handing out someone else's supporter perks for free.
    var entitlement: CosmeticEntitlement? = nil
    /// The colour used for focus rings, glows and primary emphasis.
    let accent: Color
    /// A second accent used for gradients and secondary emphasis.
    let accentVariant: Color
    /// Sweep used for the wordmark and other gradient-masked artwork.
    let accentGradient: [Color]
    /// Readable foreground on top of `accent`.
    let onAccent: Color
    let background: Color
    let elevated: Color
    let card: Color

    static func rgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension NuvioPalette {
    static let gold = NuvioPalette(
        id: "gold",
        name: "Gold",
        entitlement: .goldTheme,
        accent: rgb(0xFFD45C),
        accentVariant: rgb(0xE8A91C),
        accentGradient: [rgb(0xFFF1A8), rgb(0xFFD45C), rgb(0xE8A91C), rgb(0x9A6200)],
        onAccent: rgb(0x111111),
        background: rgb(0x0B0A07),
        elevated: rgb(0x1D1A14),
        card: rgb(0x262116)
    )

    static let jade = NuvioPalette(
        id: "jade",
        name: "Jade",
        entitlement: .jadeTheme,
        accent: rgb(0x7BF08D),
        accentVariant: rgb(0x0BBF9A),
        accentGradient: [rgb(0x7BF08D), rgb(0x22D37C), rgb(0x0BBF9A)],
        onAccent: rgb(0x111111),
        background: rgb(0x080B09),
        elevated: rgb(0x141D18),
        card: rgb(0x16251D)
    )

    static let roseGold = NuvioPalette(
        id: "roseGold",
        name: "Rose Gold",
        entitlement: .roseGoldTheme,
        accent: rgb(0xFFB37A),
        accentVariant: rgb(0xEC70A9),
        accentGradient: [rgb(0xB75AFF), rgb(0xEC70A9), rgb(0xFFB37A)],
        onAccent: rgb(0x111111),
        background: rgb(0x0D0A0C),
        elevated: rgb(0x1F161D),
        card: rgb(0x281A24)
    )

    static let arcticBlue = NuvioPalette(
        id: "arcticBlue",
        name: "Arctic Blue",
        entitlement: .arcticBlueTheme,
        accent: rgb(0x4DE3FF),
        accentVariant: rgb(0x4D55E8),
        accentGradient: [rgb(0x4DE3FF), rgb(0x3185F5), rgb(0x4D55E8)],
        onAccent: rgb(0x06131A),
        background: rgb(0x080A10),
        elevated: rgb(0x141A24),
        card: rgb(0x161E2A)
    )

    static let graphite = NuvioPalette(
        id: "graphite",
        name: "Graphite",
        entitlement: .graphiteTheme,
        accent: rgb(0xF3F5F7),
        accentVariant: rgb(0x687381),
        accentGradient: [rgb(0xFFFFFF), rgb(0xAAB2BE), rgb(0x687381)],
        onAccent: rgb(0x111111),
        background: rgb(0x08090B),
        elevated: rgb(0x17191D),
        card: rgb(0x20242A)
    )

    static let crimson = NuvioPalette(
        id: "crimson",
        name: "Crimson",
        accent: rgb(0xFF5252),
        accentVariant: rgb(0xC62828),
        accentGradient: [rgb(0xFF8A80), rgb(0xE53935), rgb(0xC62828)],
        onAccent: rgb(0xFFFFFF),
        background: rgb(0x0A0808),
        elevated: rgb(0x1A1414),
        card: rgb(0x241A1A)
    )

    static let ocean = NuvioPalette(
        id: "ocean",
        name: "Ocean",
        accent: rgb(0x42A5F5),
        accentVariant: rgb(0x1565C0),
        accentGradient: [rgb(0x82D8FF), rgb(0x1E88E5), rgb(0x1565C0)],
        onAccent: rgb(0x06131A),
        background: rgb(0x08090C),
        elevated: rgb(0x141820),
        card: rgb(0x1A1F24)
    )

    static let violet = NuvioPalette(
        id: "violet",
        name: "Violet",
        accent: rgb(0xC77DFF),
        accentVariant: rgb(0x6A1B9A),
        accentGradient: [rgb(0xE0AAFF), rgb(0xAB47BC), rgb(0x6A1B9A)],
        onAccent: rgb(0x120A18),
        background: rgb(0x0A080C),
        elevated: rgb(0x1A1520),
        card: rgb(0x211A28)
    )

    static let emerald = NuvioPalette(
        id: "emerald",
        name: "Emerald",
        accent: rgb(0x66BB6A),
        accentVariant: rgb(0x2E7D32),
        accentGradient: [rgb(0xB9F6CA), rgb(0x43A047), rgb(0x2E7D32)],
        onAccent: rgb(0x0A140B),
        background: rgb(0x080A08),
        elevated: rgb(0x141A15),
        card: rgb(0x1A241A)
    )

    static let amber = NuvioPalette(
        id: "amber",
        name: "Amber",
        accent: rgb(0xFFA726),
        accentVariant: rgb(0xEF6C00),
        accentGradient: [rgb(0xFFD180), rgb(0xFB8C00), rgb(0xEF6C00)],
        onAccent: rgb(0x1A1005),
        background: rgb(0x0B0906),
        elevated: rgb(0x1E1A14),
        card: rgb(0x24201A)
    )

    static let rose = NuvioPalette(
        id: "rose",
        name: "Rose",
        accent: rgb(0xEC407A),
        accentVariant: rgb(0xC2185B),
        accentGradient: [rgb(0xFF80AB), rgb(0xD81B60), rgb(0xC2185B)],
        onAccent: rgb(0xFFFFFF),
        background: rgb(0x0A0709),
        elevated: rgb(0x1A1418),
        card: rgb(0x241A1F)
    )

    static let snow = NuvioPalette(
        id: "snow",
        name: "Snow",
        accent: rgb(0xFFFFFF),
        accentVariant: rgb(0xE0E0E0),
        accentGradient: [rgb(0xFFFFFF), rgb(0xF5F5F5), rgb(0xC7C7C7)],
        onAccent: rgb(0x111111),
        background: rgb(0x08080A),
        elevated: rgb(0x18181A),
        card: rgb(0x222222)
    )

    static let all: [NuvioPalette] = [
        .gold, .jade, .roseGold, .arcticBlue, .graphite, .crimson,
        .ocean, .violet, .emerald, .amber, .rose, .snow,
    ]

    /// Upstream's default is `AppTheme.WHITE`; ours is its twin.
    static let fallback: NuvioPalette = .snow

    static func named(_ id: String?) -> NuvioPalette {
        all.first { $0.id == id } ?? fallback
    }

    /// The palettes an account may actually choose.
    static func available(to entitlements: Set<CosmeticEntitlement>) -> [NuvioPalette] {
        all.filter { palette in
            guard let entitlement = palette.entitlement else { return true }
            return entitlements.contains(entitlement)
        }
    }

    var isSupporterOnly: Bool { entitlement != nil }

    var accentBrush: LinearGradient {
        LinearGradient(
            colors: accentGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Theme storage

/// The chosen palette, remembered across launches.
@MainActor
final class ThemeStore: ObservableObject {
    private static let key = "nuvio.palette"
    private let defaults: UserDefaults

    /// Not `@Published`: the wrapper cannot be initialised inside `init` while
    /// the property also has an observer, so the change is announced by hand.
    var paletteID: String {
        willSet { objectWillChange.send() }
        didSet { defaults.set(paletteID, forKey: Self.key) }
    }

    var palette: NuvioPalette { NuvioPalette.named(paletteID) }

    /// Drops back to the default when the chosen palette is a supporter one
    /// the account no longer has — the same fallback `resolveAppTheme` makes.
    func reconcile(with entitlements: Set<CosmeticEntitlement>) {
        guard let entitlement = palette.entitlement, !entitlements.contains(entitlement) else {
            return
        }
        paletteID = NuvioPalette.fallback.id
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.paletteID = defaults.string(forKey: Self.key) ?? NuvioPalette.fallback.id
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = NuvioPalette.fallback
}

extension EnvironmentValues {
    var palette: NuvioPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Focus

/// Reads focus from inside a `ButtonStyle` body. The environment value has to
/// be read by a child view, not by `makeBody` itself, for it to update.
struct FocusReader<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(isFocused) }
}

// MARK: - Background

/// The app's ambient backdrop: a near-black base lit by two soft accent glows.
/// Used behind every screen so the product reads as one surface.
struct NuvioBackground: View {
    @Environment(\.palette) private var palette
    var intensity: Double = 1

    /// How much of the accent wash actually reaches the screen.
    ///
    /// A television is watched in a dark room on a panel that renders black as
    /// black. The wash that gives the phone screen its depth reads there as a
    /// tinted haze behind the artwork, so the TV gets a fraction of it and the
    /// corner vignette carries the depth instead.
    private var glow: Double {
        #if os(tvOS)
        0.30 * intensity
        #else
        intensity
        #endif
    }

    var body: some View {
        ZStack {
            palette.background

            RadialGradient(
                colors: [palette.accent.opacity(0.16 * glow), .clear],
                center: .init(x: 0.08, y: 0.02),
                startRadius: 0,
                endRadius: 1100
            )

            RadialGradient(
                colors: [palette.accentVariant.opacity(0.14 * glow), .clear],
                center: .init(x: 1.0, y: 1.0),
                startRadius: 0,
                endRadius: 1300
            )

            // Keeps the corners heavy so artwork stays the brightest thing.
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center,
                startRadius: 380,
                endRadius: 1500
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Wordmark

/// The Nuvio wordmark, filled with the palette's accent sweep.
struct Wordmark: View {
    @Environment(\.palette) private var palette
    var size: CGFloat = 34

    /// One binary ships to the TV, the phone and the Mac, so the badge says
    /// which one the viewer is actually on.
    private static var platformName: String {
        #if os(tvOS)
        "tvOS"
        #elseif os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    var body: some View {
        HStack(spacing: size * 0.22) {
            Text("NUVIO")
                .font(.system(size: size, weight: .black))
                .tracking(size * 0.18)
                .foregroundStyle(palette.accentBrush)

            Text(Self.platformName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .tracking(size * 0.04)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, size * 0.24)
                .padding(.vertical, size * 0.1)
                .background(
                    Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
                )
        }
        .accessibilityLabel("Nuvio for \(Self.platformName)")
    }
}

// MARK: - Shimmer

/// A moving highlight for skeleton placeholders, so loading reads as loading
/// rather than as an empty shelf.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.65)
                    .offset(x: phase * proxy.size.width * 1.6)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// A grey block standing in for content that hasn't arrived.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.05), lineWidth: 1)
            )
            .shimmering()
    }
}

// MARK: - Buttons

/// The app's button shapes. `prominent` is the filled call to action,
/// `glass` the translucent secondary, `ghost` the quiet tertiary.
struct NuvioButtonStyle: ButtonStyle {
    enum Kind { case prominent, glass, ghost }

    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var kind: Kind = .glass
    var icon: String?
    var fullWidth = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            let active = isFocused || configuration.isPressed

            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 15 : 20, weight: .bold))
                }
                configuration.label
                    .font(.system(size: compact ? 17 : 24, weight: .semibold))
            }
            .foregroundStyle(foreground(active: active))
            .padding(.horizontal, compact ? 20 : 34)
            .padding(.vertical, compact ? 10 : 18)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .modifier(Surface(kind: kind, active: active, palette: palette))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        active ? Color.white.opacity(0.9) : Color.white.opacity(0.16),
                        lineWidth: active ? 2 : 1
                    )
            }
            .shadow(
                color: active ? palette.accent.opacity(0.45) : .black.opacity(0.35),
                radius: active ? 26 : 10,
                y: active ? 12 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private func foreground(active: Bool) -> Color {
        switch kind {
        case .prominent:
            return active ? palette.onAccent : .white
        case .glass, .ghost:
            return active ? .black : .white
        }
    }

}

/// The material behind a `NuvioButtonStyle`.
///
/// Inactive controls are real Liquid Glass. An active one goes solid instead:
/// across a room — and under a thumb — focus has to read as a filled shape,
/// and glass is by design not one.
private struct Surface: ViewModifier {
    let kind: NuvioButtonStyle.Kind
    let active: Bool
    let palette: NuvioPalette

    func body(content: Content) -> some View {
        if active {
            content.background {
                Capsule(style: .continuous).fill(activeFill)
            }
        } else {
            content.glassEffect(glass, in: .capsule)
        }
    }

    /// `prominent` carries the palette tint so the primary action still leads
    /// the eye even as glass.
    private var glass: Glass {
        switch kind {
        case .prominent: return .regular.tint(palette.accent.opacity(0.55))
        case .glass: return .regular
        case .ghost: return .regular.tint(.black.opacity(0.15))
        }
    }

    private var activeFill: AnyShapeStyle {
        switch kind {
        case .prominent: return AnyShapeStyle(palette.accentBrush)
        case .glass, .ghost: return AnyShapeStyle(Color.white)
        }
    }
}

// MARK: - Chips

/// A small fact about a title: a year, a runtime, a genre.
struct MetaChip: View {
    let text: String
    var emphasised = false

    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(emphasised ? palette.onAccent : .white.opacity(0.86))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(
                    emphasised
                        ? AnyShapeStyle(palette.accent)
                        : AnyShapeStyle(Color.white.opacity(0.12))
                )
            }
            .overlay {
                Capsule().stroke(.white.opacity(emphasised ? 0 : 0.12), lineWidth: 1)
            }
    }
}

/// An IMDb-style rating, shown only when an addon actually supplies one.
struct RatingChip: View {
    let rating: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: 15, weight: .bold))
            Text(rating)
                .font(.system(size: 19, weight: .bold))
        }
        .foregroundStyle(NuvioPalette.rgb(0xF5C518))
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.12)))
    }
}

// MARK: - Images

/// An addon-hosted image that fades in rather than popping, and falls back to
/// something readable when the addon has no artwork.
struct RemoteImage<Fallback: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var fallback: () -> Fallback

    @State private var loaded = false

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            case .empty:
                ZStack {
                    Color.white.opacity(0.05)
                    if url != nil { SkeletonBlock(cornerRadius: 0) }
                }
            case .failure:
                fallback()
            @unknown default:
                fallback()
            }
        }
    }
}

extension RemoteImage where Fallback == AnyView {
    /// Convenience for the common case: a flat wash behind whatever is on top.
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.init(url: url, contentMode: contentMode) {
            AnyView(Color.white.opacity(0.05))
        }
    }
}

// MARK: - Text helpers

extension View {
    /// Type that has to stay legible on top of artwork.
    func overArtwork() -> some View {
        self.shadow(color: .black.opacity(0.7), radius: 12, y: 4)
    }
}
