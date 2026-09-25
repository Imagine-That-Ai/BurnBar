# Claude UI Agent Handoff: Routing-Aware Provider Account Cockpit

## Mission

Polish the UI for quota-aware provider routing. Backend/router logic exposes
account-level routing state; the UI work is to make the active lane, fallback
lane, blocked lanes, and switch reasons obvious without exposing credential
material.

## Backend Contract To Consume

- `ProviderRoutingStateSnapshot`
  - `activeAccount`
  - `nextFallback`
  - `exhaustedOrCoolingDownAccounts`
  - `lastSwitchReason`
  - `ProviderRoutingDecisionEvent`
  - selected provider/account labels
  - next fallback labels
  - skipped account reasons
  - sanitized plain-language decision reason
- `ProviderQuotaService.routingState(for:)`
- `ProviderQuotaService.routingStatesByProviderID`
- `ProviderQuotaService.routingEvents`

Treat provider totals and account routing health as separate concepts. Provider
quota snapshots can show aggregate pressure; routing state explains which
account is currently handling traffic and why.

## Product Experience

The user should be able to watch provider accounts behave like live routing
lanes:

- Active now
- Healthy fallback
- Draining or high usage
- Exhausted
- Cooling down
- Auth failed
- Local-only on this Mac
- Cloud-refreshable
- Last switch reason

Example copy shape: "Work hit rate limit, switched to Personal." Keep language
plain and specific. Distinguish pressure from hard exhaustion.

## Primary Surfaces

Mac:

- `AgentLens/Views/Settings/ProvidersSettingsView.swift`
- `AgentLens/Views/Dashboard/ProviderDashboardView.swift`
- `AgentLens/Views/Dashboard/ModelDashboardView.swift`
- `AgentLens/Views/Popover/MenuBarPopoverView.swift`

Mobile/iPad:

- `OpenBurnBarMobile/Views/ProviderConnectionsView.swift`
- `OpenBurnBarMobile/Views/QuotaView.swift`
- `OpenBurnBarMobile/Views/QuotaDetailSheet.swift`
- `OpenBurnBarMobile/Views/RootNavigationView.swift`

## UI Requirements

- Show provider totals separately from account routing state.
- Make the active account unmistakable.
- Show the next fallback account/provider when available.
- Explain switch reasons in plain language.
- Distinguish usage pressure from hard exhaustion.
- Avoid scary or vague security copy.
- Never expose raw credentials, secret refs, cookies, bearer strings, or API keys.
- Use native, calm control-panel styling. No marketing hero treatment.

## Security Boundary

Routing event text is sanitized and intentionally omits credential handles. Do
not render `credentialHandle` or any string that looks like an API key, bearer
token, cookie, credential, `secretVersionName`, or Secret Manager path. Prefer
account labels, provider labels, storage scope labels, and sanitized event
reasons.

## Acceptance Bar

A user looking at three OpenAI accounts should immediately understand:

- Which account is handling traffic.
- Which account will take over next.
- Which account is blocked and why.
- Whether the router is acting automatically or needs attention.
- That credential material is never visible.

## Implementation Status (2026-05-03)

Implemented as `ProviderRoutingCockpit` — a single shared visual contract
rendered on every account-bearing surface across Mac and Mobile/iPad. Anchored
on the package-level `ProviderRoutingStateBuilder` so iPhone, iPad, and Mac
make the same router decision for the same account/quota inputs.

### Shared core (`OpenBurnBarCore`)

- `ProviderRoutingStateBuilder` (`SharedModels/ProviderRoutingStateBuilder.swift`)
  derives a `ProviderRoutingStateSnapshot` from synced `ProviderAccountDoc`s
  and per-account `ProviderQuotaSnapshot`s using `ProviderRoutingPolicy.decide`.
  Inputs are deterministic (default → sortKey → label tiebreaker) and the
  builder synthesizes a non-secret `synced:<accountID>` handle when the doc
  has no `redactedLabel` so synced surfaces never trip
  `.missingCredential` skips while still going through the router.
