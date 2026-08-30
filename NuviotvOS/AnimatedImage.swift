import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// SwiftUI's `Image` and `AsyncImage` show the first frame of a GIF and stop —
// which is why the covers looked static. ImageIO can walk the frames, so this
// decodes them once, at the size they'll actually be drawn, and steps through
// them itself.

/// A decoded animation: frames already downsampled, and how long each is held.
struct AnimatedFrames {
    let images: [CGImage]
    /// Per-frame, in seconds. Same count as `images`.
    let delays: [Double]

    var isAnimated: Bool { images.count > 1 }
}

/// Decodes and caches animations off the main actor. Keyed by URL and draw
/// size, so a folder tile and a full-width header don't share one bitmap.
actor AnimationStore {
    static let shared = AnimationStore()

    private var cache: [String: AnimatedFrames] = [:]
    /// A handful of tiles' worth. Frames are bitmaps, so this is the one place
    /// in the app where holding "just a few more" is genuinely expensive.
    private let limit = 12
    private var order: [String] = []
    private var inFlight: [String: Task<AnimatedFrames?, Never>] = [:]

    func frames(url: URL, maxPixelSize: CGFloat) async -> AnimatedFrames? {
        let key = "\(url.absoluteString)|\(Int(maxPixelSize))"
        if let cached = cache[key] { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<AnimatedFrames?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                return nil
            }
            if let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                return nil
            }
            return Self.decode(data, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let decoded = await task.value
        inFlight[key] = nil

        if let decoded {
            cache[key] = decoded
            order.append(key)
            while order.count > limit, let oldest = order.first {
                order.removeFirst()
                cache[oldest] = nil
            }
        }
        return decoded
    }

    /// Frames at draw size. Downsampling here is what keeps a 1000×1000 GIF
    /// from becoming dozens of full-size bitmaps behind a 140-point tile.
    private static func decode(_ data: Data, maxPixelSize: CGFloat) -> AnimatedFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]

        var images: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary
            ) else { continue }
            images.append(image)
            delays.append(delay(source, at: index))
        }

        guard !images.isEmpty else { return nil }
        return AnimatedFrames(images: images, delays: delays)
    }

    /// GIF and APNG each keep their timing in their own dictionary. Browsers
    /// floor anything under 0.02s at 0.1s, and so does this — a 0-delay frame
    /// would otherwise spin as fast as the loop can run.
    private static func delay(_ source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else { return 0.1 }

        let frame = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            ?? [:]

        let unclamped = frame[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? frame[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
        let clamped = frame[kCGImagePropertyGIFDelayTime] as? Double
            ?? frame[kCGImagePropertyAPNGDelayTime] as? Double
            ?? frame[kCGImagePropertyWebPDelayTime] as? Double

        let value = unclamped ?? clamped ?? 0.1
        return value < 0.02 ? 0.1 : value
    }
}

/// An animated image that plays only while `isPlaying` *and* the viewer can
/// actually see it — scrolled into view, in an active scene. Nothing is drawn
/// until the first frame is ready, so it can be laid over static artwork and
/// faded in the way the Android card does.
struct AnimatedImage: View {
    let url: URL
    /// The largest edge this will be drawn at, in points; frames are decoded
    /// to match rather than at their natural size.
    let maxPixelSize: CGFloat
    var isPlaying: Bool = true
    var contentMode: ContentMode = .fill
    /// Called when the first frame lands, for the fade-in.
    var onReady: (Bool) -> Void = { _ in }

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    @State private var frames: AnimatedFrames?
    @State private var index = 0
    /// Tracked by `onScrollVisibilityChange`. Defaults to true so an animation
    /// used outside a scroll view — where that callback never fires — still
    /// plays.
    @State private var isOnScreen = true

    /// Every reason to be running, together: the caller wants it, it's on
    /// screen, and the app is in front. A tile scrolled off the end of a shelf
    /// is decoded and cached but costs nothing to leave sitting there.
    private var isRunning: Bool {
        isPlaying && isOnScreen && scenePhase == .active
    }

    var body: some View {
        Group {
            if let frames, frames.images.indices.contains(index) {
                Image(decorative: frames.images[index], scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            index = 0
            frames = await AnimationStore.shared.frames(
                url: url,
                maxPixelSize: maxPixelSize * displayScale
            )
            onReady(frames != nil)
        }
        // Restarted whenever playback is turned on or the frames arrive, and
        // cancelled — so the timer stops — when the tile loses focus, scrolls
        // out of view, the app leaves the foreground, or the view goes away.
        .task(id: PlaybackKey(isRunning: isRunning, frameCount: frames?.images.count ?? 0)) {
            guard isRunning, let frames, frames.isAnimated else { return }
            while !Task.isCancelled {
                let hold = frames.delays[min(index, frames.delays.count - 1)]
                try? await Task.sleep(for: .seconds(hold))
                if Task.isCancelled { return }
                index = (index + 1) % frames.images.count
            }
        }
        // Visibility within whatever scroll view this sits in. A shelf holds
        // more tiles than fit on screen, and every one of them animating is
        // work nobody can see.
        .onScrollVisibilityChange(threshold: 0.15) { visible in
            isOnScreen = visible
        }
        .onChange(of: isRunning) { _, running in
            // Android restarts the overlay on each focus; so does this.
            if !running { index = 0 }
        }
    }

    private struct PlaybackKey: Equatable {
        let isRunning: Bool
        let frameCount: Int
    }
}
