# Linux UI parity — master execution plan

**Mission:** bring the Linux desktop shell (`apps/linux-desktop/`) to full macOS UI parity (`AgentLens/`, 569 SwiftUI views) per `docs/LINUX_PORT_MASTER_PLAN.md` §9.7–§9.8 (W6/W7) and the G3 gate. This directory is a hand-holding execution plan: any competent agent should be able to pick up one packet, follow it literally, and land a reviewable PR without asking questions.

**Status:** the W6 foundation is **implemented** (React 19 + Zustand + design-token shell, see §2). Packets P01–P15 build the W7 surfaces on top of it.

---

## 1. Ground rules (read before any packet)

1. **The foundation is the law.** Reuse `src/components/*` primitives and `src/state/shellStore.ts`. Never hand-roll a card, table, banner, pill, or offline state. If a primitive is missing, add it to `src/components/` with a doc comment and a test — do not inline it in a surface.
2. **Honest degraded states, always.** A surface renders exactly one of: live daemon data (labelled), fixture data (labelled `fixture transcript`), or `OfflineNotice`. Never mock data silently. This is a parity invariant (master plan §2.2), not a style choice.
3. **Design tokens only.** Colors, spacing, radii, fonts come from `src/styles/tokens.css` (generated from `packages/design-tokens/`) and the skin layer in `app.css`. Hex literals in surface code are a review-blocking defect (provider accent colors live in `src/providerGlyphs.ts`).
4. **Evidence contracts are load-bearing.** Do not rename or restructure without reading §5:
   - perf sample names (`app.start`, `route.navigation`, `ipc.health.roundtrip`, `chat.firstToken.progress`, `db.migration.open.query`, `parser.incremental.run`, `memory.search`, `media.control.stage`);
   - a11y landmarks (`a.skip-link[href="#main"]`, `nav[aria-label="Primary"]`, `main#main`, `#route-title`, `button.nav-link[aria-current="page"]`, `.status-pill[role="status"]`);
   - localStorage keys (`openburnbar.linux.onboarding.v1`, `openburnbar.linux.textExpansion.v1`, `openburnbar.linux.textExpansion.consent.v1`, `openburnbar.linux.daemonFixture`, `openburnbar.linux.skin.v1`);
   - the literal CSS strings `body.reduced-motion *`, `animation: none`, `transition: none` in `app.css`.
5. **Nav rail geometry is frozen.** `scripts/linux-port/linux-desktop-session.sh` clicks nav items at fixed pixel coordinates. Never change nav padding, gaps, font sizes, or item order. Never add or remove routes without packet P15 updating the click coordinates in the same PR.
6. **Reduced motion is absolute.** Every animation must die under `body.reduced-motion`. The global CSS rule handles CSS animation; JS-driven animation (canvas, rAF) must check `prefers-reduced-motion` like `petGltfRuntime.ts` does.
7. **Scope discipline.** One packet = one PR lane (fast lane per `AGENTS.md`). Do not drive-by refactor another lane's surface. Follow the software-factory PR loop: cheap local checks → commit → push → PR with validation + risks → factory review.
8. **No new suppressions** (`scripts/ci/check-no-suppressions.sh` is fail-closed). No `eslint-disable`, `@ts-*` without an inline `reason:`.

**Local checks for every packet PR:**

```bash
cd apps/linux-desktop
npx tsc --noEmit      # types
npm test              # vitest (unit + component + evidence harness)
npm run build         # vite production build
```

Packaged evidence (Docker required; run when the packet claims packaged behavior):

```bash
node scripts/linux-port/run-shell-smoke.mjs
```

---

## 2. Foundation reference (implemented — study before building)

