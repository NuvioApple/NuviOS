import SwiftUI
import AetherEngine

/// Draws the subtitles the player engine deliberately doesn't.
///
/// `AetherPlaybackEngine` hands its frames to VideoToolbox and AVPlayer, which
/// is what keeps Dolby Vision, Atmos and Match Content working — and the price
/// of that is that nothing burns cues into the picture on the way past. So they
/// arrive as data and are laid out here instead, over the video surface.
///
/// The libvlc fallback draws its own, and publishes no cues, so this renders
/// nothing at all while that engine is running.
struct SubtitleOverlay: View {
    let cues: [HostSubtitleCue]
    /// The viewer's own size dial, applied to the text cues. A bitmap cue is
    /// authored at a fixed size on its own canvas and is left alone.
    var scale: Double = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(cues) { cue in
                    switch cue.body {
                    case .text(let string):
                        text(string, in: geometry.size)
                    case .image(let image, let position, let canvas):
                        bitmap(image, position: position, canvas: canvas, in: geometry.size)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Text

    private func text(_ string: AttributedString, in size: CGSize) -> some View {
        // Sized against the picture rather than the point size, so a phone and
        // a television read the same from their own viewing distances.
        let body = max(14, size.height * 0.045 * scale)
        return VStack {
            Spacer()
            Text(string)
                .font(.system(size: body, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                // A drop shadow rather than a plate: it stays legible over a
                // bright frame without covering it, which is what every
                // broadcast renderer does with the same problem.
                .shadow(color: .black.opacity(0.9), radius: body * 0.08, x: 0, y: 1)
                .shadow(color: .black.opacity(0.6), radius: body * 0.25)
                .padding(.horizontal, size.width * 0.08)
                .padding(.bottom, size.height * 0.06)
        }
    }

    // MARK: Bitmap

    /// PGS and DVB cues carry their own geometry, normalized against the
    /// composition canvas the disc authored them on. A cropped rip can have a
    /// canvas taller than the picture, so the canvas is mapped width-aligned
    /// and centre-anchored onto the video rect — which puts the lower bar back
    /// where it belongs instead of halfway up the frame.
    private func bitmap(_ image: CGImage, position: CGRect, canvas: CGSize, in size: CGSize) -> some View {
        let aspect = canvas.width > 0 && canvas.height > 0
            ? canvas.height / canvas.width
            : size.height / max(size.width, 1)
        let canvasHeight = size.width * aspect
        let originY = (size.height - canvasHeight) / 2

        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: position.width * size.width, height: position.height * canvasHeight)
            .position(
                x: (position.midX) * size.width,
                y: originY + position.midY * canvasHeight
            )
    }

    // MARK: Rich text

    /// Styled cues arrive as runs — colour, weight, slant, underline — because
    /// libavcodec converts SRT, WebVTT, teletext and ASS alike to ASS event
    /// lines before the engine sees them. Teletext's broadcaster colour is the
    /// one that matters most here: it is how the page is read.
    static func attributed(_ runs: [SubtitleTextRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if let colour = run.color {
                piece.foregroundColor = Color(
                    red: Double(colour.r) / 255,
                    green: Double(colour.g) / 255,
                    blue: Double(colour.b) / 255
                )
            }
            // Weight and slant go on as presentation intents rather than as a
            // font: a font here would carry a point size with it and override
            // the one `text(_:in:)` sized against the picture, shrinking every
            // styled cue to whatever was written in this file.
            var intent: InlinePresentationIntent = []
            if run.isBold { intent.insert(.stronglyEmphasized) }
            if run.isItalic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if run.isUnderlined { piece.underlineStyle = .single }
            if run.isStruckThrough { piece.strikethroughStyle = .single }
            result.append(piece)
        }
        return result
    }
}
