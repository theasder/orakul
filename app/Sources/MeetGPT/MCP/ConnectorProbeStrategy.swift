import Foundation

/// What to ask each connector, and what to read its answer FOR.
///
/// Before this, `researchOne(server:goal:)` sent the call's goal verbatim to
/// every connector — Notion, Sentry, HubSpot and PostHog all received the same
/// string. That wastes the only advantage a connector has: each one knows
/// something specific that the room does not, and the useful question is
/// different for every one of them. Asking a bug tracker the same thing you ask
/// a CRM gets a generic answer from both.
///
/// Two parts per connector:
///   `query`   — how to turn the call into that system's search terms
///   `readFor` — the instruction attached to the snippet, so the model knows
///               what the result is evidence OF rather than treating it as more
///               background text
///
/// `readFor` is the half that changes behaviour most. A HubSpot snippet without
/// it is "some notes about a customer"; with it, it is "the objections this buyer
/// raised last time, which nobody has mentioned today".
enum ConnectorProbeStrategy: Sendable {
    struct Probe: Sendable, Equatable {
        /// Extra search terms appended to the goal, biasing the connector's own
        /// search toward what it uniquely holds.
        let queryHint: String
        /// Why this source was pulled — becomes `[read for: …]` on the snippet.
        let readFor: String
        /// Themes where this connector is worth spending a probe on. Empty means
        /// always relevant.
        let strongFor: Set<CallTheme>
    }

    /// Keyed on `MCPServerDescriptor.id` and `TeamConnectors` raw values.
    static let byServerID: [String: Probe] = [
        "hubspot": Probe(
            queryHint: "objections, stalled deals, close date changes, prior pricing discussion",
            readFor: "objections this buyer or similar deals raised before, and any close date that has already slipped — flag anything not mentioned on this call",
            strongFor: [.sales, .customerSuccess, .strategy]),
        "attio": Probe(
            queryHint: "account history, previous conversations, deal stage changes",
            readFor: "what changed on this account since the last conversation, especially a sponsor who moved or a stage that went backwards",
            strongFor: [.sales, .customerSuccess]),
        "affinity": Probe(
            queryHint: "relationship history, introductions, account interactions, deal changes",
            readFor: "who actually has the strongest relationship with this account, what the last interaction established, and whether the deal changed since then",
            strongFor: [.sales, .customerSuccess, .strategy]),
        "fireflies": Probe(
            queryHint: "previous meeting with these attendees, commitments made, action items",
            readFor: "what these same people promised in earlier calls — surface any promise that has gone quiet rather than been completed",
            strongFor: []),
        "zoom": Probe(
            queryHint: "previous meeting recording, AI Companion summary, decisions and action items",
            readFor: "what the previous Zoom conversation with these people decided or promised, including a commitment that this call is silently revising",
            strongFor: []),
        "gmail": Probe(
            queryHint: "related email thread, prior commitments, objections, dates and approvals",
            readFor: "the written commitment or objection in email that the room has omitted, especially an agreed date, owner, or approval",
            strongFor: [.sales, .customerSuccess, .legal]),
        "linear": Probe(
            queryHint: "open issues, in-progress work, recent bugs for the feature discussed",
            readFor: "whether work being promised on this call is already open, already blocked, or contradicted by an existing issue",
            strongFor: [.engineering, .product, .standup, .strategy]),
        "atlassian": Probe(
            queryHint: "open tickets, specs, decision pages for the topic discussed",
            readFor: "the written spec or ticket that contradicts what was just said out loud",
            strongFor: [.engineering, .product, .strategy, .legal]),
        "notion": Probe(
            queryHint: "spec, PRD, decision doc, meeting notes on the topic",
            readFor: "the document that already decided this, or that states something different from what the room believes",
            strongFor: []),
        "asana": Probe(
            queryHint: "tasks, owners, due dates for the workstream discussed",
            readFor: "whether the work discussed already has an owner and a date somewhere, and whether that date is realistic given what was said",
            strongFor: [.strategy, .standup, .product]),
        "sentry": Probe(
            queryHint: "error rate, recent regressions, unresolved issues for the feature",
            readFor: "whether the thing being promised or demoed is actually stable right now — an error rate nobody in the room has looked at",
            strongFor: [.engineering, .product, .customerSuccess]),
        "intercom": Probe(
            queryHint: "recent support conversations, complaints, feature requests",
            readFor: "what customers have been reporting about this area, especially complaints that contradict the optimism in the room",
            strongFor: [.customerSuccess, .product, .sales]),

        // Analytics is the only category that can contradict the room WITH DATA.
        // A discovery call will happily conclude that users love a feature; the
        // number of people who used it last week is not in the transcript and
        // settles the argument.
        "posthog": Probe(
            queryHint: "feature usage, funnel conversion, retention for the product area discussed",
            readFor: "actual usage of the feature being discussed — if the room is asserting that users want or love something, check whether behaviour agrees, and say so plainly when it does not",
            strongFor: [.product, .strategy, .customerSuccess, .leadership]),
        "amplitude": Probe(
            queryHint: "event volume, conversion funnel, cohort retention for the flow discussed",
            readFor: "the conversion or retention numbers for the flow under discussion — quote the number, and flag any claim in the room that the data does not support",
            strongFor: [.product, .strategy, .sales]),
        "google-analytics": Probe(
            queryHint: "sessions, active users, conversion and event counts for the feature discussed",
            readFor: "what GA4 actually recorded for the flow under discussion — quote the number, and if the room is asserting usage or demand the data does not support, say so plainly",
            strongFor: [.product, .strategy, .sales, .customerSuccess]),
        "mixpanel": Probe(
            queryHint: "event trends, funnel drop-off, active users for the feature discussed",
            readFor: "where users actually drop off in the flow being discussed, versus where the room assumes they do",
            strongFor: [.product, .strategy]),

        "zapier": Probe(
            queryHint: "records related to the accounts and topics discussed",
            readFor: "anything from the connected systems that contradicts or completes what was said",
            strongFor: []),
    ]

