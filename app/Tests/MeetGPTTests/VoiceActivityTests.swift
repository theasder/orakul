import Testing
@testable import MeetGPT

@Suite("Voice-activity detection")
struct VoiceActivityTests {
    @Test("pure silence is not voiced")
    func silence() {
        #expect(VoiceActivity.isVoiced(AudioFixtures.silentInt16(count: 16_000)) == false)
    }

    @Test("a loud sine is voiced")
    func voiced() {
        #expect(VoiceActivity.isVoiced(AudioFixtures.voicedInt16(count: 16_000)) == true)
    }

    @Test("empty input is not voiced")
    func empty() {
        #expect(VoiceActivity.isVoiced([]) == false)
    }

    @Test("a sub-frame non-empty slice can't be gated, so it passes")
    func subFrame() {
        #expect(VoiceActivity.isVoiced([100, 200, 300]) == true)
    }

    @Test("a short voiced burst inside a long silent chunk still passes")
    func burstInSilence() {
        var samples = AudioFixtures.silentInt16(count: 16_000 * 6)      // 6 s silence
        let burst = AudioFixtures.voicedInt16(count: 16_000 / 2)        // 0.5 s voice
        for (i, v) in burst.enumerated() { samples[16_000 * 2 + i] = v }
        #expect(VoiceActivity.isVoiced(samples) == true)
    }

    @Test("faint hiss below the threshold is not voiced")
    func faintHiss() {
        let hiss = AudioFixtures.voicedInt16(count: 16_000, amplitude: 0.002)
        #expect(VoiceActivity.isVoiced(hiss) == false)
    }

    @Test("raw microphone room noise is gated while quiet near-field speech passes")
    func rawMicNoiseFloor() {
        let roomNoise = AudioFixtures.voicedInt16(count: 16_000, amplitude: 0.010)
        let quietSpeech = AudioFixtures.voicedInt16(count: 16_000, amplitude: 0.030)
        #expect(!VoiceActivity.isVoiced(roomNoise))
        #expect(VoiceActivity.isVoiced(quietSpeech))
    }
}