| Layer | File | What it gives you |
|---|---|---|
| Entry | `src/main.tsx` | boot sequence, perf `app.start`, onboarding redirect, React mount |
| Shell state | `src/state/shellStore.ts` | Zustand store: route, health, fixture mode, skin, bridge; `useDaemonStatusCopy()`; perf-measured `setRoute` |
| Layout | `src/app/App.tsx` | skip link → NavRail → `main#main`; hashchange sync; skin application |
| Router | `src/surfaces/SurfaceRouter.tsx` | route → surface registry (**the one map each packet edits**) |
| Nav | `src/components/NavRail.tsx` | geometry-frozen rail; status pill; skin toggle |
| Primitives | `src/components/` | `SurfaceCard`, `DataTable`, `Banner`, `OfflineNotice`, `FailureStateList`, `StatusPill`, `ProviderGlyphs`, `Sparkline`, `MeshBackdrop` |
| Shared data section | `src/surfaces/DaemonDataSection.tsx` | live/fixture/offline honest tri-state — the pattern every data surface follows |
| Bridge | `src/tauriBridge.ts` + `src-tauri/src/lib.rs` | typed Tauri `invoke` seam to the AF_UNIX daemon socket |
| Fixtures | `src/daemonFixture.ts` | per-route fixture rows (`FIXTURE_ROWS`, append-only) |
| Styles | `src/styles/tokens.css` (generated) + `src/styles/app.css` | token canon + skin layer + component styles |
| Tests | `src/app/App.test.tsx` | the component-test idiom: reset store, render `<App/>`, drive `setRoute`, assert DOM contracts |

**How a packet replaces a generic surface** (the only edit to shared files most packets need):

```tsx
// src/surfaces/SurfaceRouter.tsx — replace one line in SURFACES:
-  missions: makeDaemonSurface('missions', 'Missions'),
+  missions: MissionsSurface,
```

**How a packet extends the daemon bridge** when it needs a new RPC method:

1. Find the real method in `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPC*.swift` (Memory, MissionControl, Search, Usage, ComputerUse, Tooling, Config) and `BurnBarDaemonSocketRPCCoverage.swift`. Never invent method names.
2. Add a Tauri command in `src-tauri/src/lib.rs` (append after existing commands; copy the `daemon_health` socket-envelope pattern: newline-framed JSON, `protocolVersion: 1`, auth token file).
3. Add the typed method to `LinuxShellBridge` in `src/tauriBridge.ts`.
4. Add fixture rows to `FIXTURE_ROWS` for the route (append-only).
5. Surface consumes it through a lane-local store `src/state/<lane>Store.ts` — never widen `shellStore.ts`.

---

## 3. Packet index and parallelism map

Packets are self-contained; **Wave 1 packets can run fully in parallel** (disjoint files except the one-line `SURFACES` edit each — rebase is trivial). Wave 2 packets depend on named Wave 1 outputs.

| Packet | Surface | Wave | Depends on | Routes touched |
|---|---|---|---|---|
| [P01](packets/P01-dashboard-overview.md) | Dashboard overview + cost ticker | 1 | — | `overview` |
| [P02](packets/P02-providers-quota.md) | Providers, models, quota cockpit | 1 | — | `providers` |
| [P03](packets/P03-activity-sessions-search.md) | Activity, session logs, search | 1 | — | `activity` |
| [P04](packets/P04-chat-hermes.md) | Chat/Hermes, tool cards, thinking | 2 | P01 (ticker seam) | `chat` |
| [P05](packets/P05-insights-observatory.md) | Insights / editorial observatory | 1 | — | `insights` |
| [P06](packets/P06-missions-operating.md) | Missions / operating controller | 1 | — | `missions` |
| [P07](packets/P07-settings-system.md) | Settings, database, projects, memory | 1 | — | `settings`, `database`, `projects`, `memory` |
| [P08](packets/P08-account-sync.md) | Account & sync trust surface | 1 | — | `account` |
| [P09](packets/P09-updates-support.md) | Updates + Support diagnostics | 1 | — | `updates`, `support` |
| [P10](packets/P10-membership-pro.md) | Membership / Pro foil / checkout | 2 | P08 | `account` (section) |
| [P11](packets/P11-pet-companion.md) | Pet companion polish + tiers | 1 | — | `pet` |
| [P12](packets/P12-mercury-media.md) | Mercury media surfaces | 2 | P04 (stream idiom) | `support` (section) + future route |
| [P13](packets/P13-smarthub-devices.md) | SmartHub/Cast/HA/PixelClock | 2 | P07 | `settings` (section) |
| [P14](packets/P14-text-expansion.md) | Text expansion v1 polish | 1 | — | `text-expansion` |
| [P15](packets/P15-proof-book-harness.md) | Visual proof book, a11y, perf harness | continuous | all | evidence only |

