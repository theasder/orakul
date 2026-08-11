import Foundation
import NaturalLanguage

/// The embedder cross-meeting recall actually ships with (roadmap F1).
///
/// `NLSkillTextEmbedder` is built `for: .english` and returns nil when Apple's
/// sentence model is absent for the locale. `DecisionRecallService` reads a nil
/// query vector as "no hits", so on its own that produces the worst possible
/// failure: the feature answers nothing, says nothing, and looks like it simply
/// has no memory of the meeting. The recall intent gate also accepts Russian
/// ("что мы решили…"), which an English sentence model has no business ranking.
///
/// So recall embeds through a composite. The sentence model leads because it
/// understands paraphrase — "what did we land on" finding a digest that says
/// "we agreed". The hashed bag-of-tokens fallback catches everything it drops:
/// it is language-agnostic, needs no model, and on a question that shares
/// vocabulary with the record — which recall questions do, since people ask
/// about "pricing" using the word "pricing" — it lands the right meeting.
///
/// Degrade quality, never the feature.
struct RecallEmbedder: SkillTextEmbedder {
    let primary: any SkillTextEmbedder
    let fallback: any SkillTextEmbedder

    /// Shared instance so the NLEmbedding model is loaded once. The underlying
    /// type serialises its own CoreNLP calls; this adds no state of its own.
    static let production = RecallEmbedder(primary: NLSkillTextEmbedder.shared,
                                           fallback: HashingSkillTextEmbedder())

    func embed(_ text: String) -> [Float]? {
        if usesPrimary(for: text), let vector = primary.embed(text) { return vector }
        return fallback.embed(text)
    }

    /// Whether the sentence model is the right tool for this text.
    ///
    /// Measured on this machine: `NLEmbedding.sentenceEmbedding(for: .english)`
    /// happily returns a vector for Russian input, and there is no Russian
    /// sentence model to fall back to. So a nil check alone never routes
    /// Russian anywhere else — it just ranks Cyrillic with an English model's
    /// opinion of it. Language is the honest gate: the sentence model is used
    /// for the language it was built for, and everything else goes to the
    /// lexical embedder, which is language-agnostic by construction.
    func usesPrimary(for text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return true }
        return language == .english
    }
}
