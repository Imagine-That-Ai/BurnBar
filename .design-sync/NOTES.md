# design-sync notes — OpenBurnBar Console

The design system synced to claude.ai/design is **`apps/console`** (Next.js 15 / React 19), project **"Design System"** (`f21e8d7b-5de3-44ac-aebc-d647a31ace98`). 9 components: Button, Badge, Card, Dialog, Progress (primitives); BrandMark, DotCrestField, TierGlyph, TierBadge (brand).

## How this repo builds (it's an app, not a published library)
- **No `dist/` barrel** → bundled from a scoped barrel `apps/console/.ds-entry.tsx` via `cfg.entry`, with `@/` aliases resolved through `cfg.tsconfig` (`apps/console/tsconfig.json`). The barrel re-exports only the synced components, so esbuild does NOT drag in firebase/feature code.
- **Component list** comes entirely from `cfg.componentSrcMap` (there are no shipped `.d.ts`).
- **Contracts (`dtsPropsFor`) are hand-written** in `.design-sync/config.json` — source extraction yields `{[key]: unknown}` in synth mode. **If a component's props change, update `cfg.dtsPropsFor.<Name>` by hand.**
- **CSS** is compiled by `apps/console/.ds-build-css.mjs` → `apps/console/.ds-preview.css` (gitignored), pointed at by `cfg.cssEntry`. It concatenates Pensieve base tokens + `globals.css` (editorial overrides) and runs the app's Tailwind/PostCSS, then prepends the Google-Fonts `@import`. The shipped utility set is therefore the **tree-shaken subset the console source actually uses** — designs do NOT get a full Tailwind. The conventions header steers the design agent to tokens + components accordingly.
- **`buildCmd`** = `(cd apps/console && npm run sync:domains && node .ds-build-css.mjs .ds-preview.css)`. `sync:domains` regenerates `lib/domains.generated.ts` (needed for TierBadge) and `styles/pensieve.tokens.css` (the base tokens). Both are gitignored — re-run buildCmd on a fresh clone.

## Grouping shims
`apps/console/components/brand/{TierGlyph,TierBadge}.tsx` are **re-export shims** so those two file under the `brand` group (their real impls live in `components/basin/` and `components/inventory/`). `componentSrcMap` points at the shims. The app imports the real paths, not these.

## Brand assets (BrandMark / DotCrestField) — RE-SYNC RISK
- `BrandMark` and `DotCrestField` reference host-app assets at absolute `/brand/...` URLs. `package-build` wipes `ds-bundle/`, so the assets must be **copied in AFTER each build, before validate/upload**:
  `mkdir -p ds-bundle/brand && cp apps/console/public/brand/burnbar-logo.png apps/console/public/brand/burnbar-logo-mark.png ds-bundle/brand/`
  and `brand/**` must stay in the upload plan's `writes`. Without this, BrandMark loses its logo.
- **DotCrestField is intentionally a floor card** — it's a full-viewport ambient canvas needing ~33 runtime assets; its rich `.prompt.md` carries it. To author a real preview you'd need to ship the full `/brand/` roster.
- Whether `/brand/*.png` resolves inside the claude.ai/design DS-pane card iframe is unverified; if BrandMark shows broken in the pane it falls back to alt text. Re-uploads are cheap.

## Known render warns (treat as clean)
- `[FONT_REMOTE]` for Geist / Geist Mono / Bricolage Grotesque / Newsreader — fonts load from Google Fonts via the `@import` in `cssEntry`. Expected; this is how the app serves them.
- `[FONT_REMOTE]` also lists **"Fraunces Variable" (`--font-arcane`)** — referenced by the Tailwind `font-arcane` utility but unused by the synced components. Harmless.
- tokens "N missing, below threshold" — non-blocking.

## Re-sync sequence
1. `cp -r <skill>/…` to refresh `.ds-sync/`, `npm i` deps if needed.
2. Run `buildCmd`.
3. `node .ds-sync/package-build.mjs --config .design-sync/config.json --node-modules apps/console/node_modules --out ./ds-bundle`
4. **Copy brand assets into `ds-bundle/brand/`** (see above).
5. `node .ds-sync/package-validate.mjs ./ds-bundle` (needs playwright+chromium).
6. Upload (writes must include `brand/**`).

Grades carried in `.design-sync/.cache/review/` (gitignored); durable verified-state is the uploaded `_ds_sync.json`.
