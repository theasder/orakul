import Foundation
import MCP
import Testing
@testable import MeetGPT

@Suite("MCP one-click import safety")
struct MCPImportSafetyTests {
    private func tool(_ name: String,
                      description: String = "Returns matching context.",
                      readOnly: Bool? = nil,
                      destructive: Bool? = nil) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([:]),
            annotations: .init(
                readOnlyHint: readOnly,
                destructiveHint: destructive))
    }

    @Test("read tools survive snake, kebab and camel naming")
    func allowsPositiveReadShapes() {
        let safe = [
            "search_threads", "notion-fetch", "getRecord", "list_drafts",
            "read_file", "view-report", "check_compatibility", "run_report",
            "run_realtime_report",
        ]
        for name in safe {
            #expect(MCPImportToolPolicy.isSafeForImport(tool(name)),
                    "\(name) should be available for context import")
        }
    }

    @Test("write and destructive permutations are denied even when they also look readable")
    func rejectsMutatingNames() {
        let unsafe = [
            "create_issue", "update-page", "sendMessage", "post_comment",
            "append_block", "set_status", "assign_owner", "schedule_event",
            "upload_file", "trigger_workflow", "run_automation", "report_issue",
            "record_call", "delete_page", "remove_item", "archive_project",
            "purge_cache", "get_or_create_page", "search_then_update_record",
            "list_and_delete_messages", "mark_as_read", "search_and_reply",
            "get_then_resolve_issue", "read_and_acknowledge", "clear_cache_status",
        ]
        for name in unsafe {
            #expect(!MCPImportToolPolicy.isSafeForImport(tool(name)),
                    "\(name) must never appear under one-click Import")
        }
    }

    @Test("ambiguous tools fail closed")
    func ambiguousNamesAreHidden() {
        for name in ["do_thing", "process", "automation_v2", "calculator"] {
            #expect(!MCPImportToolPolicy.isSafeForImport(tool(name)))
        }
    }

    @Test("server annotations can veto but never smuggle a write tool through")
    func annotationsCannotWidenPolicy() {
        #expect(!MCPImportToolPolicy.isSafeForImport(
            tool("search_records", readOnly: false)))
        #expect(!MCPImportToolPolicy.isSafeForImport(
            tool("search_records", readOnly: true, destructive: true)))
        #expect(!MCPImportToolPolicy.isSafeForImport(
            tool("delete_records", readOnly: true, destructive: false)))
        #expect(MCPImportToolPolicy.isSafeForImport(
            tool("search_records", readOnly: true, destructive: false)))
    }

    @Test("a harmless name cannot hide mutation language in its description")
    func descriptionCannotHideWrites() {
        let disguised = tool(
            "search_records",
            description: "Searches records and updates the selected result.",
            readOnly: true)
        #expect(!MCPImportToolPolicy.isSafeForImport(disguised))
    }

    @Test("filter returns only tools eligible for the import picker")
    func filterInventory() {
        let advertised = [
            tool("search_threads"),
            tool("create_draft"),
            tool("delete_thread"),
            tool("run_report"),
            tool("execute_zap"),
        ]
        #expect(MCPImportToolPolicy.filter(advertised).map(\.name)
                == ["search_threads", "run_report"])
    }

    @MainActor
    @Test("execution rejects an unsafe tool before connecting or calling it")
    func executionPathRechecksPolicy() async throws {
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(),
            notificationCenter: NotificationCenter())
        let server = try #require(MCPCatalog.builtIn.first)

        do {
            _ = try await manager.callImportToolText(
                server: server,
                tool: tool("get_or_create_page", readOnly: true),
                arguments: nil)
            Issue.record("unsafe import unexpectedly reached the connector")
        } catch let error as MCPConnectionError {
            guard case .unsafeImportTool(let name) = error else {
                Issue.record("wrong rejection: \(error.localizedDescription)")
                return
            }
            #expect(name == "get_or_create_page")
            #expect(manager.state(of: server.id) == .disconnected)
        }
    }
}

@Suite("MCP grounding identity isolation")
struct MCPGroundingIdentityIsolationTests {
    private func key(scope: UInt64) -> String {
        MCPResultCache.key(
            sourceID: "mcp:notion", tool: "notion-search",
            query: "Acme renewal", scope: scope)
    }

    @Test("identical provider queries in different identity scopes never collide")
    func scopedKeysDoNotCollide() {
        #expect(key(scope: 7) != key(scope: 8))
    }

    @MainActor
    @Test("account replacement rotates evidence and invalidates workflow caches")
    func accountReplacementRotatesScope() async {
        let center = NotificationCenter()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: center)
        let oldScope = manager.groundingCacheScope
        let oldRevision = manager.capabilityRevision
        let oldKey = key(scope: oldScope)
        await manager.groundingCache.store(oldKey, text: "Account A", serverID: "notion")

        WheesprSessionNotifications.postAccountContextChanged(center: center)

        #expect(manager.groundingCacheScope == oldScope + 1)
        #expect(manager.capabilityRevision == oldRevision + 1)
        let newKey = key(scope: manager.groundingCacheScope)
        #expect(await manager.groundingCache.fresh(newKey) == nil)

        // Simulate Account A's request completing after Account B was adopted.
        // It may physically store under the old namespace, but can never satisfy
        // Account B's scoped lookup.
        await manager.groundingCache.store(oldKey, text: "late Account A", serverID: "notion")
        #expect(await manager.groundingCache.fresh(newKey) == nil)
    }

    @MainActor
    @Test("disconnect rotates the cache before clearing provider authorization")
    func disconnectRotatesScope() async throws {
        let keychain = InMemoryKeychain()
        let server = try #require(MCPCatalog.builtIn.first { $0.id == "notion" })
        keychain.set(Data("cached-token".utf8), for: "mcp.token.notion")
        let manager = MCPConnectionManager(
            tokenStore: keychain, notificationCenter: NotificationCenter())
        await manager.loadPersistedAuthorization()
        let oldScope = manager.groundingCacheScope
        let oldRevision = manager.capabilityRevision

        await manager.disconnect(server)

        #expect(manager.groundingCacheScope == oldScope + 1)
        #expect(manager.capabilityRevision == oldRevision + 1)
        #expect(!manager.isAuthorized(server.id))
        #expect(key(scope: manager.groundingCacheScope) != key(scope: oldScope))
    }

    @MainActor
    @Test("rapid account changes each create a distinct namespace")
    func rapidAccountChangesCannotReuseEvidence() {
        let center = NotificationCenter()
        let manager = MCPConnectionManager(
            tokenStore: InMemoryKeychain(), notificationCenter: center)
        let start = manager.groundingCacheScope

        for _ in 0..<20 {
            WheesprSessionNotifications.postAccountContextChanged(center: center)
        }

        #expect(manager.groundingCacheScope == start + 20)
        #expect(Set((start...manager.groundingCacheScope).map { key(scope: $0) }).count == 21)
    }
}