**Shared-file seams (append-only, single-section ownership):**

- `src/surfaces/SurfaceRouter.tsx` — each lane replaces only its own `SURFACES` entries.
- `src/daemonFixture.ts` — append your route's rows to `FIXTURE_ROWS`; never edit other routes' rows.
- `src/styles/app.css` — append a delimited section `/* ---- P0X <lane> ---- */` at the end; never edit the foundation/nav sections.
- `src/tauriBridge.ts` / `src-tauri/src/lib.rs` — append your commands; never reorder existing ones.
- `src/state/shellStore.ts`, `src/app/App.tsx`, `src/components/NavRail.tsx`, `src/routes.ts` — **foundation-owned; packets do not edit** (route additions go through P15).

---

## 4. Definition of done (every packet)

A packet is done when all of the following are true:

1. Surface renders all five states: **populated** (live or fixture), **loading**, **empty**, **error**, **degraded/offline** — each with honest provenance copy.
2. Keyboard-only traversal reaches every control; focus order is logical; interactive elements have accessible names.
3. `npx tsc --noEmit`, `npm test`, `npm run build` all pass; new component tests cover the five states plus each interaction.
4. No hex color literals, no geometry edits to the nav rail, no renamed evidence contracts.
5. Reduced-motion verified (no animation under `body.reduced-motion`).
6. PR body includes: what changed, validation run, known risks, and a `Cross-agent receipt` when reacting to another lane.
7. `docs/linux-port/parity-ledger.json` row(s) for the surface updated by P15 (or flagged in the PR body for P15 pickup).

---

## 5. Evidence and gate wiring

- Unit/component/evidence-harness: `npm test` (harness emits artifacts when `OB_EVIDENCE_OUT` is set).
- Packaged desktop session (screenshots, AT-SPI tree, tray transcript, runtime perf): `node scripts/linux-port/run-shell-smoke.mjs` → artifacts in `docs/linux-port/evidence/mission-001-shell-ux/`.
- Perf budgets: `npm run perf:budget` after a packaged session (`budgets/linux-desktop.perf.json` thresholds).
- G3 exit (master plan §7.2): every surface renders real fixture data; interaction scripts pass; Aurora/Editorial proof book green; keyboard-only + AT-SPI2 snapshots green; reduced-motion verified.
- Parity ledger: `node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked` structural check on every PR.

---

## 6. Source-of-truth pointers (macOS)

The macOS app is the design oracle. Read the SwiftUI source for interaction/data semantics, then re-express it with Linux foundation primitives — never port SwiftUI code literally (master plan §5.4).

- Dashboard chrome: `AgentLens/Views/Dashboard/` (`BurnBarTopRail.swift`, `CastleGreatHallView.swift`, `ConstellationBackgroundView.swift`, `CommandDeckPalette.swift`)
- Chat: `AgentLens/Views/Chat/` (`ChatPanel.swift`, `Components/`, `HermesToolCard.swift`, `HermesThinkingView.swift`, `PaneWorkspace/`)
- Quota: `AgentLens/Views/Components/ProviderQuota/` + `ProviderDashboardQuotaPanel.swift`
- Provider accounts/routing: `AgentLens/Views/Components/ProviderAccount/`
- Pro/membership: `AgentLens/Views/Components/Pro/`
- Operating/missions: `AgentLens/Views/Components/Operating/`
- Computer Use: `AgentLens/Views/ComputerUse/`
- Visual language: `docs/` Liquid Glass / Editorial / Swarm design docs; tokens in `packages/design-tokens/tokens/pensieve.tokens.json`
