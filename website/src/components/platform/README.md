# Platform mockup system

Faithful, animated, data-driven device mockups for the marketing site. Two
shipping devices today (Google Nest Hub, ULANZI TC001 pixel clock) — adding
a third is one data row + one screen component.

## File map

```
src/
  components/platform/
    PlatformShowcase.astro   ← section wrapper used by /, /router, /product, /platforms
    DeviceFrame.astro        ← hardware bezels: kind="nest-hub" | "ulanzi-tc001"
    NestHubScreen.astro      ← live re-render of NestHubMiniPreview.swift content
    PixelMatrix.astro        ← 32×8 LED renderer (Astro + CSS grid)
    README.md                ← this file
  data/
    platform-surfaces.ts     ← PlatformDevice manifest
    surfaces.ts              ← every surface row (mockup or not)
scripts/lib/
  pixel-clock-presenter.mjs  ← JS port of PixelClockFramePresenter (used by SSR + tests)
public/
  platform-mockups.js        ← CSP-safe runtime hydrator (clock tick + frame ticker + live rundown fetch)
pages/
  platforms/index.astro      ← deep-dive route with surface matrix
```

## Adding a new device (e.g. Apple TV)

1. **Declare it.** Add a row to `SURFACES` in `surfaces.ts` if it isn't there
   already — that's what populates the surface matrix on `/platforms`.

2. **Register the mockup.** Add a row to `PLATFORM_DEVICES` in
   `platform-surfaces.ts`:

   ```ts
   {
     id: "apple-tv",
     name: "Apple TV",
     formFactor: "Apple · 4K HDR · tvOS 18+",
     blurb: "BurnBar on the living-room TV — passive ambient when idle, full burn dashboard on demand.",
     surfaceId: "smart-display",
     mockup: "apple-tv",
     aspect: { w: 16, h: 9 },
     marqueeBullets: [...],
     setupHref: "...",
     setupLabel: "...",
   }
   ```

3. **Build the screen.** Add `AppleTvScreen.astro` next to `NestHubScreen.astro`.

4. **Build the chassis (if needed).** Add a `kind: "apple-tv"` branch to
   `DeviceFrame.astro`.

5. **Dispatch.** Add the case to `PlatformShowcase.astro`'s inline switch
   (next to `mockup === "nest-hub"`).

6. **Test.** Extend `scripts/test-platform-mockups.mjs` with any new glyphs
   or layout invariants for the new device.

`PlatformShowcase` auto-renders every entry in `PLATFORM_DEVICES` — no
template churn.

## Fidelity contract

The mockups must mirror the real device code. When the Swift previews
change:

- `NestHubScreen.astro` ← `OpenBurnBarCore/.../NestHubMiniPreview.swift`
- `PixelMatrix.astro` + `scripts/lib/pixel-clock-presenter.mjs` ←
  `OpenBurnBarCore/.../PixelClockPreviewView.swift`
- Re-run `node scripts/test-platform-mockups.mjs` to catch glyph drift.

## Live-data wiring

- Build-time fallback comes from `@data/router-rundown-loader`'s
  `LATEST_RUNDOWN` (same fixture the rundown report uses).
- Runtime hydration fetches `/api/router-rundown/latest` via the Firebase
  Hosting rewrite into the `latestRouterRundown` Cloud Function. The
  hydrator script is opportunistic — if the fetch fails, the SSR frame
  stays put.

## Reduced motion

Every animation (clock tick, frame ticker, bucket scan, live-dot pulse,
matrix repaint interval) is gated by
`matchMedia("(prefers-reduced-motion: reduce)")`. Static SSR frames keep
the mockup useful with motion off.

## CSP

`firebase.json` enforces `script-src 'self'` — no inline scripts allowed.
The hydrator ships as `/platform-mockups.js`, sourced via `<script src=...
defer>` in `PlatformShowcase.astro`. All animation state lives in
JavaScript variables in that one file; no `<script>` tags in components.
