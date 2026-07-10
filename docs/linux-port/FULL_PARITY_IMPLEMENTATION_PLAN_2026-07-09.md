# OpenBurnBar Linux Full macOS Parity Implementation Plan - 2026-07-09

This document is the implementation-grade plan for taking Linux to full macOS
product parity. It merges:

- the local full parity audit in
  `docs/linux-port/full-macos-parity-audit-2026-07-09.md`
- CMUX pane `pane:22` / `surface:36`, titled `pi: Linux full parity`
- CMUX pane `pane:23` / `surface:35`, titled `devin: Linux Parity Scan and Migration Plan`
- CMUX pane `pane:24` / `surface:37`, titled `Linux MacOS Parity Scan Thorough Exam`
- current repo verification performed on this checkout

This is not a marketing checklist. It is a build plan with ownership,
dependencies, acceptance contracts, proof commands, loophole controls, and
known platform divergences.

## Executive Verdict

Linux is not at full macOS parity.

> **Execution update (2026-07-10 UTC):** the implementation wave completed the
> fail-closed 40-requirement inventory, Linux secret custody/native gateway
> boundary, runtime capability manifest, installed accessibility harness,
> matched performance/soak harness, native signed-feed verifier, and native
> aarch64/x86_64 shard/aggregate workflow. A clean aarch64 `.deb` session passed
> GUI/daemon/version/uninstall, all 19 installed routes, AT-SPI/Orca/keyboard/200%
> zoom, 28 package-smoke steps, and repeated startup/tray/IPC measurements. The
> next blocking order is x86_64 installed proof -> prior-version update/rollback
> -> valid signed public feed -> daily-use/native product workflows -> full
> desktop/compositor certification. The independent audit is the current status
> source: `LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md`.

Linux has a real desktop shell, a broad set of route surfaces, a Swift daemon
path, AF_UNIX RPC, a provider gateway, package metadata, Linux-specific
evidence scripts, and a public signed aarch64 prerelease. That is a real base.
It is not full parity because the remaining gaps are foundational, not cosmetic:
path ownership is split, the parity ledger overclaims, release promotion is not
strict-green, the design-token/layout foundation is incomplete, several Linux
daemon subsystems are stubs or excluded, some UI surfaces are status shells
rather than workflows, and the bridge still contains at least one raw method
string that has no daemon handler.

The strategy below is now confidence-looped. "100% confident" means this plan
has no hidden assumptions left: every remaining uncertainty is either verified,
turned into a hard Phase 0 gate, or represented as an explicit blocker with an
owner and acceptance test. It does not mean every future implementation detail
is risk-free.

## Planning Baseline Live Context

The values below are the source snapshot used to create this plan. They are
preserved for provenance and are superseded by the execution update above.

- Workspace: `/Users/albertonunez/Documents/Developer/BurnBar`
- Branch: `windows/liquid-glass-kernel-reskin`
- Current HEAD during this plan: `81318d6787ab4901a23b7f2d6427773da6352220`
- Worktree state: dirty, with Linux UI changes, Linux evidence JSON changes,
  Windows parity docs/scripts, package desktop files, and several untracked
  parity-plan files
- Public Linux prerelease: `linux-v0.1.0`, published 2026-07-09 04:46:23Z
- Release workflow checked earlier: Linux Release run `28994097882`, success
  on `main` at `e265594f054726b60cdf0921c104e1e79fe577d4`
- Public update-feed check: `https://burnbar.ai/latest-linux.json` returned
  website HTML, not JSON update metadata

Do not flatten these into one "Linux shipped" fact. Treat them separately:
public prerelease assets exist; full macOS parity does not; strict release
promotion is still blocked on the local verifier and update-feed proof.

## What CMUX Added

### Pane 22 - RPC and transport correction

The `pi` pane caught a critical implementation risk: several draft strategies
invented daemon RPC names that do not exist. The corrected rule is:

- Chat send/stream uses the existing HTTP gateway through
  `apps/linux-desktop/src/chat/gatewayClient.ts` and the Tauri
  `gateway_auth_token` command. Do not invent `daemon.hermes.*`,
  `chat_send`, `chat_tool_decision`, or `hermes://stream`.
- Tool approval should wrap the existing `approval.respond` daemon method.
- Tool result dispatch should use the existing `workspace.toolResult` method
  only if the shell must post tool outputs.
- Memory review approve/reject should call existing
  `daemon.memory.remember` and `daemon.memory.forget`, not invented
  `daemon.memory.review_*` methods.
- Computer Use should wrap the existing `daemon.computer_use.*` enum methods.
- Mercury should not use raw `daemon.media.*` or `daemon.mercury.*` names.
  The real transport path is iroh plus the remote-access-agent socket. Any
  future daemon media method must first be added to `BurnBarRPCMethod`,
  `BurnBarRPCCapability`, and `BurnBarDaemonSocketRPCCoverage`.
