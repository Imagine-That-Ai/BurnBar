# OpenBurnBar Full Mobile Parity Remediation Plan

Status: execution-ready remediation plan; no implementation or release claim

Baseline: detached `origin/main` at `3f127f7da28f590441c46e0674dac7f27a04b7aa` (`v1.0.35`, `chore(release): cut OpenBurnBar v1.0.35 (#2241)`), inspected August 17, 2026.

Repository: `/Users/albertonunez/Documents/Developer/BurnBar`

This document is intentionally authored in the isolated worktree
`/private/tmp/burnbar-mobile-parity-remediation-plan-20260817-92076`. The dirty
shared checkout is not part of this plan and must not be reset, cleaned, edited,
committed, pushed, merged, or used for release proof.

## 1. Outcome

OpenBurnBar mobile parity is complete only when iOS, iPadOS, and Android expose
the same accepted product capabilities, semantics, security posture, and
recovery behavior as the source product, with platform-appropriate presentation
and independently collected proof on the real mobile surfaces.

“The file exists”, “the screen compiles”, “the unit test is green”, or “the
feature is present on one platform” is not parity evidence. Every completion
claim must bind to:

- the exact candidate commit, generated artifacts, and installed package;
- the source-of-truth contract and source-platform behavior being mirrored;
- the target platform and OS/device actually exercised;
- the user-visible outcome, including empty, offline, denied, retry, cancel,
  persistence, and recovery paths; and
- fresh evidence that another agent can read back without relying on prose.

The finished program must leave one canonical capability inventory, one
canonical cross-platform contract set, one parity ledger, and one release
evidence bundle. It must not leave parallel “done” documents that disagree.

## 2. Guardrails and non-goals

### Binding guardrails

1. Preserve the exact baseline until a candidate is deliberately created. Never
   use the dirty shared checkout as an implementation or certification tree.
2. Read source and schema evidence before changing a target. The TypeSpec
   schema-sync canon, generated outputs, source-platform implementation, and
   platform tests are the authority; hand-written summaries are not.
3. Keep one coherent PR theme per landing unit. Do not mix parity work with
   unrelated cleanup, product experiments, dependency churn, or release edits.
4. Do not add warning, lint, detekt, compiler, or coverage suppressions. Fix the
   underlying issue or record a genuine accepted exception with owner and expiry.
5. Do not claim a mocked, simulator-only, CI-only, or source-only result as
   physical-device, store, provider, or production proof.
6. Do not mutate Firebase, App Store Connect, Google Play, TestFlight, Play
   closed testing, signing credentials, or deployment state from this plan.
7. Every schema, crypto, transport, billing, or entitlement change requires
   negative-path tests and readback evidence, not only a happy-path fixture.

### Explicit non-goals

- This file does not implement parity.
- This file does not authorize a store submission, staged rollout, provider
  mutation, credential creation/rotation, or cloud write.
- This file does not force iOS and Android to look pixel-identical. Native
  controls, navigation idioms, Dynamic Type, Material behavior, and Apple
  accessibility conventions may differ while the user-visible contract remains
  equivalent.
- This file does not treat every desktop-only capability as mobile scope. A
  capability is included only when it is a supported mobile actor workflow or
  an explicitly accepted read-only/mobile companion behavior.

## 3. Evidence-backed starting diagnosis

### 3.1 The target is substantial, not a blank port

Both targets already contain broad product code. iOS has Pulse, Burn, Streams,
Hermes/Agents, Insights, Inbox, Budget, Providers, Devices, Cloud Store,
Computer Use, Mercury/media, Smart Hub, settings, widgets/live activity, and
iPad navigation under `OpenBurnBarMobile/`. Android has corresponding Compose
surfaces under `android/app/src/main/java/com/openburnbar/`, including Pulse,
Burn, Streams, Assistants, Insights, Inbox, Store, Devices, Computer Use,
Mercury/media, Smart Display, widgets, and settings.

That breadth is a risk: feature presence can conceal semantic drift, dead
buttons, stale hand mirrors, different gating, or an untested error path. The
remediation therefore starts with an inventory and differential proof rather
than another visual pass.

### 3.2 Navigation is already divergent

