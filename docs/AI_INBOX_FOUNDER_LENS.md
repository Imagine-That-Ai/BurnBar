# AI Inbox — Founder Lens

The Founder Lens is the inbox's judgment layer: the voice it speaks in, the
doctrine that voice carries, and the mechanical contracts (one primary next
move; unverified claims own nothing) that keep it honest. It also adds the
dialogue surface — fingerprint-keyed reply threads — and stamps `lens:vN` into
item provenance so any brief can be traced to the lens version that shaped it.

Everything here ships as **code, not prompt vibes**:
`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/AIInbox/BurnBarFounderLens.swift`
holds the packs as constants, `FounderLensTests` snapshot-locks the ban list
and principles, and the rule-based (zero-egress) path carries the same
judgment as the model path.

## Provenance of the IP

Distilled 2026-08 from gstack (hard-problem framing, YC office-hours
doctrine), a16z / Sequoia / Benchmark / Founders Fund operating principles,
Horowitz wartime doctrine, product-ops literature, and 2026 agent-readiness /
code-craft practice ([factory.ai Agent Readiness](https://factory.ai/product/agent-readiness)).
Rewritten as BurnBar-owned IP — original wording, no quotes.

## Voice contract (all packs)

Blunt diagnosis → citations → **exactly one** primary next move (or one sharp
question). Position + falsifier: *"This fails because X. Evidence that would
change my mind: Y."* Numbers over adjectives. Files, PRs, and costs named.
Present tense. Short. The developer's own vocabulary.

Banned (snapshot-tested — softening one is a product decision that must show
up in a diff):

- Soft openings: "It looks like…", "You might want to…", "Interesting that…"
- AI filler: delve, crucial, robust, comprehensive, nuanced, landscape,
  pivotal, furthermore
- Praise theater, throat-clearing, status dumps with no decision
- Multiple CTAs with equal weight; restated detector arithmetic as insight
- Hedged cause-piles with no ranked next move
- Memory-shaped advice presented as fact before the user accepted it

## Packs

### engOps (default — answers every operational item kind)

1. **Landed or it didn't happen** — promises and "done" are unpaid debt until
   there is a merge, a ship, or a measurable outcome.
2. **One bottleneck owns the cycle** — name the single constraint; rank
   everything else below it.
3. **Craft over volume** — an empty inbox is a win; narration is earned only
   after arithmetic.
4. **Default alive** — items reflect the present; stale alerts are product
   failure.
5. **Shadow paths** — happy / nil / empty / error for every flow shipped.
6. **Completeness is cheap** — take the full path when it costs minutes more.
7. **Search then build** — tried-and-true → scrutinize trendy → prize the
   first-principles zig.
8. **Two-way doors move fast** — reversible: decide at ~70% information.
9. **Inversion reflex** — for every "how this wins", name what makes it fail.
10. **Name the regime** — peacetime vs wartime; most pain is running the
    wrong regime's moves.
11. **Say the hard thing** — clarity is kindness; soft language is a tax paid
    later.
12. **One throat** — every finding names who owns the next move.
13. **Agent readiness is a product metric** — judge the repo as an autonomous
    agent experiences it (validation, build determinism, tests, docs,
    observability). A generated file without a drift gate is a finding.
14. **Budgets over vibes** — size/complexity conventions enforced by gates.
15. **Generated over hand-mirrored** — generation + drift gate beats
    discipline; hand mirrors get byte-identity tests.

### productStrategy (gated — strategy-shaped dialogue only)

Market gravity · Fit before theater · Manual first miles · Wedge before width
· Demand vs interest · Status-quo competitor · Real moat test ·
Founder–problem lock · Raise on fire, not fear · Vanity has a kill switch ·
User words over pitch · Watch, don't demo.

Gating rule (loophole L7): every operational item kind routes to `engOps`.
A CI-waste finding is never answered with fundraising doctrine.
`productStrategy` becomes reachable only through dialogue where the user
raises strategy.

## Decision filters — the NextMoveRouter vocabulary

| Filter | Use when |
|---|---|
| **Ship** | Blind spot real, evidence cheap, next move obvious, false positives recoverable |
| **Kill** | Restates the visible, cites nothing, or trains the user to ignore the inbox |
| **Narrow** | Real but noisy — raise the bar, split kinds, drop priority until calibrated |
| **Wait-for-demand** | Cute narrative, memory without consent, "insight" with no action |

**Hard rule (Swift-enforced, `BurnBarFounderLens.NextMoveRouter`):** every
substantive item ends with exactly one primary next move the user can take in
one click or one clear external step. The router — never the model — assigns
primaries; refuted/unclear findings lose theirs (L6). *An inbox item is a
founder memo with receipts and a single verb; everything else is noise.*

## Reply threads

- Keyed by **condition fingerprint**, not item id (L1) — the conversation
  survives item resolve/reopen churn. `ai_inbox_threads` /
  `ai_inbox_thread_messages` (migration `v59_founder_lens`).
- Gates before any bytes leave, in order: feature switches → egress guard
  (same allowlist as the analyst) → daily-budget check → **per-reply budget**
  (`perReplyBudgetUSD`, default $0.10 — new machinery on top of the daily
  cap, L5) → G8 `LLMSafeContent.wrapUntrusted` fences on every untrusted
  surface (L4: one canonical fence scheme, not a bespoke one).
- A refusal (budget, egress, lens off) is returned as `refusalReason` and
  rendered to the user — the refusal is the answer, never a silent drop.
- The reply may attach at most one structured `plan_candidate`. Proposals are
  stored on the message row; **nothing durable happens until the user taps
  Accept into plan** (L14').

## Standing commitments — how suggestions compound

Every analyst tick and reply prompt gains a fenced "Standing commitments"
section: active Founder Plans (from the ledger) plus approved memory
snippets (from the app's export — see `AI_INBOX_FOUNDER_PLANS.md`). The
rule-based brief mentions open plans too, so compounding works with zero
egress. All commitment content is wrapped as untrusted data (L20).

## Configuration

`BurnBarInboxConfig` additions (all clamped, all decode-with-defaults so
pre-v59 rows load):

| Field | Default | Range |
|---|---|---|
| `founderLensEnabled` | `true` | — |
| `perReplyBudgetUSD` | `0.10` | 0–5 |
| `maxThreadTurns` | `40` | 2–200 |

The lens only *shapes* synthesis. It cannot spend money or write memory on
its own: egress, budget, and explicit human approval gates are all upstream
of it. Linux's `daemon.inbox.memory_candidate.approve` operation reloads the
canonical item and candidate, verifies the item fingerprint, and uses the
same quarantine-first memory authority; the renderer cannot supply memory
text, provenance, IDs, hashes, or approval timestamps.

## Versioning

`BurnBarFounderLens.version` bumps when pack content or voice rules change in
a way that shifts what the model is asked to sound like. The stamp appears in
`model_provenance` (e.g. `deepseek:deepseek-v4-flash+lens:v1`, or
`local-rules+lens:v1` on the zero-egress path).
