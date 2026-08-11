import Foundation

/// Pulls likely domain vocabulary out of text the user already gave us.
///
/// Measured on two accented IETF work calls: supplying the right terms as
/// decoder prompt tokens moved term recall from 0.53 to 0.93 and from 0.57 to
/// 1.00, and removed the corruptions entirely — without a glossary "PCE" came
/// back as "piece" and "CATS" as "cast". That is the largest single accuracy
/// lever measured, and it only needs the terms.
///
/// Sources must be text the USER wrote or attached — a meeting title, an
/// agenda, a context document. Mining the transcript instead would be
/// circular: if the engine already misheard "PCE" as "piece", the transcript
/// teaches it "piece".
enum GlossaryMiner {

    /// A term must survive being wrong. Everything here is a *candidate* shown
    /// for approval, never applied silently, so the bar is "plausibly a domain
    /// term", not "certainly".
    static let maximumCandidates = 40

    /// Two characters is an initialism worth catching (AI, ML); one is a
    /// bullet or a stray letter.
    static let minimumAcronymLength = 2
    static let maximumAcronymLength = 8

    /// Words that LOOK like acronyms but carry no domain meaning, so proposing
    /// them wastes the user's attention and dilutes the prompt.
    static let ignoredAcronyms: Set<String> = [
        "OK", "TODO", "FYI", "ASAP", "AM", "PM", "USA", "UK", "EU", "US",
        "I", "A", "AND", "THE", "FOR", "NOT", "YES", "NO", "ALL", "NEW",
    ]

    /// Days and months. Capitalised, long enough to pass the proper-noun bar,
    /// and never worth biasing a decoder toward — every agenda contains them.
    static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "today", "tomorrow", "yesterday", "tonight",
    ]

    /// Common English words that happen to be capitalised at the start of a
    /// sentence — proposing them as vocabulary is noise.
    private static let sentenceStarters: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "they",
        "we", "our", "it", "is", "are", "was", "were", "a", "an", "and",
        "but", "or", "so", "if", "when", "what", "who", "how", "why",
        "let", "please", "thanks", "hi", "hello", "next", "first", "last",
        "some", "any", "all", "each", "every", "here", "now", "today",
    ]

    struct Candidate: Equatable {
        let term: String
        /// Why it was proposed, shown to the user so an odd suggestion is
        /// explainable rather than mysterious.
        let reason: String
    }

    /// Candidate terms from one piece of user-supplied text.
    ///
    /// Ordered by how strong the signal is — acronyms first, then hyphenated
    /// technical compounds, then capitalised proper nouns — because the list is
    /// truncated and the strongest evidence should survive.
    static func candidates(in text: String, existing: [String] = []) -> [Candidate] {
        let known = Set(existing.map { $0.lowercased() })
        var seen = Set<String>()
        var acronyms: [Candidate] = []
        var compounds: [Candidate] = []
        var proper: [Candidate] = []

        // A capitalised word that ONLY ever appears at the start of a sentence
        // is almost certainly an ordinary verb or adverb ("Covers the agenda").
        // The same word seen mid-sentence is evidence of a real name.
        var seenMidSentence = Set<String>()
        var sentenceInitial = true
        for raw in tokens(in: text) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'"))
            let endsSentence = raw.contains(where: { ".!?".contains($0) })
            let wasInitial = sentenceInitial
            sentenceInitial = endsSentence
            guard token.count >= minimumAcronymLength else { continue }
            if !wasInitial { seenMidSentence.insert(token.lowercased()) }
            let key = token.lowercased()
            guard !known.contains(key), seen.insert(key).inserted else { continue }
            // Applied to EVERY shape, not just the acronym rule: rejected as an
            // acronym, "FYI" would otherwise be re-caught as a proper noun and
            // proposed anyway.
            guard !ignoredAcronyms.contains(token.uppercased()) else { continue }

            // Hyphenated first: "MPLS-TE" is all-uppercase letters, so the
            // acronym rule would claim it and label it wrongly.
            if isHyphenatedTechnical(token) {
                compounds.append(Candidate(term: token, reason: "Technical term"))
            } else if isAcronym(token) {
                acronyms.append(Candidate(term: token, reason: "Acronym"))
            } else if isProperNoun(token),
                      // Interior caps/digits stand on their own ("IPv6");
                      // a plain capitalised word needs mid-sentence evidence.
                      hasInternalSignal(token) || seenMidSentence.contains(key) {
                proper.append(Candidate(term: token, reason: "Name or product"))
            }
        }

        return Array((acronyms + compounds + proper).prefix(maximumCandidates))
    }

    /// Candidates across several sources, strongest-first and deduped.
    static func candidates(inSources sources: [String], existing: [String] = []) -> [Candidate] {
        var seen = Set<String>()
        var merged: [Candidate] = []
        for source in sources {
            for candidate in candidates(in: source, existing: existing) {
                guard seen.insert(candidate.term.lowercased()).inserted else { continue }
                merged.append(candidate)
            }
        }
        return Array(merged.prefix(maximumCandidates))
    }

    // MARK: - Shapes

    /// `PCE`, `MPLS`, `IPv6`. All-caps, or caps with trailing digits.
    static func isAcronym(_ token: String) -> Bool {
        guard token.count <= maximumAcronymLength,
              !ignoredAcronyms.contains(token.uppercased()) else { return false }
        let letters = token.filter(\.isLetter)
        guard letters.count >= minimumAcronymLength else { return false }
        // Every letter uppercase. "IPv6" fails this deliberately and is caught
        // as a proper noun instead, which keeps the acronym rule unambiguous.
        return letters.allSatisfy(\.isUppercase)
    }

    /// `MPLS-TE`, `sub-TLV`, `Industry-4.0`. A hyphen joining a part that
    /// carries an uppercase letter or a digit.
    static func isHyphenatedTechnical(_ token: String) -> Bool {
        guard token.contains("-") else { return false }
        let parts = token.split(separator: "-")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.contains { part in
            part.contains(where: \.isUppercase) || part.contains(where: \.isNumber)
        }
    }

    /// An interior capital or digit — "IPv6", "OpenAPI". Strong enough on its
    /// own that no positional evidence is needed.
    static func hasInternalSignal(_ token: String) -> Bool {
        let interior = token.dropFirst()
        return interior.contains(where: \.isUppercase) || interior.contains(where: \.isNumber)
    }

    /// `Kubernetes`, `Postgres`, `IPv6`. Capitalised and not merely the first
    /// word of a sentence.
    static func isProperNoun(_ token: String) -> Bool {
        guard let first = token.first, first.isUppercase else { return false }
        let lower = token.lowercased()
        guard !sentenceStarters.contains(lower), !calendarWords.contains(lower) else { return false }
        // An interior capital or digit is strong evidence: "IPv6", "OpenAPI".
        let interior = token.dropFirst()
        if interior.contains(where: \.isUppercase) || interior.contains(where: \.isNumber) {
            return true
        }
        // Otherwise require it to be long enough that a sentence-initial common
        // word is unlikely, and to be alphabetic.
        return token.count >= 5 && token.allSatisfy(\.isLetter)
    }

    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "|" })
            .map(String.init)
    }
}
