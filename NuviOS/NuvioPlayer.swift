import SwiftUI
import Combine
import AVFoundation
import MediaPlayer

// MARK: - Engine

/// The app's own player: one screen, one set of controls, for every stream.
///
/// It does not decode anything itself. Two engines sit behind `PlaybackEngine`,
/// and this model drives whichever is running:
///
/// - `AetherPlaybackEngine` is the one every stream is opened on. FFmpeg
///   demuxes, so the addon protocol's Matroska, HEVC, AC3 and VP9 all open, and
///   VideoToolbox and AVPlayer decode and present, so Dolby Vision switches the
///   panel, Atmos is passed through rather than decoded to PCM, and tvOS Match
///   Content works. It draws no subtitles; the app composites them itself.
/// - `VLCPlaybackEngine` is the fallback, and it is why libvlc is still here at
///   all: it opens things nothing else will. A source the first engine cannot
///   start is retried on it before the failover queue moves on, so a format only
///   libvlc knows still plays — one source, two chances.
///
/// What the viewer touches is modelled on AVKit's player, because that is the
/// player every one of these people already knows: the same transport, the same
/// scrubber, the same volume and speed and track menus, the same keyboard
/// shortcuts, the same hold-to-skim and press-and-hold-for-2×. AVKit's own
/// controls only drive an `AVPlayer`, so they are rebuilt here rather than
/// adopted.
@MainActor
final class NuvioPlayerModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case opening
        case playing
        case paused
        case ended
        case failed(String)
    }

    @Published private(set) var phase: Phase = .opening
    /// Distinct from `.opening`: the stream is running but has stalled for
    /// more data, which is worth a spinner but not a state change.
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: Double?
    @Published private(set) var isSeekable = true
    @Published var currentTime: Double = 0

    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var textTracks: [MediaTrack] = []
    @Published private(set) var rate: Float = 1
    @Published private(set) var fit: VideoFit = .fit

    @Published private(set) var chapters: [MediaChapter] = []
    @Published private(set) var chapterIndex: Int = -1

    /// The cues the running engine expects this app to draw. Empty while the
    /// libvlc fallback is playing, which burns its own into the picture.
    @Published private(set) var subtitleCues: [HostSubtitleCue] = []

    /// 0…1, mirroring AVKit's volume slider.
    @Published private(set) var volume: Double = 1
    @Published private(set) var isMuted = false

    /// Track alignment, in seconds. AVKit has no equivalent, but a mismatched
    /// muxed subtitle is common enough in this app's sources to be worth a dial.
    /// Only the fallback engine carries these; `supportsTrackAlignment` says so
    /// and the menu hides them on the one that doesn't.
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var subtitleScale: Double = 1
    @Published private(set) var supportsTrackAlignment = false

    /// True while the viewer is holding the picture down to run at 2×, the way
    /// the TV app skims forward.
    @Published private(set) var isBoosting = false

    /// Shown briefly when playback resumed part-way, or when subtitles were
    /// switched on because the audio wasn't in the viewer's language.
    @Published var notice: String?

    var isPlaying: Bool { phase == .playing }
    var hasChapters: Bool { chapters.count > 1 }

    /// Held while the viewer drags the scrubber so incoming time updates
    /// don't fight the thumb.
    var isScrubbing = false

    /// The engine currently decoding. Swapped, not reconfigured, when a source
    /// has to be retried on the fallback.
    private var engine: PlaybackEngine!
    /// The one the fallback is fallen back *from*, kept alive across the swap
    /// so a second source in the queue starts on it again — the next address is
    /// a different file and deserves the better path of its own accord.
    private var preferredEngineFailed = false
    /// Whether the address being opened has already had its second chance.
    private var hasTriedFallbackForCurrentSource = false

    private var request: PlaybackRequest?
    private var hasStarted = false
    private var hasAppliedTrackPreference = false
    private var didSeekToResumePoint = false
    private var noticeDismissal: Task<Void, Never>?

    /// Sources still to try, best first, consumed as each one fails.
    private var alternates: [PlaybackAlternate] = []
    /// Where to pick up after a failover, so a swapped source resumes on the
    /// frame the dead one stopped at rather than at the resume point on disk —
    /// which is rounded to the second and not written at all in the first
    /// half-minute of a title.
    private var pendingResume: Double?
    /// Fires if a source never gets as far as playing. A host that accepts a
    /// connection and then says nothing at all is reported by neither engine as
    /// an error or a state change, so without this a dead source hangs on the
    /// spinner indefinitely — which is the failure this whole queue exists for.
    private var openWatchdog: Task<Void, Never>?
    /// The in-flight pre-open dial of the current address. Cancelled whenever
    /// the engine is pointed somewhere else, so a late verdict can never speak
    /// for a source that is no longer being opened.
    private var linkCheck: Task<Void, Never>?
    /// The address the engine was last pointed at, so a re-request can tell
    /// the fresh answers from the one that just died.
    private var currentAddress: URL?
    /// The headers it was opened with, so the retry on the other engine opens
    /// the identical request rather than a bare one.
    private var currentHeaders: [String: String] = [:]
    /// Whether the addons have already been asked again for this title. One
    /// re-request per player; see `reRequest`.
    private var hasReRequested = false
    /// An address this app resolved itself, and when. Trusted only while it is
    /// young: minutes later it is no better than any other link.
    private var minted: (url: URL, at: Date)?
    /// How long a self-minted address is taken on trust.
    private static let mintedTrustSeconds: Double = 120

    /// The surface both engines draw into. Held rather than read back off the
    /// engine, because the two hold it differently and the swap needs it.
    private weak var surface: PlatformView?

    private func isFreshlyMinted(_ url: URL) -> Bool {
        guard let minted, minted.url == url else { return false }
        return Date().timeIntervalSince(minted.at) < Self.mintedTrustSeconds
    }
    /// How long a source gets to produce a picture before its turn is over.
    private static let openTimeout: Double = 12
    /// The rate to go back to when a press-and-hold ends.
    private var rateBeforeBoost: Float = 1
    /// The last whole second the once-a-second work ran for.
    ///
    /// An engine reports the time several times a second. The Now Playing panel
    /// and the resume point both move in whole seconds, so running them on
    /// every tick burns power to produce the same answer repeatedly — and the
    /// Now Playing write is a round trip to another process.
    private var lastTickSecond = -1

    /// The speeds AVKit's own speed menu offers.
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// AVKit skips by ten, and so does every remote command the system sends.
    static let skipInterval: Double = 10

    // MARK: Lifecycle

    func open(_ request: PlaybackRequest, into view: PlatformView) {
        guard !hasStarted else { return }
        hasStarted = true
        lastTickSecond = -1
        self.request = request
        self.surface = view
        alternates = request.alternates
        minted = request.mintedAt.map { (request.url, $0) }

        configureAudioSession()
        // Claimed before the link check so that `retry` and the failover queue
        // both have a surface to draw on even if the first address never gets
        // as far as `start`.
        useEngine(makePreferredEngine(), into: view)
        load(url: request.url, headers: request.headers, into: view)

        readVolume()
        configureRemoteCommands()
    }

    /// The engine every source is opened on, unless the device cannot build it.
    private func makePreferredEngine() -> PlaybackEngine {
        AetherPlaybackEngine() ?? VLCPlaybackEngine()
    }

    /// Points the model at an engine and gives it the surface.
    private func useEngine(_ next: PlaybackEngine, into view: PlatformView) {
        if let engine, engine !== next {
            engine.delegate = nil
            engine.teardown()
        }
        engine = next
        next.delegate = self
        next.attach(to: view)
        supportsTrackAlignment = next.supportsTrackAlignment
        // A dial the new engine cannot honour must not keep reading as though
        // it were applied.
        if !next.supportsTrackAlignment {
            subtitleDelay = 0
            audioDelay = 0
            subtitleScale = 1
        }
    }

    /// Checks an address is still good, then points the engine at it.
    ///
    /// Shared by the first open, by `retry`, and by each failover, so all three
    /// start a source exactly alike — including the check. A link the host has
    /// disowned is handed straight to the next source rather than spending the
    /// twelve-second open watchdog on a request that has already been answered.
    private func load(url: URL, headers: [String: String], into view: PlatformView) {
        linkCheck?.cancel()
        // A fresh address gets the preferred engine again even if the last one
        // ended up on the fallback: this is a different file.
        hasTriedFallbackForCurrentSource = false
        if preferredEngineFailed == false, engine is VLCPlaybackEngine,
           let preferred = AetherPlaybackEngine() {
            useEngine(preferred, into: view)
        }

        // An address this app minted moments ago is one it already knows the
        // provider honours; dialling it again before opening it would spend a
        // round trip to learn what was just learned. This is the whole saving
        // on a resolve-then-play: the picture starts on the first request.
        guard !isFreshlyMinted(url) else {
            start(url: url, headers: headers, into: view)
            return
        }

        guard StreamLinkCheck.canCheck(url) else {
            start(url: url, headers: headers, into: view)
            return
        }

        linkCheck = Task { [weak self] in
            let verdict = await StreamLinkCheck.verify(url: url, headers: headers)
            // A later load — a failover, a retry, or the viewer closing the
            // player — cancels this task, so reaching here means the verdict
            // still speaks for the address being opened.
            guard !Task.isCancelled, let self else { return }

            guard let message = verdict.failureMessage else {
                self.start(url: url, headers: headers, into: view)
                return
            }
            // A dead link is asked for again before anything is given up on:
            // the source the viewer chose is almost always still on offer, it
            // is only the address that has gone off. A link the *host* has
            // disowned is not an engine's problem, so the fallback is not
            // tried here — no decoder fixes a 404.
            if await self.reRequest(replacing: url, into: view) { return }
            if !self.failOver(reason: "link check: \(verdict)", into: view) {
                self.phase = .failed(message)
            }
        }
    }

    /// Points the engine at one address, unconditionally.
    private func start(url: URL, headers: [String: String], into view: PlatformView) {
        currentAddress = url
        currentHeaders = headers

        // Where this source should begin, decided *before* the engine opens it.
        //
        // Resuming used to be a second act: the file opened at zero, filled its
        // cache from the top of the file, reported a length, and only then was
        // seeked — which threw that cache away, issued a fresh ranged request
        // at the real offset, and filled it again. A viewer picking up an hour
        // into a film paid for two openings to watch one. Both engines take the
        // position into the open instead, so nothing is fetched that nobody
        // watches.
        let resumeTarget = pendingResumeTarget()
        if let resumeTarget {
            // The transport bar should read the resume point from the first
            // frame rather than counting up from zero to meet it.
            currentTime = resumeTarget
            didSeekToResumePoint = true
            pendingResume = nil
            announceResumeWhenPlaying = resumeTarget
        }

        engine.attach(to: view)
        engine.open(url: url, headers: headers, startAt: resumeTarget)
        startOpenWatchdog()
    }

    func stop() {
        recordProgress(final: true)
        noticeDismissal?.cancel()
        openWatchdog?.cancel()
        linkCheck?.cancel()
        engine?.delegate = nil
        engine?.teardown()
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.removeTarget(nil)
        centre.pauseCommand.removeTarget(nil)
        centre.togglePlayPauseCommand.removeTarget(nil)
        centre.skipForwardCommand.removeTarget(nil)
        centre.skipBackwardCommand.removeTarget(nil)
        centre.changePlaybackPositionCommand.removeTarget(nil)
        centre.changePlaybackRateCommand.removeTarget(nil)
        centre.nextTrackCommand.removeTarget(nil)
        centre.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Reopens the same stream after a failure, from the top of the engine.
    func retry() {
        guard let request, let view = surface else { return }
        hasStarted = false
        hasAppliedTrackPreference = false
        didSeekToResumePoint = false
        // The viewer asked for this one again, so give it the queue afresh
        // rather than resuming a walk that already gave up — and let it earn a
        // new re-request too, since time has passed since the last one. The
        // engine choice is reset with it: a source that only failed because the
        // link was cold deserves the better path again.
        alternates = request.alternates
        hasReRequested = false
        preferredEngineFailed = false
        pendingResume = currentTime > 1 ? currentTime : nil
        phase = .opening
        engine.halt()
        open(request, into: view)
    }

    // MARK: Keeping it playing

    /// The second chance every address gets: the same URL, the other engine.
    ///
    /// This is what "keep libvlc as the fallback" means in practice. The two
    /// engines fail on genuinely different things — one on a container FFmpeg's
    /// demuxer or VideoToolbox won't take, the other on a stream libvlc's own
    /// demuxer chokes on — so a source is only really dead once both have said
    /// no. It costs one more open on a source that was going to fail anyway,
    /// and it is spent before the failover queue, because the viewer picked
    /// *this* source.
    ///
    /// Returns false when the address has already had its second chance.
    private func fallBackToOtherEngine(reason: String) -> Bool {
        guard !hasTriedFallbackForCurrentSource,
              let url = currentAddress,
              let view = surface,
              engine is AetherPlaybackEngine else { return false }

        hasTriedFallbackForCurrentSource = true
        // Every later source in this queue starts on the fallback too. If the
        // preferred engine could not open one address from a provider, the rest
        // of that provider's list is usually the same carriage.
        preferredEngineFailed = true

        print("[player] \(type(of: engine!).name) could not play this (\(reason)); retrying on \(VLCPlaybackEngine.name)")

        // Held across the swap: the position is the viewer's, not the engine's.
        pendingResume = pendingResume ?? (currentTime > 1 ? currentTime : nil)
        hasAppliedTrackPreference = false
        didSeekToResumePoint = false
        phase = .opening
        isBuffering = true
        duration = nil
        subtitleCues = []

        engine.halt()
        useEngine(VLCPlaybackEngine(), into: view)
        start(url: url, headers: currentHeaders, into: view)
        return true
    }

    /// Moves to the next source in the queue, holding the viewer's place.
    ///
    /// Nothing is announced. From the seat this looks like the film pausing to
    /// buffer, which is what a viewer expects when a stream hiccups — and
    /// unlike an error screen, it does not need answering.
    ///
    /// Returns false when the queue is spent and the failure is real.
    @discardableResult
    /// `view` is passed in when the engine has not been pointed at a surface
    /// yet — the very first source can fail its link check before `start` ever
    /// claims one, and its alternates deserve the same walk.
    private func failOver(reason: String, into view: PlatformView? = nil) -> Bool {
        guard !alternates.isEmpty, let view = view ?? surface else { return false }

        let next = alternates.removeFirst()
        // Taken before the engine is torn down, since stopping resets the clock.
        let resumeAt = pendingResume ?? (currentTime > 1 ? currentTime : nil)

        print("[player] failing over (\(reason)); \(alternates.count) source(s) left")

        pendingResume = resumeAt
        hasAppliedTrackPreference = false
        didSeekToResumePoint = false
        phase = .opening
        isBuffering = true
        duration = nil
        subtitleCues = []

        engine.halt()
        load(url: next.url, headers: next.headers, into: view)
        return true
    }

    /// Asks the addons for this title again and reopens on a fresh address.
    ///
    /// This is the cure a failover queue cannot be: when a list has sat long
    /// enough for the chosen link to expire, the runners-up were minted in the
    /// same breath and are usually just as dead. So the whole queue is rebuilt
    /// from the new answers, with the viewer's own source back on top.
    ///
    /// Once per player. A re-request that comes back with an address that is
    /// also refused has nothing more to offer, and asking a third time would
    /// only spend the viewer's evening on it.
    ///
    /// Returns false when there is nothing to re-request, or when the answer
    /// held no address that wasn't the dead one.
    private func reRequest(replacing dead: URL, into view: PlatformView) async -> Bool {
        guard !hasReRequested, let refresh = request?.refresh else { return false }
        hasReRequested = true

        // Nothing is announced, for the same reason a failover isn't: from the
        // seat this is the spinner it was already showing. The notice banner
        // carries a "Start over" button, which is the wrong offer here.
        phase = .opening
        isBuffering = true

        // The straight line first: a source with debrid instructions can have
        // a brand-new address minted on demand, without an addon in the middle
        // deciding how fresh an answer to give.
        if let reminted = await refresh.reResolve(), reminted.url != dead {
            print("[player] re-minted the download link")
            minted = (reminted.url, Date())
            pendingResume = pendingResume ?? (currentTime > 1 ? currentTime : nil)
            load(url: reminted.url, headers: reminted.headers, into: view)
            return true
        }

        let answers = await refresh.freshSources()
        // The one thing worth saying out loud when this fails: whether the
        // addons actually produced a different address, or handed back the
        // same dead one — which is a fault at the source, not here.
        var fresh = answers.filter { $0.url != dead }
        print("[player] re-requested \(refresh.id): \(answers.count) source(s), \(fresh.count) not the dead link")
        // The engine may have been pointed elsewhere while the addons were
        // being asked.
        guard !Task.isCancelled else { return true }
        guard !fresh.isEmpty else { return false }

        let first = fresh.removeFirst()
        // Anything still queued from the old list is of the same vintage as
        // the link that just expired; the new answers replace it outright.
        alternates = fresh
        pendingResume = pendingResume ?? (currentTime > 1 ? currentTime : nil)
        load(url: first.url, headers: first.headers, into: view)
        return true
    }

    /// The end of the queue. Before the viewer is shown an error, the addons
    /// get one last ask: a link that expired mid-film fails here just as one
    /// that expired before it started fails at the check, and both are fixed
    /// by the same fresh address.
    private func exhausted(_ message: String) {
        guard !hasReRequested,
              request?.refresh != nil,
              let view = surface,
              let dead = currentAddress else {
            phase = .failed(message)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let recovered = await self.reRequest(replacing: dead, into: view)
            if !recovered {
                self.phase = .failed(message)
            }
        }
    }

    /// A source that has been given its chance and produced no picture is
    /// treated exactly like one that errored — including its second chance on
    /// the other engine, since an engine that hangs on an open is the most
    /// common way one of the two refuses a container without saying so.
    private func startOpenWatchdog() {
        openWatchdog?.cancel()
        openWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.openTimeout))
            guard !Task.isCancelled, let self, self.phase == .opening else { return }
            let reason = "no picture in \(Int(Self.openTimeout))s"
            if self.fallBackToOtherEngine(reason: reason) { return }
            if !self.failOver(reason: reason) {
                self.exhausted(
                    "This stream didn't start. The source may be offline, or too slow to play."
                )
            }
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
            phase = .paused
        } else {
            engine.play()
            phase = .playing
        }
        updateNowPlaying()
    }

    func play() {
        guard !engine.isPlaying else { return }
        engine.play()
        phase = .playing
        updateNowPlaying()
    }

    func pause() {
        guard engine.isPlaying else { return }
        engine.pause()
        phase = .paused
        updateNowPlaying()
    }

    func jump(_ seconds: Double) {
        guard isSeekable else { return }
        let target = max(0, min(duration ?? .greatestFiniteMagnitude, currentTime + seconds))
        engine.seek(toSeconds: target)
        // An engine reports the new time on its own schedule; moving the
        // published value now keeps the scrubber from lurching backwards
        // between the tap and the next tick.
        currentTime = target
        updateNowPlaying()
    }

    func seek(toSeconds seconds: Double) {
        guard isSeekable, let duration, duration > 0 else { return }
        engine.seek(toSeconds: max(0, min(duration, seconds)))
        currentTime = seconds
        updateNowPlaying()
    }

    func setRate(_ value: Float) {
        rate = value
        rateBeforeBoost = value
        engine.setRate(value)
        updateNowPlaying()
    }

    /// Press and hold the picture to run at 2×, as the TV app does; letting go
    /// returns to whatever speed was set before.
    func beginSpeedBoost() {
        guard !isBoosting, isPlaying else { return }
        isBoosting = true
        rateBeforeBoost = rate
        rate = 2
        engine.setRate(2)
    }

    func endSpeedBoost() {
        guard isBoosting else { return }
        isBoosting = false
        rate = rateBeforeBoost
        engine.setRate(rateBeforeBoost)
    }

    /// Nudges a single frame while paused — the `,` and `.` keys, as in
    /// QuickTime. Only the fallback engine can; on the other the picture is
    /// left where it is rather than jolted by a seek pretending to be a step.
    func stepFrame(forward: Bool) {
        guard isSeekable, engine.stepFrame(forward: forward) else { return }
        phase = .paused
    }

    // MARK: Picture

    func setFit(_ value: VideoFit) {
        fit = value
        engine.setFit(value)
    }

    /// The one-key toggle AVPlayer puts behind its zoom glyph.
    func toggleFill() {
        setFit(fit == .fill ? .fit : .fill)
    }

    // MARK: Volume

    func setVolume(_ value: Double) {
        let clamped = max(0, min(1, value))
        volume = clamped
        engine.volume = clamped
        if clamped > 0, isMuted {
            isMuted = false
            engine.isMuted = false
        }
    }

    func nudgeVolume(_ delta: Double) {
        setVolume(volume + delta)
    }

    func toggleMute() {
        isMuted.toggle()
        engine.isMuted = isMuted
    }

    private func readVolume() {
        guard let engine else { return }
        volume = engine.volume
        isMuted = engine.isMuted
    }

    // MARK: Tracks

    func select(_ track: MediaTrack) {
        if audioTracks.contains(where: { $0.trackId == track.trackId }) {
            engine.selectAudioTrack(id: track.trackId)
        } else {
            engine.selectTextTrack(id: track.trackId)
        }
        refreshTracks()
    }

    func disableSubtitles() {
        engine.disableSubtitles()
        subtitleCues = []
        refreshTracks()
    }

    /// Loads a subtitle file alongside the stream — an addon's own `.srt`, or
    /// one the viewer points at.
    func addSubtitleFile(_ url: URL) {
        engine.addSubtitleFile(url)
        refreshTracks()
    }

    /// Seconds, positive meaning the subtitles arrive later than the picture.
    func setSubtitleDelay(_ seconds: Double) {
        let value = max(-10, min(10, seconds))
        guard engine.setSubtitleDelay(value) else { return }
        subtitleDelay = value
    }

    func setAudioDelay(_ seconds: Double) {
        let value = max(-10, min(10, seconds))
        guard engine.setAudioDelay(value) else { return }
        audioDelay = value
    }

    func setSubtitleScale(_ scale: Double) {
        let value = max(0.5, min(2.5, scale))
        subtitleScale = value
        // The engine that draws its own cues is told; the one whose cues this
        // app draws is not, because `SubtitleOverlay` reads the same dial.
        _ = engine.setSubtitleScale(value)
    }

    private func refreshTracks() {
        audioTracks = engine.audioTracks
        textTracks = engine.textTracks
    }

    /// Runs once, as soon as the demuxer has read the track list: picks the
    /// audio and subtitles that match the languages the system is set to.
    private func applyTrackPreferenceIfNeeded() {
        guard !hasAppliedTrackPreference else { return }
        let audio = engine.audioTracks
        let text = engine.textTracks
        guard !audio.isEmpty || !text.isEmpty else { return }
        hasAppliedTrackPreference = true

        let choice = TrackPreference.choose(audioTracks: audio, textTracks: text)
        if let track = choice.audio { engine.selectAudioTrack(id: track.trackId) }
        if let subtitle = choice.subtitle {
            engine.selectTextTrack(id: subtitle.trackId)
        } else {
            engine.disableSubtitles()
        }

        if choice.subtitlesForcedByLanguage, let name = choice.subtitle?.trackName {
            show(notice: "No audio in your language — subtitles on (\(name))")
        }

        refreshTracks()
    }

    // MARK: Chapters

    func refreshChapters() {
        let list = engine.chapters
        if list != chapters { chapters = list }
        chapterIndex = engine.chapterIndex
    }

    func select(chapter: MediaChapter) {
        engine.select(chapterIndex: chapter.chapterIndex)
        chapterIndex = chapter.chapterIndex
        currentTime = chapter.startSeconds
        updateNowPlaying()
    }

    /// AVKit's chapter arrows: back to the start of this chapter unless we are
    /// already at it, which is what a viewer means by "previous".
    func skipChapter(forward: Bool) {
        guard hasChapters else {
            jump(forward ? Self.skipInterval : -Self.skipInterval)
            return
        }
        // An engine with a chapter transport of its own walks the list; the
        // other one is seeked, which is exact here because every chapter
        // carries the timestamp it starts at.
        if !engine.skipChapter(forward: forward) {
            let here = chapterIndex
            // "Previous" means the top of this chapter unless we are already
            // sitting on it, the same rule the system player uses.
            let atChapterHead = here >= 0
                && currentTime - chapters[here].startSeconds < 3
            let target: Int
            if forward {
                target = min(chapters.count - 1, max(0, here) + 1)
            } else {
                target = atChapterHead ? max(0, here - 1) : max(0, here)
            }
            guard chapters.indices.contains(target) else { return }
            select(chapter: chapters[target])
            return
        }
        refreshChapters()
    }

    var currentChapterName: String? {
        guard hasChapters, chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        let chapter = chapters[chapterIndex]
        return chapter.name ?? "Chapter \(chapterIndex + 1)"
    }

    // MARK: Resume

    /// Where playback should pick up, or nil to start at the top.
    ///
    /// A failover's own position wins: it is exact, and it exists even in the
    /// first half-minute, where the stored resume point does not. The floor
    /// keeps a resume point of a few seconds from being worth an option.
    private func pendingResumeTarget() -> Double? {
        if let handover = pendingResume, handover > 1 {
            // Deliberately silent. The viewer did not ask for a different
            // source and does not need telling that one was swapped in — and
            // an engine swap is the same: it is the same film, still playing.
            announcesResume = false
            return handover
        }
        guard let request, let stored = PlaybackProgress.position(for: request.resumeKey),
              stored > Self.minimumResumeSeconds else { return nil }
        announcesResume = true
        return stored
    }

    /// Whether the position being resumed to is one worth mentioning — a
    /// stored resume point is, a failover's handover is not.
    private var announcesResume = false

    /// Below this, starting from the top is faster and no less correct.
    private static let minimumResumeSeconds: Double = 5

    /// The position the open was asked to begin at, until a picture confirms it.
    private var announceResumeWhenPlaying: Double?

    /// Confirms the opening actually began where it was asked to.
    ///
    /// A start position is honoured by every container this app opens in
    /// practice, but it is a request rather than a guarantee — a stream whose
    /// server refuses ranged reads starts at zero regardless. Rather than trust
    /// it blindly, the position is checked once the picture exists and seeked
    /// the old way only if it didn't take.
    private func confirmResumeLanded() {
        guard let target = announceResumeWhenPlaying else { return }
        announceResumeWhenPlaying = nil

        if engine.currentTime < target - 10 {
            didSeekToResumePoint = false
            pendingResume = target
            seekToResumePointIfNeeded()
            return
        }
        announceResume(at: target)
    }

    /// The viewer is told where they were picked up from — but only for a
    /// stored resume point, never for a failover, which is meant to pass
    /// unremarked.
    private func announceResume(at seconds: Double) {
        guard announcesResume else { return }
        announcesResume = false
        show(notice: "Resumed from \(Self.timecode(seconds))")
    }

    private func seekToResumePointIfNeeded() {
        guard !didSeekToResumePoint, let request, let duration, duration > 0 else { return }
        didSeekToResumePoint = true

        // A failover's own position wins: it is exact, and it exists even in
        // the first half-minute, where the stored resume point does not.
        if let handover = pendingResume {
            pendingResume = nil
            guard handover < duration else { return }
            seek(toSeconds: handover)
            return
        }

        guard let resume = PlaybackProgress.position(for: request.resumeKey), resume < duration else { return }
        seek(toSeconds: resume)
        announceResume(at: resume)
    }

    func startOver() {
        seek(toSeconds: 0)
        notice = nil
    }

    private func recordProgress(final: Bool = false) {
        guard let request, let duration, duration > 0 else { return }
        PlaybackProgress.record(key: request.resumeKey, seconds: currentTime, duration: duration)

        // And outward, so the Continue Watching shelf — here and on every other
        // device on this account — knows what this one just watched. Throttled
        // inside the sync; the write on the way out is not.
        let key = request.resumeKey
        let seconds = currentTime
        Task {
            await WatchProgressSync.shared.record(
                resumeKey: key,
                seconds: seconds,
                duration: duration,
                force: final
            )
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeDismissal?.cancel()
        noticeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: System integration

    /// Without an explicit playback session the app stays on the ambient
    /// category, which mutes behind the ring switch and stops at lock.
    private func configureAudioSession() {
        // macOS has no AVAudioSession: routing and mixing are the system's
        // business there, and an app that plays audio needs no set-up.
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// The lock screen, Control Centre, AirPods stems and the TV remote all
    /// speak through the remote command centre.
    private func configureRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        centre.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        centre.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.jump(Self.skipInterval) }
            return .success
        }
        centre.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        centre.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.jump(-Self.skipInterval) }
            return .success
        }
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(toSeconds: event.positionTime) }
            return .success
        }
        // Control Centre's speed control, and the same rates the speed menu
        // offers, so the two never disagree.
        centre.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        centre.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.setRate(event.playbackRate) }
            return .success
        }
        // On a file with chapters the track buttons walk them, which is what
        // the system player does with a chaptered movie.
        centre.nextTrackCommand.isEnabled = true
        centre.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipChapter(forward: true) }
            return .success
        }
        centre.previousTrackCommand.isEnabled = true
        centre.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipChapter(forward: false) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let request else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: request.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: duration == nil,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let subtitle = request.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Engine callbacks

