# P02 — Providers, models, quota cockpit

**Wave 1 · Route: `providers` · Replaces `ProvidersSurface`'s generic table.**

## Mission

Port the provider/quota experience: provider cards with glyph identity, quota buckets with pacing bars, account chips, and the routing cockpit summary. Quota truth is Tier A parity — numbers must come from the daemon, never recomputed in the shell.

## Read first

- README §1–§2.
- Current: `src/surfaces/ProvidersSurface.tsx`, `src/components/ProviderGlyphs.tsx`, `src/providerGlyphs.ts`.
- macOS oracle: `AgentLens/Views/Components/ProviderQuota/` (`ProviderQuotaChip.swift`, `ProviderQuotaBucketViews.swift`, `ProviderQuotaPacingViews.swift`, `ProviderQuotaCommandCenterViews.swift`), `ProviderDashboardQuotaPanel.swift`, `AgentLens/Views/Components/ProviderAccount/` (`ProviderAccountChips.swift`, `ProviderRoutingCockpit.swift`, `DrainTargetSwitcher.swift`).
- Provider path docs: `docs/PROVIDERS.md`.

## Data contract

1. Find quota/provider-account RPC methods in `BurnBarDaemonServer+RPCUsage.swift` / `+RPCConfig.swift`; note the `quota_state` / bucket vocabulary already in daemon models (`cooling_down`, `missing_credential`, …).
2. Bridge: `provider_catalog` → `LinuxShellBridge.providerCatalog()` returning providers with `{ id, label, accountLabel, quotaBuckets: {id,label,usedPct,resetsAt,state}[] }`.
3. Extend `src/providerGlyphs.ts` only by appending new providers (append-only; ids must match daemon `provider_id`s).
4. Fixture: `fixtureProviderCatalog()` in `daemonFixture.ts` with at least one provider per quota state (ok, cooling_down, missing_credential, exhausted).

## Files

- Create: `src/state/providersStore.ts`; `src/surfaces/providers/ProviderCard.tsx`, `QuotaBucketBar.tsx`, `AccountChips.tsx`; `src/surfaces/providers/ProvidersSurface.test.tsx`.
- Modify: `src/surfaces/ProvidersSurface.tsx` (glyph strip stays; cards replace the generic table).
- Append: `app.css` `/* ---- P02 providers ---- */`.

## Build steps

1. `QuotaBucketBar`: track + fill using `--ds-accent-gradient`; width = `usedPct`; state color via tier tokens (`--color-tier-*`), label + reset time right-aligned; `role="meter"` with `aria-valuenow/min/max` and an accessible name.
2. `ProviderCard`: glyph dot + label header, account chip, bucket list, quota-state badge reusing `StatusPill` tones.
3. Grid of cards (`repeat(auto-fill, minmax(320px, 1fr))`); keyboard focusable card actions only (no clickable-div cards).
4. Keep `data-provider` hooks on glyph chips (evidence contract).

## Required states

Populated (≥1 provider per quota state) / Loading skeleton / Empty ("No providers linked — connect from the daemon settings") / Error banner with retry / Offline (`OfflineNotice`).

## A11y / Perf / Tests

- Meters announce name + percentage; badges are text, not color-only.
- No polling; refresh on route enter + manual refresh action.
- Tests: bucket math renders exact percentages; each quota state maps to the right tone; fixture catalog renders all states; keyboard traversal order.

## Done / Forbidden

README §4. Forbidden: computing quota percentages from raw counts in the shell (daemon provides them); non-token colors; editing other lanes' fixture rows.
