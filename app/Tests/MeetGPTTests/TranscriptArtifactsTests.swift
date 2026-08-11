import Testing
import Foundation
@testable import MeetGPT

/// Whisper emits non-speech annotations as literal transcript text; the cleaner
/// must strip them (they poison the live transcript and every AI action) while
/// never touching real speech — including non-Latin scripts.
@Suite("Transcript artifacts")
struct TranscriptArtifactsTests {
    @Test("strips the exact artifacts seen in the field")
    func fieldArtifacts() {
        #expect(TranscriptArtifacts.clean("[BLANK_AUDIO]").isEmpty)
        #expect(TranscriptArtifacts.clean("(speaking in foreign language)").isEmpty)
        #expect(TranscriptArtifacts.clean("[ Silence ]").isEmpty)
        #expect(TranscriptArtifacts.clean("(MUSIC PLAYING)").isEmpty)
        #expect(TranscriptArtifacts.clean("[blank_audio] [BLANK AUDIO]").isEmpty)
        #expect(TranscriptArtifacts.clean("Takk for at du så med.").isEmpty)
        #expect(TranscriptArtifacts.clean("Undertexter av Nicolai Winther").isEmpty)
        #expect(TranscriptArtifacts.clean("Thanks for watching!").isEmpty)
        #expect(TranscriptArtifacts.clean("To be continued...").isEmpty)
        #expect(TranscriptArtifacts.clean("Продолжение следует...").isEmpty)
        #expect(TranscriptArtifacts.clean("Sigh").isEmpty)
        #expect(TranscriptArtifacts.clean("sigh.").isEmpty)
        #expect(TranscriptArtifacts.clean("Спасибо за просмотр!").isEmpty)
        #expect(TranscriptArtifacts.clean("Субтитры выполнила Анна").isEmpty)
        #expect(TranscriptArtifacts.clean("Thank you.") == "Thank you.")
    }

    @Test("removes artifacts embedded in real speech, preserving the words")
    func embedded() {
        #expect(TranscriptArtifacts.clean("we agreed [BLANK_AUDIO] on the pricing") == "we agreed on the pricing")
        #expect(TranscriptArtifacts.clean("(speaking in foreign language) итак, начнём встречу") == "итак, начнём встречу")
        #expect(TranscriptArtifacts.clean("ship it [LAUGHTER] next week") == "ship it next week")
        #expect(TranscriptArtifacts.cleanInline("Thanks for listening") == "Thanks for listening")
        #expect(TranscriptArtifacts.clean("The customer said thanks for listening before leaving")
                == "The customer said thanks for listening before leaving")
        #expect(TranscriptArtifacts.clean("She let out a sigh before answering")
                == "She let out a sigh before answering")
    }

    @Test("never touches legitimate speech, including brackets with content")
    func preservesSpeech() {
        #expect(TranscriptArtifacts.clean("мы решили перейти на новую модель") == "мы решили перейти на новую модель")
        #expect(TranscriptArtifacts.clean("the [Q3] budget is approved") == "the [Q3] budget is approved")
        #expect(TranscriptArtifacts.clean("call it done (finally)") == "call it done (finally)")
        #expect(TranscriptArtifacts.clean("She ended the demo by saying thanks for watching")
                == "She ended the demo by saying thanks for watching")
    }

    @Test("local confidence gate rejects likely silence hallucinations")
    func localConfidenceGate() {
        #expect(LocalWhisperTranscription.isReliable(avgLogProbability: -0.30,
                                                     noSpeechProbability: 0.08,
                                                     compressionRatio: 1.10))
        #expect(!LocalWhisperTranscription.isReliable(avgLogProbability: -0.90,
                                                      noSpeechProbability: 0.08,
                                                      compressionRatio: 1.10))
        #expect(!LocalWhisperTranscription.isReliable(avgLogProbability: -0.20,
                                                      noSpeechProbability: 0.72,
                                                      compressionRatio: 1.10))
        #expect(!LocalWhisperTranscription.isReliable(avgLogProbability: -0.20,
                                                      noSpeechProbability: 0.08,
                                                      compressionRatio: 2.30))
        #expect(LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.30,
                                                                  noSpeechProbability: 0.08,
                                                                  compressionRatio: 1.10))
        // The short-fragment bar was loosened from -0.50/0.20/1.80 to
        // -0.75/0.40/2.10 on measured evidence. Once decode windows overlap, a
        // seam produces legitimate short fragments, and the strict bar deleted
        // them as hallucinations: across four harness runs the dropped-segment
        // count tracked WER almost monotonically, and relaxing it took clean
        // audio from WER 0.379 to 0.105 and noisy from failing to 0.355 — with
        // no hallucinations in either transcript.
        //
        // These two cases are now ACCEPTED, and on inspection they always
        // looked like speech rather than silence: -0.70 with noSpeech 0.08 is a
        // model fairly sure it heard words, and compression 1.10 is not
        // repetitive.
        #expect(LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.70,
                                                                  noSpeechProbability: 0.08,
                                                                  compressionRatio: 1.10))
        #expect(LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.30,
                                                                  noSpeechProbability: 0.30,
                                                                  compressionRatio: 1.10))

        // Still rejected — the cases the gate actually exists for. A fragment
        // the model half-heard, one it thinks is probably not speech, and one
        // repetitive enough to be a loop.
        #expect(!LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.95,
                                                                   noSpeechProbability: 0.08,
                                                                   compressionRatio: 1.10))
        #expect(!LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.30,
                                                                   noSpeechProbability: 0.55,
                                                                   compressionRatio: 1.10))
        #expect(!LocalWhisperTranscription.isReliableShortFragment(avgLogProbability: -0.30,
                                                                   noSpeechProbability: 0.08,
                                                                   compressionRatio: 2.40))
    }
}
