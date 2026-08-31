#if os(iOS) || os(macOS) || os(tvOS)
import SwiftUI

/// The trailing tab: who is watching, and everything that belongs to them.
/// The switcher sits at the top because that is what the tab bar's bottom-right
/// control promises when you tap it.
struct ProfileScreen: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var theme: ThemeStore
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var membership: MembershipStore
    @EnvironmentObject private var tmdb: TmdbSettings

    let subtitle: String
    @ObservedObject var model: HomeViewModel

    /// One presentation, not four. SwiftUI honours a single `.sheet` per
    /// view, so stacking one modifier per destination silently loses all but
    /// the last — which is why "Edit profile" opened nothing.
    private enum Destination: Identifiable {
        case editor(Profile?)
        case server
        case auth

        var id: String {
            switch self {
            case .editor(let profile): "editor-\(profile?.index.description ?? "new")"
            case .server: "server"
            case .auth: "auth"
            }
        }
    }

    @State private var destination: Destination?
    /// Collapsed by default: the key is a fallback, not a setup step.
    @State private var showTmdbKey = false

    var body: some View {
        NavigationStack {
            ZStack {
                NuvioBackground(intensity: 0.8).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switcher
                        appearance
                        trailers
                        account
                        server
                        #if os(macOS)
                        updates
                        #endif
                        about
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 72)
                }
            }
            .navigationTitle("Profile")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                ToolbarItem(placement: .platformTopTrailing) {
                    Button("Edit profile", systemImage: "pencil") {
                        destination = .editor(profiles.current)
                    }
                }
            }
            .sheet(item: $destination) { destination in
                Group {
                    switch destination {
                    case .editor(let profile): ProfileEditor(profile: profile)
                    case .server: ServerView()
                    // A remote can't type a password comfortably, so the TV
                    // signs in the way it signs in from the welcome screen:
                    // a code on screen and a phone to enter it on.
                    #if os(tvOS)
                    case .auth: SignInView()
                    #else
                    case .auth: AuthScreen()
                    #endif
                    }
                }
                .platformSheetSizing()
            }
        }
    }

    // MARK: Switcher

    private var switcher: some View {
        Section(title: "Who's watching") {
            VStack(alignment: .leading, spacing: 10) {
            if let error = profiles.syncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                profiles.select(profile)
                                library.activate(profile: profile)
                            }
                        } label: {
                            VStack(spacing: 8) {
                                ProfileAvatar(
                                    profile: profile,
                                    size: 62,
                                    isActive: profile.index == profiles.currentIndex
                                )
                                Text(profile.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(
                                        .white.opacity(profile.index == profiles.currentIndex ? 0.95 : 0.55)
                                    )
                                    .lineLimit(1)
                            }
                            .frame(width: 78)
                        }
                        .buttonStyle(.pressable)
                    }

                    if profiles.canAdd {
                        Button {
                            destination = .editor(nil)
                        } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 62, height: 62)
                                .glassEffect(.regular, in: .circle)

                            Text("Add")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .frame(width: 78)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }

            Text("\(profiles.profiles.count) of \(Profile.maxProfiles) profiles · synced with your account")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: Appearance

    private var availablePalettes: [NuvioPalette] {
        NuvioPalette.available(to: membership.access.entitlements)
    }

    private var appearance: some View {
        Section(title: "Accent") {
            VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(availablePalettes) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { theme.paletteID = option.id }
                        } label: {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: option.accentGradient,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if theme.paletteID == option.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 16, weight: .heavy))
                                            .foregroundStyle(option.onAccent)
                                    }
                                }
                                .overlay {
                                    Circle().strokeBorder(
                                        theme.paletteID == option.id
                                            ? Color.white.opacity(0.9)
                                            : Color.white.opacity(0.12),
                                        lineWidth: theme.paletteID == option.id ? 3 : 1
                                    )
                                }
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(option.name)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }

            if availablePalettes.count < NuvioPalette.all.count {
                Text(
                    membership.isSupporter
                        ? "Some accents are tied to supporter tiers you don't have."
                        : "Gold, Jade, Rose Gold, Arctic Blue and Graphite are Nuvio supporter accents."
                )
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    // MARK: Trailers

    /// Trailers come from the addon's own metadata and need nothing set up.
    /// The TMDB key is optional extra coverage for addons that don't carry
    /// them, so it sits behind a disclosure rather than in the way.
    private var trailers: some View {
        Section(title: "Trailers") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Play trailers on the home screen", isOn: $tmdb.useTrailers)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .tint(theme.palette.accent)

                if tmdb.useTrailers {
                    Text("Trailers come from your addons and play on YouTube.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)

                    DisclosureGroup("TMDB key (optional)", isExpanded: $showTmdbKey) {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("TMDB API key", text: $tmdb.apiKey)
                                .textFieldStyle(.plain)
                                .platformNoAutocapitalization()
                                .autocorrectionDisabled()
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .padding(12)
                                .glassCard(cornerRadius: 14)

                            Text("Only used when an addon doesn't supply a trailer itself. A free key comes from themoviedb.org → Settings → API.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .tint(theme.palette.accent)
                }
            }
        }
    }

    // MARK: Account

    private var account: some View {
        Section(title: "Account") {
            VStack(alignment: .leading, spacing: 14) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.refresh(session: session, profile: profiles.current) }
                    } label: {
                        Label(
                            model.isLoading ? "Refreshing…" : "Refresh",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isLoading)

                    if case .signedIn = session.state {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                            session.signOut()
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button("Sign in", systemImage: "person.crop.circle") {
                            destination = .auth
                        }
                        .buttonStyle(.glassProminent)
                        .tint(theme.palette.accent)
                    }
                }
            }
        }
    }

    // MARK: Server

    private var server: some View {
        Section(title: "Server") {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.backendDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Change server", systemImage: "server.rack") { destination = .server }
                    .buttonStyle(.glass)
            }
        }
    }

    #if os(macOS)
    /// Only the Mac gets this. A sideloaded iOS or tvOS build can't replace
    /// itself, so there would be nothing behind the button on those.
    private var updates: some View {
        Section(title: "Updates") {
            SoftwareUpdateControls()
        }
    }
    #endif

    private var about: some View {
        Text("Unofficial Apple client · not affiliated with NuvioMedia")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    /// A titled block on a glass panel.
    private struct Section<Content: View>: View {
        let title: String
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)

                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22)
        }
    }
}

