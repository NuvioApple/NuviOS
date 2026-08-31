import SwiftUI
import CoreImage.CIFilterBuiltins

/// Device pairing: the TV shows a QR code and a code, the phone approves it.
struct SignInView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        Screen(scrolls: false) { metrics in
            VStack(alignment: .leading, spacing: metrics.lerp(24, 44)) {
                header(metrics)

                switch session.loginPhase {
                case .idle, .starting:
                    status("Requesting a code…", systemImage: "hourglass", metrics: metrics)

                case .awaitingApproval(let code, let webURL):
                    approval(code: code, webURL: webURL, metrics: metrics)

                case .exchanging:
                    status("Approved — finishing sign-in…", systemImage: "checkmark.seal.fill", metrics: metrics)

                case .failed(let message):
                    failure(message, metrics: metrics)
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .preferredColorScheme(.dark)
        #if os(tvOS)
        .onExitCommand { session.cancelLogin(); dismiss() }
        #endif
        .onAppear { session.startLogin(deviceName: Self.deviceName) }
        .onDisappear { session.cancelLogin() }
    }

    // MARK: Pieces

    private func header(_ metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(8, 14)) {
            Wordmark(size: metrics.wordmarkSize * 0.8)

            Text("Sign in")
                .font(.system(size: metrics.screenTitleSize, weight: .black))
                .tracking(-1)
                .foregroundStyle(.white)
        }
    }

    private func status(_ text: String, systemImage: String, metrics: LayoutMetrics) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.lerp(18, 30), weight: .semibold))
                .foregroundStyle(palette.accent)

            Text(text)
                .font(.system(size: metrics.lerp(16, 26), weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(metrics.lerp(18, 30))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.05))
        )
    }

    private func failure(_ message: String, metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(16, 26)) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: metrics.lerp(15, 24)))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            AdaptiveStack(isVertical: metrics.isCompact, spacing: metrics.stackSpacing) {
                Button("Try again") { session.startLogin(deviceName: Self.deviceName) }
                    .buttonStyle(
                        NuvioButtonStyle(kind: .prominent, icon: "arrow.clockwise", compact: metrics.isCompact)
                    )
                Button("Back") { session.cancelLogin(); dismiss() }
                    .buttonStyle(NuvioButtonStyle(kind: .ghost, compact: metrics.isCompact))
            }
        }
    }

    /// Side by side where there is room, stacked on a phone.
    @ViewBuilder
    private func approval(code: String, webURL: String, metrics: LayoutMetrics) -> some View {
        if metrics.isCompact {
            VStack(alignment: .leading, spacing: metrics.stackSpacing) {
                qrCode(webURL: webURL, metrics: metrics)
                instructions(code: code, webURL: webURL, metrics: metrics)
            }
        } else {
            HStack(alignment: .top, spacing: 80) {
                instructions(code: code, webURL: webURL, metrics: metrics)
                qrCode(webURL: webURL, metrics: metrics)
            }
        }
    }

    @ViewBuilder
    private func instructions(code: String, webURL: String, metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.lerp(16, 30)) {
            step(
                number: 1,
                title: "Scan the code, or open",
                detail: displayURL(webURL),
                metrics: metrics
            )

            step(
                number: 2,
                title: "Enter this code",
                detail: nil,
                metrics: metrics
            ) {
                // The backend issues a 32-character hex code, so it is grouped
                // into blocks rather than shown as one unreadable run.
                Text(Self.grouped(code, perLine: metrics.codeGroupsPerLine))
                    .font(.system(size: metrics.codeSize, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .lineSpacing(8)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, metrics.lerp(14, 22))
                    .padding(.vertical, metrics.lerp(10, 16))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.accent.opacity(0.35), lineWidth: 1)
                    )
            }

            Button("Cancel") {
                session.cancelLogin()
                dismiss()
            }
            .buttonStyle(NuvioButtonStyle(kind: .ghost, compact: metrics.isCompact))
            .padding(.top, metrics.lerp(4, 10))
        }
    }

    @ViewBuilder
    private func step<Extra: View>(
        number: Int,
        title: String,
        detail: String?,
        metrics: LayoutMetrics,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: metrics.lerp(12, 22)) {
            Text("\(number)")
                .font(.system(size: metrics.lerp(15, 24), weight: .black))
                .foregroundStyle(palette.onAccent)
                .frame(
                    width: metrics.lerp(28, 46),
                    height: metrics.lerp(28, 46)
                )
                .background(Circle().fill(palette.accentBrush))

            VStack(alignment: .leading, spacing: metrics.lerp(6, 12)) {
                Text(title)
                    .font(.system(size: metrics.lerp(14, 23), weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))

                if let detail {
                    Text(detail)
                        .font(.system(size: metrics.lerp(19, 36), weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }

                extra()
            }
        }
    }

    @ViewBuilder
    private func qrCode(webURL: String, metrics: LayoutMetrics) -> some View {
        if let qr = Self.qrImage(from: webURL) {
            Image(platformImage: qr)
                .interpolation(.none)
                .resizable()
                .frame(width: metrics.qrSize, height: metrics.qrSize)
                .padding(metrics.lerp(14, 26))
                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: palette.accent.opacity(0.35), radius: 40, y: 18)
                .accessibilityLabel("QR code to \(displayURL(webURL))")
        }
    }

    private func displayURL(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private static var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        "iPhone"
        #endif
    }

    /// Splits the code into four-character blocks, wrapped so it never runs off
    /// the edge of a narrow screen.
    static func grouped(_ code: String, size: Int = 4, perLine: Int = 5) -> String {
        let blocks = stride(from: 0, to: code.count, by: size).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: size, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[start..<end])
        }
        return stride(from: 0, to: blocks.count, by: perLine)
            .map { blocks[$0..<min($0 + perLine, blocks.count)].joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// The verification URL as a scannable QR, scaled up from the filter's
    /// tiny native output so it stays crisp at any size.
    static func qrImage(from string: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = 12.0
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
