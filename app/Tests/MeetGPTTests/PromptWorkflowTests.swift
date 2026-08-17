import Testing
import Foundation
@testable import MeetGPT

/// Per-button workflows: every built-in prompt button has a grounding spec that
/// only names real catalog servers, the anti-fabrication buttons carry a refine
/// audit, and the pure helpers behave.
@Suite("Prompt workflows")
struct PromptWorkflowTests {
    @Test("every built-in prompt button has a workflow spec")
    func fullCoverage() {
        for prompt in QuickPrompts.all {
            #expect(PromptWorkflows.spec(for: prompt.id) != nil, "missing workflow for \(prompt.id)")
            #expect(PromptWorkflows.spec(for: prompt) == PromptWorkflows.spec(for: prompt.id))
        }
    }

    @Test("custom and follow-up prompts infer every supported connected-source intent")
    func customIntentInference() {
        let calendar = PromptWorkflows.spec(for: .custom(
            icon: "🗓️", title: "Find a time slot", prompt: "Check calendar availability."))
        #expect(calendar.googleServices == [.calendar])
        #expect(calendar.servers.isEmpty)

        let documents = PromptWorkflows.spec(for: .custom(
            icon: "📚", title: "Knowledge lookup", prompt: "Search docs, sheets, and the company wiki."))
        #expect(documents.servers.isSuperset(of: ["notion", "atlassian"]))
        // Drive joins the document sources: a PDF spec next to the Doc used
        // to be invisible because search was pinned to two Google mime types.
        #expect(documents.googleServices == [.docs, .sheets, .drive])
        #expect(documents.includeTeam) // Confluence

        let meetings = PromptWorkflows.spec(for: .custom(
            icon: "🎙️", title: "Prior conversation", prompt: "Find what was said in old transcripts."))
        #expect(meetings.servers == ["fireflies", "zoom"])

        let tasks = PromptWorkflows.spec(for: .custom(
            icon: "✅", title: "Project status", prompt: "Review tickets, backlog, and pull requests."))
        #expect(tasks.servers.isSuperset(of: ["linear", "asana", "atlassian"]))
        #expect(tasks.queryStrategy == .topics)
        #expect(tasks.includeTeam) // token connectors

        let crm = PromptWorkflows.spec(for: .custom(
            icon: "🤝", title: "Customer renewal", prompt: "Review the CRM account and sales pipeline."))
        #expect(crm.servers.isSuperset(of: ["hubspot", "affinity", "attio", "intercom", "zapier"]))

        let incidents = PromptWorkflows.spec(for: .custom(
            icon: "🚨", title: "Incident review", prompt: "Find outage risks and Sentry errors."))
        #expect(incidents.servers.isSuperset(of: ["sentry", "linear", "atlassian"]))
        #expect(incidents.queryStrategy == .topics)

        let teamChat = PromptWorkflows.spec(for: QuickPrompt(
            id: "followup-1", icon: "💬", title: "Slack threads",
            tooltip: "", prompt: "Search team chat messages in the launch channel."))
        #expect(teamChat.includeTeam)
        #expect(teamChat.sourceIntents == [.teamChat])
    }

