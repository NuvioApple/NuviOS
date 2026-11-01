import Foundation

/// Debug-only counters for the player, printed as `[metrics]` lines.
///
/// They exist to answer "did that change make the player faster?" with a number
/// rather than a feeling: how long a stream takes to put a picture up, how many
/// times the player screen re-renders per second of playback, what the engine's
/// 10 Hz update costs the main thread, and how long a seek or a rebuffer holds
/// the picture. Release builds compile every call to nothing.
@MainActor
enum PlayerMetrics {
    #if DEBUG
    private static var counts: [String: Int] = [:]
    private static var spent: [String: Double] = [:]
    private static var windowStart = ContinuousClock.now
    private static var openedAt: ContinuousClock.Instant?
    private static var seekStartedAt: ContinuousClock.Instant?
    private static var stallStartedAt: ContinuousClock.Instant?
    private static let reportEvery: Double = 10

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// A new source is about to be handed to an engine.
    static func markOpen() {
        openedAt = .now
        counts = [:]
        spent = [:]
        windowStart = .now
    }

    /// The first picture reached the screen.
    static func markFirstFrame() {
        guard let openedAt else { return }
        self.openedAt = nil
        print("[metrics] time-to-first-frame \(Int(milliseconds(since: openedAt))) ms")
    }

    static func markSeekStarted() { seekStartedAt = .now }

    /// The engine's seek call returned.
    static func markSeekFinished() {
        guard let seekStartedAt else { return }
        self.seekStartedAt = nil
        print("[metrics] seek \(Int(milliseconds(since: seekStartedAt))) ms")
    }

    static func markStall(_ stalled: Bool) {
        if stalled {
            if stallStartedAt == nil { stallStartedAt = .now }
        } else if let started = stallStartedAt {
            stallStartedAt = nil
            print("[metrics] rebuffer \(Int(milliseconds(since: started))) ms")
        }
    }

    /// Counts an event and, every ten seconds of playback, reports the rates.
    static func count(_ name: String) {
        counts[name, default: 0] += 1
        flushIfDue()
    }

    /// Times a block of main-thread work under `name`.
    static func measure<T>(_ name: String, _ work: () -> T) -> T {
        let start = ContinuousClock.now
        let result = work()
        spent[name, default: 0] += milliseconds(since: start)
        counts[name, default: 0] += 1
        flushIfDue()
        return result
    }

    private static func flushIfDue() {
        let elapsed = milliseconds(since: windowStart) / 1000
        guard elapsed >= reportEvery else { return }
        let line = counts.keys.sorted().map { key -> String in
            let perSecond = Double(counts[key] ?? 0) / elapsed
            var text = "\(key)=\(String(format: "%.1f", perSecond))/s"
            if let total = spent[key], let n = counts[key], n > 0 {
                text += " (\(String(format: "%.3f", total / Double(n))) ms each, \(String(format: "%.1f", total / elapsed)) ms/s)"
            }
            return text
        }.joined(separator: "  ")
        print("[metrics] \(String(format: "%.0f", elapsed))s window: \(line)")
        counts = [:]
        spent = [:]
        windowStart = .now
    }
    #else
    static func markOpen() {}
    static func markFirstFrame() {}
    static func markSeekStarted() {}
    static func markSeekFinished() {}
    static func markStall(_ stalled: Bool) {}
    static func count(_ name: String) {}
    @inline(__always)
    static func measure<T>(_ name: String, _ work: () -> T) -> T { work() }
    #endif
}
