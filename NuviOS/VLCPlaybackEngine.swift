import Foundation
import AVFoundation
import VLCKit

/// The fallback engine: libvlc, which opens practically anything.
///
/// This was the app's only engine, and it is kept because the reason it was
/// chosen has not changed — the addon protocol hands back whatever the source
/// happens to hold, and libvlc demuxes and decodes the lot. What it cannot do
/// is hand the platform its frames, so Dolby Vision is tone-mapped, Atmos is
/// decoded to PCM and tvOS never switches the panel; that is why it is second
/// in line rather than first. It plays what `AetherPlaybackEngine` won't.
@MainActor
final class VLCPlaybackEngine: NSObject, PlaybackEngine {
    static let name = "libvlc"

    weak var delegate: PlaybackEngineDelegate?

    private let player = VLCMediaPlayer()
    private weak var surface: PlatformView?
    /// `start-time` is a request rather than a guarantee: a server that refuses
    /// ranged reads opens at zero regardless. Held until the first picture, and
    /// then seeked the old way if it didn't take.
    private var resumeTargetInFlight: Double?
    private var reportedLength: Double?

    // MARK: Lifecycle

    func attach(to view: PlatformView) {
        surface = view
        player.drawable = view
    }

    func open(url: URL, headers: [String: String], startAt: Double?) {
        let media = VLCMedia(url: url)

        // libvlc takes per-media settings as `:name=value`. Only the two
        // headers it models can be set; anything else an addon asks for has no
        // equivalent.
        for (field, value) in headers {
            switch field.lowercased() {
            case "referer", "referrer": media?.addOption(":http-referrer=\(value)")
            case "user-agent": media?.addOption(":http-user-agent=\(value)")
            default: break
            }
        }
        // A remote file over a slow link starts and seeks far better with a
        // deeper cache than libvlc's default, and remote is the only case here.
        // This is paid in full before the first frame, so it is a direct part of
        // how long the viewer waits: 1.5 s keeps a normal link smooth, and a
        // genuinely slow one is better served by the next source than by
        // everybody waiting three seconds for it.
        media?.addOption(":network-caching=1500")

        // Where this source begins, decided *before* the engine opens it.
        // Resuming used to be a second act: open at zero, fill the cache from
        // the top of the file, report a length, then seek — which threw that
        // cache away and fetched the same file twice to watch it once.
        if let startAt {
            media?.addOption(":start-time=\(Int(startAt))")
            resumeTargetInFlight = startAt
        }

        reportedLength = nil
        player.media = media
        player.delegate = self
        if let surface { player.drawable = surface }
        player.play()
    }

    func halt() {
        player.stop()
        resumeTargetInFlight = nil
        reportedLength = nil
    }

    func teardown() {
        player.stop()
        player.drawable = nil
        player.delegate = nil
        surface = nil
    }

    // MARK: Transport

    var isPlaying: Bool { player.isPlaying }
    var currentTime: Double { Double(player.time.intValue) / 1000 }

    var duration: Double? {
        if let reportedLength { return reportedLength }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        return length > 0 ? length : nil
    }

    var isSeekable: Bool { player.isSeekable }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(toSeconds seconds: Double) {
        guard let duration, duration > 0 else { return }
        player.position = Double(Float(max(0, min(1, seconds / duration))))
    }

    func setRate(_ rate: Float) { player.rate = rate }

    @discardableResult
    func stepFrame(forward: Bool) -> Bool {
        if forward { player.gotoNextFrame() } else { player.gotoPreviousFrame() }
        return true
    }

    // MARK: Picture

    func setFit(_ fit: VideoFit) {
        switch fit {
        case .fit:
            player.videoAspectRatio = nil
            player.videoFitMode = .smaller
        case .fill:
            player.videoAspectRatio = nil
            player.videoFitMode = .larger
        case .ratio16x9:
            player.videoFitMode = .smaller
            player.videoAspectRatio = "16:9"
        case .ratio4x3:
            player.videoFitMode = .smaller
            player.videoAspectRatio = "4:3"
        }
    }

    // MARK: Volume

    /// libvlc counts 0…200, but the range above 100 is amplification and is
    /// not offered.
    var volume: Double {
        get { min(1, Double(player.audio?.volume ?? 100) / 100) }
        set { player.audio?.volume = Int32((max(0, min(1, newValue)) * 100).rounded()) }
    }

