# Linux/macOS parity: current candidate source audit

Date: 2026-08-10
macOS gold standard: OpenBurnBar for macOS
Audited implementation baseline: `8e706f5d9b2cd4c09a4a197f60f8d8c04bda6416`
Branch: `codex/linux-macos-parity-completion-20260809`
Publication state: local only; not pushed, merged, signed, or promoted

## Executive summary

The Linux app is much closer to the macOS app than the strict parity ledger
looks. Most product code, packaging contracts, proof producers, hostile
mutation tests, and Linux-native fallbacks are already present. The complete
parity preflight passes **46/46**, and the focused registry, capability,
Fcitx5, pet, privacy, and shell-readiness packet passes **29/29**.

The strict release result is still **0/40 product rows and 0/7 environments**.
That does not mean the implementation is empty. It means this exact candidate
has not yet been installed and exercised in the required Linux environments,
and several rows also need production cloud, physical-device, real-device,
signed-feed, or previous-release evidence.

The most important current distinction is:

- **Source and proof infrastructure:** advanced; most rows are ready for
  installed execution.
- **Exact-candidate Linux proof:** not started for this candidate.
- **Full release certification:** blocked until all 40 rows and all seven
  environment rows pass.

The audit found and corrected four stale source-status statements:

1. The product said Fcitx5 was unavailable even though the candidate packages
   a native addon.
2. The pet document said P-30 proof ownership was not registered even though
   it is registered.
3. The privacy document said retention was unavailable even though the daemon,
   bridge, Settings UI, tests, and P-40 proof contract implement it.
4. The privacy document said account erasure was unavailable even though the
   daemon-owned trusted-device path, UI, redacted result decoder, and
   partial-failure retry behavior exist.

Those corrections do not mark any row certified. They make the app and audit
tell the truth about what is implemented and what still needs live proof.

## Evidence checked

- Complete parity preflight: **46 passed, 0 failed**, 413.83 seconds.
- Focused source packet: **29 passed, 0 failed**.
- Product requirement inventory: exactly **P-01 through P-40**.
- Proof registry: **40/40** requirements have a validator, capture owner, and
  materializer.
- Support matrix: seven required environment rows.
- Parity ledger: `productParityClaim=false`, all 40 product rows blocked, all
  seven environment rows blocked.
- Candidate worktree: clean before this source-audit correction.
- Protected user stash: unchanged.

## Current parity matrix

“Source ready” means the implementation and proof owner exist. It does not mean
the feature passed in an installed Linux package.

