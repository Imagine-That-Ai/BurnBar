# P10 — Membership / Pro foil / checkout

**Wave 2 (after P08) · Route: `account` (membership section).**

## Mission

Port the Pro membership presence: membership band, foil-card visual identity, locked-feature veils, and the Stripe **web checkout** hand-off (Tier C substitution — StoreKit does not port; master plan §2.1). The foil aesthetic is the brand's jewelry; get it right or keep it simple — never ship a cheap imitation.

## Read first

- README §1–§2; P08's `AccountSurface` structure.
- macOS oracle: `AgentLens/Views/Components/Pro/` (`MembershipBand.swift`, `MercuryFoilCard.swift`, `FoilCTAButton.swift`, `LockedFeatureVeil.swift`, `FeatureUnlockSheet.swift`, `CloudBadge.swift`, `ProBadgeDot.swift`, `MercuryCrest.swift`), `AgentLens/Views/Chat/FusionSpend/FusionFoil.swift` (foil shader intent).
- Entitlement semantics: entitlements packages under `packages/`; daemon entitlement RPC.

## Data contract

1. Bridge: `membership_status` → `{ tier: 'free'|'pro', entitlements: string[], renewsAt?, restoreAvailable }`; `membership_checkout_url` → daemon-minted Stripe checkout URL opened via `@tauri-apps/plugin-shell` `open()` (never an embedded webview); `membership_restore` triggers daemon-side restore then re-fetch.
2. Entitlement gating: a `useEntitlement(id)` hook in `src/state/membershipStore.ts` that other lanes may consume (export is the seam; announce in PR body).
3. Fixtures: free + pro states.

## Files

`src/state/membershipStore.ts`; `src/surfaces/account/membership/` (`MembershipSection.tsx`, `FoilCard.tsx`, `LockedVeil.tsx`, `FoilButton.tsx`) + tests; edit `AccountSurface.tsx` to mount the section (coordinate with P08 — this is the one intentional cross-lane file edit; leave a Cross-agent receipt); `app.css` `/* ---- P10 membership ---- */`.

## Build steps

1. `FoilCard`: CSS-only foil — layered `conic-gradient` + `radial-gradient` with subtle hue drift on hover (`transition` only; zero animation loops). Under reduced motion and `prefers-contrast: more`, render the static gradient. Test on WebKitGTK before merging (packaged smoke screenshot).
2. `FoilButton`: `.primary` variant with the foil treatment; disabled state loses the foil (no shiny disabled buttons).
3. `LockedVeil`: wraps a section with blur + lock copy + unlock CTA; the veiled content must be `inert` and excluded from tab order.
4. `MembershipSection`: tier band, renewal line, checkout/restore actions, entitlement list.

## Required states

Free / Pro / loading / checkout-in-flight (external browser opened; "waiting for confirmation" with manual re-check) / restore-in-flight / error / offline.

## A11y / Perf / Tests

- Veiled content unreachable by keyboard/AT (`inert` attribute); tier changes announced.
- Foil is GPU-cheap: gradients only, no filters over large areas, no rAF.
- Tests: gating hook (free hides, pro shows), checkout opens external URL (mock plugin-shell), restore re-fetch, veil inertness, all states.

## Done / Forbidden

README §4. Forbidden: embedded checkout webviews; entitlement decisions computed shell-side; foil via JS animation loops; shipping without a packaged-screenshot check of the foil on WebKitGTK.
