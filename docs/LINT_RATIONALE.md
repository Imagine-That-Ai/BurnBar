# Lint & suppression rationale — the strictness contract

OpenBurnBar runs every linter at maximum **defect-catching** strictness with **zero
baseline drift**. The permanence guarantee is enforced in CI by
[`scripts/ci/check-no-suppressions.sh`](../scripts/ci/check-no-suppressions.sh): a
fail-closed meta-gate that blocks any _new_ lint/type suppression or checked-in
baseline from entering the tree without an explicit, greppable justification. Its
behaviour is itself regression-tested by
[`scripts/ci/check-no-suppressions.test.sh`](../scripts/ci/check-no-suppressions.test.sh).

This file is the **single source of truth** for what is deliberately allowed. If a
suppression is not justified inline (below) and not listed in the allowlist (below),
the gate fails the build. There is no separate baseline file to drift.

## What the gate detects

The gate scans tracked files for:

| Class                              | Pattern                                                                        | Where                                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Debt budget file                   | `budgets/*.json` (incl. nested)                                                | `budgets/`                                                                          |
| Lint baseline file                 | basename matches `*baseline*.{xml,yml,yaml}`                                   | anywhere                                                                            |
| Baseline re-introduction in config | `--baseline`, `detekt-baseline`, `swiftlint-baseline`, `baseline = file(…)`    | `*.gradle{,.kts}`, `detekt*.y[a]ml`, `.swiftlint.yml`, `.github/workflows/*.y[a]ml` |
| ESLint suppression                 | `eslint-disable`, `-line`, `-next-line`                                        | `*.{ts,tsx,mts,cts,js,jsx,mjs,cjs,astro,vue,svelte}`                                |
| TypeScript escape                  | `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck` (comment-leading, incl. `///`) | same as ESLint                                                                      |
| Python lint waiver                 | `# noqa`                                                                       | `*.{py,pyi}`                                                                        |
| Kotlin/Java suppression            | `@Suppress(`, `@file:Suppress(`, `@SuppressLint(`, `@SuppressWarnings(`        | `*.{kt,kts,java,gradle}`                                                            |
| detekt inline waiver               | `// detekt:`                                                                   | `*.{kt,kts,java,gradle}`                                                            |
| SwiftLint suppression              | `swiftlint:disable`                                                            | `*.swift`                                                                           |
| Rust lint allow                    | `#[allow(` / `#![allow(`                                                       | `*.rs`                                                                              |

## How to justify a suppression

