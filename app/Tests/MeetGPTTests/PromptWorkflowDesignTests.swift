import Foundation
import Testing
@testable import MeetGPT

@MainActor
@Suite("Prompt workflow design", .serialized)
struct PromptWorkflowDesignTests {
    private func stateWithAuthorizedLinear() async throws -> (AppState, MCPConnectionManager, MCPServerDescriptor) {
        let keychain = InMemoryKeychain()
        let linear = try #require(MCPCatalog.builtIn.first { $0.id == "linear" })
        // Presence is enough for the manager's cached-authorization snapshot;
        // the test never performs a network connection.
        keychain.set(Data("cached-token".utf8), for: "mcp.token.\(linear.id)")
        let manager = MCPConnectionManager(tokenStore: keychain)
        await manager.loadPersistedAuthorization()
        let state = AppState(llm: MockLLMGateway(response: "ok"))
        state.groundApps = true
        state.mcp = manager
        return (state, manager, linear)
    }

    @Test("saving and editing a custom button immediately redesigns its workflow")
    func customSaveAndEdit() async throws {
        let (state, manager, _) = try await stateWithAuthorizedLinear()
        let id = "custom-workflow-design-\(UUID().uuidString)"
        let tasks = QuickPrompt.custom(
            id: id, icon: "✅", title: "Project status",
            prompt: "Review open tickets and the sprint backlog.")

        state.saveCustomPrompt(tasks)
        #expect(state.designedPromptWorkflows[id]?.sourceIntents.contains(.tasks) == true)
        #expect(state.promptWorkflowSources[id]?.contains(where: { $0.id == "mcp:linear" }) == true)
        #expect(state.workflowSummary(for: tasks).contains("Linear"))

        let calendar = QuickPrompt.custom(
            id: id, icon: "🗓️", title: "Find time",
            prompt: "Check calendar availability for the next meeting.")
        state.saveCustomPrompt(calendar)

        #expect(state.customPrompts.filter { $0.id == id }.count == 1)
        #expect(state.designedPromptWorkflows[id]?.sourceIntents.contains(.calendar) == true)
        #expect(state.designedPromptWorkflows[id]?.googleServices == [.calendar])
        #expect(state.promptWorkflowSources[id]?.contains(where: { $0.id == "mcp:linear" }) == false)
        state.deleteCustomPrompt(id: id)
        _ = manager // AppState intentionally holds the scene-owned manager weakly.
    }

    @Test("a capability disconnect invalidates cached routes and rebuilds affected buttons")
    func disconnectRebuilds() async throws {
        let (state, manager, linear) = try await stateWithAuthorizedLinear()
        let id = "custom-workflow-disconnect-\(UUID().uuidString)"
        let prompt = QuickPrompt.custom(
            id: id, icon: "✅", title: "Ticket status",
            prompt: "Find open Linear issues and project tasks.")
        state.saveCustomPrompt(prompt)
        #expect(state.promptWorkflowSources[id]?.contains(where: { $0.id == "mcp:linear" }) == true)

        let revision = manager.capabilityRevision
        await manager.disconnect(linear)
        #expect(manager.capabilityRevision == revision + 1)
        for _ in 0..<100
        where state.promptWorkflowSources[id]?.contains(where: { $0.id == "mcp:linear" }) == true {
            await Task.yield()
        }

        #expect(state.promptWorkflowSources[id]?.contains(where: { $0.id == "mcp:linear" }) == false)
        state.deleteCustomPrompt(id: id)
    }
}