/// Both engines report the same seven things, in the screen's own vocabulary;
/// which one is speaking only matters in one place below, where a failure
/// decides between the other engine and the next source.
extension NuvioPlayerModel: PlaybackEngineDelegate {
    func engineDidBeginOpening(_ engine: PlaybackEngine) {
        guard isCurrent(engine) else { return }
        if phase != .opening { phase = .opening }
    }

    func engineDidStartPlaying(_ engine: PlaybackEngine) {
        guard isCurrent(engine) else { return }
        // The source produced a picture, so its turn is over and it has earned
        // its place; nothing pulls it out from here — not the watchdog, and not
        // the other engine.
        openWatchdog?.cancel()
        hasTriedFallbackForCurrentSource = true
        phase = .playing
        isBuffering = false
        isSeekable = engine.isSeekable
        confirmResumeLanded()
        applyTrackPreferenceIfNeeded()
        refreshChapters()
        readVolume()
        updateNowPlaying()
    }

    func engineDidPause(_ engine: PlaybackEngine) {
        guard isCurrent(engine) else { return }
        phase = .paused
        updateNowPlaying()
    }

    func engineDidEnd(_ engine: PlaybackEngine) {
        guard isCurrent(engine) else { return }
        phase = .ended
        updateNowPlaying()
    }

