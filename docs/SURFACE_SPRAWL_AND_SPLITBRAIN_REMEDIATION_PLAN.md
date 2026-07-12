# Surface sprawl + split-brain mission execution — remediation program

> Remediation program for tech-debt audit 2026-06-30 findings **#4** (privileged & daemon
> binaries link the UI+crypto Core monolith) and **#5** (split-brain mission/trust
> execution). Grounded against the live tree at `origin/main@6f92a521a0` (2026-07-09) by a
> four-lane investigation (Core structure map, split-brain authority trace, prior-art/CI
> constraints, cross-platform duplication matrix).
>
> Enforcement lands first: `scripts/debt/check-core-ui-purity-budget.sh` and
> `scripts/debt/check-mission-splitbrain-budget.sh` (both wired into the
> `fast-feedback.yml` debt-budgets job) freeze both surfaces shrink-only, so every later
> phase is measurable and cannot regress.

## TL;DR (plain English)

Two big structural problems, one program:

1. **The shared Core is a monolith.** `OpenBurnBarCore`'s main module is 453 files /
   ~122k LOC and mixes pure data contracts with 115 SwiftUI/AppKit files. Because the
   daemon and the privileged input binaries link that module, every UI change rebuilds
   the most security-sensitive binaries, and a future security review would force a
   rushed split. **Fix:** carve the pure stuff (contracts, models) into a leaf "kernel"
   target, repoint the daemon and ComputerUseCore at it, and leave UI in a product only
   app targets link. A new CI gate makes sure Core's UI surface only shrinks from today.

2. **Two independent mission authorities.** The menubar GUI runs a ~3,700-line Firestore
   listener that does its own trust checks, approval gating, backend selection, and
   spawns agent CLI processes — in parallel to the daemon's `BurnBarMissionControlService`,
   which does the same four jobs with different code and different trust roots for a
   different mission population. Nothing routes between them. **Fix:** make the daemon
   the single decision authority via a new "remote mission authorization" RPC, rolled out
   shadow-first (compare verdicts) then enforced fail-closed, then delete the GUI's
   decision code. A second CI gate makes sure the GUI cluster only shrinks from today.

What this program is **not**: merging iOS/Android into daemon clients (they are
intentionally local-first per `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md`), a rewrite of
per-platform theming, or a Rust unification layer.

---

## Ground truth (what the investigation established)

### Finding #4 — the monolith and its link surface

- `OpenBurnBarCore/Sources/OpenBurnBarCore` = 453 files / ~122.5k LOC. Inside it:
  `Views/` 117 files (~30.7k LOC), `SharedModels/` 136 files (~30.6k), `Services/`
  73 files (LogParser 23 files/8.7k + Insights 45 files/11.7k), `ProviderQuota/` 41
  files (~6k), `Contracts/` 20 files (6.3k), plus Hermes, TextExpansion, loose AppKit
  launchers.
- **115 files import SwiftUI or AppKit** in that module (baseline now frozen in
  `budgets/core-ui-purity-baseline.json`).
- The package already has 12 extracted sibling targets (`OpenBurnBarComputerUseCore`,
  `OpenBurnBarMedia`, `OpenBurnBarSignalCore`, `OpenBurnBarIrohRelay`,
  `OpenBurnBarFirestoreModels`, `OpenBurnBarAnalytics`, …) — all UI-free today
  (assert-zero enforced by the new gate). The seam pattern works; the monolith is what
  remains.
- Link chain that motivates the split: `OpenBurnBarDaemon → OpenBurnBarCore` and
  `RemoteAccessAgentCore → ComputerUseCore → OpenBurnBarCore`, so
  `OpenBurnBarPrivilegedInputExecution` (HID entitlement) transitively links SwiftUI,
  AppKit launchers, and all Views.
- Sprawl nuance from the duplication matrix: RPC contracts are already codegen'd to a
  single canon (`tools/ipc/generate-burnbarrpc-canon.mjs` → Swift + TypeScript), and iOS
  reuses Core directly. The real dual-fix security risks are **Android's hand-written
  `BudgetGate.kt`**, **Hermes relay crypto integration points**, and **per-platform
  keystore bindings** — tracked as a separate lane (below), not solved by the Swift
  kernel split.

### Finding #5 — the two authorities, precisely

