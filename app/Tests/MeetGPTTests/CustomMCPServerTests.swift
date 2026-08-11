import Foundation
import Testing
@testable import MeetGPT

@MainActor
@Suite("Custom MCP server lifecycle", .serialized)
struct CustomMCPServerTests {
    @Test("custom endpoints fail closed, persist, reload, and remove without touching catalog apps")
    func validationPersistenceAndRemoval() async throws {
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        let originalCatalogIDs = Set(manager.servers.filter { !$0.isCustom }.map(\.id))
        let marker = "QA Custom \(UUID().uuidString)"

        #expect(!manager.addCustomServer(name: "", urlString: "https://example.com/mcp"))
        #expect(!manager.addCustomServer(name: marker, urlString: "http://example.com/mcp"))
        #expect(!manager.addCustomServer(name: marker, urlString: "https://"))
        #expect(!manager.addCustomServer(
            name: marker, urlString: "https://user:secret@example.com/mcp"))

        #expect(manager.addCustomServer(
            name: "  \(marker)  ", urlString: "  https://example.com/mcp  "))
        let added = try #require(manager.customServers.first { $0.name == marker })
        #expect(added.isCustom)
        #expect(added.endpoint.absoluteString == "https://example.com/mcp")
        #expect(Set(manager.servers.filter { !$0.isCustom }.map(\.id)) == originalCatalogIDs)

        let reloaded = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        #expect(reloaded.customServers.contains { $0.id == added.id && $0.name == marker })

        manager.removeCustomServer(id: added.id)
        let afterRemoval = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: NotificationCenter())
        #expect(!afterRemoval.customServers.contains { $0.id == added.id })
        #expect(Set(afterRemoval.servers.filter { !$0.isCustom }.map(\.id)) == originalCatalogIDs)
    }
}
