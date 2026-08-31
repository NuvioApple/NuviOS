import Foundation

/// Where each title was left off, so reopening one resumes rather than
/// restarts. Local only — the backend's own watch history is a separate
/// concern, and a position is worth keeping even for a guest.
enum PlaybackProgress {
    private static let key = "nuvio.playback.progress"

    /// Anything past this is treated as watched, and its position dropped —
    /// resuming four seconds before the credits helps nobody.
    private static let completionThreshold = 0.95

    /// Below this there is nothing worth resuming from.
    private static let minimumResume: Double = 30

    struct Entry: Codable, Equatable {
        var seconds: Double
        var duration: Double
        var updated: Date
    }

    static func position(for key: String) -> Double? {
        guard let entry = all()[key], entry.duration > 0 else { return nil }
        guard entry.seconds >= minimumResume,
              entry.seconds / entry.duration < completionThreshold
        else { return nil }
        return entry.seconds
    }

    static func record(key: String, seconds: Double, duration: Double) {
        guard duration > 0, seconds.isFinite else { return }

        var entries = all()
        if seconds / duration >= completionThreshold || seconds < minimumResume {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = Entry(seconds: seconds, duration: duration, updated: Date())
        }
        save(entries)
    }

    /// Takes a position recorded elsewhere — another device, through the
    /// account — unless what is held here is newer.
    ///
    /// Kept apart from `record` because the rules differ: `record` is the
    /// player writing what it just watched, and may drop an entry that has run
    /// to the end. This is a reconciliation, and the later of the two writers
    /// wins.
    static func adopt(key: String, seconds: Double, duration: Double, updated: Date) {
        guard duration > 0, seconds.isFinite, seconds > 0 else { return }

        var entries = all()
        if let existing = entries[key], existing.updated >= updated { return }
        entries[key] = Entry(seconds: seconds, duration: duration, updated: updated)
        save(entries)
    }

    static func clear(key: String) {
        var entries = all()
        entries.removeValue(forKey: key)
        save(entries)
    }

    /// Everything started and not finished on this device, newest first.
    ///
    /// The Continue Watching shelf is built from the account's rows, but those
    /// only exist for a signed-in user whose progress lives on the backend —
    /// and never for a guest. What this device watched is known here regardless,
    /// so the shelf falls back on it rather than being empty.
    static func inProgress() -> [(key: String, entry: Entry)] {
        all()
            .filter { _, entry in
                guard entry.duration > 0 else { return false }
                let fraction = entry.seconds / entry.duration
                return fraction >= 0.02 && fraction < completionThreshold
            }
            .sorted { $0.value.updated > $1.value.updated }
            .map { ($0.key, $0.value) }
    }

    private static func all() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ entries: [String: Entry]) {
        // Positions are cheap but unbounded otherwise; the oldest are dropped
        // once the list gets long.
        var trimmed = entries
        if trimmed.count > 200 {
            let oldest = trimmed.sorted { $0.value.updated < $1.value.updated }
                .prefix(trimmed.count - 200)
                .map(\.key)
            for key in oldest { trimmed.removeValue(forKey: key) }
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
