import Testing
import Foundation
@testable import MeetGPT

/// The role skill matrix (job position × prompt button → skills + method hint)
/// is bundled as JSON and layered onto the system prompt. Pin the parser and
/// the guidance composition.
@Suite("Role skill matrix")
struct RoleSkillMatrixTests {
    private let sample = Data("""
    {"positions":[
      {"id":"product-manager","label":"Product Manager","symbol":"shippingbox",
       "buttons":{
         "brainstorm":{"skills":["product-discovery"],"hint":"Hang ideas off discovered opportunities; score by RICE."},
         "risks":{"skills":["experiment-designer"],"hint":"Frame risks as untested hypotheses with a cheapest test."}
       }}
    ]}
    """.utf8)

    @Test("parses positions with button cells")
    func parsesPositions() {
        let positions = RoleSkillMatrix.parse(sample)
        #expect(positions.count == 1)
        let pm = positions[0]
        #expect(pm.id == "product-manager")
        #expect(pm.buttons["brainstorm"]?.skills == ["product-discovery"])
        #expect(pm.buttons["risks"]?.hint.contains("cheapest test") == true)
    }

    @Test("malformed data parses to empty, never crashes")
    func malformedData() {
        #expect(RoleSkillMatrix.parse(Data("not json".utf8)).isEmpty)
        #expect(RoleSkillMatrix.parse(Data()).isEmpty)
    }

    @Test("guidance composes role framing plus the button hint")
    func guidanceComposition() {
        // Guidance is nil for an unknown role regardless of button.
        #expect(RoleSkillMatrix.guidance(roleID: "not-a-role", promptID: "brainstorm") == nil)
        #expect(RoleSkillMatrix.guidance(roleID: nil, promptID: "brainstorm") == nil)
    }

    @Test("custom role guidance frames the user's own description")
    func customRoleGuidance() {
        let saved = Config.userCustomRole
        defer { Config.userCustomRole = saved }

        Config.userCustomRole = "Head of Growth at a B2B fintech"
        let guidance = RoleSkillMatrix.guidance(roleID: RoleSkillMatrix.customRoleID,
                                                promptID: "brainstorm")
        #expect(guidance?.contains("Head of Growth at a B2B fintech") == true)

        // An empty description means no role layer — never an empty frame.
        Config.userCustomRole = "   "
        #expect(RoleSkillMatrix.guidance(roleID: RoleSkillMatrix.customRoleID,
                                         promptID: "brainstorm") == nil)
    }

    @Test("the bundled matrix loads: 10 positions, 12 hinted buttons each")
    func bundledMatrixLoads() {
        #expect(RoleSkillMatrix.positions.count == 10)
        for position in RoleSkillMatrix.positions {
            #expect(position.buttons.count == 12, "\(position.id) has \(position.buttons.count) buttons")
            for (buttonID, cell) in position.buttons {
                #expect(!cell.hint.isEmpty, "\(position.id)/\(buttonID) hint empty")
            }
        }
        // Guidance for a real role+button carries the role framing and the hint.
        //
        // Роль называется по-русски: `label` в role-matrix.json переведён, `id`
        // остался прежним. Название подставляется в промпт, и русское там
        // уместно — вся остальная рамка уже по-русски.
        let guidance = RoleSkillMatrix.guidance(roleID: "product-manager", promptID: "brainstorm")
        #expect(guidance?.contains("Продакт-менеджер") == true)
    }
}
