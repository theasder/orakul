# Claude desktop settings — parity sweep (backlog item 16)

*2026-08-10. Inventory of the Claude desktop settings surface (web-sourced, see
sources) against Cruxwing's five tabs (General · Transcription · AI · Connected
Apps · Account & Privacy), with a verdict per item — adopt / adapt / reject —
recorded so a rejected idea is not re-proposed cold. Same discipline as the
Fireflies gap doc (item 14).*

## The frame

Claude desktop is a general chat client; Cruxwing is a live-meeting co-pilot.
Several of Claude's settings solve problems Cruxwing does not have (multiple
chat profiles, a browsable extension marketplace) and miss ones it does (nothing
in a chat client is "recording"). So parity is not the goal — the goal is the
two or three settings whose absence a Cruxwing user would actually feel.

## The table

| Claude desktop setting | Cruxwing today | Verdict | Reason |
|---|---|---|---|
| **Global hotkey** (Option+Space summons the app) | none — you alt-tab from Zoom to Cruxwing | **ADOPT** | The highest-value gap. A meeting co-pilot's whole premise is that you are looking at the *call*, not at it. A global hotkey to start/stop recording and to summon the assistant without leaving Zoom is directly on-mission. Put it in General → During calls. |
| **Search conversations** (Cmd+K) | History list, no keyboard search | **ADAPT** | Add a "search history" shortcut over saved calls. Cheap, and a co-pilot accretes many calls fast. |
| **New chat** (Cmd+N) | "New call" button, no shortcut | **ADAPT** | A `⌘N` "new call" shortcut. Trivial, matches the muscle memory Claude/most apps set. |
| **Keyboard shortcuts panel** (rebindable) | Fixed shortcuts (⌥⌘1-3 panes, item 3) | **ADAPT** | Cruxwing already ships pane/record shortcuts; surface them in a Settings → General list (discoverability), rebinding is optional and lower value. |
| **Extensions — browse & install** (.mcpb marketplace, Developer mode) | Curated `MCPCatalog` connectors via OAuth | **REJECT (install model), ADAPT (gallery)** | Cruxwing's connector strategy is depth-not-breadth (item 14); a `.mcpb` install marketplace is the opposite and a security surface. But a *browsable connector gallery* (what's available, one-click connect) is worth adapting from the "Browse extensions" idea. |
| **Profiles** (name/icon/color, palette hotkey) | none — single workspace | **REJECT** | A meeting co-pilot is one-user-per-Mac; multiple identities add UI weight with no meeting use case. Revisit only if a shared-Mac / multi-account need appears. |
| **Appearance — theme** | Theme (Auto/Light/Dark) + reading text size | **ADOPTED** | Already shipped (items 2, and General → Appearance), and Cruxwing's reading-size control goes further. |
| **MCP data-access warnings / tool permissions** | Account & Privacy tab, outbound redaction (item 6), per-app mute | **ADOPTED / EXCEEDED** | Cruxwing's outbound redaction (cards, keys, JWTs, a user term list) and per-app mute are a *stronger* privacy posture than Claude's "be thoughtful about folders" note. Keep the copy in Account & Privacy that names it. |
| **Model selection** (in-chat picker) | Model selection by plan/tier | **ADOPTED** | Already present; Cruxwing gates it by entitlement, which a chat client does not need to. |
| **Voice mode** (newer Claude) | none | **REJECT (for now)** | A spoken assistant is post-MVP and has its own backlog (items 18, 22, barge-in) with an unresolved positioning question. Not a settings item until that ships. |

## Recommendation

**Adopt one thing that matters: the global hotkey.** It is the single setting
whose absence a live-call user feels every session (alt-tabbing out of the
meeting to reach the co-pilot). Everything else Cruxwing either already has
(theme, model, privacy — often stronger), can adapt cheaply (`⌘N` new call,
`⌘K` search history, a shortcuts list), or should reject on strategy (profiles,
a `.mcpb` marketplace, voice-until-post-MVP).

**Do not re-propose, with reasons above:** profiles, an extension marketplace /
`.mcpb` developer install, and voice-mode settings.

*Sources (Claude desktop settings, 2026): support.claude.com getting-started-with-local-mcp-servers,
deeplearningnerds.com claude-desktop-settings-explained, claudelab.net
claude-desktop-app-complete-guide-2026, beginnersinai.org claude-desktop-app.*
