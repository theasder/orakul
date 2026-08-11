import Testing
import ScreenCaptureKit
@testable import MeetGPT

/// The system-audio capture surface (M8b). Locks the narrowing contract: audio
/// only, our own playback excluded, video kept to the 2×2 minimum with no cursor
/// — so a future edit can't silently widen what the sandboxed app captures.
@Suite("SystemAudioCapture config")
struct SystemAudioCaptureTests {
    @Test("the capture config is narrow: audio-only, own audio excluded, minimal video")
    func narrowCaptureSurface() {
        let c = SystemAudioCapture.makeStreamConfiguration()
        #expect(c.capturesAudio == true)
        #expect(c.excludesCurrentProcessAudio == true)   // no self-feedback
        #expect(c.sampleRate == 48_000)
        #expect(c.channelCount == 2)
        // Video is required by SCStream but we decode none — keep it minimal.
        #expect(c.width == 2)
        #expect(c.height == 2)
        #expect(c.showsCursor == false)
    }
}
