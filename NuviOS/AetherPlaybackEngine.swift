import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import AetherEngine

/// The app's player engine: FFmpeg demuxes, the platform decodes and presents.
///
/// The addon protocol hands back whatever the source happens to hold — Matroska,
/// HEVC, AC3, VP9, embedded PGS — which is why this app never used AVFoundation
/// on its own. AetherEngine keeps FFmpeg's breadth at the front of the pipeline
/// and then hands the frames to VideoToolbox and AVPlayer, so the things a
/// renderer of its own quietly loses all survive: Dolby Vision as a real display
/// switch rather than a tone-map, Atmos stream-copied rather than decoded to PCM,
/// and tvOS Match Content driving the panel.
///
/// What it does not do is draw subtitles. That is the same trade: the picture
/// stays on the platform's path, so the app composites the cues itself. See
/// `SubtitleOverlay`, fed from `hostSubtitleCues`.
///
/// Anything this engine cannot open falls back to `VLCPlaybackEngine`.
@MainActor
final class AetherPlaybackEngine: PlaybackEngine {
    static let name = "AetherEngine"

    weak var delegate: PlaybackEngineDelegate?

    private let engine: AetherEngine
    private let surfaceView = AetherPlayerView(frame: .zero)
    private var subscriptions: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    /// Latched once the running load has a frame on screen, so a mid-playback
    /// drop is told apart from a source that never started.
    private var hasPresented = false

    /// nil when the engine cannot be built on this device at all, which is the
    /// one case where the app never even tries it.
    init?() {
        guard let engine = try? AetherEngine() else { return nil }
        self.engine = engine
        engine.bind(view: surfaceView)
        observe()
    }

    // MARK: Lifecycle

    func attach(to view: PlatformView) {
        guard surfaceView.superview !== view else { return }
        surfaceView.removeFromSuperview()
        surfaceView.frame = view.bounds
        #if os(macOS)
        surfaceView.autoresizingMask = [.width, .height]
        #else
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        view.addSubview(surfaceView)
    }

