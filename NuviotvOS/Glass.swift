import SwiftUI

// MARK: - Glass surfaces

/// The app's standard raised surface: real Liquid Glass, with a hairline that
/// keeps the edge visible when it sits over dark artwork.
///
/// Everything that would previously have been "a translucent white rectangle"
/// goes through here, so one change restyles every panel in the app.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 26
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .glassEffect(glass, in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint.opacity(0.28)) }
        return .regular
    }
}

extension View {
    /// A Liquid Glass panel.
    func glassCard(cornerRadius: CGFloat = 26, tint: Color? = nil) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint))
    }

    /// A Liquid Glass pill, for chips and small controls.
    func glassPill(tint: Color? = nil) -> some View {
        glassEffect(tint.map { Glass.regular.tint($0.opacity(0.3)) } ?? .regular, in: .capsule)
    }
}

// MARK: - Profile avatar

/// A profile's face.
///
/// Upstream identifies a profile by an avatar from the backend's catalogue
/// plus a colour, so this resolves `Profile.avatarID` through
/// `AvatarCatalog` and draws the same picture Android draws. The colour is
/// the backdrop the artwork sits on — and the whole face when a profile has
/// no avatar yet, where it carries the profile's initial instead.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 44
    /// Draws the bright ring that marks the profile currently in use.
    var isActive = false
    /// Ring colour. Defaults to white, the way both upstream clients mark the
    /// selected profile.
    var activeRing: Color = .white

    @ObservedObject private var catalog = AvatarCatalog.shared

    private var imageURL: URL? { catalog.imageURL(for: profile) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [profile.tint, profile.tint.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let imageURL {
                AsyncImage(
                    url: imageURL,
                    transaction: Transaction(animation: .easeOut(duration: 0.25))
                ) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        initials
                    }
                }
                .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().strokeBorder(
                isActive ? activeRing.opacity(0.95) : Color.white.opacity(0.18),
                lineWidth: isActive ? max(2, size * 0.055) : 1
            )
        }
        // No drop shadow: over a glass panel it composites as a square patch,
        // and the ring already says which profile is in use.
        .accessibilityLabel(profile.name)
    }

    private var initials: some View {
        Text(profile.initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
            .shadow(color: .black.opacity(0.3), radius: 2)
    }
}

/// One face in the avatar picker: the catalogue artwork on its own colour.
struct AvatarThumbnail: View {
    let item: AvatarCatalogItem
    var size: CGFloat = 74
    var isSelected = false

    @ObservedObject private var catalog = AvatarCatalog.shared

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: item.bgColor ?? "") ?? Profile.fallbackTint)

            AsyncImage(
                url: catalog.imageURL(for: item),
                transaction: Transaction(animation: .easeOut(duration: 0.25))
            ) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                } else {
                    Circle().fill(.white.opacity(0.06)).shimmering()
                }
            }
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().strokeBorder(
                isSelected ? Color.white : Color.white.opacity(0.12),
                lineWidth: isSelected ? 3 : 1
            )
        }
        .scaleEffect(isSelected ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        .accessibilityLabel(item.displayName)
    }
}