- SmartHub control should stay on the `openburnbar-cli devices iot ...`
  surface unless and until a real daemon method is added.
- Text expansion sync should use existing config/database contracts, not an
  invented `daemon.textexpansion.sync`.

This changed the plan materially. Bridge work is now contract-first rather than
string-first.

### Pane 23 - foundation before surfaces

The Devin pane caught another serious risk: the existing plan would have built
feature surfaces before the foundation was stable.

Verified risks from that pane:

- Linux has no `DashboardLayout` implementation under `apps/linux-desktop/src`,
  while macOS and Windows both have a six-layout contract using the
  `dashboardLayout` persistence key.
- `apps/linux-desktop/src/styles/app.css` says token values come from
  generated design tokens, but it still hardcodes skin hex values and
  `apps/linux-desktop/package.json` does not depend on
  `@openburnbar/design-tokens`.
- `docs/linux-port/parity-ledger.json` is pinned to `main` at
  `64538ed350b1d3bd25ddd1cae1ba67b2a9165c57`, while this branch has moved.
- The ledger has 64 rows and all are `ready`; that ledger cannot be used as
  full product parity truth.
- The Windows branch is a co-oracle, not noise. Its dashboard layout C# files
  already port parts of the macOS model and should be used as a portability
  guide.

### Pane 24 - adversarial strategy gaps

The Grok pane added a hardened strategy pass:

- The current plan must explicitly handle the path triple-split: config path,
  data/support path, and runtime socket path.
- Parser discovery and user-visible provider log directories are not the same
  contract and must be reconciled before claiming parser parity.
- The ledger validator is too weak for full product parity because it validates
  internal row consistency, not current checkout freshness.
- Release proof remains blocked by local `release-verification.json` even
  though public prerelease assets exist.
- Strategy confidence is high only after G0-G5 style gates are bound to real
  commands and evidence.

## Verification Already Run

The following checks were run on this checkout while preparing this plan:

```bash
npm test --prefix apps/linux-desktop
npm run build --prefix apps/linux-desktop
cd apps/linux-desktop && npx tsc --noEmit
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
node scripts/linux-port/verify-linux-release.mjs --allow-blocked
```

Results:

- `npm test --prefix apps/linux-desktop`: passed, 41 files, 270 tests.
- `cd apps/linux-desktop && npx tsc --noEmit`: passed.
- `npm run build --prefix apps/linux-desktop`: passed, but Vite emitted a CSS
  syntax warning: `.integration-doc-link:focus-visible` has an unbalanced `{`.
- `validate-parity-ledger.mjs --allow-blocked`: passed in allow-blocked mode,
  while reporting the dirty current checkout.
- `check-linux-docs.mjs`: passed.
- `verify-linux-release.mjs --allow-blocked`: exited in allow-blocked mode but
  reported `"passed": false`. Failures include missing local AppImage/deb/rpm
  and daemon artifacts, missing checksum targets, blocked latest-linux draft,
  and dirty checkout outside generated Linux release evidence.

These results are good enough to plan from. They are not good enough to claim
full parity or release promotion.

## Confidence Loop

### Loop 0 - initial answer was not enough

Question: Are we 100% confident in the original strategy?

Answer: No.

Loopholes found:

1. It treated public prerelease assets as too close to release parity.
2. It did not treat `latest-linux.json` returning HTML as a hard update-feed
   blocker.
3. It used or tolerated invented daemon method names.
4. It did not put `DashboardLayout` and design-token integration before surface
   work.
5. It did not make the stale 64-row ledger a hard truth-reset task.
6. It did not account for the current branch being dirty and divergent.
7. It did not separate parser discovery from provider log-directory display.
8. It did not include the CSS syntax warning found by the build.
9. It did not bind every feature to VAL-* contracts and evidence paths.
10. It allowed broad parallel lanes to collide on shared files.

Fixes applied in this plan:

- Add Phase 0 hard gates before feature work.
- Add a single shared-seam integration owner.
- Require existing `BurnBarRPCMethod` contracts or explicit enum/capability
  additions for every new daemon method.
- Put path, parser, ledger, token, and dashboard foundations before surfaces.
- Add accepted divergences so strict parity is not infinite.
- Add evidence paths and proof commands for every lane.

### Loop 1 - factual source verification

Question: Are the corrected assumptions backed by source?

Answer: Mostly yes, with explicit blockers.

Verified:

- No Linux `DashboardLayout` hits exist under `apps/linux-desktop/src`.
- Windows has `DashboardLayout.cs` and `DashboardLayoutState.cs` with the same
  six layouts and `dashboardLayout` storage key.
- macOS has `DashboardLayout` plumbing through `AppearanceSettings` and related
  dashboard layout sources.
- `apps/linux-desktop/package.json` has no `@openburnbar/design-tokens`
  dependency.
