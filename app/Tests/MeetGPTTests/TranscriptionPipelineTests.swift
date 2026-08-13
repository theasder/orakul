import AVFoundation
import Testing
@testable import MeetGPT

/// End-to-end of the *logic*: audio buffer → chunking → VAD → transcribe.
/// A regression that broke any link in this chain (e.g. chunks never reaching
/// the engine) would fail here without needing a real model or microphone.
@Suite("Transcription pipeline")
struct TranscriptionPipelineTests {
    @Test("voiced audio flows through chunking into transcribed text")
    func voicedFlow() async throws {
        let mock = MockTranscriptionService(text: "recognized line")
        var wavs: [Data] = []
        let buffer = AudioChunkBuffer(chunkSeconds: 1) { wav, _ in wavs.append(wav) }
        // 3 s of voiced audio comfortably clears two 1s chunk boundaries even
        // after sample-rate-conversion rounding.
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 48_000, seconds: 3))
        #expect(wavs.count >= 2)
        for wav in wavs {
            let text = try await mock.transcribe(wav: wav)
            #expect(text == "recognized line")
        }
        #expect(await mock.transcribeCount == wavs.count)
    }

    @Test("silent audio yields no chunks to transcribe (VAD on)",
          .enabled(if: Config.vadEnabled))
    func silentFlow() async {
        let mock = MockTranscriptionService()
        var chunks = 0
        let buffer = AudioChunkBuffer(chunkSeconds: 1) { _, _ in chunks += 1 }
        buffer.append(AudioFixtures.silentBuffer(sampleRate: 48_000, seconds: 3))
        #expect(chunks == 0)
        #expect(await mock.transcribeCount == 0)
    }
}