    func open(url: URL, headers: [String: String], startAt: Double?) {
        loadTask?.cancel()
        hasPresented = false
        delegate?.engineDidBeginOpening(self)

        var options = LoadOptions()
        // Carried into the AVURLAsset on the direct-HLS route and into every
        // demux and segment fetch on the others, so an origin that enforces a
        // Referer or a User-Agent — which is most of what the addons hand back
        // — is satisfied on the first request rather than after a 403.
        options.httpHeaders = headers
        // The panel follows the source on tvOS. This is the whole reason this
        // engine is in front of libvlc.
        options.matchContentEnabled = true
        // The languages the viewer told the system they want, so the engine's
        // own first pick is already the right one and the screen's preference
        // pass has nothing to correct. `TrackPreference` still runs: it is the
        // one that decides subtitles are needed because no dub matched.
        options.preferredAudioLanguages = TrackPreference.preferredLanguages
        options.preferredSubtitleLanguages = TrackPreference.preferredLanguages

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.load(url: url, startPosition: startAt, options: options)
            } catch is CancellationError {
                // A load superseded by the next one. Not a failure: the source
                // that replaced it is the one that speaks now.
            } catch {
                guard !Task.isCancelled else { return }
                self.delegate?.engine(self, didFailWith: "load failed: \(error.localizedDescription)")
            }
        }
    }

    func halt() {
        loadTask?.cancel()
        loadTask = nil
        hasPresented = false
        engine.stop()
    }

    func teardown() {
        halt()
        subscriptions.removeAll()
        surfaceView.removeFromSuperview()
    }

    // MARK: Engine observation

    private func observe() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handle(state) }
            .store(in: &subscriptions)

        // Time lives on a separate object precisely so its ~10 Hz ticks don't
        // re-render the track menus; the screen throttles the work it does with
        // them down to once a second of its own.
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.engineDidUpdate(self)
            }
            .store(in: &subscriptions)

        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .rebuffering, .stalled:
                    self.delegate?.engine(self, isBuffering: true)
                case .playing, .paused, .seeking, .ended:
                    self.delegate?.engine(self, isBuffering: false)
                default:
                    break
                }
            }
            .store(in: &subscriptions)

        // The edge a spinner comes off on: `readyToPlay` is reached before the
        // layer holds a picture, so lifting on it lifts onto black.
        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self, ready else { return }
                self.hasPresented = true
                self.delegate?.engineDidStartPlaying(self)
            }
            .store(in: &subscriptions)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.engineDidUpdate(self)
            }
            .store(in: &subscriptions)

        // Where an open actually is, checkpoint by checkpoint. This covers the
        // two stretches nothing else reports — the source open (connection,
        // container, stream analysis) and the display-criteria handshake — so a
        // stall names the work it stalled in rather than showing a spinner.
        // Every value is work that genuinely finished, so a slow stretch holds
        // on one line instead of ticking.
        engine.$startupProgress
            .compactMap { $0 }
            .removeDuplicates { $0.stage == $1.stage && $0.completed == $1.completed }
            .receive(on: DispatchQueue.main)
            .sink { progress in
                print("[player] opening: \(progress.stage) (\(progress.completed)/\(progress.total))")
            }
            .store(in: &subscriptions)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.delegate?.engineDidUpdate(self)
            }
            .store(in: &subscriptions)
    }

    private func handle(_ state: PlaybackState) {
        switch state {
        case .loading:
            delegate?.engineDidBeginOpening(self)
        case .playing:
            // Only once a frame exists; before that the spinner is honest.
            if hasPresented { delegate?.engineDidStartPlaying(self) }
        case .paused:
            delegate?.engineDidPause(self)
        case .ended:
            delegate?.engineDidEnd(self)
        case .error(let message):
            // The message is a payload, not a classification — on the native
            // paths it is AVFoundation's, localized into the device's language
            // — so it goes to the log and the screen decides what to do from
            // where the failure happened, not from its wording.
            let kind = engine.errorInfo?.kind
            delegate?.engine(self, didFailWith: "\(kind.map { "\($0)" } ?? "error"): \(message)")
        case .idle, .seeking:
            break
        }
        delegate?.engineDidUpdate(self)
    }

    // MARK: Transport

    var isPlaying: Bool { engine.state == .playing }
    var currentTime: Double { engine.clock.currentTime }

    var duration: Double? {
        let value = engine.duration
        return value > 0 ? value : nil
    }

    /// A live channel has no length to scrub within, and that is exactly the
    /// case the transport bar must not offer a thumb for.
    var isSeekable: Bool { duration != nil }

    func play() { engine.play() }
    func pause() { engine.pause() }

    func seek(toSeconds seconds: Double) {
        Task { await engine.seek(to: seconds) }
    }

    func setRate(_ rate: Float) { engine.setRate(rate) }

    /// AVPlayer has no single-frame step on this path, and a seek of one frame
    /// time is a restart rather than a nudge. The screen leaves the picture be.
    @discardableResult
    func stepFrame(forward: Bool) -> Bool { false }

    // MARK: Picture

    func setFit(_ fit: VideoFit) {
        switch fit {
        case .fit, .ratio16x9, .ratio4x3:
            // The forced ratios are a libvlc dial with no equivalent here: the
            // engine presents at the pixel aspect the decoder attached. The
            // menu keeps them for the fallback engine and they letterbox here.
            engine.videoGravity = .resizeAspect
        case .fill:
            engine.videoGravity = .resizeAspectFill
        }
    }

    // MARK: Volume

    var volume: Double {
        get { Double(engine.volume) }
        set { engine.volume = Float(max(0, min(1, newValue))) }
    }

    /// The engine has no mute of its own, so it is a volume the screen can put
    /// back: the level to restore lives here rather than in the transport.
    private var volumeBeforeMute: Float?

    var isMuted: Bool {
        get { volumeBeforeMute != nil }
        set {
            if newValue {
                guard volumeBeforeMute == nil else { return }
                volumeBeforeMute = engine.volume
                engine.volume = 0
            } else if let restored = volumeBeforeMute {
                volumeBeforeMute = nil
                engine.volume = restored
            }
        }
    }

    // MARK: Tracks

    var audioTracks: [MediaTrack] {
        let selected = engine.activeAudioTrackIndex
        return engine.audioTracks.map { describe($0, isSelected: $0.id == selected) }
    }

    var textTracks: [MediaTrack] {
        let selected = engine.activeSubtitleTrackIndex
        return engine.subtitleTracks.map { describe($0, isSelected: $0.id == selected) }
    }

    /// The container's own dispositions, which libvlc only ever put in the
    /// track name — so the preference pass gets a real answer here instead of
    /// a substring search for "forced".
    private func describe(_ track: TrackInfo, isSelected: Bool) -> MediaTrack {
        MediaTrack(
            trackId: track.id,
            trackName: track.name,
            language: track.language,
            isSelected: isSelected,
            isForced: track.isForced,
            isSecondary: track.isCommentary || track.isHearingImpaired
        )
    }

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }
    func selectTextTrack(id: Int) { engine.selectSubtitleTrack(index: id) }
    func disableSubtitles() { engine.clearSubtitle() }

    func addSubtitleFile(_ url: URL) {
        let track = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: url, name: url.deletingPathExtension().lastPathComponent, language: nil)
        )
        engine.selectSubtitleTrack(index: track.id)
    }

    /// No delay or scale dials: the cues are drawn by the app, against the
    /// engine's own source clock, so alignment is not the engine's to offer.
    var supportsTrackAlignment: Bool { false }

    @discardableResult func setSubtitleDelay(_ seconds: Double) -> Bool { false }
    @discardableResult func setAudioDelay(_ seconds: Double) -> Bool { false }
    @discardableResult func setSubtitleScale(_ scale: Double) -> Bool { false }

    var hostSubtitleCues: [HostSubtitleCue] {
        engine.subtitleCues.map { cue in
            switch cue.body {
            case .text(let string):
                return HostSubtitleCue(id: cue.id, body: .text(AttributedString(string)))
            case .richText(let runs):
                return HostSubtitleCue(id: cue.id, body: .text(SubtitleOverlay.attributed(runs)))
            case .image(let image):
                return HostSubtitleCue(
                    id: cue.id,
                    body: .image(image.cgImage, position: image.position, canvas: image.canvasSize)
                )
            }
        }
    }

    // MARK: Chapters

    /// Container chapters (Matroska / MP4) and disc chapters are published
    /// separately; a session is one or the other, so whichever is non-empty is
    /// the list the transport walks.
    private var chapterList: [ChapterInfo] {
        engine.mediaChapters.isEmpty ? engine.discChapters : engine.mediaChapters
    }

    var chapters: [MediaChapter] {
        chapterList.enumerated().map { index, chapter in
            MediaChapter(chapterIndex: index, name: chapter.name, startSeconds: chapter.startSeconds)
        }
    }

    var chapterIndex: Int {
        let now = currentTime
        return chapterList.lastIndex { $0.startSeconds <= now + 0.25 } ?? -1
    }

    func select(chapterIndex index: Int) {
        guard chapterList.indices.contains(index) else { return }
        seek(toSeconds: chapterList[index].startSeconds)
    }

    /// No chapter transport of its own; the screen's own walk is exact anyway,
    /// since every chapter here carries the timestamp to seek to.
    @discardableResult
    func skipChapter(forward: Bool) -> Bool { false }
}
