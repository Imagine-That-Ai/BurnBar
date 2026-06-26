# Liquid Glass dashboard (`/dashboard`)

A modular, personal dashboard: draggable/resizable **glass cards** floating over a
full-bleed **WebGL2 kernel** backdrop and the page's global provider **swarm**.
This is the §7 "modular glass-card dashboard" from the Liquid Glass Studio
design handoff, rebuilt as real React on the console's Pensieve design tokens.

## What's here

```
lib/gl/                      Self-contained WebGL2 backdrop (zero deps)
  chunks.ts                  PREAMBLE + SNOISE/FBM/DITHER/RAMP + MAIN + VERT
  kernels.ts                 5 curated kernels + palettes (default: Liquid Glass / coral)
  createKernelRenderer.ts    Minimal host: compile/link, uniform cache, fullscreen
                             triangle, DPR sizing, pointer, context-loss, dispose
  palette.ts                 hex → vec3

lib/dashboard/               Data seam
  types.ts                   DashboardWindow (mirrors Swift DashboardUsageWindowSummary)
  mockUsage.ts               Deterministic synthetic window (no Date.now/Math.random)
  useDashboardUsage.ts       live | mock seam (see "Data" below)

components/dashboard/
  KernelBackdrop.tsx         Full-viewport <canvas> (z -2), reduced-motion + fallback
  gridMath.ts                Pure grid geometry (unit-tested)
  layoutStore.ts             Versioned, validated localStorage persistence
  useDashboardController.ts  State + persistence + add/remove/move/appearance
  GlassGrid.tsx              Positions cards; measures column width
  GlassGridItem.tsx          One card: pointer drag + resize + keyboard a11y
  DashboardToolbar.tsx       Range, Add-cards wizard (Radix Dialog), Edit, Appearance
  cardRegistry.tsx           9 cards → title/blurb/icon/size/component + default layout
  cards/*.tsx                The 9 card bodies + shared primitives
```

The page is `app/dashboard/page.tsx`; the nav entry is "Studio" in `AppShell`.

## Why it lives in the console (not SwiftUI/website)

`apps/console` is the repo's only React surface, and a card wizard + draggable grid
is inherently stateful React work. The SwiftUI app already has its own native
dashboard; `website/` is Astro with strict idle-canvas/reduced-motion test gates a
heavy interactive WebGL surface would fight. The backdrop kernel is the prototype's
**self-contained** GLSL (no imaginethat-llc `createShaderKernel` factory — that pulls
in sim-pass/glyph/control machinery this backdrop never uses).

## Data

The console is a **static export** served from app.burnbar.ai; its CSP `connect-src`
excludes `localhost`, so it cannot read the local daemon, and no Cloud Function
exposes aggregate usage yet. Cards therefore render **deterministic, clearly-labeled
demo data** through a single seam: `useDashboardUsage` → `loadLiveDashboardWindow`.
When a live feed lands, implement that one function — **no card changes required**.

The data shape intentionally mirrors the native app's `DashboardUsageWindowSummary`
so the eventual live mapping is 1:1.

## Decisions adopted (smallest coherent PR)

1. **Mock-with-seam now**; the backend usage endpoint is a separate PR (below).
2. **Vendor the kernel by porting the prototype's self-contained GLSL** (with
   attribution), not the coupled sibling factory.
3. **Backdrop scoped to `/dashboard`** — `DotCrestField` stays the global ambient.
4. Cards bind to **Pensieve tokens**, never hardcoded hex (bar the glass sheen).

## Follow-ups (out of scope; flagged, not done)

- **Live usage feed**: `GET /v1/usage` on the daemon *and/or* a Cloud Function
  serving aggregate usage to the static console → flips cards 1–6 live and unblocks
  The Wand (fusion rows) — flip `loadLiveDashboardWindow`.
- **Aggregate TPS**: none exists server-side today (per-message, mobile-only). The
  Throughput card shows the most-recent reading; a real aggregate makes it live.
- **GPU ping-pong swarm** via the sibling `createSimPass` for richer formation physics.
- **`react-grid-layout`** only if free-form collision reflow becomes a requirement
  (today: snap-to-grid + top-left free-slot placement, no reflow).
- **Promote the WebGL backdrop globally** once proven on the dashboard route.

## Credits

Backdrop kernels ported from the Liquid Glass Studio prototype, whose GLSL descends
from `imaginethat-llc/src/kernels`.