    func engine(_ engine: PlaybackEngine, didFailWith reason: String) {
        guard isCurrent(engine), phase != .ended else { return }
        // The order matters: this source, on the other engine, before the next
        // source on this one. The viewer chose this source.
        if fallBackToOtherEngine(reason: reason) { return }
        if failOver(reason: reason) { return }
        exhausted(
            phase == .opening
                ? "This stream couldn't be opened. The source may be offline, or it refused the request."
                : "This stream ended early. The source stopped sending data."
        )
    }

    func engine(_ engine: PlaybackEngine, isBuffering buffering: Bool) {
        guard isCurrent(engine) else { return }
        isBuffering = buffering
    }

    func engineDidUpdate(_ engine: PlaybackEngine) {
        guard isCurrent(engine) else { return }

        if duration == nil, let length = engine.duration {
            duration = length
            seekToResumePointIfNeeded()
        }
        // Tracks can appear a little after playback starts on a stream whose
        // headers arrive late.
        applyTrackPreferenceIfNeeded()

        // Cues turn over several times a second on a busy subtitle track, and
        // the overlay is the only thing that reads them, so they are published
        // on every tick rather than once a second like the rest.
        let cues = engine.hostSubtitleCues
        if cues.count != subtitleCues.count || cues.map(\.id) != subtitleCues.map(\.id) {
            subtitleCues = cues
        }

        guard !isScrubbing else { return }
        currentTime = engine.currentTime

        // Everything below is per-second work. `% 5` on its own was true for
        // every tick inside that second, so the resume point was rewritten
        // several times over rather than once — and each write re-encodes the
        // whole store.
        let second = Int(currentTime)
        guard second != lastTickSecond else { return }
        lastTickSecond = second

        if hasChapters { refreshChapters() }
        updateNowPlaying()

        // Cheap enough to keep the resume point close to the truth without a
        // timer of its own.
        if second % 5 == 0 { recordProgress() }
    }

