import Foundation

/// Picks the audio and subtitle tracks the viewer most likely wants, from the
/// languages the system is already set to.
///
/// Addon releases are routinely multi-audio and multi-subtitle, and an engine's
/// own default is the first track in the file or the container's `default`
/// disposition — which for a foreign release is the foreign dub. The rule here
/// is the one every streaming app follows: play the audio in a language the
/// viewer reads, and if that isn't possible, subtitle it in one. It runs on
/// both engines, so the answer does not change with which one opened the file.
enum TrackPreference {
    /// The languages the viewer has told the system they want, best first.
    /// `preferredLanguages` is the ordered list from Settings, not just the
    /// single display language, so a bilingual viewer's second choice counts.
    static var preferredLanguages: [String] {
        var seen = Set<String>()
        return Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    /// What a track selection decided, so the player can say why subtitles
    /// came on by themselves.
    struct Selection {
        var audio: MediaTrack?
        var subtitle: MediaTrack?
        /// True when subtitles were turned on because no audio track matched
        /// a language the viewer asked for.
        var subtitlesForcedByLanguage = false
    }

    /// - Parameters:
    ///   - audioTracks: every audio track the file declares.
    ///   - textTracks: every subtitle track the file declares.
    static func choose(
        audioTracks: [MediaTrack],
        textTracks: [MediaTrack],
        languages: [String] = preferredLanguages
    ) -> Selection {
        var selection = Selection()

        // Audio first: a matching dub beats any subtitle arrangement.
        selection.audio = firstMatch(in: audioTracks, languages: languages)

        let audioMatches = selection.audio != nil
        // Nothing matched, so fall back to what libvlc would have played
        // anyway rather than leaving the file silent.
        if !audioMatches { selection.audio = audioTracks.first }

        if audioMatches {
            // The dialogue is already understood. Subtitles stay off unless
            // the track is explicitly forced — those carry signage and
            // foreign lines the dub leaves untranslated.
            selection.subtitle = textTracks.first { isForced($0) && matches($0, languages: languages) }
        } else if let subtitle = firstMatch(in: textTracks, languages: languages) {
            selection.subtitle = subtitle
            selection.subtitlesForcedByLanguage = true
        }

        return selection
    }

    /// The best track for the viewer's languages, in the viewer's own order of
    /// preference — the first language is tried against every track before the
    /// second is considered.
    private static func firstMatch(
        in tracks: [MediaTrack],
        languages: [String]
    ) -> MediaTrack? {
        for language in languages {
            // Among equals, a track that isn't a commentary or a
            // hearing-impaired mix is the one someone means to play.
            let candidates = tracks.filter { matches($0, languages: [language]) }
            if let plain = candidates.first(where: { !isSecondary($0) }) { return plain }
            if let any = candidates.first { return any }
        }
        return nil
    }

    /// Both engines report a track's language as an ISO code when the
    /// container carries one, but plenty of releases leave it empty and put
    /// "English" in the track name instead, so both are checked.
    private static func matches(_ track: MediaTrack, languages: [String]) -> Bool {
        let code = track.language?.lowercased().trimmed ?? ""
        let name = track.trackName.lowercased()

        for language in languages {
            if !code.isEmpty, normalized(code) == language { return true }
            // `Locale` knows what each code is called in that language and in
            // the viewer's, which covers "English", "Anglais", "Español".
            for spelling in spellings(of: language) where name.contains(spelling) {
                return true
            }
        }
        return false
    }

    /// Containers use ISO 639-1 and 639-2 interchangeably ("en", "eng").
    private static func normalized(_ code: String) -> String {
        Locale(identifier: code).language.languageCode?.identifier.lowercased() ?? code
    }

    /// How a language's name is likely to be written in a track label.
    private static func spellings(of language: String) -> [String] {
        var names = Set<String>()
        let locale = Locale(identifier: language)
        if let own = locale.localizedString(forLanguageCode: language) {
            names.insert(own.lowercased())
        }
        if let inUsersLanguage = Locale.current.localizedString(forLanguageCode: language) {
            names.insert(inUsersLanguage.lowercased())
        }
        return Array(names)
    }

    /// Commentary tracks, descriptive audio and SDH subtitles are all real
    /// tracks in the viewer's language, and none of them is what "play this
    /// in English" means.
    private static func isSecondary(_ track: MediaTrack) -> Bool { track.isSecondary }

    /// Forced subtitles translate only the parts the audio leaves in another
    /// language, so they belong on top of an understood dub.
    private static func isForced(_ track: MediaTrack) -> Bool { track.isForced }
}