    @Test("custom intent inference unions title and body sources deterministically")
    func combinedCustomIntentInference() {
        let prompt = QuickPrompt.custom(
            icon: "🔭", title: "Customer meeting risks",
            prompt: "Compare the call transcript with CRM accounts, project tickets, and incident errors.")
        let first = PromptWorkflows.spec(for: prompt)
        let second = PromptWorkflows.spec(for: prompt)

        #expect(first == second)
        #expect(first.sourceIntents.isSuperset(of: [.meetings, .tasks, .crm, .incidents]))
        #expect(first.servers.isSuperset(of: ["fireflies", "zoom", "linear", "asana", "atlassian",
                                                "hubspot", "affinity", "attio", "intercom", "zapier", "sentry"]))
    }

    @Test("unknown or style-only custom prompts stay transcript-only")
    func customFallback() {
        let workflow = PromptWorkflows.spec(for: .custom(
            icon: "✨", title: "Polish this", prompt: "Make the output shorter and clearer."))

        #expect(workflow.servers.isEmpty)
        #expect(workflow.googleServices.isEmpty)
        #expect(!workflow.includeTeam)
        #expect(!workflow.includeLedger)
        #expect(workflow.sourceIntents.isEmpty)
        #expect(workflow.refine == nil)

        #expect(!PromptWorkflows.isRelevant(
            serverID: "notion", serverName: "Notion", toolText: "search documents",
            for: workflow))
    }

    @Test("adding servers preserves the rest of a workflow")
    func addingServers() {
        let base = PromptWorkflow(
            servers: ["notion"], includeTeam: true, includeLedger: true,
            queryStrategy: .claims, maxCharsPerSource: 1234, refine: "audit",
            googleServices: [.docs], sourceIntents: [.documents])
        let expanded = base.addingServers(["custom-vault", "notion"])

        #expect(expanded.servers == ["notion", "custom-vault"])
        #expect(expanded.googleServices == base.googleServices)
        #expect(expanded.sourceIntents == base.sourceIntents)
        #expect(expanded.includeTeam == base.includeTeam)
        #expect(expanded.includeLedger == base.includeLedger)
        #expect(expanded.queryStrategy == base.queryStrategy)
        #expect(expanded.maxCharsPerSource == base.maxCharsPerSource)
        #expect(expanded.refine == base.refine)
    }

    @Test("custom MCP relevance uses server and plain tool capability text")
    func customServerRelevance() {
        let docs = PromptWorkflows.spec(for: .custom(
            icon: "📚", title: "Find knowledge", prompt: "Look through internal documents."))
        #expect(PromptWorkflows.isRelevant(
            serverID: "custom-acme", serverName: "Acme Knowledge Vault",
            toolText: "semanticSearch Search internal wiki pages", for: docs))

        let tasks = PromptWorkflows.spec(for: .custom(
            icon: "✅", title: "Project work", prompt: "Review open tasks."))
        #expect(PromptWorkflows.isRelevant(
            serverID: "custom-github", serverName: "GitHub",
            toolTexts: ["searchRepositories", "list_pull_requests Project milestones"], for: tasks))
        #expect(!PromptWorkflows.isRelevant(
            serverID: "custom-weather", serverName: "Weather",
            toolText: "get_temperature Forecast a city", for: tasks))

        // A curated id is relevant even before its tools have been loaded.
        #expect(PromptWorkflows.isRelevant(
            serverID: "LINEAR", serverName: "", toolText: "", for: tasks))
    }

    @Test("built-in workflows declare the direct Google reads they may use")
    func googleServices() {
        #expect(PromptWorkflows.spec(for: "agenda")?.googleServices.contains(.calendar) == true)
        #expect(PromptWorkflows.spec(for: "summary")?.googleServices.contains(.calendar) == true)
        #expect(PromptWorkflows.spec(for: "factcheck")?.googleServices == [.docs, .sheets, .drive])
        #expect(PromptWorkflows.spec(for: "rhetoric")?.googleServices.isEmpty == true)
    }

    @Test("specs only reference real catalog server ids")
    func serversAreReal() {
        // Credential-independent contract inventory includes providers such as
        // Asana which stay hidden until a tester build supplies its OAuth app.
        let known = Set(MCPCatalog.providerContracts.map(\.id))
        for (id, spec) in PromptWorkflows.byID {
            #expect(spec.servers.isSubset(of: known), "\(id) names unknown servers: \(spec.servers.subtracting(known))")
            #expect(!spec.servers.isEmpty, "\(id) has an empty server set")
        }
    }

    @Test("only anti-fabrication buttons carry an inline refine")
    func refineAssignment() {
        // A6: tasks/summary moved to typed artifacts with ArtifactValidator +
        // targeted repair; the generic refine hook stays available for A5.
        //
        // `commitments` uses it deliberately. That button asserts what a named
        // person promised and whether they dropped it — a fabricated line there
        // is an accusation, not a wasted paragraph — so it pays for a second
        // pass. Every other button must earn its way onto this list, because
        // refine costs an extra model call per press.
        let refineAllowed: Set<String> = ["commitments"]
        for (id, spec) in PromptWorkflows.byID where !refineAllowed.contains(id) {
            #expect(spec.refine == nil, "\(id) unexpectedly carries an inline refine")
        }
        for id in refineAllowed {
            #expect(PromptWorkflows.spec(for: id)?.refine != nil, "\(id) should carry its refine")
        }
        // Answer runs with a reduced per-source budget.
        #expect((PromptWorkflows.spec(for: "answer")?.maxCharsPerSource ?? 0) <= 2000)
    }

    @Test("grounding query prefers the goal, falls back to the transcript tail")
    func groundingQuery() {
        #expect(PromptWorkflows.groundingQuery(goal: "close the Q3 renewal", recentTranscript: "irrelevant") == "close the Q3 renewal")
        let fallback = PromptWorkflows.groundingQuery(goal: "   ", recentTranscript: "we discussed the migration timeline")
        #expect(fallback.contains("migration timeline"))
        #expect(PromptWorkflows.groundingQuery(goal: "", recentTranscript: "").isEmpty)
    }

    @Test("grounding renders as a cited context block")
    func renderGrounding() {
        #expect(PromptWorkflows.renderGrounding([]).isEmpty)
        let block = PromptWorkflows.renderGrounding([
            GroundingSnippet(serverName: "Linear", toolName: "search", text: "CRX-42 open")
        ])
        #expect(block.contains("[Linear] CRX-42 open"))
    }

    @Test("continuity buttons ground in the team's own Decision Ledger (A9)")
    func ledgerFlags() {
        for id in ["dispute", "unresolved", "logdecision", "agenda", "summary"] {
            #expect(PromptWorkflows.spec(for: id)?.includeLedger == true, "\(id) should include the ledger")
        }
        // Latency-sensitive and non-continuity buttons stay ledger-free.
        for id in ["answer", "rhetoric", "brainstorm"] {
            #expect(PromptWorkflows.spec(for: id)?.includeLedger == false, "\(id) should not include the ledger")
        }
    }

    @Test("precision query strategies (A4): claims for factcheck, topics for trackers, goal elsewhere")
    func queryStrategies() {
        #expect(PromptWorkflows.spec(for: "factcheck")?.queryStrategy == .claims)
        for id in ["tasks", "unresolved", "risks", "dispute", "logdecision"] {
            #expect(PromptWorkflows.spec(for: id)?.queryStrategy == .topics, "\(id) should search by topics")
        }
        // Latency-sensitive / broad buttons stay on the free goal query.
        for id in ["answer", "agenda", "brainstorm", "summary", "whattoask", "rhetoric", "advice"] {
            #expect(PromptWorkflows.spec(for: id)?.queryStrategy == .goal, "\(id) should use the goal query")
        }
        // Only non-goal strategies have a derivation prompt.
        #expect(PromptWorkflows.derivationSystemPrompt(for: .goal) == nil)
        #expect(PromptWorkflows.derivationSystemPrompt(for: .topics)?.isEmpty == false)
        #expect(PromptWorkflows.derivationSystemPrompt(for: .claims)?.isEmpty == false)
        #expect(PromptWorkflows.derivationSystemPrompt(for: .topics) != PromptWorkflows.derivationSystemPrompt(for: .claims))
    }

    @Test("derived queries are sanitized: NONE, multi-line, and rambles fall back")
    func sanitizeDerivedQuery() {
        #expect(PromptWorkflows.sanitizeDerivedQuery("\"CRX-42, pricing page, Acme renewal\"") == "CRX-42, pricing page, Acme renewal")
        #expect(PromptWorkflows.sanitizeDerivedQuery("NONE") == nil)
        #expect(PromptWorkflows.sanitizeDerivedQuery("none") == nil)
        #expect(PromptWorkflows.sanitizeDerivedQuery("  ") == nil)
        #expect(PromptWorkflows.sanitizeDerivedQuery("line one\nline two") == nil)
        #expect(PromptWorkflows.sanitizeDerivedQuery(String(repeating: "x", count: 400)) == nil)
    }
}

