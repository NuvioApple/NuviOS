import SwiftUI

/// Lets the user point the app at a self-hosted Nuvio backend, or return to
/// the official one. Mirrors the `./nuvio setup --domain …` output.
struct ServerView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    @State private var address = ""

    var body: some View {
        Screen { metrics in
            VStack(alignment: .leading, spacing: metrics.isCompact ? 22 : 36) {
                VStack(alignment: .leading, spacing: metrics.isCompact ? 8 : 14) {
                    Wordmark(size: metrics.wordmarkSize * 0.8)

                    Text("Server")
                        .font(.system(size: metrics.screenTitleSize, weight: .black))
                        .tracking(-1)
                        .foregroundStyle(.white)
                }

                HStack(spacing: 12) {
                    Circle()
                        .fill(session.isDiscovering ? Color.orange : palette.accent)
                        .frame(width: metrics.isCompact ? 8 : 12, height: metrics.isCompact ? 8 : 12)

                    Text("Currently using \(session.backendDisplayName)")
                        .font(.system(size: metrics.isCompact ? 14 : 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, metrics.isCompact ? 14 : 22)
                .padding(.vertical, metrics.isCompact ? 10 : 16)
                .background(Capsule().fill(.white.opacity(0.06)))

                Text("Enter the Backend URL of your self-hosted Nuvio server.")
                    .font(.system(size: metrics.isCompact ? 14 : 22))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                TextField("backend.example.com", text: $address)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .font(.system(size: metrics.isCompact ? 16 : 26, weight: .medium))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    #if !os(tvOS)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                    #endif
                    .frame(maxWidth: 900)

                if let error = session.discoveryError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: metrics.isCompact ? 13 : 20))
                        .foregroundStyle(Color(.sRGB, red: 1, green: 0.42, blue: 0.4, opacity: 1))
                        .fixedSize(horizontal: false, vertical: true)
                }

                AdaptiveStack(isVertical: metrics.isCompact, spacing: metrics.stackSpacing) {
                    Button("Connect") {
                        Task { if await session.useServer(address) { dismiss() } }
                    }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .prominent, icon: "bolt.horizontal.fill", compact: metrics.isCompact)
                    )
                    .disabled(address.trimmed.isEmpty || session.isDiscovering)

                    Button("Use official server") {
                        Task {
                            if await session.useServer(ServerConfiguration.officialBackendURL) {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(NuvioButtonStyle(kind: .glass, compact: metrics.isCompact))
                    .disabled(session.isDiscovering)

                    Button("Back") { dismiss() }
                        .buttonStyle(NuvioButtonStyle(kind: .ghost, compact: metrics.isCompact))
                }

                if session.isDiscovering {
                    HStack(spacing: 14) {
                        ProgressView()
                        Text("Contacting server…")
                            .font(.system(size: metrics.isCompact ? 14 : 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}
