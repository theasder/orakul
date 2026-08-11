# Design decisions — backlog items 6–13

Each item states the options considered, the one chosen, and why. Written to be
argued with: the rejected option is named, not implied, so disagreeing means
picking a different row rather than reconstructing the reasoning.

Nothing here is built yet.

---

## 6. Filter sensitive data out of prompts

| Option | Verdict |
|---|---|
| **A. Deterministic detectors on the assembled request** | **Chosen** |
| B. A local ML classifier | Rejected |
| C. Rely on the provider's own redaction | Rejected |

**Chosen: A.** Card numbers, government IDs, API keys and credentials have
strong structural signatures — Luhn, key prefixes, entropy — so patterns do this
job well, offline, deterministically, and testably. B costs a model download and
per-request latency for the same job, and a probabilistic filter over a privacy
promise is the wrong trade: the failure is silent and unauditable. C is not a
control we own; "the vendor says they redact" cannot be verified or demonstrated
to a customer.

**The decision that actually matters** is *where* it runs, not what detects.
It must sit at the single point where the outbound request is assembled — not
per-surface — because a filter attached to surfaces is bypassed by the next
caller someone adds. That is also what makes the acceptance criterion
("detection runs on the assembled request") mechanically enforceable rather than
a convention.

**Settled 2026-08-08 by the user: REDACT AND PROCEED**, with a visible marker —
not block. So a detection never stops the send; it removes the matched span and
marks the request so the user can see what the model did not get. That makes the
false-positive path recoverable (the answer still arrives, slightly poorer)
rather than a dead end, and it keeps the per-session correction in the
acceptance criteria meaningful — you correct a redaction you can see, on an
answer you already have.

---

## 7. Answer styles

| Option | Verdict |
|---|---|
| **A. A prompt-assembly parameter** | **Chosen** |
| B. A post-hoc rewrite pass | Rejected |
| C. A per-model preset | Rejected |

**Chosen: A**, which the spec already indicated. B doubles cost and latency on
every answer and — worse — a rewrite cannot be trusted to preserve a structural
contract: asked to make a DACI "concise", a rewriter drops the D. C ties a
reading preference to a model choice, so switching model silently changes voice.

**Constraint:** style composes with the workflow contract and never overrides
it. Concise-DACI is a shorter DACI, not prose.

---

## 8. Socratic mode — the question the spec asked to settle first

| Option | Verdict |
|---|---|
| A. An answer style, i.e. a fourth entry beside concise/explanatory/formal | Rejected |
| **B. A separate mode** | **Chosen** |

**Chosen: B, and this is the load-bearing decision of the set.**

A style changes how an answer *reads*. Socratic changes *whether you get an
answer at all*. Putting it in the style picker produces a list where three
entries adjust tone and the fourth withholds the deliverable — the same class of
mistake as a button that means two things, which item 1 existed to remove.

Two of the spec's own acceptance criteria only make sense for a mode: a bound on
how long it may withhold a direct answer, and one keystroke to break out. Neither
has any meaning for "formal".

**Consequence:** items 7 and 8 are built separately and do not share a control.
The failure case the spec named — building it twice — is avoided by them being
genuinely different things, not by merging them.

---

## 9. Reflection after the call

| Option | Verdict |
|---|---|
| **A. Re-run the blind-spot pipeline post-call over the whole transcript** | **Chosen** |
| B. A new pass with its own prompt and its own judge | Rejected |

**Chosen: A.** The blind-spot machinery is already evidence-bound and judged,
and the hardest acceptance criterion — "a call with nothing worth saying
produces nothing" — is exactly what that judge already enforces. B means a
second judge, which will drift from the first, and then two definitions of
"grounded" exist in one product.

**What is genuinely new** is not the analysis but the *deduplication*: the
artefact must never restate a summary bullet. That is the work, and it belongs
against the finished summary rather than inside the judge.