- `app.css` still hardcodes skin hex values.
- Existing daemon methods include `approval.respond`, `workspace.toolResult`,
  `daemon.computer_use.session.start`, `daemon.computer_use.invoke`,
  `daemon.computer_use.approval.pending`,
  `daemon.computer_use.approval.respond`, `daemon.computer_use.panic_halt`,
  `daemon.computer_use.audit_export`, `daemon.memory.remember`,
  `daemon.memory.recall`, `daemon.memory.forget`,
  `daemon.memory.audit_trail`, `daemon.notification.command`, and
  `daemon.followup.calendar`.
- `apps/linux-desktop/src-tauri/src/lib.rs` still calls raw
  `daemon.media.status`; this is not in the current RPC enum and must be fixed
  or replaced by a real media-control contract.

Blockers:

- Some source anchors in pane notes may drift while other agents are editing.
  The implementation must re-run `rg` and source reads at the start of each PR.

### Loop 2 - strategy confidence

Question: Are we 100% confident in the revised strategy?

Answer: Yes, in the strategy. The plan is factually confidence-complete because
all remaining unknowns are represented as gates, blockers, or accepted
divergences. It is not claiming that implementation will be short or risk-free.

Stop condition:

- No hidden assumptions remain.
- No invented daemon methods remain.
- No release claim depends on allow-blocked verification.
- No UI feature can claim parity without a VAL contract and proof command.
- No parallel lane can edit shared seams without the integration owner.

## Non-Negotiable Implementation Rules

1. **Do not implement against invented RPC strings.**
   Every daemon command must use an existing `BurnBarRPCMethod` case, or the PR
   must add the enum case, handler, capability mapping, socket coverage row, and
   tests in the same coherent unit.

2. **Do not treat the current parity ledger as product truth.**
   The existing ledger is historical infrastructure evidence. Product parity
   needs a refreshed ledger or an additional product ledger that binds ready
   rows to current evidence.

3. **Do not build new surfaces on missing foundations.**
   Dashboard layout, generated design tokens, path contracts, parser paths, and
   shell shared seams come before surface expansion.

4. **Do not claim Linux release parity from a public prerelease alone.**
   Strict `verify-linux-release.mjs`, public JSON update feed, package smoke,
   signatures, provenance, rollback/update proof, and clean release state must
   all pass.

5. **Do not parallelize shared-file edits.**
   `SurfaceRouter.tsx`, `routes.ts`, `tauriBridge.ts`,
   `apps/linux-desktop/src-tauri/src/lib.rs`, `daemonFixture.ts`, app-wide CSS,
   shell stores, and release validators have one integration owner at a time.

6. **Do not hide platform limitations.**
   If GNOME Wayland blocks a capability, record a Tier C substitute with proof.
   Do not silently call it full parity.

## Accepted Divergences

Strict full parity does not mean copying Apple APIs literally.

Accepted platform substitutions:

- StoreKit -> Stripe or first-party web billing
- iCloud -> Firestore/sealed archive/cloud sync
- FSEvents -> inotify/fanotify where appropriate
- Keychain -> Secret Service/KWallet/systemd credentials/headless encrypted
  fallback
- Network.framework -> POSIX sockets and existing Linux HTTP gateway
- Sparkle/appcast -> signed Linux JSON feed and package-manager/AppImage update
  semantics
- CGEvent text expansion -> IBus/fcitx/IME route, with in-app-only fallback
  where the desktop environment cannot safely support system-wide expansion
- Apple code signing -> package-root/hash-pin/Sigstore/Ed25519 proof
- macOS privileged HID -> portal/libei/uinput/XTEST/AT-SPI equivalents with
  explicit consent and fail-closed behavior
- Lock-screen secure input -> unsupported unless compositor/system APIs provide
  a safe equivalent
- Bundled H.264 -> user-installed system codec where licensing requires it

Everything else with a Linux technical equivalent remains in scope.

## Phase 0 - Reanchor Before Any Feature Work

Goal: make current truth explicit, remove malformed build inputs, and prevent
implementation on stale or contradictory evidence.

Owned files:

- `docs/linux-port/evidence/mission-002-reanchor/**`
- `docs/linux-port/parity-ledger.json`
- `docs/linux-port/parity-ledger.md`
- `docs/linux-port/factory-pr-handoff.md`
- `docs/linux-port/README.md`
- `docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`
- `apps/linux-desktop/src/styles/app.css`
- `scripts/linux-port/validate-parity-ledger.mjs`

Work:

1. Create `docs/linux-port/evidence/mission-002-reanchor/`.
2. Save current `git rev-parse HEAD`, `git status --short --branch`, and
   active branch name.
3. Save outputs from frontend baseline commands.
4. Fix the CSS syntax warning around `.integration-doc-link:focus-visible`.
5. Run and archive:

```bash
npm test --prefix apps/linux-desktop
npm run build --prefix apps/linux-desktop
cd apps/linux-desktop && npx tsc --noEmit
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
node scripts/linux-port/verify-linux-release.mjs --allow-blocked
```