    /// A torn-down engine can still have a callback in flight — both of them
    /// hop to the main actor to report — and a dead engine must not be allowed
    /// to fail the source that replaced it.
    private func isCurrent(_ candidate: PlaybackEngine) -> Bool {
        engine === candidate
    }
}

// MARK: - Video surface

/// A bare view for the running engine to draw into. Both add their output as a
/// subview of it — libvlc its own render surface, the player engine its
/// `AetherPlayerView` — which is also what lets the two be swapped underneath a
/// picture that is already on screen.
///
/// That subview is created once, at the size the host happened to be when
/// playback opened, and libvlc does not resize it afterwards. On a phone the
/// host never changes size, so nothing showed; in a Mac window — resized,
/// zoomed, taken full screen — the picture stayed the size the window was when
/// the stream started, sitting in a corner of a black frame. The host below
/// therefore re-frames whatever libvlc puts inside it on every layout pass, so
/// the picture always fills the window and `videoFitMode` can letterbox it.
#if os(macOS)
final class VideoHostView: NSView {
    override func layout() {
        super.layout()
        // libvlc draws into that subview through an OpenGL framebuffer, so the
        // frame handed to it is the size of the render surface. A zero or
        // sub-pixel frame leaves the framebuffer incomplete, and the next
        // frame libvlc prepares dies on its own assert, on the vout thread:
        //
        //   Assertion failed: (!"GL_INVALID_FRAMEBUFFER_OPERATION"),
        //   function vout_display_opengl_Prepare, file vout_helper.c
        //
        // AppKit lays a view out at zero more often than it looks: before the
        // first real pass, while a window is live-resized, and across the
        // full-screen transition. The picture is simply left at its last good
        // size until there is a real one to give it.
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let model: NuvioPlayerModel
    let request: PlaybackRequest

    func makeNSView(context: Context) -> NSView {
        let view = VideoHostView()
        // NSView draws nothing of its own, so the black behind the picture has
        // to come from a backing layer rather than a `backgroundColor`.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        // Opened here rather than in `onAppear`: libvlc needs the view it
        // will draw into, and this is the first moment it exists.
        Task { @MainActor in model.open(request, into: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.needsLayout = true
    }
}
#else
final class VideoHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // The same guard as the AppKit host above: a zero-sized frame handed
        // to libvlc's GL surface takes the vout thread down with an assert,
        // and iOS on a Mac resizes this view as freely as AppKit does.
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
    }
}

private struct VideoSurface: UIViewRepresentable {
    let model: NuvioPlayerModel
    let request: PlaybackRequest

