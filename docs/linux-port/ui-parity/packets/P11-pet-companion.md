# P11 — Pet companion polish + tier truthfulness

**Wave 1 · Route: `pet`.**

## Mission

Elevate the pet surface from evidence scaffold to product: live tier detection (real env, not hardcoded), behavior-graph visualization, stage polish, and interaction (poke/react) — while keeping every tier claim honest per DE.

## Read first

- README §1–§2; existing `PetSurface.tsx`, `petGltfRuntime.ts`, `petCompanion.ts`, `petBehaviorGraph.ts` (all evidence-pinned: `parseGlb`, tier matrix, behavior graph tests).
- macOS oracle: PetCompanion views/behavior under `AgentLens/` (search `PetCompanion`); master plan §9.9 (W8) for tier policy.
- Evidence: `pet-runtime-behavior-evidence.json` expectations in `shellEvidence.harness.test.ts`.

## Data contract

1. Tier detection must use the real session env: add a Tauri command `session_env` returning `{ XDG_SESSION_TYPE, XDG_CURRENT_DESKTOP }`; fall back to the current hardcoded GNOME/Wayland pair in browser preview (labelled "preview assumption").
2. Keep `data-overlay-tier`, `data-input-passthrough`, `draggable`, and `data-pet-runtime` attributes — packaged evidence reads them.
3. No new daemon RPC needed.

## Files

Edit `src/surfaces/PetSurface.tsx`; create `src/surfaces/pet/BehaviorGraphView.tsx`, `src/surfaces/pet/TierMatrixTable.tsx` + tests; `tauriBridge.ts`/`lib.rs` append `session_env`; `app.css` `/* ---- P11 pet ---- */`.

## Build steps

1. Real env tier: `detectPetTierFromEnv(await bridge.sessionEnv())`; preview fallback labelled in the UI.
2. `BehaviorGraphView`: replace the raw JSON `<pre>` with a rendered node graph (SVG boxes + arrows from `buildPetBehaviorGraph`), keeping the `<pre class="pet-graph">` available behind a "Show raw graph" disclosure (evidence continuity).
3. Poke interaction: clicking the stage triggers the `react-wave` node visually (canvas pulse via the existing point-cloud renderer hook or a CSS pulse on the stage border); reduced-motion renders a static highlight.
4. `TierMatrixTable`: render `petTierMatrix()` as a `DataTable` so users see per-DE expectations.

## Required states

Runtime-loaded / runtime-error (asset fetch fails — keep `role="alert"` copy) / overlay tier / draggable-contained tier / reduced-motion static.

## A11y / Perf / Tests

- Stage keeps `role="img"` + label; poke also available as a labelled button ("Wave at pet") — never click-only.
- Canvas loop already respects reduced motion; keep DPR cap at 2.
- Tests: tier from bridge env vs preview fallback, graph view renders all nodes, raw-graph disclosure, poke button triggers react state, error state.

## Done / Forbidden

README §4. Forbidden: claiming pass-through on GNOME Wayland; removing evidence dataset attributes; second rAF loop alongside the runtime's.
