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

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 26)]

    var body: some View {
        ZStack {
            content()
                .opacity(needsChoice ? 0 : 1)

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

    private var chooser: some View {
        ZStack {
            NuvioBackground(intensity: 0.3).ignoresSafeArea()

            VStack(spacing: 34) {
                Spacer(minLength: 0)

                // Upstream's own wording, and no wordmark: Nuvio doesn't put
                // its name on this screen.
                VStack(spacing: 6) {
                    Text("Who's watching?")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Select a profile to continue")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }

                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            choose(profile)
                        } label: {
                            VStack(spacing: 10) {
                                ProfileAvatar(
                                    profile: profile,
                                    size: 92,
                                    isActive: profile.index == profiles.currentIndex,
                                    activeRing: palette.accent
                                )
                                Text(profile.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 28)

                Button("Continue as \(profiles.current.name)") {
                    choose(profiles.current)
                }
                .font(.subheadline.weight(.semibold))
                .tint(.white.opacity(0.5))

                Spacer(minLength: 0)
            }
        }
    }

    private func choose(_ profile: Profile) {
        profiles.select(profile)
        library.activate(profile: profile)
        withAnimation(.easeInOut(duration: 0.35)) { hasChosen = true }
    }
}
#endif