| ID | Area | Current source verdict | What still blocks parity | Priority |
|---|---|---|---|---|
| P-01 | Release integrity | Packaging, manifests, signatures, verification, and lifecycle proof contracts exist | Build and exercise the exact signed candidate, compatible previous release, update feed, rollback, and data preservation | Critical |
| P-02 | Parity certification | Complete 40-row fail-closed ledger and proof ownership exist | Generate candidate-bound evidence and close every row without `allowBlocked` | Critical |
| P-03 | Installed runtime | Package-owned GUI, daemon, CLI, service, version, and uninstall paths exist | Fresh install, login start, crash/restart, suspend, upgrade, rollback, and uninstall on the current candidate | Critical |
| P-04 | Architecture reach | x86_64 and aarch64 workflows and architecture checks exist | Produce and run current-candidate artifacts on both architectures | Critical |
| P-05 | Credential custody | Secret Service, KWallet, and encrypted headless custody are implemented | Real locked/unlocked/missing/rotated/recovery behavior in every required environment | Critical |
| P-06 | Gateway credential boundary | Native gateway owns credentials and keeps them out of the renderer | Installed adversarial, reconnect, streaming, log, and diagnostics proof | Critical |
| P-07 | Computer Use | Browser authority, approval, panic, replay, audit, system portal input, and mobile approval source are broad | Production auth/App Check, physical-device approval, installed browser/system actions, Agent Watch breadth, panic, tamper, and restart proof | Critical |
| P-08 | Mercury media | Calls, files, capture, playback, consent, capability probing, and proof ownership are broad | Real paired-device file/call/share, codec fallback, portal consent, teardown, and compositor proof | Critical |
| P-09 | Navigation and shell | All primary routes and bounded deep links exist | Current-candidate route, secondary-window, focus, multi-monitor, and restore proof | Medium |
| P-10 | Dashboard layouts | Six layouts and their state handling exist | Installed visual matrix with real data, compact/wide sizes, themes, and restart persistence | Medium |
| P-11 | Usage ingestion | Canonical parser catalog, local ingestion, projections, recount, and provenance checks are broad | Real Linux corpus, remaining API/quota/cloud breadth, restart/recount, and same-input macOS comparison | High |
| P-12 | Quota | Quota read state, account slots, failover policy, reset, and provenance exist | Live exhausted/cooling/ready switching, alerts, restart, and cloud-account behavior | Medium |
| P-13 | Onboarding | Daemon-owned steps, provider setup, cloud-auth state machine, retry, privacy, and restart gates exist | Clean-profile installed flow, production OAuth, permission denial/retry, first data, and all environments | High |
| P-14 | Chat | Durable threads, streaming, models, attachments, citations, approvals, export, resume, reconnect, and pop-out are broad | Installed provider breadth, binary/media behavior, unloaded history, restart re-upload, failure/recovery, and macOS comparison | High |
| P-15 | Account and billing | PKCE, membership state, portal routing, export, erasure handoff, and safe URLs exist | Production OAuth/App Check, membership, checkout/portal, recovery, erasure, and exact-candidate proof | High |
| P-16 | Cloud and devices | Encrypted replica, sync, conflict handling, remote read, escrow, and trusted-device controls exist | Production callable execution, two-device approval/revoke, conflict/recovery, and signed installed proof | High |
| P-17 | Activity and session logs | Search, detail, body, replay, resume, export, and source-resolution safety exist | Populated real history, complete-history proof, provider runtime, restart, and installed UI proof | High |
| P-18 | Memory review | Pending/approve/reject/forget, quarantine feed, tombstones, and audit hashes exist | Installed persistence, normal-recall exclusion, cross-device replication, and cloud authority | High |
| P-19 | Projects | CRUD, associations, delete/reassign, migration, tombstones, and replay protection exist | Real populated migration, restart, collision, deletion, and installed proof | Medium |
| P-20 | Missions | Create, approve, answer, cancel, detail, evidence, history, and health exist | Installed full lifecycle through restart/reconnect with real integrations | Medium |
| P-21 | Insights | Canvas, widgets, citations, compare, follow-up, audit, and stale-response fencing exist | Real ledger data, macOS qualitative comparison, restart/reconnect, and installed evidence | Medium |
| P-22 | Database | Inspect/search, snapshots, watch, recovery bundles, native pickers, and integrity checks exist | Populated SQLCipher database, native keyring, corruption/key-loss/device-transfer, performance, and installed proof | Medium |
| P-23 | Provider/model workspace | Catalog, health, aliases, variants, routing, failover, custom models, and deep links exist | Real credentials, multi-slot failover, degraded states, restart, and installed matrix | Medium |
| P-24 | Settings | Searchable tabs, selected writes, readback, persistence, and proof ownership exist | Execute all supported writes, unavailable states, restart, accessibility, and restoration in the VM matrix | Medium |
| P-25 | Updates | Signed-feed checks and installed update/rollback proof contracts exist | Compatible previous package, valid feed history, exact update/rollback, restart, and data preservation | High |
| P-26 | Tray and native shell | Native tray routes, health, usage, updates, reconnect, autostart, and background mode exist | GNOME/KDE/wlroots tray behavior, DBusMenu actions, accessibility, login start, relaunch, and restoration | High |
| P-27 | Notifications and deep links | Native actions, queued cold-start routes, OAuth return validation, and deep-link safety exist | Real notification hosts, WebDriver/AT-SPI actions, login start, persistence, accessibility, and all environments | High |
| P-28 | SmartHub | Typed allowlisted discovery/status/control and bounded CLI execution exist | Supported real devices, Avahi, offline/reconnect, daemon restart, hostile input, and installed proof | High |
| P-29 | Text expansion | Encrypted snippets, consent, IBus, native Fcitx5 addon, separate signed identities, secure-field denial, lifecycle, and proof ownership exist | Real Secret Service/KWallet, IBus/Fcitx5 registration and expansion, secure fields, cancellation, restart, sync/conflicts, and desktop matrix | High |
| P-30 | Pet companion | X11 child, Wayland contained fallback, summon, click-through controls, movement, chat, file drop, 114-entry catalog, GLB/atlas rendering, and proof ownership exist | Exact-candidate compositor/GPU/focus/scaling/restart proof; macOS offscreen 3D thumbnails and persona/local-floor behavior remain thinner | High |
| P-31 | Accessibility | Axe, keyboard, reduced motion, forced colors, focus, AT-SPI/Orca proof contracts exist | Exact-candidate keyboard/Orca/AT-SPI/200%/contrast/reduced-motion matrix in all environments | High |
| P-32 | Performance | Matched workload, latency/resource budgets, and candidate-bound proof exist | Current-candidate matched macOS/Linux startup, route, IPC, tray, memory, CPU, GPU, and soak results on comparable hardware | High |
| P-33 | Reliability | Crash/restart, stale-response, reconnect, subscription, and restoration proof contracts exist | Long idle/suspend, daemon loss, portal/keyring faults, migration faults, multi-hour soak, and all environments | High |
| P-34 | Security hardening | Native URL, secret, process, renderer, fixture, package, and proof boundaries are broad | Installed hostile-input, secret-leak, permission, symlink, replay, tamper, unsigned/substituted package, and diagnostics proof | Critical |
| P-35 | Diagnostics and support | Redacted metadata export, native save, reconnect, package/runtime facts, and proof owner exist | Exact bundle contents, cancellation, permissions, offline/reconnect, restart, accessibility, and environment proof | Medium |
| P-36 | Visual and interaction polish | Shared components, stable readiness selectors, responsive states, themes, keyboard menus, and screenshot harness exist | Current-candidate screenshot/AT-SPI baselines at required sizes, themes, motion states, overflow, GPU fallbacks, and desktop environments | Medium |
| P-37 | Linux matrix | Environment-bound proof harness exists for all seven required rows | Run Ubuntu GNOME X11/Wayland on both architectures, Fedora KDE Wayland on both, and Arch Sway x86_64 | Critical |
| P-38 | CI and release automation | Fail-closed build, package, sign, aggregate, proof, and promotion workflows exist | Run the exact candidate through hosted architecture lanes, signing, assembly, evidence closure, and promotion gates | Critical |
| P-39 | Cross-platform differential proof | Same-contract comparator, redaction, duplicate-key rejection, volatile paths, and path-level diffs exist | Generate same-commit macOS and Linux artifacts from the same corpus and close every unexpected difference | High |
| P-40 | Data and privacy | Consent, inventory, local delete, encrypted export, retention, cloud export, account erasure, partial retry, and recovery-bundle controls exist | Current-candidate installed RPC/UI proof, trusted-device backend receipts, locked keyring, recovery propagation, unrelated-data preservation, and all environments | High |

