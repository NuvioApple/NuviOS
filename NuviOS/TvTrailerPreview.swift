#if os(tvOS)
import SwiftUI
import AVFoundation

// MARK: - Layer

/// A bare `AVPlayerLayer`, filling its frame. SwiftUI's `VideoPlayer` brings
/// transport controls and focus handling with it; a card preview wants
/// neither, and must not steal focus from the card it sits on.
private final class PreviewLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PreviewSurface: UIViewRepresentable {
    let player: AVPlayer
    let onFirstFrame: () -> Void

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
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

    func updateUIView(_ view: PreviewLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

// MARK: - Preview

/// Plays a title's trailer, muted, inside whatever it is laid over.
///
/// Nothing is fetched until `isActive`, and the artwork underneath stays
/// visible until the first frame is on screen, so a slow trailer is never a
/// black card.
struct FocusTrailerPreview: View {
    /// The title whose trailer to find. Unused when `directURL` is given.
    var item: MetaItem? = nil
    /// A video to play as it is, such as a collection's hero video, instead
    /// of looking a trailer up.
    var directURL: URL? = nil
    var isActive: Bool
    /// How long the title has to hold the stage before its trailer starts.
    var delay: Duration = .milliseconds(300)
    /// Reports whether the trailer is on screen, so the caller can hold the
    /// carousel still while it plays.
    var onPlayingChange: (Bool) -> Void = { _ in }
    /// Called when the trailer plays through to its end (not when it is
    /// stopped early), so a carousel can move on at once.
    var onFinish: () -> Void = {}

    @EnvironmentObject private var tmdb: TmdbSettings
    @State private var player: AVPlayer?
    @State private var isShowing = false
    @State private var endObserver: NSObjectProtocol?
    @State private var stallObserver: NSObjectProtocol?

    /// How long focus has to rest before the trailer starts. Short enough to
    /// read as the card answering focus; long enough that sweeping across a
    /// shelf doesn't start a stream for every poster passed.
    private var canPreview: Bool {
        guard tmdb.focusPreviews else { return false }
        if directURL != nil { return true }
        return tmdb.canFetchTrailers && item?.id.hasPrefix("tt") == true
    }

    private var sourceKey: String { directURL?.absoluteString ?? item?.id ?? "" }

    var body: some View {
        ZStack {
            if let player {
                PreviewSurface(player: player) {
                    withAnimation(.easeInOut(duration: 0.35)) { isShowing = true }
                    onPlayingChange(true)
                }
                .opacity(isShowing ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: tmdb.trailerSound) { _, sound in player?.isMuted = !sound || runsInSimulator }
        .task(id: "\(isActive)|\(canPreview)|\(sourceKey)") { await run() }
        .onDisappear { stop() }
    }

    private func run() async {
        guard isActive, canPreview else {
            stop()
            return
        }

        let url: URL
        if let directURL {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            url = directURL
        } else if let item {
            // The lookup starts the moment focus lands, and the rest delay
            // runs beside it rather than after it.
            async let found = TrailerioClient.shared.trailers(
                imdbID: item.id,
                type: item.type,
                bases: tmdb.trailerBases,
                purpose: .preview
            )
            try? await Task.sleep(for: delay)
            let candidates = await found
            guard !Task.isCancelled, let trailer = candidates.first else { return }
            url = trailer.url
        } else {
            return
        }

        let playerItem = AVPlayerItem(url: url)
        // The whole trailer plays now, not a few seconds of it, so let the
        // system buffer as far ahead as it likes. A 4-second horizon ran dry
        // partway through and the picture froze there.
        let next = AVPlayer(playerItem: playerItem)
        next.isMuted = !tmdb.trailerSound || runsInSimulator
        // Start at once rather than waiting to fill a buffer...
        next.automaticallyWaitsToMinimizeStalling = false

        // ...but without waiting, a stall stops the player for good. Pick it
        // back up once data arrives.
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { _ in Task { @MainActor in
            next.automaticallyWaitsToMinimizeStalling = true
            next.play()
        } }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in Task { @MainActor in
            stop()
            onFinish()
        } }

        player = next
        next.play()
    }

    private func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        player?.pause()
        player = nil
        if isShowing {
            withAnimation(.easeInOut(duration: 0.25)) { isShowing = false }
            onPlayingChange(false)
        }
    }
}

// MARK: - Opening a trailer

extension TrailerioClient {
    /// The viewer asked for the trailer: best sound and picture first, the
    /// rest as fallbacks, as a request the full player can play.
    func playbackRequest(for item: MetaItem, bases: [String]) async -> PlaybackRequest? {
        let ranked = await trailers(
            imdbID: item.id,
            type: item.type,
            bases: bases,
            purpose: .feature
        )
        guard let first = ranked.first else { return nil }
        return PlaybackRequest(
            url: first.url,
            title: item.name,
            subtitle: "Trailer",
            alternates: ranked.dropFirst().map { PlaybackAlternate(url: $0.url) }
        )
    }
}
#endif
