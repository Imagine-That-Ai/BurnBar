# Launch Prompt for GPT-5.5 Pro

Paste the text below into GPT-5.5 Pro and attach all six files from this folder
(`01_…` through `06_…`). It instructs the model to convert the research into a
bulletproof, end-to-end launch plan that coding agents and general
computer-use agents can execute to completion. Doc 6 makes the package
self-sufficient — the executing agents get real commands, SKUs, config keys, and
the launch gate without needing repo access.

---

```
You are acting as the founder-operator and chief of staff for OpenBurnBar, a local-first
macOS menu-bar app for AI-coding-agent cost tracking with an opt-in paid cloud. I am giving
you a 5-document research package (attached). It is ground truth — every number in it is
traced to a code constant, plan, runbook, or a labeled assumption. Read all five end to end
before writing anything:

  1. 01_PRODUCT_AND_SYSTEM_OVERVIEW.md      — product, ICP, market position
  2. 02_CLOUD_BACKEND_AND_INFRASTRUCTURE.md — 76 functions, data model, SKUs, infra
  3. 03_FEATURE_COST_AND_QUOTA_MAP.md       — per-feature cost, caps, kill-switches
  4. 04_UNIT_ECONOMICS_AND_COGS.md          — per-op cost, per-user COGS, break-even
  5. 05_TWO_TIER_PRICING_BRIEF_FOR_GPT_PRO.md — the two-tier packaging + open decisions
  6. 06_OPERATIONAL_EXECUTION_APPENDIX.md   — current launch state, exact commands, SKU/config,
                                              the delta to ship two tiers, the launch gate + DoD

OUTCOME (the destination):
Produce ONE bulletproof, end-to-end launch plan that takes OpenBurnBar from its current
state to "live and selling two paid cloud tiers, margin-safe, with observability and
rollback" — and that two classes of autonomous agents can execute to completion with no
human in the loop except for irreducible identity/legal/payout steps:
  • CODING-AGENT: writes/edits code, deploys Firebase functions/rules/indexes, configures
    Stripe via API/CLI, edits the website, runs the repo's launch gates and tests.
  • COMPUTER-USE-AGENT: drives browser/desktop GUIs that have no clean API — App Store
    Connect, Google Play Console, Firebase console (App Check enforcement, Remote Config),
    Stripe dashboard, domain/DNS, analytics setup.

SUCCESS CRITERIA (what "bulletproof" means here):
  • Every strategic decision is LOCKED inside the plan (nothing left to "decide later"),
    and each decision cites the document and number that justifies it.
  • The plan is a dependency-ordered task graph, not prose. An agent can start at Task 1
    and proceed to a verifiably launched state without further strategic input.
  • The operator cannot lose money on the engaged user, and aggregate variable spend stays
    inside the existing kill-switches. Prove this with the Doc 4 numbers.

FIRST, LOCK THESE DECISIONS (grounded strictly in the research):
  1. The two paid cloud tiers: public names, monthly + annual prices, exact feature lists,
     and Tier-2 cost-containment design (flat price vs. vision-action/GB allowance + overage
     vs. tightened per-user caps). Prove gross margin ≥ target at median, power, AND
     capped-tail users using Doc 4 §3–§4. A flat Tier-2 price that loses money on the median
     Computer-Use user is disqualified.
  2. Free-tier scope + trial design (length, which tier it trials).
  3. Channel/SKU plan: map the chosen tiers onto the existing entitlements/product ids
     (burnbar_pro, burnbar_pro_max), decide what happens to the orphan SKUs ($9.99 media,
     standalone $14.99 computer-use), and how the existing $4.99 Hosted Quota Sync
     subscribers are grandfathered.
  4. Default Computer-Use vision model (cost lever — Doc 4 §7).

THEN, PRODUCE THE PLAN with these properties:

GROUND THE EXECUTION IN DOC 6. 06_OPERATIONAL_EXECUTION_APPENDIX.md contains the real current
launch state, the exact shell commands, the SKU/product ids, the config/env keys, the Remote
Config safety knobs, the channel-by-channel steps, the §5 "delta to ship two tiers" worklist,
and scripts/commercial-launch-gate.mjs as the master Definition of Done. Quote and sequence
those real commands/ids — do NOT invent paths, commands, or product ids. Treat Doc 6 §5 (the
two-tier delta) and §11 (the launch checklist) as the backbone of the task graph, and the gate
verdict (READY_FOR_LIVE_PAID_PROOF on a clean main) as the launch trigger.

A. Work breakdown as a dependency-ordered task graph (phases → tasks). For EVERY task give:
   - id, title, phase
   - owner-type: [CODING-AGENT | COMPUTER-USE-AGENT | HUMAN-REQUIRED] (+ why if human)
   - preconditions / blocking task ids
   - exact executable steps: shell commands, file paths, config keys, or the precise
     GUI screens + fields + button labels a computer-use agent must operate
   - acceptance test: an OBJECTIVE, ideally automatable check that proves the task is done
   - artifacts produced (ids, URLs, files)
   - rollback procedure if the acceptance test fails or a regression appears
   - citation: the doc section/number that justifies this task exists

B. Cover the entire launch surface at minimum:
   - Finalize pricing + write/verify StoreKit config and entitlement gating
   - App Store Connect: create the two subscription products (+ annual), localized metadata,
     review notes, manual release
   - Stripe: create products/prices, set STRIPE_BURNBAR_PRO_PRICE_ID, wire + test the webhook
   - Google Play: publish app, create subscriptions, server-verify
   - Firebase production hardening: enforce App Check for Firestore, deploy functions/rules/
     indexes, set Remote Config caps ($600/$1000 media, $1500/$2500 computer-use, 30/300
     quota), deploy billing-alert policies, pass scripts/commercial-launch-gate.mjs
   - Website (burnbar.ai): update the pricing page to the two tiers (benefit-first copy,
     no codename/transport jargon), FAQ, deploy via Firebase Hosting
   - Observability: dashboards/alerts on the four watched cost metrics; per-tier COGS monitor
   - GTM: launch sequence, positioning vs Raycast/Cursor/Copilot (companion, not substitute),
     Free→T1→T2 upsell triggers, launch comms
   - Post-launch: canary monitoring window, refund/chargeback handling, rollback triggers

C. Validation gates between phases: define a gate after each phase that lists the acceptance
   tests which MUST pass before the next phase begins. Include the repo's commercial-launch
   gate as the final pre-go-live gate.

D. Risk register: each risk with likelihood × impact, mitigation, owner-type, and the
   trigger that activates the mitigation. Explicitly handle: Apple/Play rejection, Apple
   15%→30% at $1M revenue, Computer-Use vision-token COGS overrun, kill-switch false
   positives, refunds/chargebacks, churn, and a rogue/abusive subscriber.

E. Financial model: locked unit economics per tier, break-even, and a 6- and 12-month
   projection at low/base/high adoption with a sensitivity table on the top three levers
   (vision model cost, P2P hit-rate, tier price). Use only Doc 4's baselines; flag any new
   assumption explicitly.

F. Definition of Done: a single objectively-verifiable launch checklist. The launch is
   "done" only when both tiers are purchasable on every wired channel, entitlements gate
   correctly, the cost kill-switches and billing alerts are live, and the canary window
   has passed with margins inside target.

HARD CONSTRAINTS (do not violate — see 05_…md §8):
  • Stay margin-safe on the engaged user, not just the average.
  • Treat the per-user caps and global kill-switches as non-negotiable safety floors.
  • Keep Tier 1 a cheap, high-margin impulse buy (the Free→paid conversion step).
  • Base every number on the attached docs; mark any assumption you introduce as ASSUMPTION
    and give the reasoning.
  • Public-facing copy is benefit-first and safety-forward; never expose codenames or
    transport/codec jargon.

STOPPING CONDITION:
The plan is complete when a coding agent and a computer-use agent, handed this plan and
repo access, could execute every task in dependency order — passing each gate's acceptance
tests — and arrive at a launched, selling, margin-safe two-tier product without needing any
further strategic decision from a human.

OUTPUT FORMAT:
  1. Locked Decisions (the four above, each with citation + margin proof)
  2. Launch Plan (phases → task graph, every task with the fields in A)
  3. Phase Gates (acceptance tests per gate)
  4. Risk Register
  5. Financial Model + sensitivity
  6. Definition of Done checklist
Be exhaustive and concrete. Prefer tables and explicit task lists over narrative. If two
options are genuinely close, pick one, state why, and note the runner-up in one line — do
not leave forks open.
```