    var isMuted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }

    // MARK: Tracks

    var audioTracks: [MediaTrack] { player.audioTracks.map(Self.describe) }
    var textTracks: [MediaTrack] { player.textTracks.map(Self.describe) }

    private static func describe(_ track: VLCMediaPlayer.Track) -> MediaTrack {
        let name = track.trackName
        let lowered = name.lowercased()
        return MediaTrack(
            // libvlc's track id is a string ("/es/0"), so the UI needs a stable
            // integer of its own; the string is what selection actually uses.
            trackId: Int(bitPattern: UInt(bitPattern: track.trackId.hashValue)),
            trackName: name,
            language: track.language,
            isSelected: track.isSelected,
            isForced: lowered.contains("forced"),
            isSecondary: ["commentary", "description", "descriptive", "narration", "sdh", "karaoke"]
                .contains { lowered.contains($0) }
        )
    }

    private func vlcTrack(id: Int, in tracks: [VLCMediaPlayer.Track]) -> VLCMediaPlayer.Track? {
        tracks.first { Int(bitPattern: UInt(bitPattern: $0.trackId.hashValue)) == id }
    }

    func selectAudioTrack(id: Int) {
        vlcTrack(id: id, in: player.audioTracks)?.isSelectedExclusively = true
    }

    func selectTextTrack(id: Int) {
        vlcTrack(id: id, in: player.textTracks)?.isSelectedExclusively = true
    }

    func disableSubtitles() { player.deselectAllTextTracks() }

    /// Loads a subtitle file alongside the stream — an addon's own `.srt`, or
    /// one the viewer points at.
    func addSubtitleFile(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }

    var supportsTrackAlignment: Bool { true }

    @discardableResult
    func setSubtitleDelay(_ seconds: Double) -> Bool {
        player.currentVideoSubTitleDelay = Int(seconds * 1_000_000)
        return true
    }

    @discardableResult
    func setAudioDelay(_ seconds: Double) -> Bool {
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
        return true
    }

    @discardableResult
    func setSubtitleScale(_ scale: Double) -> Bool {
        player.currentSubTitleFontScale = Float(scale)
        return true
    }

    /// libvlc burns subtitles into the picture, so the host draws none.
    var hostSubtitleCues: [HostSubtitleCue] { [] }

    // MARK: Chapters

    var chapters: [MediaChapter] {
        player.chapterDescriptions(ofTitle: player.currentTitleIndex)
            .enumerated()
            .map { index, chapter in
                MediaChapter(
                    chapterIndex: index,
                    name: chapter.name,
                    startSeconds: Double(chapter.timeOffset.intValue) / 1000
                )
            }
    }

    var chapterIndex: Int { Int(player.currentChapterIndex) }

    func select(chapterIndex index: Int) {
        player.currentChapterIndex = Int32(index)
    }

    @discardableResult
    func skipChapter(forward: Bool) -> Bool {
        if forward { player.nextChapter() } else { player.previousChapter() }
        return true
    }

    /// Confirms the opening actually began where it was asked to.
    private func confirmResumeLanded() {
        guard let target = resumeTargetInFlight else { return }
        resumeTargetInFlight = nil
        if currentTime < target - 10 { seek(toSeconds: target) }
    }
}

// MARK: - Engine callbacks

extension VLCPlaybackEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            switch newState {
            case .opening:
                delegate?.engineDidBeginOpening(self)
            case .playing:
                confirmResumeLanded()
                delegate?.engine(self, isBuffering: false)
                delegate?.engineDidStartPlaying(self)
            case .paused:
                delegate?.engineDidPause(self)
            case .stopped:
                // libvlc reports a finished file and a closed one the same way;
                // a position at the end is what tells them apart.
                if let duration, duration > 0, currentTime / duration > 0.98 {
                    delegate?.engineDidEnd(self)
                } else {
                    // Stopped anywhere else means the source dropped the
                    // connection part-way. That used to leave the player sitting
                    // on a frozen frame with no state change at all.
                    delegate?.engine(self, didFailWith: "source stopped mid-playback")
                }
            case .error:
                delegate?.engine(self, didFailWith: "engine error")
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in delegate?.engineDidUpdate(self) }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in
            guard length > 0 else { return }
            reportedLength = Double(length) / 1000
            delegate?.engineDidUpdate(self)
        }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor in delegate?.engine(self, isBuffering: progress < 100) }
    }

    nonisolated func mediaPlayerChapterChanged(_ aNotification: Notification) {
        Task { @MainActor in delegate?.engineDidUpdate(self) }
    }

    nonisolated func mediaPlayerTitleListChanged(_ aNotification: Notification) {
        Task { @MainActor in delegate?.engineDidUpdate(self) }
    }
}