    func makeUIView(context: Context) -> UIView {
        let view = VideoHostView()
        view.backgroundColor = .black
        // Opened here rather than in `onAppear`: libvlc needs the view it
        // will draw into, and this is the first moment it exists.
        Task { @MainActor in model.open(request, into: view) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.setNeedsLayout()
    }
}
#endif

// MARK: - The screen

/// Every stream in the app opens here.
struct NuvioPlayerScreen: View {
    let request: PlaybackRequest

    @Environment(\.dismiss) private var dismiss
    /// Set when the player is presented as a full-window cover rather than as
    /// a sheet, because `dismiss` has nothing to dismiss in that case.
    @Environment(\.platformCoverDismiss) private var coverDismiss
    @StateObject private var model = NuvioPlayerModel()
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// The position the thumb is being dragged to, before it is committed.
    @State private var scrubTarget: Double?
    /// The running total of a burst of skips, so repeated taps read "+30s"
    /// rather than three separate "+10s" — as AVKit's own skip badge does.
    @State private var skipTotal: Double = 0
    @State private var skipReset: Task<Void, Never>?
    @State private var volumeExpanded = false
    /// The size of the player itself, not of the display. On a Mac the player
    /// fills a window that is rarely the size of the screen, and the skip
    /// gesture needs to know which half of *that* was tapped.
    @State private var size: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(model: model, request: request)
                .ignoresSafeArea()

            // Drawn here rather than by the engine: the player engine hands its
            // frames to the platform so Dolby Vision and Atmos survive, and
            // nothing burns cues into the picture on that path. Empty while the
            // libvlc fallback is playing, which draws its own.
            SubtitleOverlay(cues: model.subtitleCues, scale: model.subtitleScale)
                .ignoresSafeArea()

            #if os(iOS) || os(macOS)
            // One tap on the picture brings the controls up, the next puts them
            // away — YouTube's rule, and every phone player's. Waiting out the
            // four-second timer to see the frame again is exactly what this
            // replaces: check the time, change a track, tap, carry on.
            //
            // It is its own layer rather than another gesture on the root
            // because the root already carries the scrub drag and the
            // press-and-hold boost, and a tap that has to win against those two
            // is a tap that only sometimes lands. The controls are drawn above
            // this, so a tap on a button belongs to the button and a tap
            // anywhere else belongs to the toggle.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    // Double-tap either half to skip, the way every phone
                    // player does. Declared before the single tap so the two
                    // resolve against each other here rather than across
                    // separate modifiers.
                    let width = size.width > 0 ? size.width : PlatformScreen.width
                    let forward = location.x > width / 2
                    skip(by: forward ? NuvioPlayerModel.skipInterval : -NuvioPlayerModel.skipInterval)
                }
                .onTapGesture { toggleChrome() }
                .ignoresSafeArea()
            #endif

            if case .failed(let message) = model.phase {
                failure(message)
            } else {
                if model.phase == .opening || model.isBuffering {
                    openingIndicator
                }

                if skipTotal != 0 {
                    skipBadge
                }

                if model.isBoosting {
                    boostBadge
                }

                if chromeVisible {
                    chrome.transition(.opacity)
                }

                if let notice = model.notice {
                    noticeBanner(notice)
                }
            }