## Meaningful gaps by type

### Functionality

- P-07 still needs full real-device Browser/System Computer Use certification
  and thinner Agent Watch behavior compared with macOS.
- P-08 still needs real paired-device media outcomes.
- P-14 still needs installed provider and attachment breadth.
- P-30 still has a visible source-level polish gap around macOS-style offscreen
  3D thumbnails and persona/local-floor behavior.
- P-40 still needs backend and cross-device proof for destructive cloud and
  recovery outcomes.

### UI and UX

- Current-candidate screenshots and AT-SPI states have not been captured.
- Secondary-window and multi-monitor behavior are thinner than macOS.
- Pet library thumbnails are not yet at the macOS offscreen 3D standard.
- Native desktop behavior must stay Linux-appropriate: portals on Wayland,
  AppIndicator/DBusMenu where available, native package-manager updates, and
  clear contained fallbacks where a compositor cannot safely match macOS.

### Performance and reliability

- Historical performance results are encouraging, but they do not prove this
  exact candidate.
- Current-candidate startup, route latency, IPC, tray, memory, CPU/GPU, long
  idle, suspend, daemon crash, keyring lock, portal denial, and upgrade/rollback
  still need live execution.

### Accessibility

- Source automation is broad, but the current candidate needs real AT-SPI,
  Orca, keyboard-only, 200% scaling, contrast, reduced-motion, and focus
  restoration proof in each required desktop/session.