- **GUI:** `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener*.swift`
  (11 files, 3,694 LOC; baseline frozen in `budgets/mission-splitbrain-baseline.json`),
  started unconditionally at app startup. Listens to Firestore
  `users/{uid}/cli_agent_mission_requests`; applies its own device-trust check
  (`escrow_devices.trustState`), approval handshake (`+ApprovalFlow.swift` +
  `InsightMissionApprovalPolicy` + `cliAssistantAllowed`), entitlement fan-out caps,
  backend/model resolution (incl. the Wand python selector), and **directly executes**:
  spawns agent CLI processes with app-side capability grants (`+DirectExecution.swift`),
  drives `ChatSessionController`, mirrors transcripts to `cli_sessions`.
- **Daemon:** `OpenBurnBarDaemon/.../MissionControl/` (~5.9k LOC,
  `BurnBarMissionControlService`). Socket-RPC only (`daemon.mission.*`), never touches
  Firebase by design; peer auth = same-uid + code-signing requirement + capability
  attenuation; dispatch requires approved status, server-approved packet fingerprint,
  and a fail-closed execution-readiness gate.
- **They serve disjoint mission populations** (mobile/Wand missions → GUI only;
  controller/console missions → daemon only). Same Mission Console UX sits on different
  authorities per platform (macOS host → daemon RPC; iOS host → Firestore path). No
  routing flag, no relay scaffolding exists.
- **Hard constraints on unification:** the daemon cannot own the Firestore listener (no
  Firebase auth by design) and cannot unseal cloud-vault payloads (vault key access is
  app-side). The GUI must therefore remain the *transport* (attach, unseal, decode) and
  forward decisions — exactly the audit's proposed shape.
- Contract gap: `BurnBarMissionCreateRequest` today carries no prompt/runtime/
  capability-grant/persona-scope fields; a new request shape + canon regeneration is
  required (the RPC-canon drift gate blocks merges otherwise).

---

## The program

### Phase 0 — enforcement (this PR)

- `scripts/debt/check-core-ui-purity-budget.sh` + `budgets/core-ui-purity-baseline.json`:
  no NEW SwiftUI/AppKit-importing file in Core's main module; baselined files may only
  leave the set; the 11 pure sibling targets are assert-zero.
- `scripts/debt/check-mission-splitbrain-budget.sh` +
  `budgets/mission-splitbrain-baseline.json`: no new files in the GUI mission-authority
  cluster; baselined files may only shrink.
- Both wired into the `debt-budgets` job in `.github/workflows/fast-feedback.yml`
  (merge-blocking on every PR), with `--update` regeneration built into each script.

### Phase 1 — kernel extraction (strangler, per-slice PRs)

Goal state: privileged/daemon binaries link a UI-free kernel; SwiftUI lives in a product
only app targets link.

1. **K1 — `OpenBurnBarKernel` leaf target**: move `Contracts/` (20 files, 6.3k LOC) +
   Foundation-only `SharedModels/` + the one-file dirs (`Errors/`, `Budget/`,
   `Membership/`, `Metrics/`, `Entitlements/`, `Memory/`) into a new target with **zero**
   SwiftUI/AppKit/Firebase imports; `OpenBurnBarCore` gets `@_exported import
   OpenBurnBarKernel` so no call site changes. Watch: `tools/ipc/generate-burnbarrpc-canon.mjs`
   reads the Contracts path — update it in the same PR; regenerate the canon and prove
   zero wire-name drift.
2. **K2 — repoint the sensitive consumers**: `OpenBurnBarComputerUseCore` and the daemon
   targets depend on `OpenBurnBarKernel` (+ whatever narrow additions they truly need)
   instead of `OpenBurnBarCore` where possible. This is where the link-surface win lands;
   measure with the UI-purity gate plus a link-graph note in the PR body.
3. **K3 — `OpenBurnBarLogParsers` and `OpenBurnBarQuota`**: extract `Services/LogParser/`
   (8.7k) and `ProviderQuota/` (6k, dropping the two Insights-coupled types) onto the
   kernel. These are consumed cross-platform (parser parity executables) and are
   UI-free already.
4. **K4 — `OpenBurnBarUI` product**: move `Views/` (117 files/30.7k), `TextExpansion/`
   UI, `Demo/`, and the Insights view-coupled subsystem into an Apple-only product that
   only app targets link. The UI-purity baseline ratchets toward zero as slices land.
5. **Explicit non-slices**: `Services/Insights` stays with UI (view-coupled, non-Apple
   excluded); scattered AppKit launchers stay in Core until K4 exposes their true
   dependents (they are `#if canImport(AppKit)`-guarded and small).