            #if os(iOS) || os(macOS)
            keyboardShortcuts
            #endif
        }
        // Always as large as whatever is presenting it — the whole window on a
        // Mac, the whole screen on a phone or a TV.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .preferredColorScheme(.dark)
        #if os(iOS)
        // Status bar and home indicator are phone chrome; a Mac has neither.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        #if os(iOS) || os(macOS)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .simultaneousGesture(boostGesture)
        // A pointer is the Mac's idea of activity: the controls come back when
        // the mouse moves and retreat again when it settles, exactly as they
        // do over an AVPlayer view.
        .onContinuousHover { phase in
            switch phase {
            case .active: revealChrome()
            case .ended: break
            }
        }
        #else
        .onPlayPauseCommand { model.togglePlayPause() }
        .onExitCommand { close() }
        .onMoveCommand { direction in
            switch direction {
            case .left: skip(by: -NuvioPlayerModel.skipInterval)
            case .right: skip(by: NuvioPlayerModel.skipInterval)
            default: break
            }
            revealChrome()
        }
        #endif
        .onAppear {
            scheduleHide()
            #if os(iOS)
            // A stream is a landscape thing: the screen turns on the way in,
            // whichever way the phone is being held, and is handed back on
            // the way out. A Mac window has no orientation to lock.
            PlayerOrientation.lockLandscape()
            #endif
        }
        .onDisappear {
            hideTask?.cancel()
            skipReset?.cancel()
            model.stop()
            #if os(iOS)
            PlayerOrientation.release()
            #endif
        }
        .onChange(of: model.phase) { _, phase in
            // The chrome should be up whenever there is a decision to make.
            switch phase {
            case .paused, .ended, .failed: revealChrome(autoHide: false)
            case .playing: scheduleHide()
            case .opening: break
            }
            if phase == .ended { close() }
        }
    }

    // MARK: States

    private var openingIndicator: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(model.phase == .opening ? "Opening stream…" : "Buffering…")
                .font(PlayerChrome.captionFont)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, PlayerChrome.badgePadding)
        .padding(.vertical, PlayerChrome.badgePadding - 4)
        .glassEffect(PlayerChrome.reading, in: .rect(cornerRadius: 22))
        .glassEffectTransition(.materialize)
    }

    private var skipBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: skipTotal > 0 ? "goforward" : "gobackward")
            Text("\(skipTotal > 0 ? "+" : "−")\(Int(abs(skipTotal)))s")
        }
        .font(.title3.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(PlayerChrome.overMedia, in: .capsule)
        .glassEffectTransition(.materialize)
        .foregroundStyle(.white)
        .transition(.opacity)
    }

    private var boostBadge: some View {
        VStack {
            HStack(spacing: 6) {
                Text("2×").fontWeight(.bold)
                Image(systemName: "forward.fill")
            }
            .font(PlayerChrome.captionFont)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(PlayerChrome.overMedia, in: .capsule)
            .glassEffectTransition(.materialize)
            .foregroundStyle(.white)
            .padding(.top, PlayerChrome.topInset + 4)
            Spacer()
        }
        .transition(.opacity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.55))

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 420)

            HStack(spacing: 14) {
                Button("Try again") { model.retry() }
                    .buttonStyle(.glassProminent)
                Button("Back to sources") { close() }
                    .buttonStyle(.glass)
            }
            .font(.headline)
        }
        .padding(34)
        .glassEffect(PlayerChrome.reading, in: .rect(cornerRadius: 28))
    }

    private func noticeBanner(_ text: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                Text(text)
                    .font(PlayerChrome.captionFont.weight(.medium))
                Button("Start over") { model.startOver() }
                    .font(PlayerChrome.captionFont.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(PlayerChrome.overMedia, in: .capsule)
            .foregroundStyle(.white)
            .padding(.bottom, chromeVisible ? PlayerChrome.noticeLiftedInset : 40)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Chrome

    /// Laid out the way the system player is: the picture dims under a flat
    /// scrim, titles and the utility glyphs ride along the top, the transport
    /// sits dead centre, and the time bar runs across the bottom.
    private var chrome: some View {
        ZStack {
            // Clear glass carries no opacity of its own, so the legibility has
            // to come from the content behind it — which is exactly the trade
            // Apple's own media controls make. The flat dim is lighter than it
            // was, because the glass now does the separating and a heavy scrim
            // on top of it just makes the picture muddy; the gradients stay,
            // banked where the controls actually sit.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }

            #if os(iOS) || os(macOS)
            transportRow
            #endif
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: PlayerChrome.glyphSpacing) {
            #if os(macOS)
            RoundIcon("xmark", label: "Close") { close() }
            #elseif os(iOS)
            RoundIcon("chevron.down", label: "Close") { close() }
            #endif

            VStack(alignment: .leading, spacing: 1) {
                Text(request.title)
                    .font(PlayerChrome.titleFont)
                    .lineLimit(1)
                if let subtitle = model.currentChapterName ?? request.subtitle {
                    Text(subtitle)
                        .font(PlayerChrome.subtitleFont)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)

            Spacer(minLength: 12)

            // One container, so the utility glyphs read as a single grouped
            // control the way a 26 toolbar does — the glass flows between
            // neighbours instead of each button being its own frosted disc.
            GlassEffectContainer(spacing: PlayerChrome.glassMergeDistance) {
                HStack(spacing: PlayerChrome.glyphSpacing) {
                    #if os(iOS) || os(macOS)
                    volumeControl
                    #endif
                    chapterMenu
                    audioMenu
                    subtitleMenu
                    speedMenu
                    fitMenu
                }
            }

            #if os(tvOS)
            // Deliberately outside the group: close is the one control that is
            // not a playback setting, and Apple separates it for that reason.
            RoundIcon("xmark", label: "Close") { close() }
            #endif
        }
        .padding(.horizontal, PlayerChrome.edgeInset)
        .padding(.top, PlayerChrome.topInset)
    }

    /// The three transport glyphs. Centred over the picture on iOS, the way
    /// AVPlayer places them; folded into the bottom panel on tvOS, where the
    /// remote does the seeking and the panel is the only focusable region.
    private var transportRow: some View {
        GlassEffectContainer(spacing: PlayerChrome.glassMergeDistance) {
            transportGlyphs
        }
    }

    private var transportGlyphs: some View {
        HStack(spacing: PlayerChrome.transportSpacing) {
            if model.hasChapters {
                RoundIcon("backward.end.fill", label: "Previous chapter", size: .transport) {
                    model.skipChapter(forward: false)
                    scheduleHide()
                }
            }

            RoundIcon("gobackward.10", label: "Back 10 seconds", size: .transport) {
                skip(by: -NuvioPlayerModel.skipInterval)
            }

            Button {
                model.togglePlayPause()
                scheduleHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: PlayerChrome.playGlyphSize, weight: .medium))
                    .frame(width: PlayerChrome.playFrame, height: PlayerChrome.playFrame)
                    .contentShape(Rectangle())
                    // The glyph swaps in place rather than the button redrawing,
                    // which is what keeps the glass from re-forming on every
                    // play/pause.
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            RoundIcon("goforward.10", label: "Forward 10 seconds", size: .transport) {
                skip(by: NuvioPlayerModel.skipInterval)
            }

            if model.hasChapters {
                RoundIcon("forward.end.fill", label: "Next chapter", size: .transport) {
                    model.skipChapter(forward: true)
                    scheduleHide()
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: PlayerChrome.bottomStackSpacing) {
            #if os(tvOS)
            transportRow
            #endif
            scrubber
        }
        .padding(.horizontal, PlayerChrome.edgeInset)
        .padding(.bottom, PlayerChrome.bottomInset)
    }

    /// The system player's time bar: a plain capsule with the elapsed and
    /// remaining times tucked underneath it, thickening while it is dragged.
    @ViewBuilder
    private var scrubber: some View {
        let position = scrubTarget ?? model.currentTime

        VStack(spacing: 6) {
            if let duration = model.duration, duration > 0, model.isSeekable {
                TimeBar(
                    position: min(position, duration),
                    duration: duration,
                    isScrubbing: scrubTarget != nil || model.isScrubbing,
                    chapterOffsets: model.chapters.map(\.startSeconds),
                    onScrub: { target in
                        model.isScrubbing = true
                        scrubTarget = target
                        revealChrome(autoHide: false)
                    },
                    onCommit: { target in
                        model.seek(toSeconds: target)
                        scrubTarget = nil
                        model.isScrubbing = false
                        scheduleHide()
                    }
                )

                HStack {
                    Text(NuvioPlayerModel.timecode(position))
                    Spacer(minLength: 0)
                    if model.rate != 1 {
                        Text("\(String(format: "%g", model.rate))×")
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                    }
                    Text("-" + NuvioPlayerModel.timecode(max(0, duration - position)))
                }
                .font(PlayerChrome.timecodeFont)
                .foregroundStyle(.white.opacity(0.75))
            } else {
                // A live stream has no length to scrub through.
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: PlayerChrome.barHeight)
                    .frame(maxWidth: .infinity)

                HStack {
                    Text(NuvioPlayerModel.timecode(position))
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                        Text("LIVE").fontWeight(.bold)
                    }
                }
                .font(PlayerChrome.timecodeFont)
                .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: Menus

    #if os(iOS) || os(macOS)
    /// AVKit's volume control: a speaker that mutes on click, with the slider
    /// sliding out beside it. Collapsed by default so the top row stays as
    /// spare as the system player's.
    @ViewBuilder
    private var volumeControl: some View {
        HStack(spacing: 10) {
            Button {
                if volumeExpanded {
                    model.toggleMute()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { volumeExpanded = true }
                }
                scheduleHide()
            } label: {
                RoundIconLabel(volumeSymbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isMuted ? "Unmute" : "Volume")

            if volumeExpanded {
                LevelBar(value: model.isMuted ? 0 : model.volume) { value in
                    model.setVolume(value)
                    revealChrome()
                }
                .frame(width: PlayerChrome.volumeBarWidth)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
    }

    private var volumeSymbol: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
    #endif

    @ViewBuilder
    private var chapterMenu: some View {
        if model.hasChapters {
            Menu {
                ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        model.select(chapter: chapter)
                        scheduleHide()
                    } label: {
                        Label(
                            "\(index + 1). \(chapter.name ?? "Chapter \(index + 1)")",
                            systemImage: model.chapterIndex == index ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                RoundIconLabel("list.bullet")
            }
            .accessibilityLabel("Chapters")
        }
    }

    @ViewBuilder
    private var audioMenu: some View {
        if model.audioTracks.count > 1 || model.audioDelay != 0 {
            Menu {
                ForEach(model.audioTracks, id: \.trackId) { track in
                    Button {
                        model.select(track)
                        scheduleHide()
                    } label: {
                        Label(track.trackName, systemImage: track.isSelected ? "checkmark" : "")
                    }
                }
                // Only the fallback engine carries an alignment dial; the
                // player engine hands its audio to AVPlayer, which has no such
                // offset to give. Offering a slider that moves nothing is worse
                // than not offering one.
                if model.supportsTrackAlignment {
                    Divider()
                    delayControls(
                        title: "Audio delay",
                        value: model.audioDelay,
                        apply: { model.setAudioDelay($0) }
                    )
                }
            } label: {
                RoundIconLabel("waveform")
            }
            .accessibilityLabel("Audio track")
        }
    }

    @ViewBuilder
    private var subtitleMenu: some View {
        if !model.textTracks.isEmpty {
            Menu {
                Button {
                    model.disableSubtitles()
                    scheduleHide()
                } label: {
                    Label("Off", systemImage: model.textTracks.contains { $0.isSelected } ? "" : "checkmark")
                }
                ForEach(model.textTracks, id: \.trackId) { track in
                    Button {
                        model.select(track)
                        scheduleHide()
                    } label: {
                        Label(track.trackName, systemImage: track.isSelected ? "checkmark" : "")
                    }
                }
                if model.supportsTrackAlignment {
                    Divider()
                    delayControls(
                        title: "Subtitle delay",
                        value: model.subtitleDelay,
                        apply: { model.setSubtitleDelay($0) }
                    )
                }
                // Text size works on both: one engine scales its own renderer,
                // the other is scaling `SubtitleOverlay`.
                Menu("Text size") {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { scale in
                        Button {
                            model.setSubtitleScale(scale)
                            scheduleHide()
                        } label: {
                            Label(
                                scale == 1 ? "Normal" : "\(String(format: "%g", scale))×",
                                systemImage: model.subtitleScale == scale ? "checkmark" : ""
                            )
                        }
                    }
                }
            } label: {
                RoundIconLabel("captions.bubble")
            }
            .accessibilityLabel("Subtitles")
        }
    }

    /// A menu can't hold a slider, so alignment is nudged in steps — the same
    /// shape as the delay controls in VLC's own players.
    @ViewBuilder
    private func delayControls(
        title: String,
        value: Double,
        apply: @escaping (Double) -> Void
    ) -> some View {
        Menu("\(title) (\(String(format: "%+.1fs", value)))") {
            Button("Earlier (−0.5s)") { apply(value - 0.5); scheduleHide() }
            Button("Later (+0.5s)") { apply(value + 0.5); scheduleHide() }
            Button("Reset") { apply(0); scheduleHide() }
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(NuvioPlayerModel.rates, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                    scheduleHide()
                } label: {
                    Label(
                        rate == 1 ? "Normal" : "\(String(format: "%g", rate))×",
                        systemImage: model.rate == rate ? "checkmark" : ""
                    )
                }
            }
        } label: {
            RoundIconLabel("speedometer")
        }
        .accessibilityLabel("Playback speed")
    }

    private var fitMenu: some View {
        Menu {
            ForEach(VideoFit.allCases) { option in
                Button {
                    model.setFit(option)
                    scheduleHide()
                } label: {
                    Label(option.rawValue, systemImage: model.fit == option ? "checkmark" : "")
                }
            }
        } label: {
            RoundIconLabel(model.fit.symbol)
        } primaryAction: {
            // A click toggles fit and fill as AVPlayer's zoom glyph does;
            // holding it opens the full list.
            model.toggleFill()
            scheduleHide()
        }
        .accessibilityLabel("Zoom")
    }

    // MARK: Keyboard

    #if os(iOS) || os(macOS)
    /// The shortcuts AVPlayer and QuickTime answer to. They hang off buttons
    /// rather than `onKeyPress` because a button's shortcut is live wherever
    /// the focus happens to be, which over a video surface is nowhere.
    private var keyboardShortcuts: some View {
        ZStack {
            shortcut(.space, modifiers: []) { model.togglePlayPause(); revealChrome() }
            shortcut(KeyEquivalent("k"), modifiers: []) { model.togglePlayPause(); revealChrome() }
            shortcut(.leftArrow, modifiers: []) { skip(by: -NuvioPlayerModel.skipInterval) }
            shortcut(.rightArrow, modifiers: []) { skip(by: NuvioPlayerModel.skipInterval) }
            shortcut(.leftArrow, modifiers: .shift) { skip(by: -60) }
            shortcut(.rightArrow, modifiers: .shift) { skip(by: 60) }
            shortcut(KeyEquivalent("j"), modifiers: []) { skip(by: -NuvioPlayerModel.skipInterval) }
            shortcut(KeyEquivalent("l"), modifiers: []) { skip(by: NuvioPlayerModel.skipInterval) }
            shortcut(.upArrow, modifiers: []) { model.nudgeVolume(0.05); revealChrome() }
            shortcut(.downArrow, modifiers: []) { model.nudgeVolume(-0.05); revealChrome() }
            shortcut(KeyEquivalent("m"), modifiers: []) { model.toggleMute(); revealChrome() }
            shortcut(KeyEquivalent("f"), modifiers: []) { model.toggleFill(); revealChrome() }
            shortcut(KeyEquivalent(","), modifiers: []) { model.stepFrame(forward: false); revealChrome(autoHide: false) }
            shortcut(KeyEquivalent("."), modifiers: []) { model.stepFrame(forward: true); revealChrome(autoHide: false) }
            shortcut(KeyEquivalent("["), modifiers: []) { model.skipChapter(forward: false); revealChrome() }
            shortcut(KeyEquivalent("]"), modifiers: []) { model.skipChapter(forward: true); revealChrome() }
            shortcut(.escape, modifiers: []) { close() }
        }
        // Present in the hierarchy — a hidden view answers no shortcut — but
        // invisible and out of the way of every gesture above.
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
    }
    #endif

    // MARK: Behaviour

    #if os(iOS) || os(macOS)
    /// Dragging anywhere across the picture scrubs, which is quicker than
    /// hunting for a thumb on a phone.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard let duration = model.duration, duration > 0, model.isSeekable else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // A hold that turns into a drag is a scrub, not a skim.
                model.endSpeedBoost()
                revealChrome(autoHide: false)
                model.isScrubbing = true
                // The window's width, not the display's: on a Mac the player
                // is rarely the size of the screen, and scrubbing against the
                // wrong span makes every drag overshoot.
                let span = size.width > 0 ? size.width : PlatformScreen.width
                let delta = Double(value.translation.width / span) * min(duration, 600)
                scrubTarget = max(0, min(duration, model.currentTime + delta))
            }
            .onEnded { _ in
                if let target = scrubTarget { model.seek(toSeconds: target) }
                scrubTarget = nil
                model.isScrubbing = false
                scheduleHide()
            }
    }

    /// Press and hold anywhere to run at 2×, as in the TV app; letting go
    /// drops back to the speed that was set before.
    private var boostGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.55)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, _) = value, !model.isScrubbing {
                    model.beginSpeedBoost()
                }
            }
            .onEnded { _ in model.endSpeedBoost() }
    }
    #endif

    /// Skips, and shows the running total the way AVKit does: tap three times
    /// quickly and the badge reads "+30s" rather than flashing "+10s" thrice.
    private func skip(by seconds: Double) {
        model.jump(seconds)
        skipReset?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            // A change of direction starts the count again.
            skipTotal = (skipTotal * seconds > 0) ? skipTotal + seconds : seconds
        }
        skipReset = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { skipTotal = 0 }
        }
        revealChrome()
    }

    private func close() {
        model.stop()
        if let coverDismiss {
            coverDismiss()
        } else {
            dismiss()
        }
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        if chromeVisible {
            scheduleHide()
        } else {
            // Put away by hand. The pending timer would only re-hide something
            // already hidden, but leaving it running means the next reveal
            // inherits whatever was left of its four seconds.
            hideTask?.cancel()
            volumeExpanded = false
        }
    }

    private func revealChrome(autoHide: Bool = true) {
        if !chromeVisible {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true }
        }
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    /// The chrome retreats on its own, but never while paused or stalled —
    /// there is nothing to watch behind it.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                chromeVisible = false
                volumeExpanded = false
            }
        }
    }
}

