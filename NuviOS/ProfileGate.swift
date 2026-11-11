#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI

/// The "Who's watching?" screen every streaming app opens with when an
/// account has more than one profile.
///
/// It only stands in front of the app when there is a choice to make: a single
/// profile is not a decision, it's a delay, so the gate is skipped entirely.
struct ProfileGate<Content: View>: View {
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.palette) private var palette

    @ViewBuilder var content: () -> Content

    @State private var hasChosen = false

    private var needsChoice: Bool { profiles.profiles.count > 1 && !hasChosen }

    /// Big, the way Disney+ does it: the faces are the whole screen.
    #if os(tvOS)
    private let avatarSize: CGFloat = 220
    private let itemSpacing: CGFloat = 70
    #elseif os(macOS)
    private let avatarSize: CGFloat = 130
    private let itemSpacing: CGFloat = 40
    #else
    private let avatarSize: CGFloat = 104
    private let itemSpacing: CGFloat = 26
    #endif
    /// Room for the focused avatar to grow without touching its neighbours.
    private var itemWidth: CGFloat { avatarSize * 1.18 }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: itemWidth), spacing: itemSpacing)]
    }

    /// The width the profiles would occupy on a single row, so a short row is
    /// centred rather than pinned to the leading edge of a wide grid.
    private var naturalWidth: CGFloat {
        let count = CGFloat(max(profiles.profiles.count, 1))
        return count * itemWidth + (count - 1) * itemSpacing
    }

    var body: some View {
        ZStack {
            // Not built at all until a profile is picked: a hidden copy would
            // still load its shelves and start the hero's trailer behind the
            // chooser.
            if !needsChoice {
                content()
            }

            if needsChoice {
                chooser
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: needsChoice)
        .onAppear {
            // One profile: adopt it and get out of the way.
            if profiles.profiles.count <= 1 {
                library.activate(profile: profiles.current)
            }
        }
        // The account's profiles arrive after the first sync; if that turns a
        // one-profile account into several, the gate is no longer owed.
        .onChange(of: profiles.profiles.count) { _, count in
            if count <= 1 { library.activate(profile: profiles.current) }
        }
    }

    @FocusState private var focusedProfile: Int?

    private var chooser: some View {
        ZStack {
            NuvioBackground(intensity: 0.3).ignoresSafeArea()

            VStack(spacing: titleGap) {
                Spacer(minLength: 0)

                Text("Who's watching?")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                LazyVGrid(columns: columns, spacing: itemSpacing) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            choose(profile)
                        } label: {
                            Text(profile.name)  // the style draws the tile
                        }
                        .buttonStyle(ProfileTileStyle(profile: profile, size: avatarSize))
                        .focused($focusedProfile, equals: profile.index)
                    }
                }
                // The remote starts on whoever watched last, so carrying on is
                // a single press.
                .defaultFocus($focusedProfile, profiles.currentIndex)
                .onAppear {
                    DispatchQueue.main.async { focusedProfile = profiles.currentIndex }
                }
                .frame(maxWidth: naturalWidth)
                .padding(.horizontal, 28)

                Spacer(minLength: 0)
            }
        }
    }

    #if os(tvOS)
    private let titleSize: CGFloat = 56
    private let titleGap: CGFloat = 70
    #else
    private let titleSize: CGFloat = 30
    private let titleGap: CGFloat = 34
    #endif

    private func choose(_ profile: Profile) {
        profiles.select(profile)
        library.activate(profile: profile)
        withAnimation(.easeInOut(duration: 0.35)) { hasChosen = true }
    }
}

/// One profile on the chooser. Focused, it grows and gets a bright ring and
/// glow, and its name lights up; the rest dim back, so it's obvious from the
/// sofa which one Select will open.
private struct ProfileTileStyle: ButtonStyle {
    let profile: Profile
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        FocusReader { isFocused in
            #if os(tvOS)
            let lit = isFocused
            let dims = true
            #else
            let lit = configuration.isPressed
            let dims = false
            #endif
            VStack(spacing: size * 0.12) {
                ProfileAvatar(profile: profile, size: size)
                    .overlay {
                        Circle()
                            .strokeBorder(.white, lineWidth: max(3, size * 0.03))
                            .opacity(lit ? 1 : 0)
                    }
                    .shadow(color: .white.opacity(lit ? 0.35 : 0), radius: size * 0.12)
                    .scaleEffect(lit ? 1.12 : 1)

                Text(profile.name)
                    .font(.system(size: max(15, size * 0.13), weight: lit ? .bold : .semibold))
                    .foregroundStyle(.white.opacity(lit || !dims ? 1 : 0.5))
                    .lineLimit(1)
            }
            .opacity(lit || !dims ? 1 : 0.55)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lit)
        }
    }
}
#endif