iOS defines `AuroraNavDestination` in
`OpenBurnBarMobile/Views/Navigation/AuroraNavigationIcons.swift` and routes the
primary shell through `RootTabView.swift` / `RootNavigationView.swift`.
Android defines `AuroraNavDestination` in
`android/app/src/main/java/com/openburnbar/ui/components/AuroraNavDestination.kt`
and `BurnBarTab`/the route graph in
`android/app/src/main/java/com/openburnbar/ui/navigation/BurnBarNavHost.kt` and
`BurnBarNavHostSections.kt`.

The source currently exposes different route sets and labels: Android includes
an Inbox destination and a Store-labelled You destination, while the iOS
primary shell has its own Insights/Agents/You arrangement and places some
surfaces in secondary navigation. `docs/ANDROID_NATIVE_PARITY_GOAL.md` still
describes a five-tab goal, while the Android route candidate list is broader.
This is not automatically a bug, but it is an unowned contract. A canonical
route/capability registry must decide which destinations are primary,
secondary, gated, deep-linkable, or intentionally platform-specific.

### 3.3 Data contracts are in migration

The schema canon is `tools/schema-sync/typespec/`, with domain ownership and
emission paths in `tools/schema-sync/manifest.json`. Generated Swift and Kotlin
models live under `OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/` and
`android/app/src/main/java/com/openburnbar/data/models/generated/`.

Hand mirrors and legacy exports remain in `functions/src/types/legacy/` and
other platform shared-model files. `tools/schema-sync/check-drift.sh`,
`check-hand-mirror.mjs`, and the generated parity checks are the required drift
guards. New mobile work must not introduce another hand-maintained schema.
Existing legacy domains must be migrated domain-by-domain, with the migration
budget and known drift ratcheting down rather than being re-baselined upward.

### 3.4 Existing tests are necessary but not sufficient

The repository has useful automated lanes:

- `./scripts/test-openburnbar-mobile.sh` runs the iOS mobile XCTest bundle,
  preferring a connected physical iPhone/iPad locally and an iOS Simulator in
  CI; it also prepares the Signal FFI and enforces the iOS 27 Firestore source
  graph.
- `./scripts/test-openburnbar-android.sh` runs Android JVM tests for the app,
  Iroh relay, and remote module.
- `.github/workflows/openburnbar-pr-harness.yml` builds/tests Android, runs the
  iOS mobile lane, Android Hermes instrumentation, and targeted Mercury/media
  coverage when path filters select them.
- `tools/schema-sync/check-drift.sh`, the Android lint/detekt gates, app builds,
  generated-artifact checks, and release preflight scripts cover important
  scrutiny surfaces.

These commands prove code and selected harness behavior. They do not by
themselves prove an exact installed candidate on a named iPhone, iPad, or
Android device; a valid Firebase/App Check session; a real Mac-to-phone relay;
StoreKit/Google Play purchase readback; or accepted App Store/Play distribution.

### 3.5 Historical evidence must be rebound

The repository contains prior mobile, Signal, Mercury, Computer Use, and store
evidence. Historical evidence may guide setup and test selection, but it is
supporting evidence until it is explicitly bound to the candidate SHA, package
identity, version/build, device identity, OS, network, and artifact digest.
The parity ledger must mark such rows `historical`, `stale`, `rebind-required`,
or `fresh`; never silently promote them to `PASS`.

## 4. Canonical parity model

### 4.1 Source and ownership

Use this ownership order for every capability:

1. The accepted product contract and source-platform behavior define intent.
2. `tools/schema-sync/typespec/` defines shared Firestore wire shape where a
   domain is represented there.
3. Generated Swift/Kotlin/TypeScript artifacts define transport types.
4. `OpenBurnBarCore` shared models and pure policy code define cross-platform
   semantics when a reusable implementation exists.
5. iOS and Android views/stores/adapters provide native presentation and OS
   integration.
6. Fresh real-surface evidence decides whether the behavior is actually done.

If source, generated output, hand mirror, or evidence disagree, stop the parity
claim and repair the earliest invalid source rather than patching the display.

### 4.2 Capability registry

Create one machine-readable registry (recommended location:
`docs/mobile-parity/mobile-capability-registry.json`) and a human-readable
ledger derived from it. Each row must contain:

| Field | Required value |
|---|---|
| `capabilityId` | Stable ID, never a screen nickname |
| `actor` | Signed-out user, signed-in user, paired phone, Mac operator, or system |
| `sourceSurface` | Source implementation and contract path |
| `iosSurface` | View/store/service/test paths |
| `androidSurface` | Compose/store/service/test paths |
| `sharedContract` | TypeSpec/generated/shared-model ID, or explicit none |
| `states` | Loading, ready, empty, offline, denied, expired, retry, cancel, recovery |
| `entitlement` | Free/Cloud/Pro/Ultra or none |
| `securityBoundary` | Auth, App Check, device trust, encryption, approval, or none |
| `evidenceFloor` | Unit, integration, simulator, physical device, store/provider, or multiple |
| `status` | `unmapped`, `implemented`, `validated`, `rebind-required`, `blocked`, `accepted-divergence` |
| `owner` | One implementation owner and one validation owner |

The registry must include the primary route map, deep links, push routes,
widgets/intents, background jobs, and cross-device side effects. It must list
accepted divergences explicitly; absence from the registry is not an implicit
non-goal.

### 4.3 VAL contract set

The following assertions are the minimum closure contract. The eventual mission
may split them into more granular files, but it may not collapse them into a
single “mobile works” bucket.

#### VAL-MOB-001 — Candidate identity and ledger integrity

Surface: artifact/data/parity.

Needs: clean detached candidate, registry, ledger schema.

Behavior: every implementation, generated artifact, installed package, test
result, screenshot, device receipt, and store readback is bound to one exact
commit and version/build; dirty, stale, or unattributed evidence cannot close a
row.

Evidence: candidate fingerprint, `git status --short`, artifact SHA-256,
package/version/build identity, device/OS identity, and ledger readback.

#### VAL-MOB-002 — Canonical route and capability reachability

Surface: parity/UI/deep-link.

Needs: capability registry and accepted route decisions.

Behavior: every accepted mobile capability is reachable from the intended iOS,
iPadOS, and Android route; primary/secondary/gated labels, back behavior,
warm/cold deep links, push taps, and authentication gates agree.

Evidence: real navigation transcript and screenshots on each target, route
registry diff, and cold/warm deep-link traces for every registered route.

#### VAL-MOB-003 — Schema canon and generated-consumer parity

Surface: schema/generated artifact/parity.

Needs: TypeSpec domain inventory and source-platform fixtures.

Behavior: every mobile-consumed Firestore/callable document is defined by the
canon or explicitly accepted legacy boundary; generated Swift/Kotlin models,
TypeScript producers, and hand mirrors agree on field names, optionality,
enum values, timestamps, unknown-field behavior, and null/absent semantics.

Evidence: `./tools/schema-sync/check-drift.sh`, generated artifact diff,
hand-mirror check, cross-language golden fixtures, and a deliberate drift test
that fails before being reverted.

#### VAL-MOB-004 — Auth, App Check, session, and account mismatch behavior

Surface: real app/provider/auth.

Needs: staging account and valid/invalid Firebase configurations.

Behavior: Apple/Google sign-in, sign-out, expiry, revoked account, App Check
failure, Firebase unavailable, Firestore permission denial, and account switch
produce honest UI states with no stale data leakage or false success.

Evidence: iOS/iPadOS/Android traces, screenshots, auth/App Check logs, and
readback showing listeners and caches are scoped to the active UID.

#### VAL-MOB-005 — Sync, freshness, cache, and recovery parity

Surface: data/UI/background.

Behavior: Mac-published summaries, rollups, quota snapshots, activity, devices,
and transcript caches converge on both mobile targets; stale/offline/partial
data is labeled; foreground refresh, retry, cancellation, process restart, and
cache clear are idempotent.

Evidence: before/after Firestore fixtures, offline/online device runs, cache
metadata, listener/retry logs, and screenshots of fresh, stale, empty, and
error states.

#### VAL-MOB-006 — Pulse and Burn numerical parity

Surface: UI/data.

Behavior: burn totals, time windows, currency/token modes, provider/account
grouping, quota pressure, trend/forecast values, sorting, and rounding match
the source oracle for the same fixture; no zero-value or stale-data illusion is
shown after a failed load.

Evidence: shared golden vectors, differential output from source/iOS/Android,
real fixture screen captures, and accessibility labels containing the same
values.

#### VAL-MOB-007 — Streams, activity, projects, and encrypted search parity

Surface: UI/data/search.

Behavior: activity/session/project navigation, filtering, pagination/cursors,
hosted encrypted index lookup, local encrypted transcript cache, detail view,
export/share behavior, empty results, entitlement lock, and retry semantics
match across supported targets.

