import AppKit
import Darwin
import Foundation
import Testing
@testable import MeetGPT

@MainActor
@Suite("Live-test dump path confinement")
struct LiveTestHooksConfinementTests {
    @Test("accepts a nonexistent direct child beneath a canonicalized private-tmp root")
    func acceptsNonexistentChildUnderPrivateTmpRoot() throws {
        let fileManager = FileManager.default
        let rawRoot = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "cruxwing-livetest-confinement-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rawRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: rawRoot) }

        // The environment-backed root is standardized at launch, while the
        // dump command still carries the shell's /private/tmp spelling.
        let canonicalRoot = rawRoot.standardizedFileURL
        let rawCandidate = rawRoot.appendingPathComponent("state.json")
        #expect(!fileManager.fileExists(atPath: rawCandidate.path))

        let accepted = try #require(
            LiveTestHooks.confinedDumpURL(rawCandidate.path, under: canonicalRoot)
        )

        #expect(accepted.lastPathComponent == "state.json")
        #expect(
            accepted.deletingLastPathComponent().standardizedFileURL.path
                == canonicalRoot.path
        )
        #expect(!fileManager.fileExists(atPath: accepted.path))
    }

    @Test("rejects sibling, escaping traversal, and nested dump destinations")
    func rejectsPathsOutsideDirectChildBoundary() throws {
        let fileManager = FileManager.default
        let rawRoot = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "cruxwing-livetest-confinement-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rawRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: rawRoot) }

        let canonicalRoot = rawRoot.standardizedFileURL
        let sibling = rawRoot.deletingLastPathComponent()
            .appendingPathComponent("\(rawRoot.lastPathComponent)-sibling", isDirectory: true)
            .appendingPathComponent("state.json")
        let traversal = "\(rawRoot.path)/../escaped-state.json"
        let nested = rawRoot
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("state.json")

        #expect(LiveTestHooks.confinedDumpURL(sibling.path, under: canonicalRoot) == nil)
        #expect(LiveTestHooks.confinedDumpURL(traversal, under: canonicalRoot) == nil)
        #expect(LiveTestHooks.confinedDumpURL(nested.path, under: canonicalRoot) == nil)
    }

    @Test("requires a real owner-only artifact directory")
    func requiresOwnerOnlyArtifactDirectory() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cruxwing-livetest-owner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: root) }

        #expect(LiveTestHooks.isOwnerOnlyArtifactRoot(root))
        #expect(!LiveTestHooks.isOwnerOnlyArtifactRoot(nil))
        #expect(!LiveTestHooks.isOwnerOnlyArtifactRoot(
            root, currentUserID: getuid() &+ 1))

        try fileManager.setAttributes(
            [.posixPermissions: 0o750], ofItemAtPath: root.path)
        #expect(!LiveTestHooks.isOwnerOnlyArtifactRoot(root))
    }

    @Test("rejects a symlink even when its destination is owner-only")
    func rejectsSymlinkArtifactRoot() throws {
        let fileManager = FileManager.default
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cruxwing-livetest-link-\(UUID().uuidString)", isDirectory: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try fileManager.createDirectory(
            at: target, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fileManager.removeItem(at: parent) }

        #expect(LiveTestHooks.isOwnerOnlyArtifactRoot(target))
        #expect(!LiveTestHooks.isOwnerOnlyArtifactRoot(link))
    }

    @Test("requires dev mode, exact bounded nonce, and an authorized owner")
    func commandAuthorizationMatrix() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "cruxwing-livetest-auth-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: root) }
        let nonce = String(repeating: "a", count: 64)

        #expect(LiveTestHooks.commandAuthorized(
            suppliedNonce: nonce, expectedNonce: nonce,
            artifactRoot: root, isDevBuild: true))
        #expect(!LiveTestHooks.commandAuthorized(
            suppliedNonce: "wrong", expectedNonce: nonce,
            artifactRoot: root, isDevBuild: true))
        #expect(!LiveTestHooks.commandAuthorized(
            suppliedNonce: nonce, expectedNonce: nonce,
            artifactRoot: root, isDevBuild: false))
        #expect(!LiveTestHooks.commandAuthorized(
            suppliedNonce: nonce, expectedNonce: nonce,
            artifactRoot: nil, isDevBuild: true))
        #expect(!LiveTestHooks.validLiveTestNonce(String(repeating: "a", count: 31)))
        #expect(!LiveTestHooks.validLiveTestNonce(String(repeating: "z", count: 64)))
    }

    @Test("synthetic goal and command payloads are fixed and bounded")
    func boundedSyntheticBlindSpotPayloads() {
        #expect(LiveTestHooks.syntheticGoal(
            for: LiveTestHooks.syntheticBlindSpotFixtureID)
            == LiveTestHooks.syntheticBlindSpotGoal)
        #expect(LiveTestHooks.syntheticGoal(for: "arbitrary-user-call") == nil)
        #expect(LiveTestHooks.syntheticGoal(for: nil) == nil)

        #expect(LiveTestHooks.validCommandID("run:clean.blind-spot_1")
            == "run:clean.blind-spot_1")
        #expect(LiveTestHooks.validCommandID("") == nil)
        #expect(LiveTestHooks.validCommandID("contains/slash") == nil)
        #expect(LiveTestHooks.validCommandID("contains\nnewline") == nil)
        #expect(LiveTestHooks.validCommandID(
            String(repeating: "x", count: LiveTestHooks.maximumCommandIDBytes + 1)) == nil)
    }

    @Test("dev snapshot retains reconstructable synthetic Blind Spot evidence")
    func snapshotContainsSyntheticBlindSpotEvidence() throws {
        _ = NSApplication.shared
        let state = AppState()
        state.callGoal = LiveTestHooks.syntheticBlindSpotGoal
        state.workflowSteps = [WorkflowStep(
            id: 7,
            label: "Search project tracker",
            status: .succeeded,
            app: WorkflowApp(
                id: "linear", name: "Linear", symbol: "checkmark.square",
                kind: .mcp),
            tool: "search_issues",
            detail: "Synthetic fixture returned one rollout risk")]
        state.suggestions = [Suggestion(
            title: "Confirm hardware date",
            detail: "The vendor delivery date is still unresolved.",
            kind: .risk,
            evidence: "vendor has not confirmed the delivery date",
            claim: nil,
            cheapTest: nil,
            costOfMissing: nil)]
        state.applyTestWorkspace(recording: true)
        state.ingestStreamedLine(
            text: "Instant provider evidence",
            source: .system,
            speaker: "Speaker A",
            transcriptionEngine: .deepgram)

        let data = LiveTestHooks.snapshotJSON(
            of: state, requestID: "blind-spot-evidence", appliedAt: 123)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["callGoal"] as? String == LiveTestHooks.syntheticBlindSpotGoal)
        #expect(root["effectiveCallGoal"] as? String == LiveTestHooks.syntheticBlindSpotGoal)
        #expect(root["blindSpotLastProbeIDs"] as? [String] == [])
        #expect(root["blindSpotLastGrounded"] as? Bool == false)
        let allowance = TariffAllowance.forTier(state.currentTier)
        #expect(root["tariffCopilotHours"] as? Int == allowance.copilotHours)
        #expect(root["tariffComputeCredits"] as? Int == allowance.computeCredits)
        #expect(root["tariffGroundedCycles"] as? Int == allowance.groundedCycles)
        #expect((root["copilotSecondsRemaining"] as? Int) != nil)
        #expect((root["groundedCyclesRemaining"] as? Int) != nil)
        #expect((root["deepgramHandoffReadinessTimeoutSeconds"] as? Double) == 12)

        let transcript = try #require(root["transcriptFull"] as? [[String: Any]])
        let instant = try #require(transcript.first)
        #expect(instant["transcriptionEngine"] as? String == "deepgram")
        #expect(instant["speaker"] as? String == "Speaker A")

        let workflows = try #require(root["workflowStepsFull"] as? [[String: Any]])
        let workflow = try #require(workflows.first)
        #expect(workflow["id"] as? Int == 7)
        #expect(workflow["appID"] as? String == "linear")
        #expect(workflow["tool"] as? String == "search_issues")
        #expect(workflow["status"] as? String == "succeeded")
        #expect(workflow["done"] as? Bool == true)

        let suggestions = try #require(root["suggestionsFull"] as? [[String: Any]])
        let suggestion = try #require(suggestions.first)
        #expect(suggestion["title"] as? String == "Confirm hardware date")
        #expect(suggestion["kind"] as? String == "risk")
        #expect(suggestion["evidence"] as? String
            == "vendor has not confirmed the delivery date")
    }
}