### Platform integrations

- IBus and Fcitx5 are now both represented honestly in source and packaging.
- Tray, notifications, portals, autostart, secret stores, package managers,
  SmartHub discovery, PipeWire/GStreamer, and desktop deep links still require
  environment-specific live proof.

### Overall polish

- The codebase has strong fail-closed behavior and unusually complete proof
  infrastructure.
- The remaining polish risk is concentrated in installed visual behavior,
  compositor differences, real data/devices, recovery states, and exact package
  lifecycle—not in basic route scaffolding.

## Linux parity implementation plan

### 1. Seal the current source candidate

Engineering tasks:

- Correct stale product capability and audit statements.
- Run focused Fcitx5, pet, privacy, readiness, registry, and document checks.
- Keep `productParityClaim=false`.
- Commit locally without pushing or merging.

Dependencies:

- None beyond the clean candidate worktree.

Acceptance criteria:

- No product copy says Fcitx5 is missing.
- P-30 documentation says proof ownership is registered but unexecuted.
- P-40 documentation matches implemented retention and account-erasure source.
- Focused tests pass and the worktree is clean after commit.

### 2. Prepare the exact X31 VM candidate

Engineering tasks:

- Confirm the X31 VM identity, architecture, desktop, session, free space, and
  package prerequisites.
- Build or transfer only artifacts bound to the exact candidate HEAD.
- Record source HEAD, package digest, manifest digest, version, architecture,
  and build/run IDs before installation.
- Do not reuse a historical installed package as current proof.

Dependencies:

- Step 1 committed.
- X31 storage and VM attached.

Acceptance criteria:

- Candidate identity is recorded before install.
- Package bytes and manifests are hashed.
- Existing VM/user state is inventoried and recoverable.
- No unrelated host or VM process is disrupted.

### 3. Run the first installed smoke and native shell gate

Engineering tasks:

- Install the exact candidate.
- Prove one package-owned daemon, CLI, GUI, and service.
- Exercise launch, relaunch, login start, deep links, tray, notifications,
  Settings, onboarding, Support, accessibility tree, and basic recovery.
- Capture screenshots, AT-SPI, logs, package ownership, process identity, and
  restoration.

Dependencies:

- Step 2.

Acceptance criteria:

- No blank window, crash loop, stale binary, duplicate daemon, or wrong version.
- All primary routes load from the installed package.
- Honest unavailable/degraded states appear when a dependency is missing.
- VM state is restored after the proof lane.

### 4. Execute high-risk native product rows

Recommended order:

1. P-05/P-34 secret and security boundaries.
2. P-29 IBus/Fcitx5 text expansion and secure fields.
3. P-30 pet X11/Wayland behavior.
4. P-31 accessibility.
5. P-32/P-33 performance and reliability.
6. P-40 privacy retention/export/delete/recovery.
7. P-07/P-08 Computer Use and Mercury.

Dependencies:

- Stable installed smoke.
- Required local secret store, portal, media, and input-method packages.
- Physical trusted device for P-07/P-08/P-16/P-40 external authorization.

Acceptance criteria:

- Every feature is proven from the installed app, not a fixture or source scan.
- Every destructive or permission-sensitive flow has cancel, deny, partial
  failure, retry, restart, and restoration evidence.
- Unsupported compositor behavior stays visibly unavailable or contained.

### 5. Execute core product rows with real data

Engineering tasks:

- Usage, quota, onboarding, chat, account, cloud, Activity, memory, projects,
  missions, insights, database, providers, Settings, updates, tray,
  notifications, SmartHub, diagnostics, and visual polish.
- Use bounded real test data and restore the original state.
- Compare outcomes with the macOS gold standard.

Dependencies:

- Stable daemon/database/secret store.
- Production or approved staging authority where a row requires cloud data.
- Compatible previous package for update/rollback.
- Supported SmartHub devices where P-28 is claimed.

Acceptance criteria:

- No synthetic production state.
- Exact readback after mutations.
- Restart persistence and stale-response safety.
- Clear macOS-equivalent outcome or an explicit Linux-native substitute.

### 6. Close external and production dependencies

Engineering tasks:

- Production OAuth/App Check/Firebase callable execution.
- Stripe membership/portal lifecycle.
- Physical-device approval and two-device cloud/media flows.
- Real SmartHub devices.
- Valid signed update feed and previous release.

Dependencies:

- Separate exact approval before billable cloud/provider changes.
- Physical device availability.
- Release signing and distribution secrets.

Acceptance criteria:

- Backend receipts bind to the exact candidate and exact user-approved action.
- No credential, token, action proof, or private payload enters renderer state,
  logs, diagnostics, or proof artifacts.
- Partial backend failure remains retryable and is never reported as success.

### 7. Run all seven Linux environments

Required order:

1. Ubuntu 24.04 GNOME X11 x86_64.
2. Ubuntu 24.04 GNOME X11 aarch64.
3. Ubuntu 24.04 GNOME Wayland x86_64.
4. Ubuntu 24.04 GNOME Wayland aarch64.
5. Fedora KDE Wayland x86_64.
6. Fedora KDE Wayland aarch64.
7. Arch Sway/wlroots Wayland x86_64.

Acceptance criteria:

- All mandatory P rows meet their required evidence tier.
- No environment uses `allowBlocked`.
- All evidence matches the exact HEAD and package digest.
- Installation, runtime, accessibility, performance, reliability, cleanup, and
  restoration pass in every row.

### 8. Same-commit macOS/Linux differential and release seal

Engineering tasks:

- Build macOS and Linux from the same commit.
- Run the canonical shared corpus and behavior contract.
- Review every normalized difference.
- Generate final product closures and parity ledger.
- Keep promotion blocked until every required closure is valid.

Dependencies:

- Steps 1 through 7.

Acceptance criteria:

- P-01 through P-40 are ready.
- All seven environments are ready.
- `productParityClaim=true` is generated only by the validated closure path.
- The exact signed artifacts, public feed, release notes, and rollback path
  agree on version, commit, architecture, and digest.

## Prioritized roadmap

| Order | Work | Why now | Exit condition |
|---|---|---|---|
| 1 | Commit current source-truth corrections | Prevents the app and audit from lying about implemented features | Focused tests green; clean local commit |
| 2 | Start X31 VM and identify the exact environment | Converts source confidence into real installed evidence | VM identity and prerequisites recorded |
| 3 | Build/install exact candidate and run smoke | Finds package/runtime blockers before expensive deep testing | Stable GUI/daemon/CLI/service and route smoke |
| 4 | Text expansion, pet, privacy, accessibility | These changed recently and are Linux-native/high-risk | P-29/P-30/P-31/P-40 installed receipts or named defects |
| 5 | Core product workflows | Proves daily-use parity with real state | Installed row receipts and fixed defects |
| 6 | Computer Use, media, cloud, billing, devices | Requires external authority and physical systems | Exact backend/device receipts |
| 7 | Performance, reliability, update/rollback | Requires a stable candidate and previous release | Budgets, soak, fault, and lifecycle green |
| 8 | Remaining six environments | Closes architecture/compositor portability | 7/7 environments ready |
| 9 | Same-commit macOS comparison and seal | Final independent parity decision | 40/40, 7/7, signed closure |

## QA checklist

### Candidate identity

- [ ] Record exact HEAD, version, branch, artifact digest, manifest digest, run
  ID, architecture, desktop, session, and package type.
