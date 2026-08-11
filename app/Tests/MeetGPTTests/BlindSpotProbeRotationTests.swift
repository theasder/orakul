import Testing
@testable import MeetGPT

@Suite("Blind-spot probe rotation")
struct BlindSpotProbeRotationTests {
    @Test("paid probes rotate through distinct workflows")
    func rotates() {
        let ids = (1...14).map(BlindSpotProbeRotation.probeID(at:))
        #expect(Set(ids).count == BlindSpotProbeRotation.paidProbeIDs.count)
        #expect(ids[0] == "brainstorm")
        #expect(ids[1] == "whattoask")
        #expect(ids[2] == "risks")
        #expect(ids[7] == "brainstorm") // wraps
    }

    @Test("every probe id has a curated PromptWorkflow and a lens brief")
    func workflowsExist() {
        for id in BlindSpotProbeRotation.paidProbeIDs {
            #expect(PromptWorkflows.spec(for: id) != nil, "missing workflow for \(id)")
            #expect(!BlindSpotProbeRotation.lensBrief(for: id).isEmpty)
            #expect(BlindSpotProbeRotation.lensBrief(for: id).contains("Probe lens:"))
        }
    }
}

    @Test("higher tiers fan out across more workflows per wake")
    func fanOutByTier() {
        #expect(BlindSpotProbeRotation.workflowCount(for: .free) == 1)
        #expect(BlindSpotProbeRotation.workflowCount(for: .pro) == 2)
        #expect(BlindSpotProbeRotation.workflowCount(for: .premium) == 3)
        #expect(BlindSpotProbeRotation.workflowCount(for: .ultra) == 4)

        let pro = BlindSpotProbeRotation.probeIDs(at: 1, count: 2)
        #expect(pro == ["brainstorm", "whattoask"])
        let premium = BlindSpotProbeRotation.probeIDs(at: 2, count: 3)
        #expect(premium == ["whattoask", "risks", "unresolved"])
        #expect(BlindSpotProbeRotation.probeIDs(at: 1, count: 3)
            == ["brainstorm", "whattoask", "risks"])
        let ultra = BlindSpotProbeRotation.probeIDs(at: 1, count: 4)
        #expect(ultra.count == 4)
        #expect(Set(ultra).count == 4)
        #expect(BlindSpotProbeRotation.lensBriefs(for: pro).contains("What To Ask"))
    }