Every K-slice is a structured-large-lane PR: review map, invariants (byte-identical wire
canon, no behavior change, all suites green), validation matrix (SPM build + tests on
macOS/iOS/Linux daemon cross-compile), rollback = revert (moves are mechanical; the
`@_exported` shim means consumers never see the seam move).

### Phase 2 — single mission authority (security path, shadow-first)

1. **M1 — characterization tests** (audit's own "test-first" directive): pin the current
   verdict behavior of BOTH engines — GUI trust/approval/fan-out verdicts, daemon
   approval/fingerprint/readiness verdicts — as table-driven tests, before any routing
   change.
2. **M2 — daemon authorization RPC**: new `daemon.mission.authorizeRemote` (request
   carries the decoded mission fields: prompt, runtime, requested capability grant,
   persona scope, origin device, approval evidence). The daemon ports the four decision
   classes (trust, approval incl. `InsightMissionApprovalPolicy`, backend resolution
   policy, capability-grant ceiling) behind its existing peer-auth + capability
   attenuation. Canon regenerated; wire-name gate green.
3. **M3 — shadow mode**: the GUI listener calls M2 before every claim/execute and logs
   verdict divergence (no behavior change). Run until divergence telemetry is quiet.
4. **M4 — enforce**: GUI executes only with a daemon-approved verdict; **fail closed**
   when the daemon is unreachable (parity with the daemon's own readiness-gate
   philosophy), with an explicit user-visible "daemon required for remote missions"
   state. The GUI's own decision code paths are deleted in the same PR the enforcement
   flips — the split-brain ratchet drops accordingly.
5. **M5 — execution migration (optional wave)**: move execution itself
   (`createDaemonManagedRun` growing interactive/transcript-mirror semantics) — larger,
   because the live-transcript mirror to `cli_sessions` is app-side today. Decide after
   M4 lands; authorization unification alone removes the security-divergence risk.

### Parallel lane — cross-platform dual-fix hotspots (tracked, separate PRs)

Not blocked by (and not blocking) the phases above:

- **Android `BudgetGate.kt`**: hand-reimplementation of Core's `BudgetGate`; also has
  zero callers per the Wave-5 finding (Alberto A/B pending). Either delete or generate
  conformance tests from a shared fixture corpus.
- **Hermes relay crypto** and **escrow keystore bindings**: shared models, divergent
  integration; add cross-platform sealed-fixture parity tests (same pattern as the
  existing parser-parity executables) so a crypto change that breaks one platform's
  integration fails CI.

## Risks / loophole audit

- **Gate evasion by rename** (mission cluster): glob-scoped; called out in the script
  header as a review-time offense. The per-*type* size gate (audit finding #2) is the
  durable fix and is a separate remediation.
- **`@_exported` hides progress**: consumers keep compiling against Core, so K1 alone
  does not shrink the privileged link surface — K2 is where the win lands; the PR bodies
  must not claim the win early.
- **Canon drift**: K1 and M2 both touch contract files; the repo-wide RPC-canon gate
  (fixed in #1395) blocks silent wire-name drift — regenerate and diff in-PR.
- **pbxproj/XcodeGen churn**: K-slices change `OpenBurnBarCore/Package.swift`, not the
  app pbxproj; XcodeGen `project.yml` references products — verify product names stay
  stable or update `project.yml` in the same slice.
- **Fail-closed availability cost (M4)**: remote missions stop working when the daemon
  is down, where today the GUI works alone. Deliberate: this is a security-authorization
  path; parity with the daemon's own fail-closed readiness gate. Mitigation is the
  explicit UI state plus daemon auto-start, not a silent fallback to GUI-side authority.
- **iOS build breaks invisible to PR CI** bit Wave 4 three times; the mobile compile
  gate now exists — K-slices must keep `OpenBurnBarMobile` compiling (it imports Core
  directly).

## Status

| Item | State |
|---|---|
| Phase 0 gates | this PR |
| K1 kernel target | PR in flight (this program) |
| M1 characterization + M2 authorization RPC | PR in flight (this program) |
| K2–K4, M3–M5 | staged behind the above |
| **K3/K4 completion (Core god-module decomposition)** | **Split into its own program — see [`docs/CORE_DECOMPOSITION_PROGRAM.md`](CORE_DECOMPOSITION_PROGRAM.md). S0 scaffold + regrowth gates landed; ~26 parallel move packets QUEUED. K3 unblocked by extracting the SQLite reader first; K4 (Views→OpenBurnBarUI) is the final wave.** |