Evidence: deterministic corpus replay, ciphertext-only storage scan, query
request/response traces, pagination boundary cases, cache-size/clear proof, and
real device flow.

#### VAL-MOB-008 — Hermes/Agents/Pi conversation parity

Surface: real chat/relay.

Behavior: conversation list, new chat, model/runtime selection, connection
selection, streaming markdown, tool-call rendering, attachments, stop/cancel,
partial response, reconnect, thread isolation, and assistant deep links behave
the same semantically across iOS/iPadOS/Android.

Evidence: source-compatible stream fixtures, live LAN/relay request traces,
stop/retry/error screenshots, attachment readback, and physical-device chat
transcripts bound to the candidate.

#### VAL-MOB-009 — Insights, Budget, Missions, AI Inbox, and provider flows

Surface: UI/data/entitlement.

Behavior: provider setup/readback, budget rules and enforcement, insights
canvas/widgets, mission start/approval/progress/recovery, AI Inbox delivery and
row actions, and Cloud/Pro gating are equivalent or explicitly marked as
accepted platform differences.

Evidence: cross-platform fixture vectors, Room/Firestore/Keychain state
readback, push/deep-link flows, entitlement receipt state, and device captures.

#### VAL-MOB-010 — Devices, trust, and encrypted credential transfer

Surface: security/real app.

Behavior: device list, bootstrap, trust/revoke/rename, escrow envelope import,
Keychain/Android Keystore storage, provider readback validation, wrong-device,
expired-grant, revoked-grant, missing-key, malformed-envelope, and retry paths
fail closed and explain recovery.

Evidence: cross-platform crypto KATs, negative fixtures, secure-storage
inspection, Firestore rule/callable traces, and a physical-device transfer
receipt that proves provider readback before “validated”.

#### VAL-MOB-011 — Mercury/media/mirroring/call parity

Surface: real transport/device.

Behavior: paired-Mac discovery, Mercury capability display, presence heartbeat,
Ask to Mirror, screen share, file transfer, call invite/ack, reconnect, PiP,
permission denial, and capability fallback use the shared `media.control` and
relay contracts without inventing a parallel protocol.

Evidence: iOS/iPadOS/Android live paired-device traces, frame-level protocol
logs, screenshots/video of user surfaces, reconnect/denial results, and exact
device/OS/network metadata.

Historical Android handoff checkpoints to reconcile against the current tree are
the Kotlin `MercuryPeer` model, mirror/ack/heartbeat frame cases, paired-Mac
controls, `MercuryPeerSource`, and the 60-second heartbeat. Do not mark these
complete from the handoff text alone.

#### VAL-MOB-012 — Computer Use safety and approval parity

Surface: security/real device.

Behavior: paired phone authority, Mac-rooted trust, signed input, approval,
deny-region protection, replay/tamper rejection, panic/kill switch, rate limit,
session expiry, audit entries, and view-only/control separation are equivalent
on iOS/iPadOS/Android.

Evidence: physical-device live traces for tap/scroll/panic/approval, 100-intent
latency row, replay/tamper chaos row, deny-region/secure-field refusal, audit
readback, and candidate-bound receipts. Historical Android-only rows must not
close the iPhone/iPad rows.

#### VAL-MOB-013 — Notifications, widgets, Live Activities, and background work

Surface: OS integration.

Behavior: agent reply, AI Inbox, quota, Mercury/call, and relevant mission
notifications deep-link to the correct route in cold/warm states; widgets and
Live Activities show privacy-safe, correctly refreshed values; notification
permission denial and background expiration degrade honestly.

Evidence: installed candidate on each OS family, notification payload and
permission traces, widget snapshots/timeline readback, cold/warm launch logs,
and stale/denied screenshots.

#### VAL-MOB-014 — Accessibility, localization, privacy, and performance floor

Surface: real UI/system.

Behavior: Dynamic Type/font scaling, TalkBack/VoiceOver labels and focus order,
reduced motion/transparency, contrast, keyboard/IME avoidance, privacy screen,
rotation/large-screen layout, memory/scroll/streaming budgets, and sensitive
logging rules meet the agreed floor.

Evidence: automated accessibility checks plus manual VoiceOver/TalkBack runs on
named devices, 100/200% text-size captures, reduced-motion captures, profiler
reports, and release log/secret scans.

#### VAL-MOB-015 — Release/store/package integrity

