import Testing
import Foundation
@testable import MeetGPT

/// Invariants over the whole vendored catalog, not over one parsed string.
///
/// These exist because the catalog is bulk-ingested from third-party repos and
/// `BundledSkillLibrary.load()` deliberately skips anything it cannot read — a
/// malformed skill ships silently instead of failing. Each check below caught a
/// real defect: 22 skills whose `description` parsed to a bare YAML block-scalar
/// indicator (and were therefore unrankable by `BundledSkillRelevance`), 268
/// names that kept their surrounding quotes, one upstream test fixture, and one
/// directory whose name disagreed with its `name` field.
@Suite("Bundled skill catalog")
struct BundledSkillCatalogTests {
    /// `a-z0-9` words joined by single hyphens — the Agent Skills naming rule,
    /// and what keeps a folder name usable as a stable id.
    private static let idPattern = try! NSRegularExpression(
        pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")

    /// Generous: the open standard caps `description` at 1024, but this app
    /// consumes skills rather than publishing them, and three vendored skills sit
    /// just above that with descriptions worth keeping intact. This bound only
    /// catches a runaway value — e.g. a body accidentally folded into the field.
    private static let maxDescriptionChars = 2_000

    @Test("the catalog loads at full size")
    func catalogSize() {
        #expect(BundledSkillLibrary.all.count >= 1_180)
    }

    @Test("every skill has a usable description")
    func descriptionsAreUsable() {
        for skill in BundledSkillLibrary.all {
            let description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!description.isEmpty, "\(skill.id) has no description — it can never win a route")
            #expect(
                description.count <= Self.maxDescriptionChars,
                "\(skill.id) description is \(description.count) chars")
        }
    }

    @Test("no description is a leftover YAML block-scalar indicator")
    func descriptionsAreNotScalarIndicators() {
        for skill in BundledSkillLibrary.all {
            let description = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                ![">", ">-", ">+", "|", "|-", "|+"].contains(description),
                "\(skill.id) description is the block indicator \(description) — the scalar was not read")
        }
    }

    @Test("no name or description keeps its surrounding quotes")
    func valuesAreUnquoted() {
        for skill in BundledSkillLibrary.all {
            for (field, value) in [("name", skill.name), ("description", skill.description)] {
                guard let first = value.first, first == "\"" || first == "'" else { continue }
                #expect(
                    !value.hasSuffix(String(first)),
                    "\(skill.id) \(field) is still quoted: \(value.prefix(40))")
            }
        }
    }

    @Test("every folder name is a valid skill id")
    func folderNamesAreValidIDs() {
        for skill in BundledSkillLibrary.all {
            let range = NSRange(skill.id.startIndex..., in: skill.id)
            #expect(
                Self.idPattern.firstMatch(in: skill.id, range: range) != nil,
                "\(skill.id) is not a valid skill id")
            #expect(skill.id.count <= 64, "\(skill.id) exceeds the 64-char id limit")
        }
    }

    /// Collisions are resolved by suffixing the upstream owner
    /// (`ab-testing` → `ab-testing-sickn33`), so the folder is either the name or
    /// the name plus a suffix. Anything else means the two drifted apart.
    @Test("each folder name agrees with its name field")
    func folderNamesAgreeWithNameField() {
        for skill in BundledSkillLibrary.all {
            #expect(
                skill.id == skill.name || skill.id.hasPrefix(skill.name + "-"),
                "\(skill.id) declares name '\(skill.name)'")
        }
    }

    @Test("every router seed resolves to a real skill")
    func routerSeedsResolve() {
        for (promptID, seeds) in BundledSkillRouter.map {
            for seed in seeds {
                #expect(
                    BundledSkillLibrary.skill(id: seed) != nil,
                    "\(promptID) seeds '\(seed)', which is not in the catalog")
            }
        }
    }

    @Test("router seeds are themselves rankable")
    func routerSeedsAreRankable() {
        for (promptID, seeds) in BundledSkillRouter.map {
            for seed in seeds {
                guard let skill = BundledSkillLibrary.skill(id: seed) else { continue }
                #expect(
                    !skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(promptID) seed '\(seed)' has no description — relevance ranks on it")
            }
        }
    }

    @Test("no skill id collides after quarantine")
    func idsAreUnique() {
        let ids = BundledSkillLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The catalog carries ~70 skills whose methodology is to take a real-world
    /// action — send mail, post to social, move funds, administer a server. None
    /// is a router seed, but `BundledSkillRelevance` can surface a non-preferred
    /// catalog skill, so a meeting that merely *mentions* email could pull one in.
    /// `rankable` is the set the ranker is allowed to see.
    @Test("critical-risk skills are excluded from the rankable set")
    func rankableExcludesCriticalRisk() {
        let rankable = BundledSkillLibrary.rankable
        #expect(!rankable.isEmpty)
        #expect(rankable.allSatisfy { $0.risk != .critical })

        let excluded = BundledSkillLibrary.all.count - rankable.count
        #expect(excluded > 0, "the catalog should still carry critical-risk skills")
        // They remain resolvable by id — this is a ranking gate, not a deletion.
        for skill in BundledSkillLibrary.all where skill.risk == .critical {
            #expect(BundledSkillLibrary.skill(id: skill.id) != nil)
        }
    }

    @Test("router seeds all survive the risk gate")
    func routerSeedsAreRankable2() {
        let rankableIDs = Set(BundledSkillLibrary.rankable.map(\.id))
        for (promptID, seeds) in BundledSkillRouter.map {
            for seed in seeds {
                #expect(
                    rankableIDs.contains(seed),
                    "\(promptID) seeds '\(seed)', which the risk gate excludes")
            }
        }
    }

    /// Backstop for the fail-closed default. `SkillRisk.unrecognized` keeps an
    /// unknown verdict out of the ranker, but silently gating a skill is a poor
    /// outcome too — if an ingest starts writing `risk: high`, that should be a
    /// build failure and a deliberate mapping decision, not a quiet exclusion.
    @Test("no shipped skill carries a risk value this build does not recognize")
    func noUnrecognizedRiskValues() {
        let offenders = BundledSkillLibrary.all
            .filter { $0.risk == .unrecognized }
            .map(\.id)
        #expect(
            offenders.isEmpty,
            "unrecognized risk: values — map them in SkillRisk or fix the frontmatter: \(offenders)")
    }

    /// Skills whose methodology performs a real-world action against a live
    /// account. Found rankable by a 2026-07-26 audit because neither carried a
    /// `risk:` field at all — the exact fail-open path `unrecognized` now closes.
    @Test("action-taking skills are barred from automatic injection")
    func actionTakingSkillsAreGated() {
        for id in ["google-workspace-cli", "baoyu-post-to-x"] {
            guard let skill = BundledSkillLibrary.all.first(where: { $0.id == id }) else {
                Issue.record("\(id) is missing from the catalog")
                continue
            }
            #expect(
                skill.risk.barsAutomaticInjection,
                "\(id) takes a real-world action and must never be ranked in")
            // Still resolvable by id — a gate, not a deletion.
            #expect(BundledSkillLibrary.skill(id: id) != nil)
        }
    }
}