// MARK: - Editor

/// Creates a profile, or edits (and can delete) an existing one. Mirrors the
/// fields Android's profile editor writes: a name, one of the shared avatar
/// colours, and — for non-primary profiles — whether it borrows the primary
/// profile's addons and plugins instead of keeping its own.
private struct ProfileEditor: View {
    /// `nil` when adding.
    let profile: Profile?

    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var avatars = AvatarCatalog.shared

    @State private var name: String
    @State private var colorHex: String
    @State private var avatarID: String?
    @State private var category: String?
    @State private var usesPrimaryAddons: Bool
    @State private var usesPrimaryPlugins: Bool
    @State private var isSaving = false

    init(profile: Profile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _colorHex = State(initialValue: profile?.avatarColorHex ?? Profile.avatarColors[1])
        _avatarID = State(initialValue: profile?.avatarID)
        _usesPrimaryAddons = State(initialValue: profile?.usesPrimaryAddons ?? false)
        _usesPrimaryPlugins = State(initialValue: profile?.usesPrimaryPlugins ?? false)
    }

    /// `true` while creating, when the new profile cannot be primary.
    private var isPrimary: Bool { profile?.isPrimary ?? false }

    /// The live preview, so choices are visible before they are saved.
    private var preview: Profile {
        Profile(
            index: profile?.index ?? 2,
            name: name.trimmed.isEmpty ? "New profile" : name.trimmed,
            avatarColorHex: colorHex,
            usesPrimaryAddons: usesPrimaryAddons,
            usesPrimaryPlugins: usesPrimaryPlugins,
            avatarID: avatarID,
            avatarURL: profile?.avatarURL
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                NuvioBackground(intensity: 0.7).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        ProfileAvatar(profile: preview, size: 108, isActive: true)
                            .padding(.top, 12)

                        TextField("Name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(14)
                            .glassCard(cornerRadius: 16)

                        avatarPicker

                        colorPicker

                        if !isPrimary {
                            sharing
                        }

                        if let profile, !profile.isPrimary {
                            Button("Delete profile", systemImage: "trash", role: .destructive) {
                                Task {
                                    await profiles.remove(profile, session: session)
                                    dismiss()
                                }
                            }
                            .buttonStyle(.glass)
                            .padding(.top, 4)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(profile == nil ? "New profile" : "Edit profile")
            .platformInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
    }

    /// The account's own avatars, straight from the backend's catalogue —
    /// the same faces the Android client offers, so a profile looks the same
    /// on every device. Picking one also adopts the colour the backend pairs
    /// with that artwork, which is what upstream writes to `avatar_color_hex`.
    @ViewBuilder
    private var avatarPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Avatar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)

            if avatars.items.isEmpty {
                Text(
                    avatars.isLoading
                        ? "Loading avatars…"
                        : "Your server didn't return an avatar catalogue."
                )
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CategoryChip(label: "All", isOn: category == nil) { category = nil }
                        ForEach(avatars.categories, id: \.self) { name in
                            CategoryChip(
                                label: name.capitalized,
                                isOn: category?.caseInsensitiveCompare(name) == .orderedSame
                            ) { category = name }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 66), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(avatars.items(in: category)) { avatar in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                avatarID = avatar.id
                                if let bg = avatar.bgColor, Color(hex: bg) != nil {
                                    colorHex = bg
                                }
                            }
                        } label: {
                            AvatarThumbnail(
                                item: avatar,
                                size: 66,
                                isSelected: avatarID == avatar.id
                            )
                        }
                        .buttonStyle(.pressable)
                    }
                }

