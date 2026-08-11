import Foundation
import Testing
@testable import MeetGPT

/// Rendering the team's decision ledger into grounding text.
///
/// This string is prepended to prompts, so every character is paid for on every
/// call that uses it. Two failure modes, opposite and both silent: render too
/// much and the budget the caller passed is a lie, render a bare header and the
/// model is told "here are your decisions" followed by nothing — which invites
/// it to invent some.
///
/// Layered on one base fact — a decision renders as a dated, status-tagged line
/// — with each later test adding a dimension: which date, which optional
/// fields, and what the cap actually bounds.
@Suite("Decision ledger grounding text")
struct DecisionLedgerRenderTests {

    /// Built by decoding, so the tests also pin the wire shape the ledger API
    /// returns rather than a hand-made value that could drift from it.
    private func decision(
        id: String = "d1",
        title: String = "Launch moves to September",
        statement: String? = nil,
        status: String = "accepted",
        decidedAt: String? = nil,
        createdAt: String = "2026-08-01T09:00:00Z",
        outcome: String? = nil
    ) throws -> DecisionLogService.LedgerDecision {
        var fields: [String] = [
            "\"id\":\"\(id)\"", "\"title\":\"\(title)\"",
            "\"status\":\"\(status)\"", "\"goalType\":\"decision\"",
            "\"createdAt\":\"\(createdAt)\"",
        ]
        if let statement { fields.append("\"statement\":\"\(statement)\"") }
        if let decidedAt { fields.append("\"decidedAt\":\"\(decidedAt)\"") }
        if let outcome { fields.append("\"outcome\":\"\(outcome)\"") }
        return try JSONDecoder().decode(
            DecisionLogService.LedgerDecision.self,
            from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    private func render(_ decisions: [DecisionLogService.LedgerDecision],
                        cap: Int = 4_000) -> String {
        DecisionLogService.renderForGrounding(decisions, cap: cap)
    }

    // MARK: - Base

    @Test("a decision renders as one dated, status-tagged line")
    func rendersADecision() throws {
        let text = render([try decision()])
        #expect(text.contains("• 2026-08-01 [accepted] Launch moves to September"))
        #expect(text.hasPrefix("Your team's logged decisions"))
    }

    // MARK: - Layer: nothing to say means say nothing

    @Test("no decisions renders an empty string, not a lonely header")
    func emptyRendersNothing() {
        // A header with no decisions under it spends tokens to tell the model
        // that decisions exist — and then shows none, which is an invitation to
        // invent them.
        #expect(render([]).isEmpty)
    }

    @Test("a cap too small for even one decision renders nothing rather than a header")
    func unaffordableRendersNothing() throws {
        // The floor is 400 characters, so this is genuinely testing the
        // truncation path and not the cap arithmetic.
        let long = String(repeating: "x", count: 500)
        #expect(render([try decision(title: long)], cap: 1).isEmpty)
    }

    // MARK: - Layer: which date, which fields

    @Test("the decided date wins over the created date")
    func prefersDecidedAt() throws {
        // When a decision was logged matters far less than when it was made —
        // the model is being asked whether today's discussion reopens it.
        let text = render([try decision(decidedAt: "2026-07-15T10:00:00Z",
                                        createdAt: "2026-08-01T09:00:00Z")])
        #expect(text.contains("2026-07-15"))
        #expect(!text.contains("2026-08-01"))
    }

    @Test("dates are trimmed to the day; no time of day reaches the prompt")
    func rendersDateOnly() throws {
        let text = render([try decision(createdAt: "2026-08-01T09:00:00Z")])
        #expect(!text.contains("T09:00"))
        #expect(!text.contains("Z]"))
    }

    @Test("statement and outcome appear when present")
    func rendersOptionalFields() throws {
        let text = render([try decision(statement: "Ship after the audit",
                                        outcome: "held")])
        #expect(text.contains("— Ship after the audit"))
        #expect(text.contains("(outcome: held)"))
    }

    @Test("absent or empty optionals leave no dangling punctuation")
    func omitsEmptyOptionals() throws {
        // The tell-tale of a naive template: "Title — (outcome: )".
        // Checked on the DECISION lines only: the header legitimately contains
        // an em dash of its own.
        for text in [render([try decision()]),
                     render([try decision(statement: "", outcome: "")])] {
            let decisionLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("• ") }
            #expect(!decisionLines.isEmpty)
            for line in decisionLines {
                #expect(!line.contains("—"), "dangling em dash: \(line)")
                #expect(!line.contains("(outcome:"), "dangling outcome: \(line)")
            }
        }
    }

    @Test("long statements and outcomes are clipped, not passed through whole")
    func clipsLongFields() throws {
        // One verbose decision must not crowd out the rest of the ledger.
        let text = render([try decision(statement: String(repeating: "s", count: 500),
                                        outcome: String(repeating: "o", count: 300))])
        #expect(!text.contains(String(repeating: "s", count: 141)), "statement not clipped")
        #expect(!text.contains(String(repeating: "o", count: 81)), "outcome not clipped")
        #expect(text.contains(String(repeating: "s", count: 140)))
    }

    // MARK: - Layer: what the cap bounds

    @Test("the rendered text stays within the caller's budget")
    func respectsTheCap() throws {
        let many = try (1...60).map { try decision(id: "d\($0)", title: "Decision number \($0)") }
        for cap in [500, 1_000, 2_000, 4_000] {
            let text = render(many, cap: cap)
            #expect(text.count <= cap, "cap \(cap) produced \(text.count) characters")
        }
    }

    @Test("a bigger budget includes more decisions, never fewer")
    func moreBudgetMeansMoreDecisions() throws {
        let many = try (1...60).map { try decision(id: "d\($0)", title: "Decision number \($0)") }
        var previous = 0
        for cap in [500, 1_000, 2_000, 4_000] {
            let lines = render(many, cap: cap).components(separatedBy: "\n").count
            #expect(lines >= previous, "cap \(cap) rendered fewer lines than a smaller cap")
            previous = lines
        }
    }

    @Test("truncation drops whole decisions, never half of one")
    func truncatesOnDecisionBoundaries() throws {
        // A half-written decision in the prompt is worse than an absent one:
        // the model reads it as fact.
        let many = try (1...40).map {
            try decision(id: "d\($0)", title: "Decision number \($0)",
                         statement: "A reasonably long statement for decision \($0)")
        }
        let text = render(many, cap: 900)
        for line in text.components(separatedBy: "\n").dropFirst() {
            #expect(line.hasPrefix("• "), "partial line rendered: \(line)")
            #expect(line.contains("["), "line lost its status tag: \(line)")
        }
    }

    @Test("decisions keep the order they arrived in — newest first")
    func preservesOrder() throws {
        let text = render([
            try decision(id: "a", title: "Newest decision"),
            try decision(id: "b", title: "Older decision"),
        ])
        let newest = try #require(text.range(of: "Newest decision"))
        let older = try #require(text.range(of: "Older decision"))
        #expect(newest.lowerBound < older.lowerBound)
    }
}
