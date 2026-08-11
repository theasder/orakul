# Fireflies integration parity — gap analysis (backlog item 14)

*2026-08-10. Fireflies advertises "100+ apps"; the acceptance for this item says
explicitly **do not chase the count** — a long shallow tail is the competitor's
game, and depth is ours. So this table is not "what is missing"; it is "which
missing connector, added deeply, would win a meeting a shallow one would lose",
and whether an **official MCP server** makes that a config drop-in or a bespoke
build.*

## Two reframes that shrink the list before it starts

- **Video-conferencing is not a gap.** Fireflies integrates Meet / Teams /
  Webex / GoToMeeting / Lifesize because it needs a bot to *get into* the call.
  Cruxwing captures the call directly through ScreenCaptureKit — it is already
  inside every one of those meetings with no integration. Listing them as gaps
  would be measuring ourselves on the competitor's constraint, not ours.
- **The automation tail is already covered.** Zapier is a built-in connector,
  and its keywords already route Salesforce and "webhooks/automation". Fireflies'
  Custom row (Skyvia, Latenode, MindStudio, Keragon) is that same category — no
  native work is warranted for any of them.

What is left after those two cuts is a short, honest list of connectors that
would deepen what Cruxwing does in the room: reach the systems a team actually
discusses and acts on.

## Current catalogue (17 built-in, `MCP/MCPCatalog.swift`)

Notion · Fireflies · Linear · Asana · Atlassian (Jira & Confluence) · Intercom ·
Sentry · Zapier · Attio · PostHog · Amplitude · Mixpanel · HubSpot · Affinity ·
Zoom · Gmail · Google Analytics.

Strong already in: CRM (HubSpot, Attio, Affinity), issue/PM (Linear, Jira,
Asana), product analytics (PostHog, Amplitude, Mixpanel), support (Intercom),
eng (Sentry). Thin in: **team chat, enterprise docs/storage, the CRM leader.**

## The gap table

MCP status per the 2026 official/vendor-hosted list (sources below). Demand is
**inferred**, not measured — Cruxwing has no connector-request telemetry yet;
item 13's `funnel_events` is where that signal will eventually come from, and
this ranking should be re-cut against it once it exists.

| Missing app | Category | Official MCP? | Inferred demand | Verdict |
|---|---|---|---|---|
| **Slack** | Team chat | **Yes** (vendor-hosted) | Very high | **Quick win — do first.** Where meeting outcomes get posted and where the next decision is argued. An MCP drop-in. |
| **Salesforce** | CRM | **Yes** (vendor-hosted) | High | **Quick win.** The CRM leader; we have HubSpot/Attio/Affinity but not SF. Reachable via Zapier today, but native is deep. |
| **Airtable** | Flexible DB / PM | **Yes** (vendor-hosted) | Medium-high | **Quick win.** Common lightweight ops/PM store; MCP ready. |
| **Monday.com** | PM | **Yes** (vendor-hosted) | Medium | Quick win when the PM lane is the focus. |
| **Dropbox** | Storage | **Yes** (vendor-hosted) | Medium | Quick win for doc-grounding; MCP ready. |
| **Google Drive / Docs** | Storage / docs | **Yes, but gated** | Medium-high | **Deliberate tension.** `drive.readonly` was withdrawn to clear CASA (item 4); Google's own gated MCP is a *different* access path (user-picked files) and would sidestep that. Worth a scoped revisit, not a reflexive add. |
| **Microsoft 365** (Teams, SharePoint, OneDrive) | Chat + docs + storage | **No** (Outlook exists, gated; no Teams server) | High (enterprise) | **The one bespoke bet worth it.** Biggest enterprise gap and no MCP shortcut — a real build, justified only when enterprise is the target. |
| **Box** | Storage | Emerging (MCP-Apps launch partner, not clearly a server) | Low-medium | Wait for the vendor server; not bespoke-worthy now. |
| **Greenhouse / Lever / BambooHR** | ATS | No | Low (for a co-pilot) | Skip — recruiting-specific; narrow for a general meeting co-pilot. |
| **Redtail / Wealthbox / Supersales** | Niche CRM | No | Low | Skip — wealth-management vertical; revisit only if that vertical is chosen. |
| **Dialers** (OpenPhone, RingCentral, Aircall, Dialpad, Zoom Phone) | Telephony | No | Low-medium | Skip for now — Cruxwing already captures the call audio directly; the CRM write-back is the value, and that lands via the CRM connectors above. |

## Recommendation

**Add in this order, all official-MCP drop-ins:** Slack → Salesforce → Airtable →
(Monday, Dropbox as the PM/storage lanes warrant). That is four to five deep,
high-signal connectors that reach where teams actually chat, sell, and track —
the depth argument the acceptance asked for, not breadth.

**One bespoke bet, gated on strategy:** Microsoft 365. Only when enterprise is
the explicit target, because it is the only high-value gap with no MCP shortcut.

**Do NOT build:** video platforms (we are already in the call), the automation
tail (Zapier covers it), ATS/niche-CRM/dialers (narrow for a co-pilot).

*Sources (MCP availability, 2026): strac.io/blog/best-mcp-servers,
workos.com/blog/everything-your-team-needs-to-know-about-mcp-in-2026,
tokenmix.ai/blog/mcp-servers-list-2026-complete-directory, slack.com MCP guide,
support.airtable.com MCP docs.*
