import Foundation
import Testing
@testable import MeetGPT

/// The "thinking process" step log (AppState.workflowSteps) is derived from the
/// aiStreaming/aiStage transitions via property observers — this locks that logic.
@MainActor
@Suite("Thinking steps")
struct ThinkingStepsTests {
    private func makeState() -> AppState { AppState(llm: MockLLMGateway(response: "ok")) }

    @Test("stage transitions build an ordered step log; the prior step completes")
    func derivesSteps() {
        let state = makeState()
        state.aiStreaming = true                       // new run → fresh log
        #expect(state.workflowSteps.isEmpty)

        state.aiStage = "Checking Notion…"
        state.aiStage = "Composing the answer…"
        #expect(state.workflowSteps.map(\.label) == ["Checking Notion…", "Composing the answer…"])
        #expect(state.workflowSteps[0].done)           // first closed when the second began
        #expect(!state.workflowSteps[1].done)          // second still active

        state.aiStreaming = false                       // run finished → close the final step
        #expect(state.workflowSteps.last?.done == true)
    }

    @Test("a new run resets the previous run's steps")
    func resetsBetweenRuns() {
        let state = makeState()
        state.aiStreaming = true
        state.aiStage = "Grounding…"
        state.aiStreaming = false
        #expect(state.workflowSteps.count == 1)

        state.aiStreaming = true                        // second run
        #expect(state.workflowSteps.isEmpty)
    }

    @Test("repeating a stage, or clearing to nil, appends no extra step")
    func noSpuriousSteps() {
        let state = makeState()
        state.aiStreaming = true
        state.aiStage = "Drafting…"
        state.aiStage = "Drafting…"                     // unchanged → no-op
        state.aiStage = nil                            // clear → no step
        #expect(state.workflowSteps.map(\.label) == ["Drafting…"])
    }

    @Test("legacy done API maps to active and terminal statuses")
    func legacyDoneCompatibility() {
        var step = WorkflowStep(id: 1, label: "Drafting…", done: false)
        #expect(step.status == .running)
        #expect(!step.done)

        step.done = true
        #expect(step.status == .succeeded)
        #expect(step.done)

        step.done = false
        #expect(step.status == .running)
        #expect(!step.done)
    }

    @Test("skipped and failed steps are terminal without losing their outcome")
    func terminalOutcomes() {
        var skipped = WorkflowStep(id: 1, label: "Check calendar", status: .skipped)
        var failed = WorkflowStep(id: 2, label: "Search docs", status: .failed)

        #expect(skipped.done)
        #expect(failed.done)

        skipped.done = true
        failed.done = true
        #expect(skipped.status == .skipped)
        #expect(failed.status == .failed)
    }

    @Test("structured steps identify their app and expose a safe accessibility summary")
    func structuredStepMetadata() {
        let app = WorkflowApp(
            id: "notion",
            name: "Notion\nWorkspace",
            symbol: "doc.text.magnifyingglass",
            kind: .mcp
        )
        let step = WorkflowStep(
            id: 3,
            label: "  Search\nproject   notes  ",
            status: .running,
            app: app,
            tool: " search_pages ",
            detail: "Private meeting content"
        )

        #expect(step.app == app)
        #expect(step.tool == " search_pages ")
        #expect(step.detail == "Private meeting content")
        #expect(
            step.accessibilitySummary
                == "Search project notes, Notion Workspace, MCP, search_pages, In progress"
        )
        #expect(!step.accessibilitySummary.contains("Private meeting content"))
    }

    @Test("a preplanned workflow mutates rows in place and skips unused steps")
    func stablePreplannedRows() {
        let state = makeState()
        let notion = WorkflowApp(
            id: "mcp:notion", name: "Notion", symbol: "note.text", kind: .mcp)
        let ai = WorkflowApp(
            id: "ai:auto", name: "Cruxwing AI", symbol: "sparkles", kind: .ai)

        state.aiStreaming = true
        state.installWorkflowPlan([
            WorkflowStep(id: 1, label: "Search relevant context", app: notion),
            WorkflowStep(id: 2, label: "Compose the answer", app: ai),
        ])
        let ids = state.workflowSteps.map(\.id)

        state.aiStage = "Compose the answer"
        #expect(state.workflowSteps.map(\.id) == ids)
        #expect(state.workflowSteps.count == 2)
        #expect(state.workflowSteps[0].status == .pending)
        #expect(state.workflowSteps[1].status == .running)

        state.aiStreaming = false
        #expect(state.workflowSteps.map(\.id) == ids)
        #expect(state.workflowSteps[0].status == .skipped)
        #expect(state.workflowSteps[1].status == .succeeded)
    }

    @Test("using a suggestion does not remove the other suggestions")
    @MainActor
    func carriesFollowUpsWhenNoneAreGenerated() {
        let state = makeState()
        let chips = [QuickPrompts.all[0], QuickPrompts.all[1]]
        state.followUpPrompts = chips
        state.carriedFollowUpPrompts = []

        // Pressing a chip archives the current ones and clears the live row.
        state.carriedFollowUpPrompts = state.followUpPrompts
        state.followUpPrompts = []

        // The new answer's follow-up generation is best-effort and can come
        // back blank. Before, the row then stayed empty for the rest of the
        // session — so using one suggestion deleted the rest.
        if state.followUpPrompts.isEmpty {
            state.followUpPrompts = state.carriedFollowUpPrompts
        }

        #expect(state.followUpPrompts == chips)
    }

    @Test("clearing the workspace removes the previous workflow trace")
    func clearRemovesTrace() {
        let state = makeState()
        state.aiStreaming = true
        state.aiStage = "Compose the answer"
        state.followUpPrompts = [QuickPrompts.all[0]]

        state.clearAll()

        #expect(state.workflowSteps.isEmpty)
        #expect(state.followUpPrompts.isEmpty)
        #expect(state.aiStage == nil)
    }
}