    /// Team token connectors (Slack, Confluence) keyed on their
    /// raw values — a chat search answers a different question than a CRM.
    static let byTeamService: [String: Probe] = [
        "slack": Probe(
            queryHint: "recent discussion, decisions, complaints about the topic",
            readFor: "what the team has been saying about this in channel — especially a concern raised there that nobody has repeated on this call",
            strongFor: []),
        "confluence": Probe(
            queryHint: "specs, runbooks, decision records on the topic",
            readFor: "the written record that contradicts what the room believes",
            strongFor: [.engineering, .strategy, .legal]),
    ]

    static func probe(forServerID id: String) -> Probe? { byServerID[id] }
    static func probe(forTeamService raw: String) -> Probe? { byTeamService[raw] }

    /// The query actually sent to the connector. The goal leads, because it is
    /// what the user cares about; the hint follows to bias the connector's own
    /// ranking. Bounded — several connector search APIs degrade badly on long
    /// queries, matching on stray terms rather than the subject.
    static func query(goal: String, serverID: String, maxChars: Int = 320) -> String {
        let base = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hint = byServerID[serverID]?.queryHint ?? byTeamService[serverID]?.queryHint else {
            return String(base.prefix(maxChars))
        }
        guard !base.isEmpty else { return String(hint.prefix(maxChars)) }
        return String("\(base) — \(hint)".prefix(maxChars))
    }

    /// Ordering hint: connectors that are strong for this call's field first, so
    /// a tier that only affords two probes spends them where the field says the
    /// answer lives. Stable within each group, so the order never shuffles
    /// between wakes on the same call.
    static func prioritized(_ ids: [String], for theme: CallTheme) -> [String] {
        let strong = ids.filter { byServerID[$0]?.strongFor.contains(theme) ?? false }
        let rest = ids.filter { !strong.contains($0) }
        return strong + rest
    }
}