// MARK: - Pieces

/// The metrics the chrome is drawn to, kept in one place because the phone and
/// the television want the same design at very different sizes.
private enum PlayerChrome {
    #if os(tvOS)
    static let edgeInset: CGFloat = 80
    static let topInset: CGFloat = 50
    static let bottomInset: CGFloat = 60
    static let glyphSpacing: CGFloat = 22
    static let transportSpacing: CGFloat = 54
    static let bottomStackSpacing: CGFloat = 34
    static let glyphSize: CGFloat = 26
    static let glyphPadding: CGFloat = 16
    static let playGlyphSize: CGFloat = 46
    static let playFrame: CGFloat = 74
    static let barHeight: CGFloat = 8
    static let scrubbingBarHeight: CGFloat = 12
    static let knobSize: CGFloat = 20
    static let volumeBarWidth: CGFloat = 160
    static let badgePadding: CGFloat = 34
    static let noticeLiftedInset: CGFloat = 260
    static let titleFont: Font = .title3.weight(.semibold)
    static let subtitleFont: Font = .callout
    static let timecodeFont: Font = .callout.monospacedDigit()
    static let captionFont: Font = .callout
    #elseif os(macOS)
    // Between the phone's and the television's: a Mac is viewed from about a
    // metre, with a pointer rather than a thumb or a remote.
    static let edgeInset: CGFloat = 34
    static let topInset: CGFloat = 24
    static let bottomInset: CGFloat = 30
    static let glyphSpacing: CGFloat = 18
    static let transportSpacing: CGFloat = 50
    static let bottomStackSpacing: CGFloat = 24
    static let glyphSize: CGFloat = 19
    static let glyphPadding: CGFloat = 12
    static let playGlyphSize: CGFloat = 46
    static let playFrame: CGFloat = 72
    static let barHeight: CGFloat = 8
    static let scrubbingBarHeight: CGFloat = 14
    static let knobSize: CGFloat = 18
    static let volumeBarWidth: CGFloat = 120
    static let badgePadding: CGFloat = 30
    static let noticeLiftedInset: CGFloat = 180
    static let titleFont: Font = .headline
    static let subtitleFont: Font = .subheadline
    static let timecodeFont: Font = .callout.monospacedDigit()
    static let captionFont: Font = .callout
    #else
    static let edgeInset: CGFloat = 20
    static let topInset: CGFloat = 14
    static let bottomInset: CGFloat = 22
    static let glyphSpacing: CGFloat = 14
    static let transportSpacing: CGFloat = 44
    static let bottomStackSpacing: CGFloat = 20
    static let glyphSize: CGFloat = 15
    static let glyphPadding: CGFloat = 9
    static let playGlyphSize: CGFloat = 40
    static let playFrame: CGFloat = 62
    static let barHeight: CGFloat = 7
    static let scrubbingBarHeight: CGFloat = 12
    static let knobSize: CGFloat = 16
    static let volumeBarWidth: CGFloat = 110
    static let badgePadding: CGFloat = 26
    static let noticeLiftedInset: CGFloat = 150
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let subtitleFont: Font = .caption
    static let timecodeFont: Font = .caption.monospacedDigit()
    static let captionFont: Font = .footnote
    #endif