6. Decide ledger strategy:
   - Option A: split historical infrastructure ledger and product parity ledger.
   - Option B: extend the existing ledger with `scope`, `evidenceHead`,
     `validatedAtHead`, and `staleWhenHeadDiffers`.
7. Strengthen strict ledger validation so ready Tier A/B product rows cannot
   remain green when their evidence head differs from the target release head.
8. Update `factory-pr-handoff.md` so blocker language matches the ledger.
9. Add a CI check that catches public `latest-linux.json` returning HTML.

Acceptance:

- `VAL-000-BASELINE`: current branch, HEAD, dirty entries, frontend test/build,
  docs check, ledger validator, and release verifier outputs are archived.
- `VAL-000-CSS`: Vite build has no CSS syntax warning.
- `VAL-000-LEDGER`: ledger semantics distinguish historical rows from current
  product parity rows.

## Phase 1 - Path, Parser, Token, and Dashboard Foundation

Goal: eliminate foundation drift before adding more user-visible workflows.

Owned files:

- `apps/linux-desktop/src/linuxPaths.ts`
- `apps/linux-desktop/src-tauri/src/lib.rs`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonConfiguration.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift`
- `apps/linux-desktop/src/onboardingSteps.ts`
- `apps/linux-desktop/src/surfaces/settings/**`
- `apps/linux-desktop/src/styles/app.css`
- `apps/linux-desktop/package.json`
- `apps/linux-desktop/src/state/**`
- new Linux dashboard layout files under `apps/linux-desktop/src/**`

### 1.1 Canonical Linux paths

Current issue:

- Tauri uses `$XDG_RUNTIME_DIR/openburnbar/daemon.sock`, then support-dir
  fallback.
- TypeScript support path uses `XDG_DATA_HOME/OpenBurnBar`.
- Rust support path uses `XDG_DATA_HOME/openburnbar`.
- Daemon defaults and evidence scripts still mention `~/.config/OpenBurnBar` or
  other locations.
- Onboarding can tell users to start a command that only probes health.

Target:

- Runtime socket: `$XDG_RUNTIME_DIR/openburnbar/daemon.sock`
- Durable support/data: one casing and one XDG location, explicitly chosen
- Config: one XDG config location
- Auth token: one owner, one file mode, one reader path shared by shell, daemon,
  and CLI
- CLI reads token file and env vars
- Package systemd unit creates and owns the runtime path

Acceptance:

- `VAL-PATH-001`: Rust, TS, daemon, CLI, package service, onboarding, and
  evidence scripts agree on socket/token/config/data paths.
- `VAL-PATH-002`: tests cover default XDG paths, custom XDG paths, missing
  runtime dir, wrong permissions, and token-file fallback.

### 1.2 Parser discovery versus log-directory display

Current issue:

- Provider parser discovery and user-visible provider log settings are distinct.
- The app risks showing one path while the parser reads another.

Target:

- Define a shared Linux provider path registry with:
  - provider id
  - logical path
  - resolved path
  - file pattern
  - XDG behavior
  - symlink behavior
  - display label
  - parser source id
- Use the registry from parser tests, settings UI, onboarding copy, and evidence
  scripts.

Acceptance:

- `VAL-PARSER-001`: Codex, Claude, Grok, OpenCode, Goose, Cline, Cursor,
  Gemini, Kimi, Pi, OMP, Droid, Forge, Antigravity, and Junie paths have one
  source-of-truth row.
- `VAL-PARSER-002`: UI displayed path and parser discovery path match for each
  provider under default and custom XDG homes.

### 1.3 Design tokens

Current issue:

- `app.css` claims token ownership but hardcodes hex values for skins.
- `apps/linux-desktop/package.json` does not depend on the design-token package.

Target:

- Add a real dependency or Vite alias for generated design-token CSS.
- Import generated token CSS once.
- Move skin colors into token inputs or a generated Linux skin layer.
- Keep component CSS on semantic tokens only.
- Add lint/check for new hex literals in app surface CSS except in approved
  generated files.

Acceptance:

- `VAL-TOKENS-001`: Linux app consumes generated token CSS.
- `VAL-TOKENS-002`: app source CSS contains no new ad hoc skin hex constants
  outside allowlisted generated/token files.
- `VAL-TOKENS-003`: reduced motion and reduce transparency modes still pass.

### 1.4 Dashboard layout system

Current issue:

- macOS and Windows define the six-layout contract.
- Linux has no `DashboardLayout` implementation.

Target:

- Add Linux `DashboardLayout` enum with raw values:
  - `classic`
  - `aurora`
  - `nebula`
  - `constellation`
  - `cockpit`
  - `atelier`
- Persist with storage key `dashboardLayout`.
- Add `DashboardLayoutState` / Zustand equivalent.
- Add layout switcher.
- Add six layout shells.
- Mark kernel-forward layouts (`constellation`, `atelier`) and wire them to the
  existing kernel backdrop.

Acceptance:

- `VAL-DASHBOARD-001`: Linux raw values and default match macOS/Windows.
- `VAL-DASHBOARD-002`: layout survives reload through `dashboardLayout`.
- `VAL-DASHBOARD-003`: every layout has empty, loading, populated, offline, and
  error states.
- `VAL-DASHBOARD-004`: visual proof captures all six layouts at desktop and
  mobile-ish widths.

## Phase 2 - RPC and Bridge Contract Correction

Goal: make the Tauri bridge a typed adapter over real daemon contracts.

Owned files:

- `apps/linux-desktop/src-tauri/src/lib.rs`
- `apps/linux-desktop/src/tauriBridge.ts`
- `apps/linux-desktop/src/daemonFixture.ts`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift`
- daemon RPC handler tests

Rules:

- No ad hoc raw strings except existing documented transitional probes.
- New daemon behavior requires enum, capability, handler, coverage, fixture,
  TS type, and tests in the same PR.
- Commands must be appended to `generate_handler![...]` in one section by the
  bridge owner.

Work:

1. Add Tauri `tool_approval_respond` wrapper -> `approval.respond`.
2. Add optional Tauri `workspace_tool_result` wrapper -> `workspace.toolResult`
   only if needed by chat/tool execution.
3. Add Tauri `memory_set_status` wrapper:
   - approve -> `daemon.memory.remember`
   - reject -> `daemon.memory.forget`
   - audit -> `daemon.memory.audit_trail`
4. Add Tauri Computer Use wrappers:
   - `computer_use_session_start`
   - `computer_use_invoke`
   - `computer_use_approval_pending`
   - `computer_use_approval_respond`
   - `computer_use_panic_halt`
   - `computer_use_audit_export`
5. Fix `media_status`:
   - remove raw success expectation for `daemon.media.status`
   - return explicit capability-absent until a real media-control contract
     exists
   - if adding a media method, add the Swift enum/capability/coverage first
6. Add SmartHub control bridge through `openburnbar-cli devices iot ...`
   subprocesses only after CLI commands exist.
7. Add text-expansion persistence through existing config/database paths, not
   invented daemon strings.

Acceptance:

- `VAL-RPC-001`: `rg` over bridge code shows no new `daemon.hermes.*`,
  `daemon.media.*`, `daemon.mercury.*`, `daemon.smarthub.*`,
  `daemon.textexpansion.*`, or `daemon.memory.review_*` strings unless they
  exist in `BurnBarRPCMethod`.
- `VAL-RPC-002`: every Tauri command has a fixture, TS type, success test, and
  daemon-down degraded test.
- `VAL-RPC-003`: `BurnBarDaemonSocketRPCCoverage` covers every daemon method
  used by the shell.

## Phase 3 - Daemon/Core Feature Completion

Goal: replace stubs and macOS-only exclusions with Linux equivalents where the
platform can support them.

Owned files:

- `OpenBurnBarDaemon/Package.swift`
- `OpenBurnBarCore/Package.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/**`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/MissionControl/Bridges/**`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/**`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/**`
- `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/**`
- `OpenBurnBarDaemon/Tests/**`
- `OpenBurnBarCore/Tests/**`

Work:

1. Secret storage:
   - wire Secret Service/KWallet/systemd credential backends into provider,
     connector, notification, DB-key, audit signer, and phone-pin stores
   - refuse plaintext for high-value keys
   - prove locked-keyring fail-closed behavior
2. Pensieve:
   - lift pure Swift chunker/cloak pieces where possible
   - replace no-op `PensieveKnowledgeWatcherLinux` with inotify
   - debounce and enqueue changed files to the queue directory
3. Switcher shell:
   - replace `unsupportedCLI` Linux shell with POSIX PTY runner
   - support spawn, resize, terminate, and process-tree cleanup
4. Gateway:
   - port `/v1/models` and `/v1/models/catalog` parity
   - add model health, route health, failover, quota exhaustion, and oversized
     AF_UNIX payload tests
   - add IPv6 loopback if policy permits
5. CLI:
   - align `cliSupport` capability with actual CLI commands
   - test run/list/get/poll/cancel/retry/approval paths under production peer
     auth
6. Mission control:
   - D-Bus notifications through `org.freedesktop.Notifications`
   - shell banner fallback when no D-Bus is available
   - CalDAV/evolution-data-server or configured calendar backend for calendar
     followups
7. Computer Use:
   - keep browser path fully supported
   - implement system path through AT-SPI2 inspect, xdg-desktop-portal
     RemoteDesktop, libei/EIS where available, uinput helper with polkit and
     hash pin, and XTEST for X11
   - fail closed when compositor blocks control
   - implement panic halt and audit export signer with Linux secret backing
8. Mercury:
   - wire iroh and `crates/burnbar-remote`
   - use remote-access-agent socket where appropriate
   - add real file-transfer, screen-share, and call state control surface
   - no raw media RPC names without enum/capability/coverage
9. SmartHub/devices:
   - extend `openburnbar-cli devices iot ...` control subcommands
   - keep Tauri shell as caller of CLI commands until daemon methods exist
10. Linux test backfill:
   - replace `LinuxEmptyTests.swift` placeholders with behavior tests
   - cover analytics, remote engine, media, iroh relay, signal/session
     transport, computer-use core, and OpenBurnBarCore contracts

Acceptance:

- `VAL-DAEMON-001`: Docker Linux Swift build passes for
  `OpenBurnBarCore` and `OpenBurnBarDaemon`.
- `VAL-DAEMON-002`: Linux gateway tests cover chat, models, model catalog,
  failover, rate-limit, auth, malformed input, and large frames.
- `VAL-SECRETS-001`: real GNOME Secret Service and KDE KWallet tests pass, and
  locked-keyring behavior fails closed.
- `VAL-CU-001`: browser Computer Use works with approval/audit/panic proof.
- `VAL-CU-002`: system Computer Use either works on certified compositors or is
  recorded as Tier C with proof of the block.
- `VAL-MEDIA-001`: media transport has a real capability source and no
  non-existent daemon method calls.

## Phase 4 - Linux Shell and Workflow Parity

Goal: make Linux feel like OpenBurnBar, not a status dashboard.

Owned files:

- `apps/linux-desktop/src/surfaces/**`
- `apps/linux-desktop/src/state/**`
- `apps/linux-desktop/src/components/**`
- `apps/linux-desktop/src/chat/**`
- `apps/linux-desktop/src/routes.ts`
- `apps/linux-desktop/src/surfaces/SurfaceRouter.tsx`
- `apps/linux-desktop/src/daemonFixture.ts`
- surface tests

Shared-seam rule:

- One integration owner edits `routes.ts`, `SurfaceRouter.tsx`,
  `tauriBridge.ts`, `src-tauri/src/lib.rs`, global CSS, and fixtures.
- Surface agents own their feature folders and local stores only.

Surface work:

1. Overview/dashboard:
   - six dashboard layouts
   - layout switcher
   - real daemon health offline state, not only `!bridge`
   - kernel-forward layout support
2. Menu/tray:
   - macOS-equivalent popover sections: insights, summary, providers, Mercury,
     chat, quick switch
   - AppIndicator/fallback behavior documented
3. Chat:
   - remove stub assistant/tool text
   - consume real `gatewayClient.ts` stream events
   - tool cards approve/deny through `approval.respond`
   - attachments, memory citations, model picker, transcript replay, popout,
     options, backend status, and offline states
4. Activity/session logs:
   - transcript panes
   - source filters
   - local/cloud body resolution
   - resume/export/pending questions
   - mission context
5. Missions:
   - skeleton loading
   - runtime health
   - evidence drawers
   - controller workbench
   - freshness/history
6. Providers/models:
   - provider deep dive
   - model catalog
   - route health
   - quota state
   - credential state
   - failover/cooldown visibility
7. Account/cloud/membership:
   - accepted Stripe redirect flow
   - Firebase auth providers
   - App Check status
   - cloud backup/trust device state
   - remote MCP/account settings
8. Memory:
   - true review inbox semantics using remember/forget/audit
   - quarantine/approve/reject UX
   - no recall-as-approved substitute unless explicitly degraded
9. Computer Use:
   - settings tab/route
   - trust mode
   - approval queue
   - audit export
   - panic controls
   - portal permissions
   - browser session UX
   - system degraded states
10. Mercury:
   - dedicated route or full support surface
   - pair/call/mirror/file controls
   - incoming call state
   - mute/camera/share/end controls
   - capability-absent state when transport is unavailable
11. SmartHub/integrations:
   - cast/Home Assistant/PixelClock/SmartHub controls through real CLI or daemon
     contracts
   - no read-only masquerading as parity
12. Text expansion:
   - daemon-backed snippet persistence
   - IBus/fcitx integration for system-wide expansion when available
   - in-app-only fallback as explicit Tier C
13. Pet companion:
   - route preview plus daemon-backed state
   - overlay where supported
   - Wayland-safe contained fallback
   - chat bubble, hover toolbar, file/drop actions where possible
14. Insights:
   - agent insights workspace
   - canvas/composer
   - citations
   - compare/followups/audit actions
15. Projects/database:
   - project register/edit/detail
   - database inspector/search/snapshot
   - watch semantics bound to Linux inotify/poll truth

Acceptance:

- `VAL-UI-001`: every route has populated, loading, empty, error, and
  degraded/offline states.
- `VAL-UI-002`: every interactive control has a test for success and daemon-down
  behavior.
- `VAL-UI-003`: no visible text overflows at mobile or desktop widths.
- `VAL-UI-004`: packaged shell smoke covers navigation, route interactions,
  keyboard-only operation, reduced motion, and screenshots.

## Phase 5 - Release, Packaging, Update, and Public Trust

Goal: Linux promotion must be as defensible as macOS direct release.

Owned files:

- `packaging/linux/**`
- `.github/workflows/linux-*.yml`
- `scripts/linux-port/**`
- `scripts/ci/**`
- `website/public/downloads/**`
- `docs/linux-port/release-runbook.md`
- `docs/security/SUPPLY_CHAIN_PROVENANCE.md`
- `docs/RELEASE_ROLLBACK.md`
- `CHANGELOG.md`
- `README.md`

Work:

1. Add top-level `make release-linux` or equivalent factory entrypoint.
2. Produce AppImage, deb, rpm, and daemon from a clean release commit.
3. Upload Linux source tarball parity and verify it.
4. Verify Ed25519 signature bytes.
5. Verify Sigstore/cosign identity and predicate payload.
6. Fix tag/ref identity mismatch if present.
7. Publish real JSON `latest-linux.json` only after strict verifier green.
8. Add update-feed parser tests and shell update-state tests.
9. Add previous-version install -> update -> verify -> rollback smoke, with a
   documented first-release exception until a previous stable artifact exists.
10. Prove deb/rpm package installs daemon, systemd user service, desktop file,
    icon, autostart, and uninstall cleanup.
11. Add AppImage GUI launch smoke.
12. Add RPM GUI launch smoke.
13. Fix or mark AUR metadata as unpublished until hashes and tags match.
14. Keep Flatpak non-promotable until portal/update/Flathub evidence exists.
15. Add public download trust verification for website links.
16. Add Sentry Linux daemon/shell readback and strict observability release
    setting.
17. Add support matrix, known limitations, user setup, and rollback docs.

Acceptance:

- `VAL-RELEASE-001`: strict `node scripts/linux-port/verify-linux-release.mjs`
  exits 0 without `--allow-blocked`.
- `VAL-RELEASE-002`: `curl -fsS https://burnbar.ai/latest-linux.json` returns
  valid JSON and passes schema/signature verification.
- `VAL-RELEASE-003`: package install/launch/uninstall proof exists for deb,
  rpm, and AppImage.
- `VAL-RELEASE-004`: update/rollback proof exists or first-release exception is
  explicit and validator-approved.
- `VAL-RELEASE-005`: public docs and CHANGELOG describe prerelease/stable status
  accurately.

## Phase 6 - Real-Surface Matrix and Security Proof

Goal: certify the product on actual Linux desktops.

Target environments:

- Ubuntu 24.04 GNOME X11
- Ubuntu 24.04 GNOME Wayland
- Fedora KDE Wayland
- Arch or wlroots/Sway

Work:

1. Provision self-hosted runners, UTM VMs, or equivalent nested compositor jobs.
2. Run packaged shell smoke in every environment.
3. Capture screenshots and AT-SPI snapshots for every route.
4. Run Secret Service tests on GNOME.
5. Run KWallet tests on KDE.
6. Run portal permission tests on Wayland.
7. Run global panic proof where the compositor permits it.
8. Run support bundle redaction scan.
9. Run App Check/Firebase/Auth/Stripe/cloud sync proof against staging/prod.
10. Record blocked rows as `blocked.json` with exact platform reason.

Acceptance:

- `VAL-MATRIX-001`: every supported environment has a dated proof artifact.
- `VAL-MATRIX-002`: unsupported environment/capability combinations are public
  limitations, not hidden failures.
- `VAL-SECURITY-001`: secret, checkout, App Check, support bundle, peer-auth,
  and Tauri URL tests pass.

## Six Parallel Implementation Streams

### Stream A - Foundation and ledger

Mission:

- Establish true current state, fix CSS syntax, ledger semantics, paths, parser
  registry, design tokens, and DashboardLayout.

Owns:

- `docs/linux-port/parity-ledger*`
- `scripts/linux-port/validate-parity-ledger.mjs`
- `apps/linux-desktop/src/linuxPaths.ts`
- `apps/linux-desktop/src/styles/app.css`
- dashboard layout state/components
- design-token integration

Non-goals:

- Feature-specific surfaces beyond skeletons.
- Daemon behavior changes except path contract coordination.

Verification:

- `VAL-000-*`, `VAL-PATH-*`, `VAL-PARSER-*`, `VAL-TOKENS-*`,
  `VAL-DASHBOARD-*`

### Stream B - Daemon, core, and security

Mission:

- Replace Linux stubs, wire credential stores, align CLI capability, complete
  gateway/provider behavior, and implement Linux-safe Computer Use/media
  foundations.

Owns:

- `OpenBurnBarDaemon/**`
- `OpenBurnBarCore/**`
- Linux daemon tests
- Linux core tests

Non-goals:

- React surface layout and visual polish.

Verification:

- Linux Docker Swift build/test
- secret store proof
- gateway proof
- CU/media daemon proof

### Stream C - Tauri bridge and shell contract

Mission:

- Make Tauri commands a typed adapter over real daemon/CLI contracts.

Owns:

- `apps/linux-desktop/src-tauri/src/lib.rs`
- `apps/linux-desktop/src/tauriBridge.ts`
- `apps/linux-desktop/src/daemonFixture.ts`
- bridge tests

Non-goals:

- New daemon methods without Stream B.
- Surface UI redesign.

Verification:

- `VAL-RPC-*`
- Tauri command tests
- no invented RPC grep

### Stream D - UI workflows and visual parity

Mission:

- Port macOS workflow depth and visual system onto the Linux shell.

Owns:

- `apps/linux-desktop/src/surfaces/**`
- lane-local stores
- lane-local components
- route-specific tests

Non-goals:

- Shared seam edits without Stream C/integration owner.
- Daemon contract changes.

Verification:

- Vitest route tests
- Vite build
- packaged shell smoke
- screenshots/AT-SPI/reduced-motion proof

### Stream E - Release, CI, docs, and public trust

Mission:

- Close release parity, CI gates, documentation, update feed, package smoke, and
  public trust.

Owns:

- `.github/workflows/linux-*.yml`
- `scripts/linux-port/**`
- `scripts/ci/**`
- `packaging/linux/**`
- release docs and website metadata

Non-goals:

- Product feature implementation beyond release blockers.

Verification:

- strict release verifier
- package smoke
- public feed validation
- docs checker
- provenance/signature verification

### Stream F - Verification, red-team, and integration

Mission:

- Be the independent reviewer of the other streams. Maintain proof matrix,
  regression tests, and final integration.

Owns:

- proof books
- evidence directories
- red-team scripts
- integration checklist
- final PR body/review map

Non-goals:

- Primary feature implementation.

Verification:

- all VAL contracts linked to artifacts
- no stale evidence rows
- no unowned shared-file changes
- final matrix green or explicitly blocked

## Immediate PR Sequence

1. **Reanchor PR**
   - Fix CSS warning.
   - Archive baseline evidence.
   - Add ledger freshness/product-scope semantics.
   - Update docs to say public prerelease exists but full parity does not.

2. **Paths and parser PR**
   - Unify XDG paths.
   - Unify socket/token ownership.
   - Reconcile parser discovery and provider log-directory display.
   - Fix onboarding/CLI/systemd contract.

3. **Design foundation PR**
   - Integrate generated design tokens.
   - Add DashboardLayout state, persistence, switcher, and six skeletons.
   - Keep current visual branch work intact where possible.

4. **Bridge contract PR**
   - Add approval, memory, and Computer Use wrappers over existing methods.
   - Fix `media_status` capability behavior.
   - Add bridge tests and no-invented-RPC grep check.

5. **Daemon foundation PR**
   - Linux secrets, Pensieve inotify, PTY shell, model catalog, CLI capability
     alignment.

6. **Chat/provider PR**
   - Replace chat stub stream with real gateway events.
   - Add model picker, tool approvals, citations, attachments, transcript
     handling.

7. **Computer Use PR**
   - Linux browser CU UI plus approval/audit/panic.
   - System mode behind explicit compositor gates.

8. **Mercury PR**
   - Real iroh/remote-access-agent control surface and Linux UI.

9. **Workflow parity PRs**
   - Account/cloud, activity/session logs, insights, projects, provider/model
     detail, memory review, text expansion, pet companion, SmartHub.

10. **Release promotion PR**
    - Artifact closure, source tarball, signing/provenance verification, public
      JSON feed, package smoke, update/rollback, docs.

## Final Full-Parity Exit Criteria

Linux cannot be called full parity until all are true:

1. Current checkout is clean or all dirty entries are intentional and committed.
2. Product parity ledger is current at the target release head.
3. No Tier A/B product row is stale or allow-blocked.
4. `npm test --prefix apps/linux-desktop` passes.
5. `cd apps/linux-desktop && npx tsc --noEmit` passes.
6. `npm run build --prefix apps/linux-desktop` passes with no CSS syntax
   warnings.
7. Linux Docker Swift builds pass.
8. Linux Swift behavior tests run in PR CI.
9. Tauri bridge has no invented daemon method strings.
10. Dashboard layouts, design tokens, path contracts, and parser registry are
    shared-current.
11. Chat uses live gateway events and real approval methods.
12. Memory review uses real remember/forget/audit semantics.
13. Computer Use has browser parity and explicit system-mode proof or Tier C
    limits.
14. Mercury has real transport/control proof or explicit blocked rows.
15. Account/cloud/App Check/Stripe proof is live against staging/prod.
16. Release verifier passes strict mode without `--allow-blocked`.
17. Public `latest-linux.json` is valid JSON and verified.
18. deb/rpm/AppImage install, launch, update/rollback, and uninstall proof
    exists.
19. Ubuntu GNOME X11, Ubuntu GNOME Wayland, Fedora KDE Wayland, and Arch/wlroots
    are tested or explicitly blocked with public limitations.
20. README, CHANGELOG, release docs, support matrix, known limitations,
    rollback docs, and supply-chain docs match live truth.