/// A9 — the ledger-as-context renderer: compact, capped, newest-first lines the
/// grounding block injects so buttons can flag reopened/contradicted decisions.
@Suite("Ledger grounding")
struct LedgerGroundingTests {
    private func decision(title: String, status: String = "decided",
                          decidedAt: String? = "2026-06-12T10:00:00.000Z",
                          statement: String? = nil, outcome: String? = nil) -> DecisionLogService.LedgerDecision {
        DecisionLogService.LedgerDecision(
            id: UUID().uuidString, title: title, statement: statement, status: status,
            goalType: "planning", decidedAt: decidedAt,
            createdAt: "2026-06-01T09:00:00.000Z", rationale: nil, outcome: outcome)
    }

    @Test("renders date, status, title, statement, and outcome")
    func renderShape() {
        let block = DecisionLogService.renderForGrounding([
            decision(title: "Migrate to Postgres", statement: "Move off SQLite for prod.", outcome: "Shipped"),
            decision(title: "Hire a staff SRE", status: "proposed", decidedAt: nil)
        ], cap: 3000)
        #expect(block.contains("• 2026-06-12 [decided] Migrate to Postgres — Move off SQLite for prod. (outcome: Shipped)"))
        #expect(block.contains("• 2026-06-01 [proposed] Hire a staff SRE"))   // falls back to createdAt
        #expect(block.hasPrefix("Your team's logged decisions"))
    }

    @Test("respects the character cap and returns empty for no decisions")
    func capAndEmpty() {
        #expect(DecisionLogService.renderForGrounding([], cap: 3000).isEmpty)
        let many = (0..<50).map { decision(title: "Decision number \($0) with a reasonably long title") }
        let block = DecisionLogService.renderForGrounding(many, cap: 600)
        #expect(block.count <= 700)   // header + budgeted lines only
        #expect(block.contains("Decision number 0"))
        #expect(!block.contains("Decision number 49"))
    }
}