- `ProviderRoutingStateText` exposes the human-readable label and SF Symbol
  glyph for every `ProviderRoutingQuotaState`. Mac and Mobile bind only their
  platform-specific tints; the wording stays in lockstep.
- `ProviderRoutingStateSnapshot.hasMeaningfulRoutingDetail` is the calm-by-
  default predicate every surface uses to decide whether a cockpit earns its
  space — a lone healthy account suppresses the cockpit; a fallback, blocked,
  or non-healthy active account brings it in.
- 16 dedicated unit tests in `ProviderRoutingStateBuilderTests` cover empty
  inputs, deletion filtering, default-account promotion, deterministic order
  across Firestore reorders, status mapping (`error`/`disconnected`/
  `disabled`/`deleted`), pressure on the lowest-remaining bucket, stale
  snapshot fallback, blocked lane surfacing, secret material filtering, and
  the `hasMeaningfulRoutingDetail` predicate. Total package suite: 206 tests
  passing.

### Mac (AgentLens)

- `AgentLens/Views/Components/ProviderAccount/ProviderRoutingCockpit.swift` —
  shared cockpit with header status pill, Active / Next / Blocked lanes, last
  switch reason, and an expandable router history feed. The popover-friendly
  `compact: true` mode stacks the lanes vertically so 290pt-wide rows stay
  legible. `ProviderRoutingVisual` defers labels and icons to the package
  `ProviderRoutingStateText` and only owns Mac-specific tints.
- `ProvidersSettingsView` — renders the cockpit per provider (only when
  `hasMeaningfulRoutingDetail` or >1 account) plus a per-account routing hint
  chip (Active / Next / Blocked: <reason>) on `ProviderAccountRow`.
- `ProviderDashboardQuotaPanel` — embeds the cockpit above the quota grid,
  gated on `hasMeaningfulRoutingDetail`.
- `MenuBarPopoverView` / `ProviderQuotaPopoverViews` — expanded provider rows
  show a one-line routing hint (active → next) plus the compact, vertically
  stacked cockpit.

### Mobile / iPad (OpenBurnBarMobile)

- `OpenBurnBarMobile/Views/Components/ProviderRoutingCockpit.swift` — mobile
  cockpit (also with stacked compact mode) plus the
  `ProviderRoutingMobileVisual` binding for tints (labels and icons come from
  the package `ProviderRoutingStateText`). All callers — `QuotaStore`,
  `ProviderConnectionStore`, and the views — go directly through
  `ProviderRoutingStateBuilder.build(...)`.
- `QuotaView` — every `QuotaProviderCard` shows the compact cockpit when
  `hasMeaningfulRoutingDetail`.
- `QuotaDetailSheet` — full cockpit at the top of the detail sheet (gated on
  `hasMeaningfulRoutingDetail`).
- `ProviderConnectionsView` — group sections render the cockpit and pass an
  `AccountRoutingHint` to each `AccountRow` so a glance at the connections
  list shows which account is active, next, or blocked, with a sanitized
  blocked reason.
- `ProviderDashboardView` — quota section renders the cockpit alongside the
  unified bucket views.
- `QuotaStore.routingState(for:)` and `ProviderConnectionStore.routingState(for:)`
  delegate to the package builder.

### Security boundary

All rendered strings flow through `ProviderRoutingPolicy.sanitizedAuditText`.
The builder, cockpit views, and account row hints never read
`credentialHandle`, secret references, cookies, bearer strings, or API keys.
Only account labels, storage-scope labels, quota-state labels, and sanitized
switch reasons appear in the UI. The package contract tests
(`ProviderAccountContractTests.test_routingEventsNeverIncludeCredentialsOrSecretRefs`
and `ProviderRoutingStateBuilderTests.test_build_neverEmitsRawCredentialMaterialIntoEvents`)
encode this invariant.
