import SwiftUI

#if os(macOS)
import AppKit

/// AppKit and UIKit name the same things differently. The app is written
/// against the UIKit spelling because iOS and tvOS came first, so the macOS
/// build aliases its way back rather than carrying two copies of every view.
typealias PlatformView = NSView
typealias PlatformImage = NSImage
#else
import UIKit

typealias PlatformView = UIView
typealias PlatformImage = UIImage
#endif

/// How a full-window cover asks to be closed.
///
/// `dismiss` belongs to a sheet or a cover the system is presenting. The Mac
/// player is neither — it is drawn over the window's own content — so the
/// presenter hands its close action down through the environment instead.
private struct PlatformCoverDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var platformCoverDismiss: (() -> Void)? {
        get { self[PlatformCoverDismissKey.self] }
        set { self[PlatformCoverDismissKey.self] = newValue }
    }
}

extension View {
    /// macOS has no `fullScreenCover`, and a sheet is the wrong shape for
    /// video: an AppKit sheet sizes itself to its content, inherits the window
    /// it hangs from, and cannot be taken full screen — which is how the Mac
    /// player ended up a small letterboxed panel floating over the library.
    /// A cover drawn over the window's own content fills whatever the window
    /// is instead, so the green button and Enter Full Screen work on the
    /// picture exactly as they do in QuickTime.
    @ViewBuilder
    func platformPlayerCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        overlay {
            if let value = item.wrappedValue {
                content(value)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .environment(\.platformCoverDismiss) { item.wrappedValue = nil }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.wrappedValue != nil)
        #else
        fullScreenCover(item: item, content: content)
        #endif
    }

    /// macOS has no `fullScreenCover`; a sheet is the closest equivalent that
    /// exists on every platform the app builds for. On iOS and tvOS this stays
    /// the cover it always was, so the phone and the TV are unaffected.
    @ViewBuilder
    func platformFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().frame(minWidth: 720, minHeight: 560)
        }
        #else
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #endif
    }

    /// The `item:` form of the same cover, for screens that present from an
    /// optional value rather than a boolean.
    @ViewBuilder
    func platformFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(macOS)
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).frame(minWidth: 720, minHeight: 560)
        }
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }

    /// A floor under a sheet's size on the Mac.
    ///
    /// An AppKit sheet sizes itself to its content, and a `NavigationStack`
    /// wrapped around a list expresses no opinion about how big it wants to
    /// be — which is how the source picker opened as a sliver with its own
    /// buttons cut off below the edge. iOS sizes and positions sheets itself,
    /// so this is a Mac-only floor and the phone is untouched.
    @ViewBuilder
    func platformSheetSizing(minWidth: CGFloat = 720, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization` is iOS-only. Nothing on macOS
    /// autocapitalises a text field, so the modifier simply drops away.
    @ViewBuilder
    func platformNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

extension View {
    /// `navigationBarTitleDisplayMode` describes a bar only iOS has.
    @ViewBuilder
    func platformInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Hiding the navigation bar's background is likewise iOS-only.
    @ViewBuilder
    func platformHiddenNavigationBackground() -> some View {
        #if os(iOS)
        toolbarBackground(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// The tab bar minimise-on-scroll behaviour and its glass background are
    /// both iOS 26 bar features with no macOS counterpart.
    @ViewBuilder
    func platformMinimizingTabBar() -> some View {
        #if os(iOS)
        tabBarMinimizeBehavior(.onScrollDown)
            .toolbarBackgroundVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// Hiding the navigation bar outright, likewise iOS-only.
    @ViewBuilder
    func platformHiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// The shell's tab style.
    ///
    /// The Mac takes the platform's own top tab bar — `TabView`'s default —
    /// rather than a sidebar: a sidebar spends a column of a window on five
    /// fixed destinations and pushes the artwork it exists to show into a
    /// narrower space. iOS keeps the Liquid Glass bar along the bottom, under
    /// the thumb.
    @ViewBuilder
    func platformShellTabViewStyle() -> some View {
        self
    }

    /// The paged carousel style exists on iOS and tvOS only. macOS falls back
    /// to the plain style; the hero row still scrolls, it just doesn't page.
    @ViewBuilder
    func platformPagedTabViewStyle() -> some View {
        #if os(iOS)
        tabViewStyle(.page(indexDisplayMode: .never))
        #else
        self
        #endif
    }
}

extension View {
    /// `onHover` reports a pointer, which is the closest thing a phone or a
    /// Mac has to the television's focus. tvOS has the real thing, so the
    /// views that would have tracked a pointer read their own focus instead
    /// and this drops away.
    @ViewBuilder
    func platformOnHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: action)
        #endif
    }
}

/// The share control, where the platform has one.
///
/// A phone and a Mac both hand a title to the share sheet; a television has
/// nowhere to send it and no `ShareLink` to build, so the control simply isn't
/// drawn there rather than being drawn dead.
struct PlatformShareButton: View {
    let text: String
    var width: CGFloat = 70

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        ShareLink(item: text) {
            VStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(height: 22)
                Text("Share")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: width)
        }
        .buttonStyle(.pressable)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// `topBarTrailing` is iOS-only; `primaryAction` lands in the equivalent
    /// corner elsewhere.
    static var platformTopTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension Image {
    /// Builds an `Image` from whichever image type the platform uses, so call
    /// sites keep a single unbroken modifier chain.
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

enum PlatformScreen {
    /// Width of the main screen. Used only to decide which half of a
    /// double-tap landed, so screen rather than window width is close enough.
    static var width: CGFloat {
        #if os(macOS)
        NSScreen.main?.frame.width ?? 0
        #else
        UIScreen.main.bounds.width
        #endif
    }
}