    /// How close two pieces of glass have to be before they flow together.
    /// Roughly the gap between the transport glyphs, so the cluster reads as
    /// one object and separates as it animates apart.
    static let glassMergeDistance: CGFloat = glyphPadding * 2

    /// Glass for something floating over the picture.
    ///
    /// `.clear` rather than `.regular`: over media, Apple's rule is that the
    /// glass lets the content through and the *content* is dimmed to carry the
    /// legibility, which is what the scrim under the chrome is for. Regular
    /// glass over a film reads as a frosted slab sitting on top of it.
    static let overMedia: Glass = .clear

    /// Glass for something carrying text to read — the failure card, the
    /// opening panel. These are app surfaces that happen to be over video, and
    /// they take the full material so the words hold at any brightness.
    static let reading: Glass = .regular
}

/// The time bar. Not a `Slider`: AVPlayer's bar fills solid white behind the
/// playhead, swells under the finger, grows a knob while it is being dragged
/// and carries a tick at every chapter boundary — and tvOS has no `Slider` at
/// all, so the bar is drawn by hand for both.
private struct TimeBar: View {
    let position: Double
    let duration: Double
    let isScrubbing: Bool
    var chapterOffsets: [Double] = []
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    private var height: CGFloat {
        isScrubbing ? PlayerChrome.scrubbingBarHeight : PlayerChrome.barHeight
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(width: max(height, width * fraction))

                // Chapter boundaries, as notches in the track — the same cue
                // the system player gives a chaptered movie.
                ForEach(Array(chapterOffsets.enumerated()), id: \.offset) { _, offset in
                    let mark = duration > 0 ? min(max(offset / duration, 0), 1) : 0
                    if mark > 0.001, mark < 0.999 {
                        Rectangle()
                            .fill(.black.opacity(0.55))
                            .frame(width: 2, height: height)
                            .offset(x: width * mark - 1)
                    }
                }
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .clipShape(.capsule)
            .overlay(alignment: .leading) {
                if isScrubbing {
                    // The knob is glass rather than a white dot: under a thumb
                    // it picks up the frame behind it, so the viewer can still
                    // see what they are scrubbing past.
                    Circle()
                        .fill(.white)
                        .frame(width: PlayerChrome.knobSize, height: PlayerChrome.knobSize)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .offset(x: width * fraction - PlayerChrome.knobSize / 2)
                }
            }
            #if os(iOS) || os(macOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(target(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        onCommit(target(at: value.location.x, width: width))
                    }
            )
            #endif
        }
        .frame(height: PlayerChrome.scrubbingBarHeight + 16)
        .animation(.easeOut(duration: 0.18), value: isScrubbing)
    }

    private func target(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }
}

#if os(iOS) || os(macOS)
/// A small 0…1 bar in the time bar's idiom, for volume.
private struct LevelBar: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white)
                    .frame(width: max(4, width * min(max(value, 0), 1)))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        onChange(min(max(Double(drag.location.x / width), 0), 1))
                    }
            )
        }
        .frame(height: 26)
        .accessibilityLabel("Volume")
    }
}
#endif

/// The circular glyph button the chrome is built from.
///
/// Every one of these is a piece of Liquid Glass. Inside a
/// `GlassEffectContainer` the neighbouring ones flow together into a single
/// pill and part again as they move, which is the whole point of the material
/// and the reason the chrome is grouped rather than laid out as loose buttons.
private struct RoundIcon: View {
    enum Size { case utility, transport }

    let systemName: String
    let label: String
    let size: Size
    let action: () -> Void

    init(_ systemName: String, label: String, size: Size = .utility, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            RoundIconLabel(systemName, size: size, carriesGlass: false)
        }
        // `.glass` rather than `.plain`: it carries the press flex, and on tvOS
        // it is also the focus treatment, so a focused control lifts and
        // brightens the way every other 26 control does instead of relying on
        // a highlight this file would have to draw itself.
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }
}

/// The glyph inside a `RoundIcon`, and the label a `Menu` hangs off.
///
/// A `Menu`'s label is not a `Button`, so it cannot take a button style; it
/// wears its glass directly here instead, which keeps the two visually
/// identical in the same row.
private struct RoundIconLabel: View {
    let systemName: String
    let size: RoundIcon.Size
    /// True when this is a `Menu`'s own label and has to bring its own glass.
    /// A `RoundIcon` leaves it off and lets `.buttonStyle(.glass)` do it, so
    /// the material is never applied twice to one control.
    let carriesGlass: Bool

    init(_ systemName: String, size: RoundIcon.Size = .utility, carriesGlass: Bool = true) {
        self.systemName = systemName
        self.size = size
        self.carriesGlass = carriesGlass
    }

    var body: some View {
        switch size {
        case .utility:
            Image(systemName: systemName)
                .font(.system(size: PlayerChrome.glyphSize, weight: .semibold))
                .frame(width: PlayerChrome.glyphSize + 4, height: PlayerChrome.glyphSize + 4)
                .padding(PlayerChrome.glyphPadding)
                .foregroundStyle(.white)
                // `.identity` is the no-op glass, which is how a control opts
                // out without this view having to branch its whole body.
                .glassEffect(
                    carriesGlass ? PlayerChrome.overMedia.interactive() : .identity,
                    in: .circle
                )
        case .transport:
            // The transport glyphs carry no glass of their own: they sit inside
            // the transport's container, where the play button is the shape the
            // group flows out of. Glass on each would read as three separate
            // chips rather than one control.
            Image(systemName: systemName)
                .font(.system(size: PlayerChrome.playGlyphSize * 0.62, weight: .medium))
                .frame(width: PlayerChrome.playFrame * 0.8, height: PlayerChrome.playFrame * 0.8)
                .contentShape(Rectangle())
                .foregroundStyle(.white)
        }
    }
}