Surface: artifact/store/installed app.

Behavior: release builds use the exact intended Firebase/App Check config,
signing identity, native artifacts, page-size/ABI settings, version/build
numbers, privacy declarations, subscription products, and package contents; the
installed package is the one tested and the store readback is the one submitted.

Evidence: clean candidate fingerprint, reproducible build logs, artifact
manifest/digests, Android strict Firebase validation, iOS source-Firestore graph
check, signing/notarization/package checks, TestFlight/Play closed-test
readback, and store publication receipt. Store proof remains external until
freshly collected.

## 5. Capability remediation inventory

This is the minimum feature inventory to load into the registry. “Code surface”
means a place to start investigation, not a completion claim.

| Capability family | iOS / iPadOS starting surfaces | Android starting surfaces | Remediation focus |
|---|---|---|---|
| Auth and onboarding | `OpenBurnBarMobile/Views/Auth`, `Views/Onboarding`, `Services/AuthRepository.swift` | `ui/auth`, `data/firebase`, `MainActivity.kt` | Same account states, provider setup, App Check, first-run copy, and recovery |
| Route shell | `Views/RootTabView.swift`, `RootNavigationView.swift`, `Views/Navigation` | `ui/navigation`, `AuroraNavDestination.kt` | Canonical route registry, labels, deep links, cold/warm routing, back stacks |
| Pulse | `Views/Pulse`, `Services/DashboardStore.swift`, `LiveUsageAccumulator` | `ui/pulse`, dashboard/live stores | Numerical oracle, local-midnight/rollup windows, stale/error states |
| Burn/quota | `Views/Burn`, `QuotaView.swift`, `QuotaDetailSheet.swift` | `ui/burn`, quota stores/repository | Account/provider grouping, sorting, bucket semantics, rounding, retry |
| Streams/activity/projects | `Views/Streams`, `ActivityView.swift`, `SessionDetailView.swift` | `ui/streams`, `data/cloud`, project stores | Encrypted search, pagination, cache policy, project/session detail parity |
| Hermes/Agents/Pi | `Views/Hermes`, `Views/Chat`, `Services/Hermes`, `Services/CLIAgents` | `ui/hermes`, `data/hermes`, assistants and relay services | Streaming, stop, thread isolation, tools, attachments, runtime/connection parity |
| Insights and Budget | `Views/Insights`, `Views/Budget`, `Services/Insights` | `ui/insights`, `data/insights`, budget screens | Widget/schema parity, budget enforcement, entitlement gates, mission state |
| AI Inbox | `Views/Inbox`, `Services/AIInboxStore.swift` | `ui/inbox`, `MainActivity` deep-link handling | Notification delivery, row actions, cold/warm selection and persistence |
| Providers and accounts | `Views/ProviderConnectionsView.swift`, `MobileProviderWizardView.swift` | `ui/providers`, provider stores | Source-of-truth ownership, readback, account identity, error copy |
| Devices and transfer | `Views/You`, `Services/DevicesStore.swift`, credential transfer services | `ui/you`, cloud/escrow services | Trust/revoke/bootstrap, encrypted escrow, secure storage, readback validation |
| Mercury/media | `Views/Media`, `Features/Mercury`, media services | `ui/media`, `data/media`, `services/media` | Shared frames, peer model, heartbeat, mirror/call/file flows, fallback |
| Computer Use | `Views/ComputerUse`, `Services/ComputerUse` | `ui/computeruse`, `data/computeruse` | Authority, grants, approval, safety, live physical matrix |
| Store and entitlements | `Views/Store`, StoreKit services | `ui/store`, Google Play billing services | Product IDs, purchase/restore/expiry, entitlement readback and copy |
| OS integrations | Widgets, Live Activity, intents, push routing, iPad split views | `ui/widget`, notification services, deep links, Smart Display | Permission state, privacy, background refresh, OS-specific evidence |
| Accessibility/performance | Aurora theme/components and mobile test targets | Aurora theme/components, detekt/benchmark targets | Dynamic Type/TalkBack, reduced motion, memory/frame/stream budgets |

## 6. Execution topology

The program is sequenced by dependency, but each landing unit remains one
coherent PR theme. Every work task gets an independent validator and a gate.

### M0 — Freeze the inventory and evidence system

