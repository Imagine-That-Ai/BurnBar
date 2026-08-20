# Monthly Recap

> At the end of each calendar month, OpenBurnBar reads back how you actually
> worked with AI — as a small personal magazine, not a metrics dump.

## What it is

A curated deck of cards about one calendar month: which model became your
default, which day of the week you kept returning on, the week you were on a
roll, what changed since last month, and a closing sentence that tries to name
what kind of month it was.

It is a **destination**, not a dashboard. On macOS it sits in the sidebar beside
Overview and Insights. On iPad it is a tray destination. On iPhone it is reached
from a pinned banner at the top of the Insights tab — a surface that matters once
a month has not earned a seventh permanent tab slot.

The default view is the most recent **completed** month. The month in progress is
available as an explicitly-labelled "so far" preview that never seals.

## The rule that makes it trustworthy

**The model never authors a number.**

A deterministic generator computes every statistic, comparison and record from
your own rows. The LLM is handed those candidates — numbers already filled in —
and asked only to select, order and write. A post-processor then rejects any
sentence containing a figure that cannot be traced back to that candidate's own
metrics, and the deterministic sentence ships instead.

This is the same contract `InsightVoiceSchemaV2` already enforces for verdicts.
Without it, a fluent model asked to improve *"Grok handled 41% of your sessions"*
will happily produce *"Grok handled nearly half your sessions, up from a fifth"* —
plausible, well-written, and computed by nobody.

**With the editorial layer off, the recap is still complete.** The toggle changes
the prose, not the presence.

## What leaves the device

Only `RecapPromptPayload`, and only when the editorial toggle is on.

- Numbers travel as their **formatted strings**, not raw series.
- **Project names are tokenized** (`{project1}`) and restored locally, so the
  model writes natural prose around a placeholder it never resolves. Repository,
  client and employer names are the genuinely private identifiers here.
- **Candidate ids are opaque** (`c1`, `c2`, …). Rule ids embed their subject —
  `headline-project:burnbar` — so sending them would leak exactly what the
  tokenizer is protecting.
- File paths appear nowhere, at any layer.
- Model and provider names *are* sent: they are vendor product names, and
  withholding them costs real copy quality for no privacy gain.

Local-first routing, as everywhere else in the app: Hermes on localhost before
any cloud CLI. The closing card always names who wrote the words and whether they
left the device.

## Architecture

```
RecapSource                MacRecapSource (GRDB)  ·  MobileRecapSource (paged Firestore)
      ▼
RecapFacts                 deterministic monthly fold; real names; on-device only
      ├──────────────────► RecapHistoryStore   one struct per month, accumulated
      ├──────────────────► RecapPromptPayload  sanitized; the only thing that leaves
      ▼
RecapCandidateGenerator    ~30 rules, each with its own data floor
      ▼
RecapRanker                interestingness → diversity caps → narrative slotting
      ▼
RecapComposer (actor)  ──► deterministic MonthlyRecap  (renders immediately)
      │  optional LLM upgrade   │
      ▼                         ▼
RecapVoiceAuthor → RecapVoicePostProcessor → prose swaps in; numbers never move
      ▼
RecapStore                 a completed month seals once authored
      ▼
RecapDeckView              macOS 3-col · iPad 2-col · iPhone 1-col
      ▼
RecapShareCardRenderer     ImageRenderer → 1080×1350 / 1080×1080 PNG
```

Engine and models: `OpenBurnBarCore/Sources/OpenBurnBarRecap/` — its own target, carved out of `OpenBurnBarInsights` once the feature landed whole.
Card system: `OpenBurnBarCore/Sources/OpenBurnBarUI/Views/Recap/`.
Both shells consume the same implementation.

### Why a separate `RecapSource`

`InsightDataSource` is not reused, because neither shipped implementation is fit
for a calendar month:

- `MacInsightDataSource` filters `dataStore.usages` — the bounded **warm
  in-memory cache**. A month older than that window would come back silently
  truncated, and the deck would report records computed from whatever was cached.
- `MobileInsightDataSource` maps a window onto a `RollupWindowKey` by *duration*,
  so any 28–31 day span becomes `.thirtyDays`, a **rolling** rollup. "August"
  would render as "the last 30 days" and every historical month would collide.

Retrofitting either would change behaviour for the existing Insights verdict
surface. The recap brings its own source instead.

## Data floors

Every rule declares its own minimum: months of history, sample size, effect size.
A rule that cannot clear its floor emits nothing. That single discipline is what
makes all of these behave without special cases:

| Situation | What happens |
|---|---|
| First month ever | Records become firsts; comparisons are simply not made |
| A quiet month | Fewer cards, bigger type — never padded |
| Under ~5 active days | One editorial card saying the recap unlocks with more history |
| iOS without conversation data | Tool and task-title rules do not fire |
| Partial read (paging budget hit) | **No totals, no records, no "most ever"**, and the deck says so |

Significance is computed, never asserted: share shifts use a two-proportion
z-test, day and hour concentration use Cramér's V against uniform, and records
carry their margin over the previous record. With seven weekdays and nine
sessions, *some* day always leads — the test is what stops that becoming a card.

## Sealing

A month seals only once it has **ended** and the editorial pass has either
succeeded or been declined. After that it is frozen: last August must read the
same way in December, and `RecapStore` enforces that at the storage boundary
rather than trusting callers.

The one exception is `sealedWithoutVoice` — a month frozen with deterministic
copy accepts exactly one re-author if the user later turns the editorial layer
on. Without it, enabling the toggle would appear to do nothing to the recaps they
already have.

## Sharing

Any card that stands on its own can be exported as a PNG (1080×1350 portrait or
1080×1080 square). The image is **re-composed for its frame**, not a screenshot:
someone seeing it in a group chat has none of the surrounding app, so it carries
the month, the claim, the number and the source by itself. macOS exports through
`NSSavePanel`; iOS shows the rendered image first, then a share sheet.

## Scheduling

`CadenceScheduler` already carried a monthly slot (1st, 08:00 local, 28-day
minimum gap) and `CadenceArtifact` a `.monthly` case; both were written and had
no production caller. The recap is that caller.

## Testing

`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Insights/Recap/` — the fold against
fixed fixtures including 31-day months and a DST transition, one test per data
floor, ranker diversity and determinism, the numeric-containment guard, the
privacy of the prompt payload, sealing semantics, and deck layout at 3/2/1
columns. Renderer tests assert real exported pixel dimensions in both colour
schemes.

Kept to pure-logic and renderer assertions on purpose: ViewInspector silently
skips tests on Xcode 27, so view-tree inspection would report false green.

## See also

- [`docs/INSIGHTS.md`](INSIGHTS.md) — the Intelligence Brief and canvas surface
  the recap's voice contract is modelled on.
- [`docs/CHARTS_PAGE.md`](CHARTS_PAGE.md) — the analytics gallery; the recap
  reuses its opt-in AI toggle contract and its local-first backend selection.
- [`docs/PRIVACY.md`](PRIVACY.md) — overall data-collection posture.
