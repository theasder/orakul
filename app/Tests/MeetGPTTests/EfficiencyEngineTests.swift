import Testing
import Foundation
@testable import MeetGPT

/// The Efficiency Engine's client side. The renderer is generic by design — the
/// server's contract table decides which fields exist, so hardcoding ten layouts
/// in Swift would drift the first time a contract changed. These tests pin the
/// generic behaviour against real payload shapes from each contract.
@Suite("Efficiency Engine rendering")
struct EfficiencyEngineRenderTests {
    private func decode(_ json: String) throws -> EfficiencyEngineService.FollowUp {
        try JSONDecoder().decode(EfficiencyEngineService.FollowUp.self, from: Data(json.utf8))
    }

    /// A close_deal payload as the server returns it.
    private let dealJSON = """
    {"goalType":"close_deal","label":"Close the deal",
     "fields":{"next_step":{"owner":"Dana","date":"2026-08-04"},
               "pricing_state":"Hold at 8% with quarterly billing",
               "objections":["procurement timeline","liability cap"],
               "single_ask":"Send the revised order form to Acme"},
     "actionItems":[{"title":"Send the revised order form","owner":"Dana","due":"2026-08-04",
                     "ask":"Send the revised order form to Acme",
                     "efficiency":{"score":1,"missing":[],"reasons":[]}},
                    {"title":"Circle back with the CFO","owner":null,"due":null,"ask":null,
                     "efficiency":{"score":0.28,"missing":["owner","date","unambiguous-ask"],
                                   "reasons":["no-owner","no-date","vague:circle-back"]}}],
     "efficiencyScore":0.64,"model":"gpt-4o-mini"}
    """

    @Test("decodes the per-goal fields without a Swift type per contract")
    func decodesDynamicFields() throws {
        let followUp = try decode(dealJSON)
        #expect(followUp.goalType == "close_deal")
        #expect(followUp.fields.count == 4)
        #expect(followUp.actionItems.count == 2)
        #expect(followUp.efficiencyScore == 0.64)
    }

    @Test("renders a record field as key/value pairs, not as JSON")
    func rendersRecord() throws {
        let out = EfficiencyEngineService.render(try decode(dealJSON))
        #expect(out.contains("Next step:"))
        #expect(out.contains("Dana"))
        #expect(out.contains("2026-08-04"))
        #expect(!out.contains("{"))
    }

    @Test("humanizes snake_case field names from the contract table")
    func humanizesNames() {
        #expect(EfficiencyEngineService.humanize("next_step") == "Next step")
        #expect(EfficiencyEngineService.humanize("recurring_themes") == "Recurring themes")
        #expect(EfficiencyEngineService.humanize("jtbd") == "Jtbd")
        #expect(EfficiencyEngineService.humanize("") == "")
    }

    @Test("honours the server's field order so the actionable field leads")
    func honoursFieldOrder() throws {
        // Alphabetical would put `objections` above `next_step`, burying the
        // thing the user has to act on. The order comes from the contract.
        let ordered = EfficiencyEngineService.render(
            try decode(dealJSON),
            fieldOrder: ["next_step", "pricing_state", "objections", "single_ask"])
        let next = try #require(ordered.range(of: "Next step"))
        let objections = try #require(ordered.range(of: "Objections"))
        #expect(next.lowerBound < objections.lowerBound)
    }

    @Test("falls back to a stable order when contracts have not loaded")
    func fallsBackToAlphabetical() throws {
        // Degraded but never wrong, and never nondeterministic — a dictionary has
        // no order, so without sorting the output would shuffle between runs.
        let a = EfficiencyEngineService.render(try decode(dealJSON))
        let b = EfficiencyEngineService.render(try decode(dealJSON))
        #expect(a == b)
    }

    @Test("names what each action item is missing, not just its score")
    func namesMissing() throws {
        // Scoring an item down without saying why leaves the user nothing to fix.
        let out = EfficiencyEngineService.render(try decode(dealJSON))
        #expect(out.contains("needs:"))
        #expect(out.contains("Owner"))
        #expect(out.contains("Unambiguous ask"))
    }

