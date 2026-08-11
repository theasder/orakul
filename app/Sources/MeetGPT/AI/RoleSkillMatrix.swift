import Foundation

/// The role-aware skill matrix: for each user job position (Founder/CEO, PM,
/// Sales AE, …) and each quick-prompt button, the best-fit MIT skills and a
/// distilled, role-specific method hint.
///
/// Produced by the role-skills assessment (10 positions × 12 buttons, ranked
/// from a 306-skill MIT pool and adversarially verified — see
/// `docs/role-skills-matrix.md`), bundled as `Resources/Skills/role-matrix.json`,
/// and layered onto the system prompt as the third skill layer:
/// base + call theme + **role** + button.
struct RolePosition: Codable, Identifiable, Equatable, Sendable {
    struct ButtonCell: Codable, Equatable, Sendable {
        let skills: [String]  // MIT skill names backing this cell (for provenance/UI)
        let hint: String      // role-specific method addition for this button
    }

    let id: String            // e.g. "product-manager"
    let label: String         // e.g. "Product Manager"
    let symbol: String        // SF Symbol for the picker row
    let buttons: [String: ButtonCell]  // keyed by QuickPrompt id
}

enum RoleSkillMatrix {
    /// All positions, in the matrix's curated order. Empty if the resource is
    /// missing — every caller degrades to "no role layer", never crashes.
    static let positions: [RolePosition] = load()

    static func position(id: String?) -> RolePosition? {
        guard let id else { return nil }
        return positions.first { $0.id == id }
    }

    /// The guidance layer for a role (+ optionally the button being run):
    /// a role-framing line plus the role×button method hint when one exists.
    /// Sentinel id for "the user wrote their own role" (Config.userCustomRole).
    static let customRoleID = "custom"

    static func guidance(roleID: String?, promptID: String?) -> String? {
        if roleID == customRoleID {
            let text = Config.userCustomRole.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // No per-button hints for free-text roles — the description itself
            // is the frame.
            return "ROLE — The user describes their role as: \(text). Frame every output for that role's work."
        }
        guard let role = position(id: roleID) else { return nil }
        var lines = ["ROLE — The user is a \(role.label). Frame every output for that role's work."]
        if let promptID, let cell = role.buttons[promptID], !cell.hint.isEmpty {
            lines.append(cell.hint)
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Loading

    private struct MatrixFile: Codable { let positions: [RolePosition] }

    static func parse(_ data: Data) -> [RolePosition] {
        (try? JSONDecoder().decode(MatrixFile.self, from: data))?.positions ?? []
    }

    private static func load() -> [RolePosition] {
        guard let root = SkillResources.skillsDirectory else { return [] }
        let url = root.appendingPathComponent("role-matrix.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }
}