**1. Inline `reason:` token (preferred — granular, self-documenting).**
Put a `reason: <why>` marker **inside a comment** on the directive's own line — or on a
comment line **directly above** it (where `rustfmt` relocates an attribute's comment,
and the natural spot for a multi-line directive). The marker must be in comment position
(not inside the directive's own string arguments) and carry real text (≈8+ chars), so it
cannot be gamed. Examples:

```kotlin
@Suppress("LargeClass") // reason: cohesive crypto facade kept whole for Swift byte-parity.
```

```rust
// reason: crate-root re-exports of UniFFI-exported types; not referenced in-crate.
#[allow(unused_imports)]
```

```swift
// swiftlint:disable:next force_try // reason: test-only precondition, never ships.
```

**Python `# noqa`:** a _coded_ waiver (`# noqa: E402`, `# noqa: S608,N802`) is accepted on
its own — the code names exactly what is waived and `ruff` enforces it is real and still
needed (`RUF100`). A **bare `# noqa`** is rejected; add the code(s) or a `reason:`.

**ESLint:** the directive's native `-- <description>` counts as justification, e.g.
`// eslint-disable-next-line no-console -- prints CLI banner to stdout`.

**2. Allowlist an exact path (for whole-file or generated artifacts).**
Use this only for generated lint baselines, tracked debt-budget files, and genuine
file-level suppressions. **Exact paths only — globs are rejected**. A stale path warns
and grants no amnesty, so deleting the underlying artifact still removes the waiver in
practice. For a source file, scope the entry to the permitted token kind with
`path | kind[,kind]`; any _other_ suppression kind in that file is still gated.
Kinds: `eslint-disable`, `ts-suppress`, `noqa`, `kotlin-suppress`, `detekt`,
`swiftlint-disable`, `rust-allow`.

<!-- BEGIN:suppression-allowlist -->

```text
# Exact paths only (globs rejected). `path | kind[,kind]` scopes a source file to
# the named occurrence kind(s); a bare path allows a budget/baseline artifact.

# --- Debt-budget ratchets: deleted at zero; CI fails on increase (docs/TECH_DEBT_METRICS.md) ---
budgets/datastore-isolation-baseline.json
budgets/hand-maintained-ts-baseline.json
budgets/knip-baseline.json
budgets/raw-firestore-baseline.json
budgets/singleton-baseline.json
budgets/string-any-boundary-baseline.json
budgets/swift-file-size-baseline.json
budgets/port-file-size-baseline.json
budgets/windows-tree-baseline.json
budgets/core-ui-purity-baseline.json
budgets/mission-splitbrain-baseline.json
budgets/core-target-membership-baseline.json
budgets/core-umbrella-imports-baseline.json
budgets/linux-desktop.perf.json
budgets/usage-refresh-tick-baseline.json
# macOS idle/occluded CPU regression tripwire (P-PERF-3): structural assertion
# gate for the backdrop WebGL rAF pause on occlusion — no existing baseline raised.
budgets/macos-idle-cpu.perf.json
# migrator-parity: annotated schema divergences between the canonical Swift GRDB
# migrator and the Windows/Linux mirrors (scripts/check-migrator-parity.mjs).
# Exact-set matched both ways: new divergences AND stale entries fail CI.
budgets/migrator-parity-baseline.json
budgets/force-unwrap-baseline.json

# --- Filename false positive: not a lint baseline ---
# GitHub Actions workflow for the protected one-time P-25 Linux release-baseline
# bootstrap (signs the 0.1.1 update baseline). "baseline" names the signed release
# artifact it produces, not a checked-in lint/type baseline; the file contains no
# suppression configuration.
.github/workflows/linux-release-baseline.yml

# --- File-level TypeScript suppressions (token-scoped) ---
functions/src/types/legacy.ts | eslint-disable
website/src/scripts/dotConstellation.ts | ts-suppress
website/src/scripts/easterEggFx.ts | ts-suppress
website/src/scripts/emberSwarm.ts | ts-suppress
website/src/scripts/pretextShrinkwrap.ts | ts-suppress

# --- Rust crate-root re-exports (token-scoped): two #[allow(unused_imports)] on UniFFI re-exports.
# Allowlisted rather than annotated inline because crates/openburnbar-iroh/** changes trigger a full
# AAR rebuild-parity gate; the justification lives here instead of churning the FFI source.
crates/openburnbar-iroh/src/lib.rs | rust-allow

# --- Generated UniFFI Swift bindings (token-scoped) ---
# Regenerated and drift-checked from crates/openburnbar-domain-core; never hand-edited.
OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/openburnbar_domain_ffi.swift | swiftlint-disable
# Same generator, same contract: regenerated and drift-checked from crates/openburnbar-iroh.
OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift | swiftlint-disable

# --- Vendored GRDB SQLCipher fork (token-scoped) ---
# Upstream GRDB carries SwiftLint waivers for compatibility with its own lint profile. Keep exact
# path entries so the vendor tree remains visible; re-check and delete stale entries on GRDB updates.
Vendor/GRDB-SQLCipher/GRDB/Core/Database+Schema.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/DatabaseError.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/DatabasePool.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/DatabaseSnapshotPool.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/Statement.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/Support/StandardLibrary/JSONRequiredEncoder.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/TransactionObserver.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/WALSnapshot.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Core/WALSnapshotTransaction.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/FTS/FTS4.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/FTS/FTS5.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/FTS/FTS5CustomTokenizer.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Fixits.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Record/EncodableRecord+Encodable.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/Record/FetchableRecord+Decodable.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/ValueObservation/Observers/ValueConcurrentObserver.swift | swiftlint-disable
Vendor/GRDB-SQLCipher/GRDB/ValueObservation/Reducers/Trace.swift | swiftlint-disable
```

<!-- END:suppression-allowlist -->

## Security-gate advisory ignores (time-boxed)

The PR security gates keep a **paired, expiring** ignore list for dependency
advisories that have **no actionable fix**: [`osv-scanner.toml`](../osv-scanner.toml)
(OSV Scanner job, `ignoreUntil`) and `ADVISORY_ALLOWLIST` in
[`scripts/ci/check-npm-audit-fail-closed.mjs`](../scripts/ci/check-npm-audit-fail-closed.mjs)
(npm audit job, `expires`). The known-vulnerability floor derives its
temporary exception from the same npm allowlist, and Workflow Lint validates
the checked-in pair on every PR through
[`scripts/ci/export-active-advisory-allowlist.mjs`](../scripts/ci/export-active-advisory-allowlist.mjs).
Dependency Review deliberately stays unallowlisted: its `allow-ghsas` input is
advisory-ID-wide, so an exception there would also suppress the same GHSA for
every newly introduced dependency instead of only the reviewed package that
justified it, and unchanged base-pinned dependencies never trip its diff-based
check anyway. Entries must stay in sync (same GHSA id, same expiry) and each
carries a `reason:`; any drift fails closed, and past the expiry all gates
reject the advisory again instead of letting the ignore rot.

Current entries:

- **GHSA-528h-pc64-c93x** (stream-json path-filter DoS, expires 2026-12-03):
  `pick`/`ignore`/`filter`/`replace` recompute the whole path string per token,
  so deeply nested JSON costs O(depth²). The only depender is `firebase-tools`,
  a `functions/` **devDependency** that never reaches a deployed bundle, and it
  loads the library through the 1.x CommonJS entry points
  (`stream-json/filters/Filter`, `stream-json/streamers/StreamObject`,
  `stream-json/filters/Pick`, `stream-json/streamers/StreamArray`). Upstream
  fixed the advisory only in 3.5.0+, which is pure ESM (`"type": "module"`,
  Node >= 22), renames every one of those entry points and replaces the
  `Transform` subclasses with stream-chain 4 factory links. Forcing 3.x through
  a scoped `overrides` entry was tried and measured: the install resolves and
  `firebase --version` still works, but `firebase database:import`,
  `firebase auth:import` and the Next.js framework integration all fail to load
  with `MODULE_NOT_FOUND`. The latest `firebase-tools` (15.29.0) still declares
  `stream-json: ^1.7.3` and no patched 1.x release exists, so a version bump
  resolves nothing. The advisory is also unreachable in this consumer: the
  filters only ever parse a developer-selected local file passed to a CLI
  command, not untrusted request bodies on a served event loop, which is the
  attack the advisory describes. Remove the entries when `firebase-tools`
  migrates to `stream-json` 3.x.

The previous entry (GHSA-mh99-v99m-4gvg, brace-expansion DoS, expiring
2026-08-21) was retired when the vendored callable CommonJS shim in
[`functions/vendor/openburnbar/brace-expansion-cjs`](../functions/vendor/openburnbar/brace-expansion-cjs/README.md)
removed the final vulnerable 1.x copies: the minimatch 3 consumers inside the
Firebase CLI subtree now resolve a callable facade over the patched
`@isaacs/brace-expansion` algorithm instead of the unfixable 1.x line. The same
shim shape does not transfer to `stream-json`: a facade needs a patched
implementation to wrap, and 3.5.0's API is not a rename of 1.9.1's but a
different stream-integration model, so wrapping it would mean reimplementing
the parser plumbing that `auth:import` and `database:import` feed user data
through.

## Mac/iOS Swift twin-basename allowlist

[`scripts/ci/check-twin-basenames.sh`](../scripts/ci/check-twin-basenames.sh)
blocks new `.swift` files that share a basename across `AgentLens/` and
`OpenBurnBarMobile/`. The current twins are allowed only as explicit exact-path
pairs so new forks cannot slip in behind the existing debt. Asset twins are not
in scope.

Categories:

- `storage-backend-divergence`: shared domain concept with intentionally different local storage, Firestore, or platform persistence.
- `platform-ui`: parallel SwiftUI surface with platform-specific layout or navigation.
- `transport`: shared realtime, attachment, media, relay, or attestation concept with platform-specific runtime wiring.

<!-- BEGIN:twin-basename-allowlist -->

```text
# Exact AgentLens path | exact OpenBurnBarMobile path | category
AgentLens/App/AppDelegate.swift | OpenBurnBarMobile/App/AppDelegate.swift | storage-backend-divergence
AgentLens/Services/Analytics/AmplitudeTransport.swift | OpenBurnBarMobile/Services/Analytics/AmplitudeTransport.swift | transport
AgentLens/Services/Analytics/AnalyticsConfig.swift | OpenBurnBarMobile/Services/Analytics/AnalyticsConfig.swift | transport
AgentLens/Services/Analytics/AnalyticsShared.swift | OpenBurnBarMobile/Services/Analytics/AnalyticsShared.swift | platform-ui
AgentLens/Services/AppCheckAttestationMonitor.swift | OpenBurnBarMobile/Services/AppCheckAttestationMonitor.swift | transport
AgentLens/Services/Chat/HermesAttachmentLoader.swift | OpenBurnBarMobile/Services/HermesAttachmentLoader.swift | transport
AgentLens/Services/ComputerUse/ComputerUseSecurityCallableClient.swift | OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift | transport
AgentLens/Services/DataStore/BudgetEnforcement.swift | OpenBurnBarMobile/Models/BudgetEnforcement.swift | storage-backend-divergence
AgentLens/Services/DataStore/BudgetForecast.swift | OpenBurnBarMobile/Models/BudgetForecast.swift | storage-backend-divergence
AgentLens/Services/DataStore/BudgetLedger.swift | OpenBurnBarMobile/Models/BudgetLedger.swift | storage-backend-divergence
AgentLens/Services/DataStore/BudgetNotificationCenter.swift | OpenBurnBarMobile/Services/BudgetNotificationCenter.swift | storage-backend-divergence
AgentLens/Services/DataStore/BudgetRulesStore.swift | OpenBurnBarMobile/Models/BudgetRulesStore.swift | storage-backend-divergence
AgentLens/Services/DataStore/BudgetSettings.swift | OpenBurnBarMobile/Models/BudgetSettings.swift | storage-backend-divergence
AgentLens/Services/IrohRelay/FirestoreIrohPairingDirectory.swift | OpenBurnBarMobile/Services/IrohRelay/FirestoreIrohPairingDirectory.swift | transport
AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift | OpenBurnBarMobile/Services/IrohRelay/IrohRelayKeyStore.swift | transport
AgentLens/Services/IrohRelay/IrohTransportAuditLogger.swift | OpenBurnBarMobile/Services/IrohRelay/IrohTransportAuditLogger.swift | transport
AgentLens/Services/Media/IrohBlobKeyStore.swift | OpenBurnBarMobile/Services/Media/IrohBlobKeyStore.swift | transport
AgentLens/Services/Media/MediaFileTransferServiceFactory.swift | OpenBurnBarMobile/Services/Media/MediaFileTransferServiceFactory.swift | transport
AgentLens/Services/Media/MercuryPeerSource.swift | OpenBurnBarMobile/Services/Media/MercuryPeerSource.swift | transport
AgentLens/Services/Settings/Stores/ElderWandSettings.swift | OpenBurnBarMobile/Services/Hermes/ElderWandSettings.swift | platform-ui
AgentLens/Services/SmartHub/PixelClockSettingsAdapter.swift | OpenBurnBarMobile/Services/PixelClockSettingsAdapter.swift | storage-backend-divergence
AgentLens/Services/SmartHub/SmartHubDisplaySettingsAdapter.swift | OpenBurnBarMobile/Services/SmartHubDisplaySettingsAdapter.swift | storage-backend-divergence
AgentLens/Theme/LiquidGlass.swift | OpenBurnBarMobile/Theme/LiquidGlass.swift | platform-ui
AgentLens/Theme/ProTheme.swift | OpenBurnBarMobile/Theme/ProTheme.swift | platform-ui
AgentLens/Views/Chat/BudgetBlockedCard.swift | OpenBurnBarMobile/Views/Chat/BudgetBlockedCard.swift | storage-backend-divergence
AgentLens/Views/Chat/Components/ChatAttachmentTray.swift | OpenBurnBarMobile/Views/ChatAttachmentTray.swift | transport
AgentLens/Views/Chat/ElderWand/ElderWandAnalysisSection.swift | OpenBurnBarMobile/Views/Hermes/ElderWand/ElderWandAnalysisSection.swift | platform-ui
AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorModel.swift | OpenBurnBarMobile/Views/Hermes/ElderWand/ElderWandConfiguratorModel.swift | platform-ui
AgentLens/Views/Chat/ElderWand/ElderWandConfiguratorView.swift | OpenBurnBarMobile/Views/Hermes/ElderWand/ElderWandConfiguratorView.swift | platform-ui
AgentLens/Views/Chat/ElderWand/ElderWandJudgeSection.swift | OpenBurnBarMobile/Views/Hermes/ElderWand/ElderWandJudgeSection.swift | platform-ui
AgentLens/Views/Chat/ElderWand/ElderWandPresetSection.swift | OpenBurnBarMobile/Views/Hermes/ElderWand/ElderWandPresetSection.swift | platform-ui
AgentLens/Views/Components/Pro/CloudBadge.swift | OpenBurnBarMobile/Views/Components/Pro/CloudBadge.swift | platform-ui
AgentLens/Views/Components/Pro/FoilCTAButton.swift | OpenBurnBarMobile/Views/Components/Pro/FoilCTAButton.swift | platform-ui
AgentLens/Views/Components/Pro/LockedFeatureVeil.swift | OpenBurnBarMobile/Views/Components/Pro/LockedFeatureVeil.swift | platform-ui
AgentLens/Views/Components/Pro/MembershipBand.swift | OpenBurnBarMobile/Views/Components/Pro/MembershipBand.swift | platform-ui
AgentLens/Views/Components/Pro/MercuryCrest.swift | OpenBurnBarMobile/Views/Components/Pro/MercuryCrest.swift | transport
AgentLens/Views/Components/Pro/MercuryFoilCard.swift | OpenBurnBarMobile/Views/Components/Pro/MercuryFoilCard.swift | transport
AgentLens/Views/Components/Pro/ProBadgeDot.swift | OpenBurnBarMobile/Views/Components/Pro/ProBadgeDot.swift | platform-ui
AgentLens/Views/Components/Pro/ProPosterScaffold.swift | OpenBurnBarMobile/Views/Components/Pro/ProPosterScaffold.swift | platform-ui
AgentLens/Views/Components/ProviderAccount/ProviderAccountChips.swift | OpenBurnBarMobile/Views/Components/ProviderAccountChips.swift | storage-backend-divergence
AgentLens/Views/Components/ProviderAccount/ProviderRoutingCockpit.swift | OpenBurnBarMobile/Views/Components/ProviderRoutingCockpit.swift | storage-backend-divergence
AgentLens/Views/Dashboard/Components/ConstellationBackgroundView.swift | OpenBurnBarMobile/Views/Aurora/ConstellationBackgroundView.swift | platform-ui
AgentLens/Views/Dashboard/Components/EasterEggEventCanvas.swift | OpenBurnBarMobile/Views/Aurora/EasterEgg/EasterEggEventCanvas.swift | platform-ui
AgentLens/Views/Dashboard/Components/EasterEggOverlay.swift | OpenBurnBarMobile/Views/Aurora/EasterEgg/EasterEggOverlay.swift | platform-ui
AgentLens/Views/Dashboard/DashboardNavigationModel.swift | OpenBurnBarMobile/Models/DashboardNavigationModel.swift | platform-ui
AgentLens/Views/Dashboard/DashboardView.swift | OpenBurnBarMobile/Views/DashboardView.swift | platform-ui
AgentLens/Views/Dashboard/ProviderDashboardView.swift | OpenBurnBarMobile/Views/ProviderDashboardView.swift | platform-ui
AgentLens/Views/Dashboard/SessionDetailView.swift | OpenBurnBarMobile/Views/SessionDetailView.swift | platform-ui
AgentLens/Views/Media/PaperclipButton.swift | OpenBurnBarMobile/Views/Media/PaperclipButton.swift | transport
AgentLens/Views/Onboarding/OnboardingWizardView.swift | OpenBurnBarMobile/Views/Onboarding/OnboardingWizardView.swift | platform-ui
AgentLens/Views/Popover/InsightCardView.swift | OpenBurnBarMobile/Views/ChartStudio/InsightCardView.swift | platform-ui
AgentLens/Views/SessionLogs/SessionLogsView.swift | OpenBurnBarMobile/Views/SessionLogsView.swift | platform-ui
AgentLens/Views/Settings/AccountSettingsView.swift | OpenBurnBarMobile/Views/You/AccountSettingsView.swift | platform-ui
AgentLens/Views/Settings/BudgetSettingsView.swift | OpenBurnBarMobile/Settings/BudgetSettingsView.swift | storage-backend-divergence
AgentLens/Views/Settings/FusionImpact/FusionImpactView.swift | OpenBurnBarMobile/Views/Insights/FusionImpactView.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsAnchorModifiers.swift | OpenBurnBarMobile/Settings/Search/SettingsAnchorModifiers.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsItem.swift | OpenBurnBarMobile/Settings/Search/SettingsItem.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsManifest.swift | OpenBurnBarMobile/Settings/Search/SettingsManifest.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsRouter.swift | OpenBurnBarMobile/Settings/Search/SettingsRouter.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsSearchEngine.swift | OpenBurnBarMobile/Settings/Search/SettingsSearchEngine.swift | platform-ui
AgentLens/Views/Settings/Search/SettingsSearchResultsView.swift | OpenBurnBarMobile/Settings/Search/SettingsSearchResultsView.swift | platform-ui
AgentLens/Views/Settings/SmartDisplays/NestHubSettingsCard.swift | OpenBurnBarMobile/Views/SmartHub/NestHubSettingsCard.swift | storage-backend-divergence
AgentLens/Views/Settings/SmartDisplays/PixelClockSettingsCard.swift | OpenBurnBarMobile/Views/SmartHub/PixelClockSettingsCard.swift | storage-backend-divergence
AgentLens/Views/Settings/TextExpansionSettingsView.swift | OpenBurnBarMobile/Views/You/TextExpansionSettingsView.swift | platform-ui
```

<!-- END:twin-basename-allowlist -->

## Allowlist hygiene

- Each entry above is **debt with a deletion plan**, not a permanent exception. When the
  underlying work lands (TypeSpec strangler, ktlint burn-down, debt budgets hitting
  zero), delete the entry **and** the artifact in the same PR. A stale path no longer
  suppresses anything and is reported so cleanup is visible.
- New entries require a one-line rationale and should be rare. Prefer the inline `reason:`
  mechanism, which keeps the justification next to the code.
- The gate reads only the FIRST `BEGIN…END:suppression-allowlist` block (markers must be
  whole-line HTML comments); a second BEGIN anywhere fails the build closed.

## Per-rule strictness rationale

The suppression gate blocks waivers and baselines. This section is the companion contract
for rules that are deliberately not enabled yet, or that are enabled at `warn` instead of
`error`. Defect-catching rules are candidates for future burn-down; style-only rules stay
off unless they start hiding real bugs. Any config change that disables a rule must update
this section in the same PR.

### SwiftLint

Source of truth: [`.swiftlint.yml`](../.swiftlint.yml).

| Rule                                                                     | Current state      | Rationale / deletion plan                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------ | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `trailing_whitespace`                                                    | disabled           | Whitespace-only churn is batched separately. Enable after a repo-wide formatter/autocorrect pass.                                                                                                                                                |
| `nesting`                                                                | disabled           | Existing SwiftUI, generated-adjacent, and parser code has deep type-level nesting. Refactor as ownership boundaries stabilize; do not add new deep nesting casually.                                                                             |
| `todo`                                                                   | disabled           | TODO/FIXME markers carry tracked work ids. Phase 5 converts remaining markers to issue-linked, expiring debt instead of forcing deceptive rewording.                                                                                             |
| `optional_data_string_conversion`                                        | disabled           | Changing these sites changes optionality semantics; burn down with per-call-site review.                                                                                                                                                         |
| `non_optional_string_data_conversion`                                    | disabled           | Same as above; string/data conversion failability must be preserved intentionally.                                                                                                                                                               |
| `force_cast`                                                             | warn               | Still enabled, but soft while brownfield casts are burned down. Use typed decoding, enum parsing, or guarded casts in new code.                                                                                                                  |
| `xct_specific_matcher`                                                   | warn               | Soft during XCTest cleanup; prefer specific matchers for new assertions.                                                                                                                                                                         |
| `modifier_order`                                                         | warn               | Soft because existing declarations predate the preferred order. New code should follow the configured order.                                                                                                                                     |
| `line_length`, `function_body_length`, `type_body_length`, `file_length` | ratchet thresholds | Thresholds are set above measured maxima so the gate blocks regression now; tighten as decomposition work lands.                                                                                                                                 |
| `identifier_name`                                                        | relaxed            | Single-letter names are common in graphics, math, parsers, and coordinates. Prefer descriptive names outside those domains.                                                                                                                      |
| `force_unwrapping`                                                       | not opted in       | Measured brownfield debt (215 sites) is frozen by `scripts/debt/check-force-unwrap-budget.sh` (shrink-only ratchet, `budgets/force-unwrap-baseline.json`). Enable the SwiftLint rule once the count reaches zero; the ratchet enforces the path. |
| `discouraged_optional_collection`                                        | not opted in       | Optional collection semantics are API-facing in several models; burn down with compatibility tests before enabling.                                                                                                                              |
| `implicitly_unwrapped_optional`                                          | not opted in       | UIKit/AppKit/SwiftUI lifecycle and IBOutlet-like surfaces need hand review before this can be made blocking.                                                                                                                                     |
| `no_extension_access_modifier`                                           | not opted in       | The repo convention is ACL on extensions in several public API files. Revisit only with an ADR-backed style migration.                                                                                                                           |
| `discouraged_optional_boolean`                                           | not opted in       | Optional booleans represent tri-state provider and rollout values in existing APIs; require domain review before enabling.                                                                                                                       |

### detekt

Source of truth: [`android/detekt.yml`](../android/detekt.yml). Android detekt is already
baseline-free and enforces the active defect rules. The disabled rules below are grouped
by why they remain off.

| Group                             | Disabled rules                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Rationale / deletion plan                                                                                                                                                                                                   |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Documentation policy              | `AbsentOrWrongFileLicense`, `DocumentationOverPrivateFunction`, `DocumentationOverPrivateProperty`, `EndOfSentenceFormat`, `KDocReferencesNonPublicProperty`, `OutdatedDocumentation`, `UndocumentedPublicClass`, `UndocumentedPublicFunction`, `UndocumentedPublicProperty`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | KDoc completeness is not used as a quality gate yet. Keep architectural docs in `docs/`; enable API-doc rules only after deciding which Android packages are public contracts.                                              |
| Complexity style                  | `ComplexInterface`, `LabeledExpression`, `MethodOverloading`, `NamedArguments`, `NestedScopeFunctions`, `ReplaceSafeCallChainWithRun`, `StringLiteralDuplication`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | These are mostly style or design-pressure rules. Existing Compose, parser, crypto, and generated-adjacent code would need structural refactors; active complexity rules already catch the dangerous size/depth regressions. |
| Coroutine architecture candidates | `GlobalCoroutineUsage`, `InjectDispatcher`, `SuspendFunWithCoroutineScopeReceiver`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Candidate defect rules. Enable after Android coroutine ownership is normalized around injected dispatchers and lifecycle scopes; new work should not introduce global scope use.                                            |
| Empty-block candidates            | `EmptyElseBlock`, `EmptyIfBlock`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Candidate defect rules. `EmptyCatchBlock` and most empty block rules are already active; burn these down once UI placeholder branches are removed or made explicit.                                                         |
| Exception candidates              | `NotImplementedDeclaration`, `ObjectExtendsThrowable`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Candidate defect rules. Enable after placeholders and throwable modeling are audited; production code should use real errors, not `TODO()`/marker throwables.                                                               |
| Naming style                      | `BooleanPropertyNaming`, `ForbiddenClassName`, `FunctionNameMaxLength`, `FunctionNameMinLength`, `LambdaParameterNaming`, `NonBooleanPropertyPrefixedWithIs`, `VariableMaxLength`, `VariableMinLength`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Naming length/prefix rules are noisy across Compose callbacks, wire models, and generated-adjacent code. Active naming rules still enforce package/type/function/variable basics.                                           |
| Performance candidates            | `CouldBeSequence`, `UnnecessaryPartOfBinaryExpression`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `CouldBeSequence` can make hot paths better or worse depending on allocation and collection size; use profiler-driven changes. The binary-expression rule is cosmetic unless it hides a real bug.                           |
| Potential-bug candidates          | `CastToNullableType`, `Deprecation`, `DontDowncastCollectionTypes`, `ElseCaseInsteadOfExhaustiveWhen`, `ExitOutsideMain`, `HasPlatformType`, `ImplicitUnitReturnType`, `LateinitUsage`, `MissingPackageDeclaration`, `NullableToStringCall`, `UnnecessaryNotNullCheck`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Best future ROI group. Turn on in small tranches with tests, because these touch Java interop, migration compatibility, exhaustive state modeling, and Android lifecycle initialization.                                    |
| Style / readability               | `AlsoCouldBeApply`, `BracesOnIfStatements`, `BracesOnWhenStatements`, `CanBeNonNullable`, `CascadingCallWrapping`, `ClassOrdering`, `DataClassContainsFunctions`, `DataClassShouldBeImmutable`, `DoubleNegativeLambda`, `EqualsOnSignatureLine`, `ExplicitCollectionElementAccessMethod`, `ExplicitItLambdaParameter`, `ExpressionBodySyntax`, `ForbiddenAnnotation`, `ForbiddenImport`, `ForbiddenMethodCall`, `ForbiddenVoid`, `MandatoryBracesLoops`, `MaxChainedCallsOnSameLine`, `MayBeConstant`, `MultilineLambdaItParameter`, `MultilineRawStringIndentation`, `NoTabs`, `NullableBooleanCheck`, `OptionalUnit`, `RedundantExplicitType`, `RedundantVisibilityModifier`, `SerialVersionUIDInSerializableClass`, `StringShouldBeRawString`, `TrailingWhitespace`, `TrimMultilineRawString`, `UnderscoresInNumericLiterals`, `UnnecessaryBracesAroundTrailingLambda`, `UnnecessaryInnerClass`, `UnnecessaryLet`, `UnnecessaryParentheses`, `UseDataClass`, `UseEmptyCounterpart`, `UseIfEmptyOrIfBlank`, `UseIfInsteadOfWhen`, `UseLet`, `UseSumOfInsteadOfFlatMapSize` | Mostly formatting, idiom, or preference rules. Keep off until a formatter owns them or a concrete bug class appears. New code should still be simple and idiomatic.                                                         |

### ESLint / TypeScript

Sources of truth: each `eslint.config.mjs` and `tsconfig*.json`.

| Surface                                                                            | Deliberate gap                                                                                   | Rationale / deletion plan                                                                                                                                                  |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `functions`, hosted MCP services, realtime relay, remote MCP tool, signal packages | `no-console` disabled in executable/CLI sections                                                 | These surfaces intentionally log to stdout/stderr or cloud logs. Library sections still restrict console use where configured.                                             |
| `extensions/openburnbar`                                                           | `@typescript-eslint/explicit-function-return-type` disabled                                      | VS Code command, event, and test callback types are often clearer when inferred from the API. Revisit after exported extension APIs are separated from internal callbacks. |
| `extensions/openburnbar`                                                           | `no-empty-function` disabled in TypeScript sections                                              | Test doubles and lifecycle no-ops are legitimate here. Prefer explicit comments for new no-op implementations.                                                             |
| `website`                                                                          | `@typescript-eslint/ban-ts-comment` disabled                                                     | The suppression meta-gate still requires justified `@ts-*` comments and allowlists the legacy script sites exactly. Remove once those scripts no longer need TS escapes.   |
| TypeScript configs outside the hardened package set                                | `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride` not universal yet | `packages/libsignal-protocol` is the hardened reference. Migrate other TS surfaces package-by-package with tests because these flags change API and dictionary semantics.  |
| `apps/console`                                                                     | `@typescript-eslint/no-explicit-any` at `warn`                                                   | Console tooling still has brownfield dynamic payloads. Promote to `error` after schemas or validators cover those payloads.                                                |

### Python, schema drift, and generated contracts

Owned by dedicated workstreams and folded in when each reaches zero, so the boundary is a
known decision rather than a blind spot:

- **`# type: ignore` (Python, ~38 sites)** - mypy/ruff strictness workstream (plan D12).
  Coded `# noqa` is already governed by ruff; bare `# noqa` is rejected.
- **`knownDrift` schema tokens** - gated by `tools/schema-sync` (plan D10). The schema
  checker fails on new drift and stale grandfathered drift.

## Known limitations (recoverable, fail-closed)

- A directive token appearing inside a **string literal** is flagged like a real one. This
  is safe (fail-closed) — recover with a `reason:` comment or an allowlist entry.
- **Extensionless** scripts (shebang, no extension) and exotic source extensions are not
  scanned. There are none with suppressions today; add the extension to `EXT_PATTERNS`
  when one appears.
- A `reason:` for the line above must sit on a `//` line or a single-line `/* … */`; a
  reason on the _continuation_ line of a multi-line block comment is not recognised
  (fail-closed). Use a `//` line or put `reason:` on the directive's own line.