Inputs: baseline SHA above, `docs/ANDROID_NATIVE_PARITY_GOAL.md`,
`docs/IOS_APP_ARCHITECTURE.md`, `OpenBurnBarMobile/`, Android source tree,
existing tests and release runbooks.

Deliverables:

- capability registry and route/deep-link map;
- parity ledger with `fresh`, `historical`, `rebind-required`, `blocked`, and
  `accepted-divergence` states;
- source-to-iOS/iPadOS/Android ownership map;
- exact device/store/provider evidence schema;
- accepted non-goals and platform divergences signed off before coding.

Gate: VAL-MOB-001 and VAL-MOB-002 inventory portions pass. No feature may be
silently omitted because its current code is difficult to classify.

### M1 — Canonical contracts and generated consumers

Inputs: `tools/schema-sync/typespec/`, `manifest.json`, generated Swift/Kotlin/
TypeScript outputs, legacy mirrors.

Work:

- map every mobile-consumed document/callable to a TypeSpec domain or a named
  temporary legacy boundary;
- generate Swift and Kotlin outputs from the canon and make consumers import
  generated models where appropriate;
- migrate `functions/src/types/legacy/` domain-by-domain, preserving wire
  compatibility and shrinking `knownDrift`;
- add cross-language fixture vectors for optional/absent/null, enum evolution,
  timestamps, numeric precision, unknown fields, and malformed payloads;
- add CI checks so changing a mobile consumer without schema-sync output fails.

Do not hand-edit generated files. Do not “fix” drift by widening decoders or
adding suppressions. A compatibility exception must name its removal condition.

Gate: VAL-MOB-003 plus TypeScript, Swift, Kotlin, Firestore-rules, and generated
consumer tests.

### M2 — Shared semantics, crypto, transport, and policy

Inputs: `OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels`, shared kernel,
Signal/CloudVault/Iroh/Mercury packages, Android generated bindings and crypto/
relay modules.

Work:

- identify pure policies that must be single-source or vector-pinned: usage
  windows, quota status, entitlement gates, device trust, envelope AAD,
  signing/canonical JSON, relay frames, chunk completeness, and error classes;
- add Swift/Kotlin/TypeScript/Rust vectors where a shared implementation is not
  practical;
- preserve fail-closed behavior for malformed, stale, revoked, replayed,
  tampered, sender-unauthenticated, or binding-mismatched inputs;
- require Android parity for every existing iOS security decision, including
  cancellation and legacy fallback classification;
- prove native artifact identity and ABI/source fingerprint for Signal, Iroh,
  domain-core, and any generated AAR/XCFramework consumed by the app.

Gate: VAL-MOB-003, VAL-MOB-010, VAL-MOB-011, and VAL-MOB-012 scrutiny portions;
all relevant negative KATs and artifact-identity tests pass.

### M3 — Auth, sync, identity, devices, providers, and billing

Inputs: iOS stores/services, Android `data/firebase`, `data/stores`, auth,
devices, provider, and billing packages; Firestore rules/callables; StoreKit and
Play tooling.

Work:

- converge auth/session/account-mismatch state machines and error
  classifications;
- make Mac-first publishing and mobile read-only/mirror ownership explicit;
- align sync watermarks, freshness labels, listener lifecycle, offline cache,
  foreground refresh, retries, and cache clearing;
- align provider/account setup and readback semantics without moving secrets
  into Firestore or pretending a local-only account is cloud-connected;
- align device trust/bootstrap/revoke/rename and encrypted credential transfer;
- align StoreKit/Google Play product IDs, purchase/restore/expiry states,
  entitlement gating, and subscription copy without hardcoded prices;
- test account deletion/sign-out, revoked device, expired grant, missing key,
  wrong account, App Check denial, and network recovery.

Gate: VAL-MOB-004, VAL-MOB-005, VAL-MOB-009, VAL-MOB-010, and VAL-MOB-015
scrutiny portions.

### M4 — Primary product surfaces

Inputs: Pulse, Burn, Streams, Insights, Budget, Inbox, Providers, Store, and
their stores/services on both targets.

Work:

- build differential fixtures that drive source, iOS, iPadOS, and Android from
  identical usage/quota/provider/project/session data;
- compare totals, windows, rounding, grouping, sorting, provider identity,
  chart summaries, forecasts, and empty/error states;
- close route/deep-link/back-stack gaps revealed by the registry;
- make every interactive card action either real or removed; no decorative
  buttons, fake stop/cancel, silent discard, or success state before readback;
