#if os(iOS)
import SwiftUI
import UIKit

/// Long-press detection over the tab bar's trailing corner.
///
/// SwiftUI's `Tab` takes no gestures — a tab item can be tapped and nothing
/// else — so a press-and-hold on the profile tab has to be caught below
/// SwiftUI. Rather than reaching into the tab bar's private view hierarchy
/// (which the Liquid Glass bar no longer guarantees is a `UITabBar`), this
/// attaches one recognizer to the window and asks only *where* the press
/// landed.
///
/// The recognizer never swallows a touch, so an ordinary tap on the tab still
/// reaches the tab bar and opens the profile screen as usual.
struct TabBarLongPress: UIViewRepresentable {
    /// Fired when a press is held in the bar's trailing corner.
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
        context.coordinator.attach(to: view.window)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Never takes a touch: it exists only to find the window.
    private final class PassthroughView: UIView {
        var onMoveToWindow: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onMoveToWindow?(window)
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void
        private weak var window: UIWindow?
        private var recognizer: UILongPressGestureRecognizer?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func attach(to window: UIWindow?) {
            guard let window, window !== self.window else { return }
            detach()

            let recognizer = UILongPressGestureRecognizer(self, action: #selector(handle))
            recognizer.minimumPressDuration = 0.45
            // Both flags matter: the tab bar must keep receiving the touch, so
            // a press that turns out to be a tap still selects the tab.
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)

            self.window = window
            self.recognizer = recognizer
        }

        func detach() {
            if let recognizer, let window { window.removeGestureRecognizer(recognizer) }
            recognizer = nil
            window = nil
        }

        @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let window else { return }
            guard Self.isInTrailingTabCorner(recognizer.location(in: window), in: window) else {
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        /// The trailing tab's rough footprint.
        ///
        /// Measured off the tab bar's own frame when one can be found, so the
        /// region tracks the bar's real size; the constants are only a
        /// fallback for a bar this can't identify.
        private static func isInTrailingTabCorner(_ point: CGPoint, in window: UIWindow) -> Bool {
            let bounds = window.bounds
            let bar = tabBarFrame(in: window)
                ?? CGRect(
                    x: 0,
                    y: bounds.maxY - window.safeAreaInsets.bottom - 60,
                    width: bounds.width,
                    height: 60
                )
            // The last of five tabs, with a little slack around it.
            let trailing = CGRect(
                x: bar.maxX - bar.width / 4,
                y: bar.minY - 8,
                width: bar.width / 4,
                height: bar.height + 16
            )
            return trailing.contains(point)
        }

        private static func tabBarFrame(in window: UIWindow) -> CGRect? {
            var found: CGRect?
            func walk(_ view: UIView) {
                if String(describing: type(of: view)).contains("TabBar"), view.bounds.width > 100 {
                    let frame = view.convert(view.bounds, to: window)
                    // Keep the lowest match: the bar itself, not a container.
                    if found == nil || frame.minY > found!.minY { found = frame }
                }
                view.subviews.forEach(walk)
            }
            walk(window)
            return found
        }
    }
}

private extension UILongPressGestureRecognizer {
    convenience init(_ target: Any, action: Selector) {
        self.init(target: target, action: action)
    }
}
#endif
