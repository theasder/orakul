import Foundation

/// Energy-based voice-activity detection for transcription chunks.
///
/// A chunk is worth transcribing when a meaningful slice of its short frames
/// carries energy — whole-chunk RMS would wrongly drop a chunk that is 5.5 s
/// of silence around 0.5 s of speech. Silent chunks are skipped before they
/// reach the transcription engine (API cost / local compute), while the
/// session recorder still receives every sample for diarization.
enum VoiceActivity {
    /// 30 ms frames at 16 kHz.
    ///
    /// Not private: `AudioChunkBuffer.quietestBoundary` must hand `isVoiced` at
    /// least this many samples. It used to pass 20 ms, which fell under the
    /// guard below and came back `true` unconditionally — so the pause search
    /// saw every frame as speech and never moved a boundary.
    static let frameSize = 480
    /// RMS above ≈ −36 dBFS counts as a raw-microphone voiced frame. Built-in
    /// mic room/fan noise regularly sits above the old −42 dBFS gate and made
    /// every quiet chunk reach Whisper; near-field quiet speech remains above
    /// this threshold. Voice-processed and system tracks use lower gates below.
    static let defaultThreshold: Float = 0.015
    /// ≈ −52 dBFS — ScreenCaptureKit's system-audio stream can sit well below
    /// the mic level even for intelligible meeting playback. Keep quiet remote
    /// speech while still rejecting digital silence and low-level hiss.
    static let systemAudioThreshold: Float = 0.0025
    /// ≈ −52 dBFS — for audio that already went through Apple voice processing.
    /// The VP chain (AEC + noise suppression + gating) attenuates anything it
    /// doesn't classify as near-field speech by 10–30 dB, so speech that would
    /// sit at −35 dBFS raw can land below the −42 dBFS default gate and the
    /// transcript silently starves. VP output is also already denoised, so the
    /// lower gate doesn't re-admit line hiss.
    static let voiceProcessedThreshold: Float = 0.0025
    /// Fraction of voiced frames for the chunk to pass (~0.3 s in a 6 s chunk).
    private static let voicedFrameFraction = 0.05

    static func isVoiced(_ samples: [Int16], threshold: Float = defaultThreshold) -> Bool {
        guard samples.count >= frameSize else { return !samples.isEmpty }
        let frameCount = samples.count / frameSize
        var voiced = 0
        let needed = max(1, Int(Double(frameCount) * voicedFrameFraction))

        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var energy: Float = 0
                let base = frame * frameSize
                for i in base..<(base + frameSize) {
                    let sample = Float(buffer[i]) / 32768.0
                    energy += sample * sample
                }
                if (energy / Float(frameSize)).squareRoot() >= threshold {
                    voiced += 1
                    if voiced >= needed { break }
                }
            }
        }
        return voiced >= needed
    }
}
