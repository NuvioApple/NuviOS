#if os(tvOS)
import SwiftUI

/// Draws nothing of its own. tvOS's `.plain` button style puts a white platter
/// behind a focused control; cards that already draw their own focus use this
/// so the two don't stack.
struct BarePlatterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
