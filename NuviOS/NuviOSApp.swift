import SwiftUI

@main
struct NuviOSApp: App {
    @StateObject private var session = AppSession()

    #if os(iOS)
    // The player asks the app to turn sideways, and only the delegate can
    // answer the system's question about which orientations are allowed.
    @UIApplicationDelegateAdaptor(NuvioAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                #if os(macOS)
                // A window narrower than this can't hold a shelf of posters,
                // so the Mac window doesn't go there.
                .frame(minWidth: 900, minHeight: 620)
                #endif
        }
        #if os(macOS)
        // Artwork runs to the top of the window rather than under a grey
        // title bar; the traffic lights stay, floating over it.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1320, height: 860)
        // Only the Mac can install its own updates, and a Mac user expects
        // the control for that directly under About in the app menu.
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
        }
        #endif
    }
}

#if os(iOS)
final class NuvioAppDelegate: NSObject, UIApplicationDelegate {
    /// Everything outside the player rotates as it always did; the player
    /// narrows this to landscape for as long as it is on screen.
    static var supportedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

/// Turns the phone sideways for playback and hands rotation back afterwards.
///
/// Two halves are needed: the delegate above decides what the system will
/// *allow*, and `requestGeometryUpdate` performs the rotation itself — which
/// also overrides the device's own rotation lock, the way every video app does.
enum PlayerOrientation {
    static func lockLandscape() {
        apply(.landscape)
    }

    static func release() {
        apply(.allButUpsideDown)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        NuvioAppDelegate.supportedOrientations = mask

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}
#endif
