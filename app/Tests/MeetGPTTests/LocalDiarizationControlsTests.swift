import Foundation
import SwiftUI
import Testing
import ViewInspector
@testable import MeetGPT

private actor LocalDiarizationUIProbe {
    private var expectedCount: Int?

    func run(expected: Int) async throws -> [SpeakerSegment] {
        expectedCount = expected
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return [SpeakerSegment(
            speakerID: "remote", startSeconds: 0, endSeconds: 20)]
    }

    func waitForCount() async -> Int? {
        for _ in 0..<400 {
            if let expectedCount { return expectedCount }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return expectedCount
    }
}

@MainActor
@Suite("Private speaker-label controls", .serialized)
struct LocalDiarizationControlsTests {
    private func eligibleState() -> AppState {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("orakul-speaker-controls-\(UUID().uuidString)")
        let state = AppState(
            credentialStore: InMemoryKeychain(),
            sessionStore: SessionStore(root: root))
        state.applyTestWorkspace(recording: false)
        let start = Date(timeIntervalSinceReferenceDate: 40_000)
        state.transcript = [TranscriptEntry(
            source: .system, text: "Проверим подписи.", timestamp: start,
            transcriptionEngine: .local)]
        state.applyTestLocalFinalPassRetention(
            samples: Array(repeating: Int16(0), count: 21 * 16_000),
            startedAt: start,
            optedIn: false,
            localDiarization: true)
        return state
    }

    private func rendered(
        state: AppState,
        manager: MCPConnectionManager
    ) throws -> InspectableView<ViewType.ClassifiedView> {
        try ContentView()
            .environmentObject(state)
            .environmentObject(manager)
            .environment(\.dynamicTypeSize, .accessibility5)
            .frame(width: 360, height: 720, alignment: .topLeading)
            .inspect()
    }

    @Test("360-point large-text footer keeps count, run, progress, and Cancel reachable")
    func narrowLargeTextControlsRemainReachable() async throws {
        try await SharedDefaults.withExclusiveAccess {
            let savedCount = Config.localDiarizationRemoteSpeakerCount
            let savedLayout = PaneLayoutStore.shared.layout
            defer {
                Config.localDiarizationRemoteSpeakerCount = savedCount
                PaneLayoutStore.shared.replace(savedLayout)
            }
            Config.localDiarizationRemoteSpeakerCount = 3
            PaneLayoutStore.shared.replace(PaneLayout(
                sidebar: false, transcript: true, assistant: false))

            let state = eligibleState()
            let manager = MCPConnectionManager(
                tokenStore: InMemoryKeychain(),
                notificationCenter: NotificationCenter())
            let probe = LocalDiarizationUIProbe()
            state.localDiarizationRunnerOverride = { _, expected, _ in
                try await probe.run(expected: expected)
            }

            let idle = try rendered(state: state, manager: manager)
            #expect(throws: Never.self) {
                try idle.find(viewWithAccessibilityIdentifier:
                    "postcall.localDiarization.speakers")
            }
            #expect(throws: Never.self) {
                try idle.find(viewWithAccessibilityIdentifier:
                    "postcall.localDiarization.run")
            }

            try idle.find(button: "Подписать говорящих").tap()
            let receivedCount = await probe.waitForCount()
            #expect(receivedCount == 3, "модель получила \(String(describing: receivedCount))")
            #expect(state.localDiarizationRunning)

            let running = try rendered(state: state, manager: manager)
            #expect(throws: Never.self) {
                try running.find(viewWithAccessibilityIdentifier:
                    "postcall.localDiarization.progress")
            }
            #expect(throws: Never.self) {
                try running.find(viewWithAccessibilityIdentifier:
                    "postcall.localDiarization.cancel")
            }
            try running.find(button: "Отмена").tap()
            #expect(!state.localDiarizationRunning)
            #expect(!state.diarizing)
        }
    }
}
