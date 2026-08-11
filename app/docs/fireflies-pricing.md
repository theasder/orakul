# Fireflies pricing, and what it says about ours

Read from the live in-app `/upgrade` page 2026-08-09 (account is on Business).
Screenshots: `docs/fireflies-walkthrough/05-pricing-annual.jpg`,
`06-pricing-monthly.jpg`.

---

## Correction first: we already have annual

The premise for this investigation was that we do not offer yearly billing. We
do — `TARIFF_PLANS` in `cruxwing-api/functions/tariffs.js` has `pro-annual`,
`premium-annual` and `ultra-annual`, priced at ten monthly payments, and the
paywall model already decodes an `interval` field.

What we do not have is an annual **offer**. It appears once, as prose, in a
footnote under the pricing cards:

> *"Annual billing costs 10 monthly payments."*

There is no monthly/annual toggle on the cards, and nothing in the app paywall
requests the annual plans. So the plumbing is built and the offer is invisible —
which is why it reads as missing. That is a much cheaper problem than building
annual billing, and it is the main finding here.

---

## Their table

| | Free | Pro | Business | Enterprise |
|---|---|---|---|---|
| Monthly | $0 | $18 | $29 | — |
| **Annual** | $0 | **$10** | **$19** | **$39** (annual only) |
| Implied discount | — | **44%** | **34%** | n/a |
| Storage | 400 min/team | 8,000 min/seat | Unlimited | Unlimited |
| **AI credits** | — | **20** | **30** | **50** |

All prices per seat per month. Transcription and AI summaries are **unlimited on
every tier including Free**.

The toggle is labelled `ANNUAL · 40% OFF` — a single badge covering tiers whose
real discounts are 44% and 34%.

### Three structural choices worth naming

**1. The thing you fear running out of is unlimited; the thing that costs them is
metered.** Transcription is unlimited at every tier. What is capped is *storage
minutes* (400/team on Free) and *AI credits* (20/30/50). Nobody churns because
they hit a transcription cap, because there isn't one — they hit a retention
wall instead, by which point their archive is the reason they stay.

**2. AI is a third axis, sold separately from seats.** AI credits are bundled per
tier and metered independently, with their own 7-day trial banner running across
the whole app. AI Skills and Voice Agents are gated to Pro+ and consume credits.
Seats buy the archive; credits buy the intelligence.

**3. The top tier is annual-only, and pays by invoice.** Enterprise has no
monthly price at all.

---

## Ours, for comparison

| | Free | Pro | Premium | Ultra |
|---|---|---|---|---|
| Monthly | $0 | $19 | $49 | $99 |
| Annual (total) | — | $190 | $490 | $990 |
| **Annual, per month** | — | **$15.83** | **$40.83** | **$82.50** |
| Discount | — | **16.7%** | 16.7% | 16.7% |
| Copilot hours | 2 | 20 | 40 | — |
| Compute credits | 15 | 250 | 750 | — |

Plus add-on packs (compute 250/750/2000, copilot hours 10/50/200).

**Our annual discount is roughly half theirs** — 16.7% against 34–44%. Ten
monthly payments is the conservative SaaS default; they are treating annual
prepay as worth far more than two months of cash.

On a per-seat annual basis we sit between their two paid tiers: Fireflies Pro
$10, **us $15.83**, Fireflies Business $19.

The comparison table on our landing page is honest about this — it is explicitly
labelled *"Entry paid plan, monthly list price"* and quotes them at $18. But it
means the annual picture has never been compared anywhere, and annual is the
price a committed buyer actually pays.

---

## What to change, in cost order

**1. Surface the annual offer. (Cheapest, largest gap.)**
A monthly/annual toggle on the pricing cards and in the app paywall. The backend
already serves these plans. Today the only mention is a footnote, and a discount
nobody sees converts nobody. State the saving in money per year, not only as a
percentage — "$38 a year" is more legible than "16.7%".

**2. Decide deliberately whether 16.7% is the right depth.**
This is a business call, not an engineering one, so this document does not
recommend a number. What it can say is what the trade is: annual prepay buys
churn reduction and working capital, and Fireflies has evidently priced those
higher than we have. If the depth moves, the allowances should be checked at the
same time — our tiers bundle copilot hours and compute credits whose unit cost is
real (up to $0.0308 a credit), so a deeper discount is margin, not just cash
timing, in a way that theirs is not for unlimited transcription they run at scale.

**3. Consider making the top tier annual-only.**
They do it for Enterprise. It suits a tier bought by a company rather than a
person, and it removes a month-to-month escape hatch on the plan with the most
support cost.

**4. Separate "the tool" from "the intelligence" in how allowances read.**
Their split is legible in one glance: seats buy the product, AI credits buy the
AI. Ours has two credit pools (`copilotCredits`, `computeCredits`) plus copilot
hours, and the distinction between them is an implementation detail that leaked
into the pricing page. The pools are correct — they exist because a single pool
sized against the expensive path made Pro's advertised 20 hours deliver 5.8 — but
the *presentation* could be one number the buyer understands.

## What NOT to copy

**Storage-based gating.** Their Free tier is limited by retention because the
archive is the product. Ours is limited by AI usage because the co-pilot is the
product, and on-device transcription is unlimited on every plan including Free —
which is already the better version of their "unlimited transcription" move,
since ours costs us nothing to honour.