- include large-screen iPad and Android tablet layouts where the capability is
  accepted, not just handset screenshots.

Gate: VAL-MOB-002, VAL-MOB-006, VAL-MOB-007, and VAL-MOB-009 real-surface
validation on simulator plus named physical devices.

### M5 — Hermes, Agents, Pi, Mercury, media, and Computer Use

Inputs: iOS Hermes/relay/media/computer-use surfaces; Android Hermes/relay/media/
computer-use surfaces; shared protocol and trust code; Mac receiver.

Work:

- converge conversation/runtime/model/connection selection and stream state;
- prove stop, cancel, retry, partial result, tool call, attachment, reconnect,
  and thread isolation behavior;
- reconcile the Android Mercury checkpoints named in `android/app/AGENTS.md`
  against the current implementation and tests;
- keep Mercury additions on the existing shared `media.control` path unless the
  shared protocol changes first;
- exercise mirror/call/file/presence on iPhone, iPad, and Android against a
  paired Mac, including permission denial and recovery;
- run the full Computer Use safety matrix on every mobile family: authority,
  approval, deny regions, replay/tamper chaos, panic, expiry, kill switch,
  latency, and audit readback.

Gate: VAL-MOB-008, VAL-MOB-011, and VAL-MOB-012 real-surface validation. A
historical Android row cannot close an iPhone/iPad row.

### M6 — OS integrations and durable behavior

Inputs: iOS widgets/Live Activity/intents/push/deep-link code; Android widget,
notification, background, and deep-link code; iPad split navigation.

Work:

- create a platform matrix for notification permission granted/denied,
  foreground/background/terminated, warm/cold deep links, stale payloads,
  duplicate taps, and account changes;
- verify privacy-safe widget and Live Activity data, refresh cadence, and
  entitlement behavior;
- align keyboard/IME, rotation, split-screen, accessibility focus, process
  death, and state restoration;
- keep background work bounded and cancelable; no hidden infinite listener or
  retry loop.

Gate: VAL-MOB-002, VAL-MOB-013, and VAL-MOB-014 real-surface evidence.

### M7 — Accessibility, performance, and failure quality

Inputs: Aurora theme/components, screen-specific UI, existing mobile tests,
profiling/benchmark tooling.

Work:

- replace fixed-size text with Dynamic Type / scalable Compose typography;
- give every chart, quota ring, provider logo, icon-only action, loading state,
  error state, and live stream an equivalent VoiceOver/TalkBack label or
  announcement;
- verify contrast, focus order, touch targets, reduced motion/transparency,
  keyboard avoidance, screen privacy, and large text on iPhone/iPad/Android;
- measure cold launch, first useful data, list scroll, chart render, chat stream,
  memory, battery, and background retry behavior on representative hardware;
- remove dead/decorative code found by the parity inventory only when it is part
  of the same parity fix; do not turn this into a general refactor.

Gate: VAL-MOB-014 scrutiny plus manual accessibility and profiler evidence.

### M8 — Candidate-bound release and store certification

Inputs: release workflows, Android Gradle config, iOS project/package graph,
Firebase/App Check injection, StoreKit/ASC/Play tooling, evidence schema.

Work:

- build from a clean exact candidate; record source, generated artifact, native
  library, package, version/build, signing, and config fingerprints;
- run strict Android Firebase validation before release packaging;
- enforce the iOS source-Firestore graph and prepare the exact Signal artifacts;
- run Android ABI/page-size/package checks and iOS archive/export checks;
- install the exact artifacts on named iPhone, iPad, and Android devices and
  rerun smoke plus the relevant parity matrix;
- use TestFlight/App Store Connect and Google Play closed testing only with
  explicit authorization, then read back version/build, artifact digest,
  track/review state, tester availability, and install/update behavior;
- seal the evidence bundle and ledger before any release/rollout decision.

Gate: VAL-MOB-001, VAL-MOB-013, VAL-MOB-014, and VAL-MOB-015. Missing store,
provider, or physical-device evidence means `blocked`, not `ready with
conditions` disguised as `PASS`.

## 7. Validation matrix and commands

Run the cheapest relevant checks first, but do not substitute them for the
required surface.

