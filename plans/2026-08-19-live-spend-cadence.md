# Making spend actually live — a proposal

**Status:** proposal, nothing changed yet. Asked for during the living-layout
redesign (2026-08-19), because a dashboard cannot feel alive if the data behind
it moves twice a quarter-hour.

---

## TL;DR

The burn rate in the header updates **every 10 minutes** by default. That is not
a bug and the number is not arbitrary — a refresh re-parses provider logs, and
that path caused a real memory incident on 2026-07-16.

But the app **already knows, within about 1.4 seconds, every time a provider
writes a session file.** There is a live FSEvents watcher over every provider's
log directory, armed whenever Home is on screen. It only feeds the fleet panel.
The spend readouts never subscribed to it.

So the fix is not "make the expensive thing happen more often." It is: let the
cheap signal we already have drive the display, and leave the expensive sweep
where it is.

**One question for you at the bottom.**

---

## What is actually there today

### The 600-second tick

`BehaviorSettings.refreshInterval` defaults to `600`
([`BehaviorSettings.swift:11`](../AgentLens/Services/Settings/Stores/BehaviorSettings.swift)).
It drives one registered cadence, `agentlens-periodic-refresh`
([`AgentLensApp+LiveServices.swift:363-399`](../AgentLens/App/AgentLensApp+LiveServices.swift)),
whose work is `aggregator.refreshAll()` + daemon health + controller runtime +
an inbox badge nudge.

Two things worth noticing:

- **600 is a default, not a floor.** The cadence resolves to
  `max(refreshInterval, minimum)` where the minimum is **60s** normally and 600s
  only when the pixel clock is enabled. A user who drags the slider down to one
  minute already gets a one-minute tick today.
- **The coordinator is already well-behaved.** It pauses entirely on display
  sleep and stretches 5× in the background. Nothing runs with the lid closed.

### Why the expensive thing is expensive

`UsageAggregator.refreshAll()` → `RefreshBackgroundWork.runFullRefresh(...)`
re-parses provider session logs. That is the path behind the **2026-07-16 parser
memory blowup** (autorelease pile-up, full re-reads, an O(n²) iterator in the
Codex usage-refresh parser).

It has since been tightened — `reloadUsagesIfChanged()` now costs one actor hop
on an idle tick instead of refetching and re-aggregating all history
(`docs/architecture/macos-performance.md` §18). But it is still a **full sweep
across every provider**, and it is the correct thing to be conservative about.

### The live signal nobody wired to spend

[`ProviderSessionActivityWatcher`](../AgentLens/Services/Fleet/ProviderSessionActivityWatcher.swift)
runs a recursive FSEvents stream per provider over its session-log directory
([`FileTreeEventStream`](../AgentLens/Services/Fleet/FileTreeEventStream.swift)):

| Property | Value |
|---|---|
| FSEvents coalescing latency | **1.0s** |
| App-side debounce after a batch | **400ms** |
| Streams actually open | 3–6, not 37 (one `stat` per provider at arm time) |
| Armed | when Home mounts (`DashboardView.swift:1240`) |
| Disarmed | on display sleep — deliberately, so a lid-closed CLI cannot wake the process |
| Unavailable | `DISTRIBUTION_MAS` builds (sandbox cannot read `~/.claude/projects`) |

Its only consumer is `LiveFleetModel.recordWrite(provider:at:path:)`
([`LiveFleetModel.swift:159`](../AgentLens/Services/Fleet/LiveFleetModel.swift)).
That is why the fleet dots feel instant and the burn rate does not: **they are on
two completely different clocks, and one of them is already the fast one.**

---

## The proposal

**Decouple display freshness from scan cost.** Three changes, in dependency
order, each shippable alone.

### 1. Targeted refresh on an observed write

When the watcher reports a write for provider *P*, refresh **only P**, not all of
them. The watcher already hands over the provider and the exact path, so the
scope is known — this is the piece that makes the frequency affordable, and it
should land before any frequency change.

Guards, all of which have precedent in this codebase:
- Coalesce to at most one targeted refresh per provider per **5s**, on top of the
  watcher's existing 1.0s + 400ms.
- Skip entirely while `isRefreshing` — `refreshAll()` already self-guards this way.
- Inherit the cadence coordinator's sleep/background policy rather than inventing
  a second lifecycle.

### 2. Keep the 600s sweep exactly as it is

It becomes the safety net for everything the watcher cannot see: MAS builds,
providers whose directory did not exist at arm time, API-sourced usage, and any
write FSEvents drops. **Do not lower the default.** The incident reason still
holds for the full sweep, and after change 1 the default stops being what
determines whether the UI feels alive.

### 3. Let the readouts animate on the signal they already have

`dataStore.usagesVersion` is a monotonic counter bumped only on content-changing
writes. The header sparkline, the burn-rate value and the delta chip should
transition on `usagesVersion` with `MotionTokens.tick`, so a real change reads as
a roll rather than a snap. This is display-only and independent of 1 and 2.

### What I would not do

- **Lower the global interval.** Cheapest to type, and it multiplies the exact
  cost the 2026-07-16 incident was about, across every provider, forever.
- **Poll faster in the view layer.** Same cost, less honesty, and it would fight
  the cadence coordinator's sleep policy.
- **Fake it.** Animating a number on a timer when the underlying value has not
  moved is the "lifeless data dump" failure wearing a nicer coat, and it would
  make the burn rate lie.

---

## What this does not fix

Cloud/API-sourced usage has no local file to watch, so it stays on the 600s
sweep. Same for MAS builds, where the sandbox makes the watcher structurally
impossible — those should keep saying so per row (`recordUnwatchable` already
does) rather than rendering as quiet.

---

## Before implementing, measure

I have **not** measured any of this; the reasoning above is from reading the
code. Numbers worth having first:

1. Wall-clock and peak RSS of one `refreshAll()` on your real corpus.
2. The same for a single-provider refresh — the ratio is what justifies change 1.
3. Observed write-event rate per provider during an active agent session, to size
   the coalescing window honestly.
4. Whether `OpenBurnBarQueryTracer.assertMaxQueries` can pin the targeted path so
   it cannot silently regrow into a full sweep.

---

## The question

**Do you want change 1 (targeted per-provider refresh on an observed write), or
only change 3 (animate on `usagesVersion`, leave every cadence alone)?**

Change 3 is display-only, essentially risk-free, and makes the numbers move
smoothly — but only every 10 minutes. Change 1 is what actually makes the surface
live, and it touches the refresh path the 2026-07-16 incident came from.
