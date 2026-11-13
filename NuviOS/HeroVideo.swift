import SwiftUI
import AVFoundation

// A folder's hero video, on every platform: muted, played through once over
// the still artwork, then faded back to it. `FocusTrailerPreview` does the
// same job on the TV but looks trailers up and follows the trailer setting;
// this takes a URL the folder's author chose and just plays it.

// MARK: - Layer

#if os(macOS)
import AppKit

private final class HeroVideoLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = AVPlayerLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct HeroVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let onFirstFrame: () -> Void

    final class Coordinator { var observation: NSKeyValueObservation? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HeroVideoLayerView {
        let view = HeroVideoLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        context.coordinator.observation = view.playerLayer.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { onFirstFrame() }
        }
        return view
    }

    func updateNSView(_ view: HeroVideoLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#else
import UIKit

private final class HeroVideoLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct HeroVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let onFirstFrame: () -> Void

    final class Coordinator { var observation: NSKeyValueObservation? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HeroVideoLayerView {
        let view = HeroVideoLayerView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        context.coordinator.observation = view.playerLayer.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { onFirstFrame() }
        }
        return view
    }

    func updateUIView(_ view: HeroVideoLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif

// MARK: - View

/// Plays `url` once when `isActive`, fading in on its first frame and out
/// when it ends, so whatever is underneath is back on screen afterwards.
struct HeroVideo: View {
    let url: URL
    var isActive: Bool = true
    /// A beat before it starts, so a page that is still settling isn't also
    /// starting a download.
    var delay: Duration = .milliseconds(600)
    /// How long to wait for a first frame before giving up on the video.
    var patience: Duration = .seconds(8)
    /// Called once per play when the video is over — it ended, it never
    /// started, or it was cut short — as its fade out begins. A title that
    /// was held back for the video comes in on this.
    var onFinish: () -> Void = {}
    /// Off for a folder's intro, which plays with its sound.
    var muted: Bool = true

    @State private var player: AVPlayer?
    @State private var isShowing = false
    @State private var endObserver: NSObjectProtocol?
    @State private var didFinish = false

    var body: some View {
        ZStack {
            if let player {
                HeroVideoSurface(player: player) {
                    withAnimation(.easeInOut(duration: 0.5)) { isShowing = true }
                }
                .opacity(isShowing ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .task(id: "\(isActive)|\(url.absoluteString)") { await run() }
        .onDisappear { teardown() }
    }

    private func run() async {
        guard isActive else {
            teardown()
            return
        }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }

        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        next.isMuted = muted
        next.automaticallyWaitsToMinimizeStalling = true

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                finish()
                withAnimation(.easeInOut(duration: 0.9)) { isShowing = false }
                // Let the fade finish before the player goes.
                try? await Task.sleep(for: .seconds(1))
                teardown()
            }
        }

        didFinish = false
        player = next
        next.play()

        // A video that never produces a frame — a dead link, a stalled
        // connection — must not keep a title waiting behind it for good.
        try? await Task.sleep(for: patience)
        if !Task.isCancelled, player === next, !isShowing {
            finish()
            teardown()
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        onFinish()
    }

    private func teardown() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        isShowing = false
    }
}