| Layer | Command / procedure | Proves | Does not prove |
|---|---|---|---|
| Schema | `./tools/schema-sync/check-drift.sh` | Canon/generated/hand-mirror drift | User-visible decode or live Firestore behavior |
| Functions | `npm --prefix functions test` and targeted callable/rules suites | Producers, validation, rules | Mobile UI or store state |
| iOS package/core | `swift test --package-path OpenBurnBarCore` and targeted core suites | Shared policy, vectors, generated consumers | Installed app behavior |
| iOS mobile | `./scripts/test-openburnbar-mobile.sh` | Mobile XCTest bundle; simulator or connected device according to destination | Store acceptance, live provider, paired Mac unless configured |
| Android app | `./scripts/test-openburnbar-android.sh` | JVM tests for app/Iroh/remote modules | Physical Android behavior, Play billing, live Mac |
| Android quality | `cd android && ./gradlew ktlintCheck :app:detekt testDebugUnitTest` | Compile/style/static/unit quality | OS permission/device/store behavior |
| Android instrumentation | `cd android && ./gradlew connectedDebugAndroidTest` or the focused CI smoke | Emulator/device instrumentation | Named production candidate unless artifact-bound |
| Differential | Source/iOS/iPadOS/Android fixture replay | Numerical/semantic parity | Uncovered real user paths |
| Physical iOS/iPadOS | `OPENBURNBAR_IOS_DESTINATION=platform=iOS,id=<UDID> ./scripts/test-openburnbar-mobile.sh` plus manual flow receipt | Installed exact candidate on named Apple device | Android or store distribution |
| Physical Android | Gradle install/connected tests plus manual flow receipt on named device | Installed exact candidate on named Android device | Apple or Play publication |
| Release config | `node scripts/ci/verify-android-firebase-release-config.mjs --strict-release`; iOS Firebase injection/source-graph checks | Release configuration integrity | Provider correctness or store approval |
| Store | Authorized ASC/TestFlight and Play closed-test readback | Submitted/published artifact and tester/update state | Code correctness without candidate test evidence |

Every command must record cwd, environment assumptions, exit code, candidate
SHA, artifact path/digest, and evidence path. A command that could not reach its
intended surface must be marked `blocked` with the setup failure.

## 8. Failure, rollback, and evidence policy

- If source and target disagree, preserve the failing fixture and repair the
  earliest invalid contract or adapter.
- If generated output is stale, regenerate from the canon and review the diff;
  never hand-edit the generated file to make CI green.
- If a physical device, provider account, App Check token, or store credential
  is unavailable, stop that gate and record the missing prerequisite. Do not
  replace it with a weaker simulator/mock claim.
- If an artifact is rebuilt, invalidate all downstream device/store evidence
  until the new digest is read back.
- If a release or provider mutation is authorized and fails, follow the exact
  approved retry policy; do not improvise retries, rotate keys, or clean up
  external state.
- Keep raw logs, screenshots, traces, and receipts under a candidate-bound
  evidence directory. Keep the ledger concise and link each row to raw proof.
- Rollback must prove that the previous known-good mobile artifact, schema,
  entitlement state, and migration behavior remain usable. A code revert alone
  is not a mobile rollback proof.

## 9. Definition of done

The program is complete only when all of the following are true:

1. The capability registry covers every accepted mobile workflow and records
   explicit platform divergences and non-goals.
2. The route/deep-link map is canonical and cold/warm navigation is proven.
3. TypeSpec/generated/hand-mirror checks are green with no new drift and a
   decreasing legacy migration budget.
4. Source, iOS, iPadOS, Android, and shared vectors agree for all accepted data,
   policy, crypto, transport, entitlement, and error semantics.
5. Pulse, Burn, Streams, Hermes/Agents, Insights/Budget, Inbox, Providers,
   Devices/Transfer, Mercury/media, Computer Use, notifications, widgets, and
   store flows have passed their named VAL assertions.
6. Physical-device evidence exists for each required iPhone, iPad, and Android
   row, with exact artifact identity, OS, network, account, and result details.
7. Accessibility and performance floors have fresh evidence on representative
   hardware, including large text, reduced motion, privacy, offline, and
   process-restart behavior.
8. Store/provider/cloud readback evidence is fresh and exact-candidate-bound;
   external state is not inferred from source or CI.
9. The final evidence bundle and parity ledger are independently reviewed, the
   clean pass has run on the implementation diff, and no unresolved `blocked`,
   `rebind-required`, or stale `PASS` row remains.

Until then, the honest status is **mobile parity remediation in progress**.