- [ ] Confirm no source, package, or evidence substitution.
- [ ] Confirm all captured evidence is newer than installation and bound to the
  same candidate.

### Installation and lifecycle

- [ ] Fresh install.
- [ ] Upgrade from a compatible previous version.
- [ ] Rollback.
- [ ] Uninstall.
- [ ] Login start and tray-first background start.
- [ ] Crash and daemon restart.
- [ ] Suspend/resume and logout/login.
- [ ] No duplicate daemon or stale/deleted binary.
- [ ] Data preserved where required.

### Core UX

- [ ] Every primary route loads with real state.
- [ ] Loading, empty, populated, offline, error, retry, and restored states.
- [ ] Keyboard-only operation and visible focus.
- [ ] Deep links, secondary windows, focus restoration, and multi-monitor.
- [ ] Compact, standard, wide, light, dark, reduced-motion, high-contrast, and
  200% scaling.
- [ ] No clipping, overlap, blank render, fake success, or stale state.

### Native Linux integration

- [ ] Secret Service and KWallet locked/unlocked/missing/rotated.
- [ ] GNOME/KDE/wlroots tray and notifications.
- [ ] Wayland portal grant/deny/cancel/revoke/restart.
- [ ] X11 safe fallback behavior.
- [ ] IBus and Fcitx5 registration, expansion, secure fields, restart, cleanup.
- [ ] PipeWire/GStreamer capture/playback and codec fallback.
- [ ] Native save/open pickers and cancellation.
- [ ] Autostart, package manager, desktop files, MIME/deep-link handlers.

### Data and security

- [ ] No secrets or tokens in renderer state, logs, screenshots, diagnostics, or
  proof JSON.
- [ ] Symlink, traversal, unsafe owner/permission, replay, stale identity,
  tamper, and oversized-input rejection.
- [ ] Exact readback after every mutation.
- [ ] Destructive actions require exact confirmation and approved authority.
- [ ] Partial destructive failure is not reported as success.
- [ ] Unrelated data remains intact.
- [ ] Cleanup restores services, processes, files, policies, and user state.

### Product workflows

- [ ] Usage and quota.
- [ ] Onboarding and provider credentials.
- [ ] Chat, attachments, citations, approvals, export, resume, and pop-out.
- [ ] Account, billing, cloud sync, trusted devices, export, and erasure.
- [ ] Activity, memory, projects, missions, insights, and database.
- [ ] Providers/models, Settings, updates, tray, notifications, and support.
- [ ] Computer Use, Mercury, SmartHub, text expansion, and pet companion.

### Accessibility

- [ ] Axe/static semantic checks.
- [ ] Real AT-SPI tree.
- [ ] Orca traversal and announcements.
- [ ] Keyboard-only workflows.
- [ ] Focus entry, movement, trapping where appropriate, and restoration.
- [ ] 200% scaling.
- [ ] Reduced motion, forced colors, and contrast.
- [ ] Native tray/notification/dialog accessibility.

### Performance and reliability

- [ ] Cold and warm startup.
- [ ] Route navigation p50/p95/p99.
- [ ] IPC and daemon response p50/p95/p99.
- [ ] Tray open and notification action latency.
- [ ] CPU, RSS, GPU, file descriptors, and process count.
- [ ] Long idle and multi-hour soak.
- [ ] Offline/reconnect, daemon crash, portal loss, keyring lock, database
  corruption, and interrupted update.
- [ ] No unbounded retries, hangs, deadlocks, or stale response overwrite.

### Final release gate

- [ ] P-01 through P-40 ready.
- [ ] Seven of seven environments ready.
- [ ] Same-commit macOS/Linux differential reviewed.
- [ ] Signed artifacts and feed match exact digests.
- [ ] Rollback path proven.
- [ ] Documentation describes only proven behavior.
- [ ] `productParityClaim=true` generated by the validated closure path.

## Current conclusion

The Linux implementation is in the final proof-and-defect-fixing phase, not the
early build phase. The immediate next step is the X31 VM. The VM may still find
real defects, and those defects must be fixed before any percentage or “full
parity” claim is treated as release truth.
