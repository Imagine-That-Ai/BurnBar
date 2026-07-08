# P08 — Account & sync trust surface

**Wave 1 · Route: `account`.**

## Mission

Make the lower-trust Linux cloud identity legible: signed-out/signed-in states, sync posture (local-canonical vs encrypted sync), and quota/entitlement summary — all with explicit trust copy. Linux is a lower-trust principal by design (master plan §2.2); this surface must say so, beautifully.

## Read first

- README §1–§2; existing `AccountSurface.tsx` (its `[data-failure-state]` rows are evidence-pinned: `login-required`, `sync-paused`, `quota-exhausted` — keep ids).
- macOS oracle: account/membership views (`AgentLens/Views/Components/Pro/MembershipBand.swift` for the band idiom; full Pro visuals are P10).
- Trust posture: `docs/linux-port/cloud-security-runbook.md`, master plan §9.4 (W3).

## Data contract

1. Bridge: `account_status` → `{ signedIn, identityLabel?, trustClass: 'linux-lower-trust', syncState: 'local-only'|'paused'|'active', lastSyncAt? }` from the daemon's config/cloud RPC.
2. Sign-in itself is daemon/browser-mediated in v1: the surface renders instructions + a "Check again" refresh, not a credential form. Never collect credentials in the shell.
3. Fixtures for signed-out, signed-in+active, signed-in+paused.

## Files

`src/state/accountStore.ts`; `src/surfaces/account/` (`AccountSurface.tsx` rework, `TrustBadge.tsx`, `SyncStateCard.tsx`) + tests; one-line `SurfaceRouter` edit; `app.css` `/* ---- P08 account ---- */`.

## Build steps

1. `TrustBadge`: pill naming the trust class ("Linux · lower-trust identity") with a disclosure explaining what that limits (high-risk actions require step-up on a trusted device).
2. `SyncStateCard`: three-state visual (local-only / paused / active) with the invariant sentence "Local SQLite remains canonical" always visible; last-sync timestamp when active.
3. Keep the existing failure-state list beneath the new cards.
4. Signed-out hero: calm, not nagging — local-first is a supported mode, not an error.

## Required states

Signed-out / signed-in+active / signed-in+paused / loading / error / offline. (Six — sync tri-state counts as populated variants.)

## A11y / Perf / Tests

- Trust disclosure is a real `button[aria-expanded]`; state changes announced politely.
- Tests: all six states, refresh action, failure-state ids stable, no credential inputs exist (assert `container.querySelector('input[type="password"]') === null`).

## Done / Forbidden

README §4. Forbidden: credential forms; hiding the local-canonical invariant; claiming higher trust than the daemon reports.
