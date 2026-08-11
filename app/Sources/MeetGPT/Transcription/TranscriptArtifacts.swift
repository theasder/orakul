import Foundation

/// Strips Whisper's non-speech annotations from transcription output. The
/// model emits tokens like "[BLANK_AUDIO]", "[MUSIC]", or "(speaking in
/// foreign language)" as literal text — noise in the live transcript, poison
/// for every downstream AI action, and the second one specifically means the
/// decoder gave up on the language rather than transcribing it. Applied by
/// both chunked engines (on-device WhisperKit and the Whisper API).
enum TranscriptArtifacts {
    /// Bracketed/parenthesized non-speech annotations, e.g. [BLANK_AUDIO],
    /// [ Silence ], (MUSIC PLAYING).
    private static let annotationPattern =
        #"[\[(]\s*(?:BLANK[_ ]?AUDIO|MUSIC(?:\s+PLAYING)?|NOISE|INAUDIBLE|SILENCE|APPLAUSE|LAUGHTER|CROSSTALK|TYPING|COUGHING)\s*[\])]"#

    /// The wrong-language fallback family: "(speaking in foreign language)",
    /// "(speaks Russian)", "(foreign language)".
    private static let foreignLanguagePattern =
        #"\(\s*(?:speaking[^)]{0,60}language|speaks\s[^)]{0,40}|foreign\s+language[^)]{0,40})\s*\)"#

    /// Stock subtitle/sign-off phrases Whisper memorized from training data and
    /// emits confidently over silence or clipped speech. Only whole-result
    /// matches are removed so a real sentence containing the same words remains.
    private static let standaloneHallucinationPatterns = [
        #"^\s*(?:thanks?|thank\s+you)(?:\s+so\s+much)?\s+for\s+(?:watching|listening)[.!]?\s*$"#,
        #"^\s*takk\s+for\s+at\s+du\s+så\s+med[.!]?\s*$"#,
        #"^\s*(?:undertekster|undertexter|subtitles?|captions?)\s+(?:av|af|by|:).{0,100}$"#,
        #"^\s*(?:sous-titres\s+(?:réalisés\s+)?par|subtítulos\s+(?:realizados\s+)?por).{0,100}$"#,
        #"^\s*(?:www\.)?amara\.org.{0,100}$"#,
        #"^\s*(?:to\s+be\s+continued|продолжение\s+следует)\s*[.!…]*\s*$"#,
        #"^\s*sigh\s*[.!…]*\s*$"#,
        #"^\s*спасибо\s+за\s+(?:просмотр|внимание|то,?\s+что\s+смотрели)\s*[.!…]*\s*$"#,
        #"^\s*субтитры\s+(?:выполнил[аи]?|подготовил[аи]?|:).{0,100}$"#
    ]

    /// Remove annotations that are safe to strip even when they occur inside a
    /// larger result. Stock sign-offs are handled only by `clean(_:)`, after
    /// all local segments have been joined.
    static func cleanInline(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: annotationPattern, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: foreignLanguagePattern, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clean(_ raw: String) -> String {
        let text = cleanInline(raw)
        for pattern in standaloneHallucinationPatterns where
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return ""
        }
        return text
    }

}
