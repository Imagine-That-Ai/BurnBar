# Liquid Glass dashboard (`/dashboard`)

A modular, personal **usage** dashboard: draggable/resizable **glass cards** over a
full-bleed **WebGL2 kernel** backdrop + the provider **swarm**, an add-card wizard,
an appearance surface, persisted layout — and **real, live member usage** read
straight from Firestore. No mock data.

## Live data — where every number comes from

The macOS app's `UsageSyncService` mirrors `TokenUsage` to Firestore (project
`burnbar`); a Cloud Function pre-aggregates owner-readable rollups. The console is
the **last reader**, not a new writer:

| Source (owner-readable) | Cards |
|---|---|
| `users/{uid}/usage_rollups/{window}` — `totals{requests,tokens,costUsd}`, `providerSummaries`, `modelSummaries`, `deviceSummaries`, `dailyPoints{day:tokens}`, `computedAt` | Burn, Tokens, Requests, Tokens/day, Provider spend, Models, Devices, Formation |
| `users/{uid}/quota_snapshots/*` — `buckets[{used,limit,remaining}]` | Provider limits |
| `users/{uid}/billing/allowances/months/{monthKey}` — fusion meter | The Wand |

`window ∈ {today, 7d, 30d, 90d, all_time}`. Reads are auth-gated (`useAuth().uid`),
each source is **independent and fail-soft** (a denied quota/allowance never blanks
the usage cards), and a member who has never synced renders a real **zeroed empty
state**, never fabricated data. "Refresh" calls the `rebuildUsageRollups` callable
then re-reads; the toolbar shows `computedAt` as "updated Xm ago".

**Cache-hit and TPS were removed, not faked:** neither exists in the cloud
aggregate today (cache tokens aren't in the rollup/daily counters; TPS is
per-message, mobile-only). Surfacing them honestly requires a server-side metric
(app counters → rollup) — a flagged follow-up, not a mock.

## What's here

```
lib/firebaseClient.ts        + db() (Firestore singleton + emulator)
lib/usage.ts                 Types mirrored 1:1 from functions/src/types/legacy/quota-usage.ts
                             + normalizeRollup / normalizeQuotaSnapshot / normalizeAllowance (defensive)
lib/api.ts                   + rebuildUsageRollups callable wrapper
lib/dashboard/useDashboardUsage.ts   The live hook: auth-gated, fail-soft, window-aware, reload

lib/gl/*                     Self-contained WebGL2 backdrop (5 kernels, context-loss, fallback)
components/dashboard/
  KernelBackdrop.tsx         Full-viewport <canvas> (z -2), reduced-motion + static fallback
  gridMath.ts                Pure grid geometry (unit-tested)
  layoutStore.ts             Versioned, validated localStorage persistence
  useDashboardController.ts  Layout + appearance state + persistence
  GlassGrid / GlassGridItem  Positions cards; pointer drag + resize + keyboard a11y
  DashboardToolbar.tsx       Window selector + Refresh + Add-cards wizard + Appearance
  cardRegistry.tsx           10 cards → title/blurb/icon/size/component + default layout
  cards/*.tsx                The card bodies + shared primitives
```

The route is `app/dashboard/page.tsx`; the nav entry is "Studio" in `AppShell`.
The fusion card is enabled by an owner-read rule on the allowance month doc
(`firestore.rules` + `firestore-rules-tests/billing-allowance-owner-read.test.js`).

## Why the console (not SwiftUI/website)

`apps/console` is the repo's only React surface, it's already Firebase-auth'd to the
same `burnbar` project the usage lives in, and its CSP already allows Firestore
(`*.googleapis.com`) — so live reads need **no CSP/config change**. The SwiftUI app
has its own native dashboard; `website/` is Astro with idle-canvas/reduced-motion
gates a heavy interactive WebGL surface would fight.

## Follow-ups (out of scope; flagged, not faked)

- **Cache-hit + aggregate TPS**: add the metric to the app's usage counters →
  rollup aggregation → a new field; then add the cards back live.
- **Team/workspace usage**: needs a tenancy model + an admin-SDK fan-out callable
  (rules forbid cross-uid reads). Seam: `getTeamUsageRollup`.
- **Full SOTA backdrop**: adopt `imaginethat-llc`'s tested 44-kernel factory
  (`src/kernels/{KernelHost,registry,gl/*}`) to replace the 5-kernel port — a
  separate PR so a graphics-engine swap isn't entangled with the data migration.

## Credits

Backdrop kernels ported from the Liquid Glass Studio prototype, whose GLSL descends
from `imaginethat-llc/src/kernels`.