                if avatarID != nil {
                    Button("Use initials instead", systemImage: "textformat") {
                        withAnimation { avatarID = nil }
                    }
                    .font(.footnote.weight(.semibold))
                    .tint(.white.opacity(0.55))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Avatar colour")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Profile.avatarColors, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? Profile.fallbackTint)
                                .frame(width: 40, height: 40)
                                .overlay {
                                    Circle().strokeBorder(
                                        colorHex == hex ? Color.white : Color.white.opacity(0.15),
                                        lineWidth: colorHex == hex ? 3 : 1
                                    )
                                }
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    /// Non-primary profiles can share the primary's addons and plugins rather
    /// than curating their own — the same two flags the backend stores.
    private var sharing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use primary profile's addons", isOn: $usesPrimaryAddons)
            Toggle("Use primary profile's plugins", isOn: $usesPrimaryPlugins)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .tint(preview.tint)
        .padding(16)
        .glassCard(cornerRadius: 18)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if var existing = profile {
            existing.name = name.trimmed.isEmpty ? existing.name : name.trimmed
            existing.avatarColorHex = colorHex
            existing.avatarID = avatarID
            if !existing.isPrimary {
                existing.usesPrimaryAddons = usesPrimaryAddons
                existing.usesPrimaryPlugins = usesPrimaryPlugins
            }
            await profiles.update(existing, session: session)
        } else if let created = await profiles.add(
            name: name,
            colorHex: colorHex,
            avatarID: avatarID,
            usesPrimaryAddons: usesPrimaryAddons,
            usesPrimaryPlugins: usesPrimaryPlugins,
            session: session
        ) {
            profiles.select(created)
        }
        dismiss()
    }
}

/// A pill that filters the avatar grid by category.
private struct CategoryChip: View {
    @Environment(\.palette) private var palette
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isOn ? palette.onAccent : .white.opacity(0.8))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassPill(tint: isOn ? palette.accent : nil)
        }
        .buttonStyle(.pressable)
    }
}
#endif