**Note:** post-call is also where the whole-file re-transcription now lands
(32% more accurate than the live chunked transcript). Reflection should read the
re-transcribed text, not the live one — otherwise the most careful pass in the
product runs on the least accurate transcript.

---

## 10. Tool use from ordinary prompts and blind spots

| Option | Verdict |
|---|---|
| A. A full agentic loop — the model plans and calls freely | Rejected |
| **B. One bounded round: the model may request reads, results re-enter once** | **Chosen** |
| C. Not at all | Rejected |

**Chosen: B.** A has unbounded latency and cost, which collides directly with
the spec's latency ceiling on the live path. B is enough for the actual need
("check the ticket before answering") and its cost is knowable in advance.

**Blind spots take reads only post-call, or with a hard timeout.** A blind spot
arriving after the room has moved on is noise, and the spec says so.

**Reuse `MCPImportToolPolicy` for read/write classification.** A second
classifier is how "read-only" ends up meaning two different things — and the
existing one is already fail-closed against write-shaped names.

---

## 11. Internet search

| Option | Verdict |
|---|---|
| **A. A search provider, explicit and metered, in three named lanes** | **Chosen** |
| B. `:online` model routing | Rejected |
| C. Do not build it | Rejected |

**Chosen: A**, scoped to fact-check of public claims, pre-call briefs, and the
research runs already metered as grounded cycles. Not a general background
capability. B hides the search inside a model call, so there is no source list
and no way to label a web-checked claim differently — both of which the spec
requires. C leaves fact-check unable to evaluate any claim about the world,
which is the hole that prompted the item.

**The part I will not sequence differently:** the marketing promise "verified
only against what you attach" must change in the **same** commit as the
capability. Shipping first and updating copy later means the page states
something false about where data goes, for as long as the gap lasts.

---

## 12. Token-maxxing mode

| Option | Verdict |
|---|---|
| **A. Per-request opt-in, cost shown before the send** | **Chosen** |
| B. A persistent setting | Rejected |
| C. Auto-escalate when the context is large | Rejected |

**Chosen: A**, as the spec indicates. B turns a deliberate spend into a default
someone forgets is on. C is the worst of the three: it spends the most money
exactly when the user is least expecting it, on the longest call.

**Gate on the catalogue entry**, not on a hardcoded model list — the app already
knows which models declare large context windows, and a second list would
diverge.

---

## 13. Product analytics

| Option | Verdict |
|---|---|
| **A. Extend the existing funnel endpoint, with the event list checked in** | **Chosen** |
| B. A third-party analytics SDK | Rejected |

**Chosen: A.** B is disqualified by what this product is: a meeting recorder. A
third-party SDK means behavioural data about meetings leaving to another vendor,
the existing "Share anonymous usage data" opt-out would not govern it, and the
privacy page would need a new subprocessor. That is a large promise change to buy
a dashboard.

Extending what exists keeps one opt-out, one audit surface, and one place a
reader can check what is collected.

**The event list is checked in beside the code.** Not for tidiness: it is the
only way a reader can see what is collected without reading every call site, and
the acceptance criteria ask for exactly that.

---

## Sequencing

If these are agreed, the order I would build them in — cheapest-with-clearest-
payoff first, and dependencies respected:

1. **7 (answer styles)** — small, self-contained, immediately visible.
2. **9 (post-call reflection)** — reuses machinery that exists; pairs naturally
   with the whole-file re-transcription already measured.
3. **6 (sensitive-data filter)** — the choke-point placement is the work; do it
   before 10 and 11 widen what leaves the machine.
4. **13 (analytics)** — needed to tell whether any of the rest is used.
5. **8 (Socratic mode)** — after 7, so the separation is concrete rather than
   theoretical.
6. **12 (token-maxxing)** — small once 6 exists.
7. **10 (tool use)** — the first item that changes what the model can do.
8. **11 (internet search)** — last: largest promise change, and it wants 6 and
   10 already in place.
