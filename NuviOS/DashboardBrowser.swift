#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import SafariServices
#else
import AuthenticationServices
#endif

/// The Nuvio dashboard, inside the app, with the system's saved passwords,
/// passkeys and AutoFill. A plain web view can't offer those for a site the
/// app has no associated-domain tie to, so both platforms borrow Safari's.
///
/// Closing it is the cue to pull in whatever was changed there, which is why
/// the caller passes `onClose`.
#if os(iOS)
/// Safari's own in-app view, presented as a sheet.
struct DashboardBrowser: View {
    let url: URL
    var onClose: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SafariView(url: url) {
            onClose()
            dismiss()
        }
        .ignoresSafeArea()
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}
#else
/// macOS has no in-app Safari view, but `ASWebAuthenticationSession` is a
/// Safari-backed browser window that shares its saved passwords and shows
/// AutoFill. It is meant for sign-in, so it has no callback to wait for here:
/// it simply stays open until the viewer cancels it.
@MainActor
final class DashboardBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DashboardBrowser()

    private var session: ASWebAuthenticationSession?

    func open(_ url: URL, onClose: @escaping () -> Void) {
        session?.cancel()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "nuvios-dashboard") { _, _ in
            Task { @MainActor in onClose() }
        }
        session.presentationContextProvider = self
        // Not ephemeral: sharing Safari's cookies is what keeps the sign-in.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}
#endif
#endif
