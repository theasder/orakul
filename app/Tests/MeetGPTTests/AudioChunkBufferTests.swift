import AVFoundation
import Testing
@testable import MeetGPT

@Suite("Audio chunk buffer")
struct AudioChunkBufferTests {
    @Test("emits one WAV chunk per chunkSeconds of voiced audio")
    func chunksAtBoundaries() {
        var wavs: [Data] = []
        // overlapSeconds: 0 pins the cadence itself. Overlap is covered below;
        // mixing the two here would make this assert two things at once.
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0) { wav, _ in wavs.append(wav) }
        // 2.5 s of voiced 48k audio → two full 1s chunks (0.5 s remains buffered).
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 48_000, seconds: 2.5))
        #expect(wavs.count == 2)
        #expect(LocalWhisperTranscription.floatSamples(fromWAV: wavs[0]).count == 16_000)
    }

    @Test("overlapping windows advance by less than a window, and stay full length")
    func overlapAdvancesByLessThanAWindow() {
        var wavs: [Data] = []
        // 1s windows overlapping by 0.5s advance 0.5s at a time, so 2.5s of
        // audio yields windows at 0.0, 0.5, 1.0 and 1.5 — four, not two.
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0.5) { wav, _ in wavs.append(wav) }
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 48_000, seconds: 2.5))

        var withoutOverlap: [Data] = []
        let plain = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0) { wav, _ in
            withoutOverlap.append(wav)
        }
        plain.append(AudioFixtures.voicedBuffer(sampleRate: 48_000, seconds: 2.5))

        // Asserted as a relationship rather than an exact count: resampling
        // 48k to 16k does not yield a whole number of windows, so a hard
        // expectation here is arithmetic luck rather than a property.
        #expect(wavs.count > withoutOverlap.count)
        // Every window is still a FULL window: overlap adds context, it does
        // not shorten what the engine decodes.
        for wav in wavs {
            #expect(LocalWhisperTranscription.floatSamples(fromWAV: wav).count == 16_000)
        }
    }

    @Test("an overlap at or beyond the window cannot stall the buffer")
    func clampsOverlapSoItAlwaysAdvances() {
        var wavs: [Data] = []
        // At parity the buffer would advance zero samples and emit the same
        // audio forever, which is a hang rather than a bad transcript.
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 10) { wav, _ in wavs.append(wav) }
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 48_000, seconds: 2.0))

        #expect(wavs.count > 0)
        #expect(wavs.count <= 8)
    }

    @Test("downsamples + mixes to mono 16 kHz regardless of the input format")
    func resampleStereo44k() {
        var wavs: [Data] = []
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0) { wav, _ in wavs.append(wav) }
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 44_100, seconds: 1.2, channels: 2))
        #expect(wavs.count == 1)
        #expect(LocalWhisperTranscription.floatSamples(fromWAV: wavs[0]).count == 16_000)
    }

    @Test("flush emits the buffered remainder below the chunk boundary")
    func flushRemainder() {
        var wavs: [Data] = []
        let buffer = AudioChunkBuffer(chunkSeconds: 10) { wav, _ in wavs.append(wav) }
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 0.5))
        #expect(wavs.isEmpty)
        buffer.flush()
        #expect(wavs.count == 1)
        // The exact sample count depends on AVAudioConverter internals; what
        // matters is that flush emits the buffered remainder (non-empty).
        let remainder = LocalWhisperTranscription.floatSamples(fromWAV: wavs[0]).count
        #expect(remainder > 0 && remainder <= 8_000)
    }

    @Test("onSamples sees every converted sample (feeds the diarization recorder)")
    func onSamplesTap() {
        var total = 0
        let buffer = AudioChunkBuffer(chunkSeconds: 1) { _, _ in }
        buffer.onSamples = { total += $0.count }
        buffer.append(AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 2))
        #expect(total == 32_000)
    }

    @Test("VAD drops silent chunks before the engine (when VAD is enabled)")
    func vadGate() {
        guard Config.vadEnabled else { return }   // only meaningful with VAD on
        var wavs: [Data] = []
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0) { wav, _ in wavs.append(wav) }
        buffer.append(AudioFixtures.silentBuffer(sampleRate: 16_000, seconds: 3))
        #expect(wavs.isEmpty)
    }

    @Test("voice-processed multi-channel input keeps channel 0 at full level (no aux-channel dilution)",
          arguments: [AVAudioChannelCount(3), AVAudioChannelCount(9)])
    func channelZeroExtraction(channels: AVAudioChannelCount) {
        var wavs: [Data] = []
        let buffer = AudioChunkBuffer(chunkSeconds: 1, overlapSeconds: 0) { wav, _ in wavs.append(wav) }
        // Quiet voice (peak 0.05 ≈ RMS 0.035) on ch0, silence on the aux
        // channels — the shape VP emits. A default N→1 downmix would dilute
        // this ~3–9× and land near/below the VAD gate; channel-0 extraction
        // must preserve it at full level.
        buffer.append(AudioFixtures.voiceProcessedShapedBuffer(sampleRate: 48_000,
                                                               seconds: 1.2,
                                                               channels: channels))
        #expect(wavs.count == 1)
        let samples = LocalWhisperTranscription.floatSamples(fromWAV: wavs[0])
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        // Sine at peak 0.05 → RMS ≈ 0.0354. Allow resampler tolerance, but a
        // 3-channel average (≈0.012) or 9-channel (≈0.004) must fail.
        #expect(rms > 0.028 && rms < 0.043)
    }

    @Test("lowered VAD gate admits VP-attenuated speech that the default gate drops")
    func vpThresholdAdmitsQuietSpeech() {
        guard Config.vadEnabled else { return }
        // ≈ −46 dBFS: below the −42 default gate, above the −52 VP gate.
        let quiet = AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 1.2, amplitude: 0.007)

        var defaultGate: [Data] = []
        let strict = AudioChunkBuffer(chunkSeconds: 1) { wav, _ in defaultGate.append(wav) }
        strict.append(quiet)
        #expect(defaultGate.isEmpty)

        var vpGate: [Data] = []
        let relaxed = AudioChunkBuffer(chunkSeconds: 1) { wav, _ in vpGate.append(wav) }
        relaxed.vadThreshold = VoiceActivity.voiceProcessedThreshold
        relaxed.append(quiet)
        #expect(vpGate.count == 1)
    }

    @Test("system-audio VAD admits quiet meeting playback that the mic gate drops")
    func systemThresholdAdmitsQuietPlayback() {
        guard Config.vadEnabled else { return }
        let quiet = AudioFixtures.voicedBuffer(sampleRate: 16_000, seconds: 1.2, amplitude: 0.007)

        var strictChunks: [Data] = []
        let strict = AudioChunkBuffer(chunkSeconds: 1) { wav, _ in strictChunks.append(wav) }
        strict.append(quiet)
        #expect(strictChunks.isEmpty)

        var systemChunks: [Data] = []
        let system = AudioChunkBuffer(chunkSeconds: 1) { wav, _ in systemChunks.append(wav) }
        system.vadThreshold = VoiceActivity.systemAudioThreshold
        system.append(quiet)
        #expect(systemChunks.count == 1)
    }
}