    @Test("a weak item renders a visibly shorter bar than a strong one")
    func barReflectsScore() {
        #expect(EfficiencyEngineService.bar(1) == "█████")
        #expect(EfficiencyEngineService.bar(0) == "░░░░░")
        #expect(EfficiencyEngineService.bar(0.6) == "███░░")
        // Out-of-range input must not produce a malformed bar.
        #expect(EfficiencyEngineService.bar(-3).count == 5)
        #expect(EfficiencyEngineService.bar(99).count == 5)
    }

    @Test("an empty contract field reads as absent, never as the word null")
    func emptyFieldsReadAsAbsent() throws {
        let json = """
        {"goalType":"hiring","label":"Hiring",
         "fields":{"evidence":[],"missing_signals":[],"scorecard":null},
         "actionItems":[],"efficiencyScore":0,"model":null}
        """
        let out = EfficiencyEngineService.render(try decode(json))
        #expect(out.contains("_none recorded_"))
        #expect(!out.lowercased().contains(">null"))
        #expect(!out.contains(": null"))
        #expect(out.contains("No action items were supported"))
    }

    @Test("a retro payload renders different fields than a deal — the whole claim")
    func differentGoalDifferentFields() throws {
        let retro = """
        {"goalType":"retro","label":"Retrospective",
         "fields":{"kept":["pairing on migrations"],"dropped":["friday deploys"],
                   "experiments":[{"owner":"Rob","metric":"deploy failure rate"}],
                   "recurring_themes":["release checklist ignored","flaky tests"]},
         "actionItems":[],"efficiencyScore":0,"model":"gpt-4o-mini"}
        """
        let retroOut = EfficiencyEngineService.render(try decode(retro))
        let dealOut = EfficiencyEngineService.render(try decode(dealJSON))

        #expect(retroOut.contains("Recurring themes"))
        #expect(retroOut.contains("Experiments"))
        #expect(!retroOut.contains("Pricing state"))
        #expect(dealOut.contains("Pricing state"))
        #expect(!dealOut.contains("Recurring themes"))
    }

    @Test("multi-entry lists become bullets; a single entry stays inline")
    func listRendering() throws {
        let out = EfficiencyEngineService.render(try decode(dealJSON))
        // objections has two entries -> bulleted
        #expect(out.contains("  - procurement timeline"))
        // single_ask is a scalar -> inline on its own line
        #expect(out.contains("**Single ask:** Send the revised order form to Acme"))
    }

    @Test("survives a payload whose field types are not what the contract said")
    func survivesUnexpectedTypes() throws {
        // The server coerces, but the client must not crash if a shape slips
        // through — a follow-up is appended to a response the user already has.
        let json = """
        {"goalType":"planning","label":"Planning",
         "fields":{"commitments":"not a list","cut_list":[1,2,3],"revisit_date":true},
         "actionItems":[],"efficiencyScore":0,"model":null}
        """
        let out = EfficiencyEngineService.render(try decode(json))
        #expect(out.contains("Planning"))
        // A scalar where a list was declared still prints, rather than vanishing.
        #expect(out.contains("not a list"))
        // Numbers where strings were declared: three entries, so bulleted.
        #expect(out.contains("  - 1"))
        #expect(out.contains("  - 3"))
        // A bool where a date was declared.
        #expect(out.contains("yes"))
    }
}

@Suite("Efficiency Engine goal taxonomy")
struct EfficiencyEngineTaxonomyTests {
    @Test("the client can emit every goal the server contracts describe")
    func taxonomyCoversTenGoals() {
        // While this list held only the roadmap's six, the extractor coerced a
        // retro or design review to `planning` before the API saw it — so those
        // contracts existed server-side and were unreachable, silently.
        // test/goalTypeMirror.test.js pins this against goalContracts.js.
        #expect(DecisionLogService.goalTypes.count == 10)
        for goalType in ["one_on_one", "retro", "status_review", "design_review"] {
            #expect(DecisionLogService.goalTypes.contains(goalType), "\(goalType) is unreachable from the Mac app")
        }
    }

    @Test("goal types are unique and lower_snake_case, as the API requires")
    func taxonomyShape() {
        #expect(Set(DecisionLogService.goalTypes).count == DecisionLogService.goalTypes.count)
        for goalType in DecisionLogService.goalTypes {
            #expect(goalType == goalType.lowercased())
            #expect(!goalType.contains(" "))
        }
    }
}
