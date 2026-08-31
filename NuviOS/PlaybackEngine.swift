import Foundation
import AVFoundation

// MARK: - Engine-neutral media model

/// One selectable audio or subtitle stream, as the player screen sees it.
///
/// Both engines describe their tracks differently — libvlc hands back reference
/// types whose `isSelectedExclusively` setter *is* the selection call, while
/// AetherEngine hands back value types selected by index — so neither type can
/// be the one the UI binds to. This is: a plain snapshot, re-read from whichever
/// engine is running whenever the selection changes.
struct MediaTrack: Identifiable, Equatable {
    /// The engine's own identifier for the stream: a libvlc track id, or an
    /// FFmpeg AVStream index. Only ever handed back to the engine that made it.
    let trackId: Int
    let trackName: String
    let language: String?
    let isSelected: Bool
    let isForced: Bool
    /// Commentary, descriptive audio, or an SDH mix: a real track in the
    /// viewer's language that isn't what "play this in English" means.
    let isSecondary: Bool

    var id: Int { trackId }
}

/// A chapter boundary, from a container that carries them.
struct MediaChapter: Identifiable, Equatable {
    let chapterIndex: Int
    let name: String?
    let startSeconds: Double

    var id: Int { chapterIndex }
}

/// How the picture is fitted to the frame. AVPlayer offers the first two; the
/// forced ratios are for the releases that carry a wrong one.
enum VideoFit: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case fill = "Fill"
    case ratio16x9 = "16:9"
    case ratio4x3 = "4:3"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .fit: "arrow.up.left.and.arrow.down.right"
        case .fill: "arrow.down.right.and.arrow.up.left"
        case .ratio16x9, .ratio4x3: "rectangle.ratio.16.to.9"
        }
    }
}

/// A subtitle cue the *host* has to draw, because the engine renders none.
///
/// libvlc burns subtitles into the picture itself, so this is empty there.
/// AetherEngine deliberately draws nothing — that is the price of keeping the
/// frames on the platform's own path, where Dolby Vision and Atmos survive —
/// and publishes its cues for the app to place. See `SubtitleOverlay`.
struct HostSubtitleCue: Identifiable {
    let id: Int
    let body: Body

    enum Body {
        case text(AttributedString)
        /// PGS / DVB / DVD bitmaps, with the rect they were authored at,
        /// normalized against `canvas`.
        case image(CGImage, position: CGRect, canvas: CGSize)
    }
}

// MARK: - The engine contract

/// What the player screen needs from whatever is decoding.
///
/// The app ships two implementations. `AetherPlaybackEngine` is the one that
/// runs: it demuxes with FFmpeg but decodes and presents through VideoToolbox
/// and AVPlayer, so Dolby Vision, Dolby Atmos and tvOS Match Content all keep
/// working — none of which survive a renderer of its own.
/// `VLCPlaybackEngine` is the fallback, kept for exactly the reason it was the
/// original choice: libvlc opens things nothing else will, and the addon
/// protocol hands back whatever the source happens to hold. A source the first
/// engine cannot start is retried on the second before the failover queue is
/// touched, so a format only libvlc knows still plays.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// Which engine this is, for logs and for the "already tried" bookkeeping.
    static var name: String { get }

    var delegate: PlaybackEngineDelegate? { get set }

    // Lifecycle
    /// Claims a surface to draw into. Called before `open`, and again on the
    /// swap to the fallback, so the second engine draws where the first did.
    func attach(to view: PlatformView)
    /// Points the engine at one address. `startAt` is folded into the open
    /// rather than seeked afterwards, so a resumed title fetches only what
    /// somebody watches.
    func open(url: URL, headers: [String: String], startAt: Double?)
    /// Tears the session down but leaves the engine reusable.
    func halt()
    /// Tears down for good and gives the surface back.
    func teardown()

    // Transport
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double? { get }
    var isSeekable: Bool { get }
    func play()
    func pause()
    func seek(toSeconds: Double)
    func setRate(_ rate: Float)
    /// Nudges a single frame while paused. Not every engine can; returns false
    /// when it can't, and the screen leaves the picture where it is.
    @discardableResult
    func stepFrame(forward: Bool) -> Bool

    // Picture
    func setFit(_ fit: VideoFit)

    // Volume. 0…1, mirroring AVKit's slider.
    var volume: Double { get set }
    var isMuted: Bool { get set }

    // Tracks
    var audioTracks: [MediaTrack] { get }
    var textTracks: [MediaTrack] { get }
    func selectAudioTrack(id: Int)
    func selectTextTrack(id: Int)
    func disableSubtitles()
    func addSubtitleFile(_ url: URL)
    /// Seconds, positive meaning the track arrives later than the picture.
    /// Engines that carry no such dial return false and the screen hides it.
    @discardableResult
    func setSubtitleDelay(_ seconds: Double) -> Bool
    @discardableResult
    func setAudioDelay(_ seconds: Double) -> Bool
    @discardableResult
    func setSubtitleScale(_ scale: Double) -> Bool
    /// Whether the delay and scale dials above do anything on this engine.
    var supportsTrackAlignment: Bool { get }

    /// Cues the host has to draw. Empty on an engine that draws its own.
    var hostSubtitleCues: [HostSubtitleCue] { get }

    // Chapters
    var chapters: [MediaChapter] { get }
    var chapterIndex: Int { get }
    func select(chapterIndex: Int)
    /// Walks to the neighbouring chapter. False when the engine has no chapter
    /// transport of its own and the screen should seek instead.
    @discardableResult
    func skipChapter(forward: Bool) -> Bool
}

/// What an engine tells the screen, on the main actor, in the screen's own
/// vocabulary. Both engines report the same seven things; everything either one
/// says beyond that is its own business.
@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engineDidBeginOpening(_ engine: PlaybackEngine)
    /// The source produced a picture. Its turn is over and it has earned its
    /// place: nothing pulls it out from here.
    func engineDidStartPlaying(_ engine: PlaybackEngine)
    func engineDidPause(_ engine: PlaybackEngine)
    /// The source played to completion.
    func engineDidEnd(_ engine: PlaybackEngine)
    /// The source stopped without finishing, or refused to open at all. The
    /// screen decides whether that is a failover, a retry on the other engine,
    /// or the error the viewer finally sees.
    func engine(_ engine: PlaybackEngine, didFailWith reason: String)
    func engine(_ engine: PlaybackEngine, isBuffering: Bool)
    /// Time, length, tracks or chapters moved; the screen re-reads what it
    /// needs. Fires several times a second, so it does no work of its own.
    func engineDidUpdate(_ engine: PlaybackEngine)
}
