import AVFoundation
import Testing
@testable import MeetGPT

@Suite("Live duplex diagnostics")
struct LiveDuplexDiagnosticsTests {
    @Test("capture diagnostics prove liveness, signal, timing, and reset")
    func captureDiagnostics() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8 { samples[index] = index.isMultiple(of: 2) ? 0.25 : -0.25 }

        let diagnostics = AudioTrackDiagnostics()
        for _ in 0..<10 { diagnostics.record(buffer) }
        let captured = diagnostics.snapshot()

        #expect(captured.bufferCount == 10)
        #expect(captured.rmsSampleCount == 3)
        #expect(captured.rmsSum > 0)
        #expect(captured.maxRMS > 0)
        #expect(captured.nonSilentSampleCount == 3)
        #expect(captured.lastBufferAt != nil)

        diagnostics.reset()
        let reset = diagnostics.snapshot()
        #expect(reset.bufferCount == 0)
        #expect(reset.rmsSampleCount == 0)
        #expect(reset.rmsSum == 0)
        #expect(reset.lastBufferAt == nil)
    }
}

@MainActor
@Suite("Identified live prompt surfaces")
struct LivePromptSurfaceStateTests {
    @Test("mandatory notices are isolated and instance-owned")
    func mandatoryNoticeOwnership() {
        // `debugPresentMandatoryNotice` is `guard Config.isDevBuild` — the whole
        // surface is compiled out of a dist build, so asserting it works there
        // fails on a feature that is absent on purpose. `notarize.sh` regenerates
        // Secrets.swift with devMode "0", which leaves the tree in that state for
        // whatever `swift test` runs next.
        guard Config.isDevBuild else { return }   // dist builds: feature absent

        let state = AppState()

        #expect(state.debugPresentMandatoryNotice(
            id: "surface-a", message: "Read this before continuing."))
        #expect(state.liveTestMandatoryNotice?.id == "surface-a")
        #expect(!state.debugPresentMandatoryNotice(
            id: "surface-b", message: "Must not replace A."))
        #expect(!state.debugClearMandatoryNotice(id: "surface-b"))
        #expect(state.liveTestMandatoryNotice?.id == "surface-a")
        #expect(state.debugClearMandatoryNotice(id: "surface-a"))
        #expect(state.liveTestMandatoryNotice == nil)
    }
}
