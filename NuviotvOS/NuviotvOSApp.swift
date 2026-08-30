import SwiftUI

@main
struct NuviotvOSApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
