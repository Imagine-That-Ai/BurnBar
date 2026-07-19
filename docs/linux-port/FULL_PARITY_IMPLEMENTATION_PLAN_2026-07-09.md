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

### Latest installed checkpoint — 2026-07-19 UTC

The Ubuntu GNOME/X11 UTM guest now runs source candidate `5b70a3d320` from an
exact rebuilt arm64 DEB. The Settings loading defect found during live QA was
caused by the packaged route shell deferring the entire Settings surface before
its loader could run. `2f75f3269e` mounts Settings immediately, and
`5b70a3d320` opts Settings out of the inner idle hydration queue while leaving
other routes deferred. The installed receipt records 105 AT-SPI nodes, 50
actionable controls, no `Loading Settings` node, a reachable startup checkbox,
and a working Media & Sharing route:
`evidence/mission-002-reanchor/vm-e2e/current-5b70a3d320-settings-hydration-arm64/`.

Final source gates are **87 frontend files / 806 tests**, focused Settings and
route coverage **45/45**, accessibility coverage **10/10**, Tauri Rust
**125/125**, TypeScript, formatting, and production-bundle verification. The
connected physical iPad focused navigation suite passed with xcodebuild exit 0.
This is an implementation and live-QA
milestone only; the strict product/environment promotion boundary remains
**0/40 product rows and 0/7 environment receipts**.

The current source checkpoint is `7bcf432bf4`; the kernel capability slice at
`50d40b9acb` adds a typed backdrop kernel
resolution receipt and surfaces requested-versus-resolved kernel state in the
Linux switcher. The live Ubuntu WebKitGTK probe reports `webgl2=false` and
`webgl1=true`; Aurora therefore resolves to the animated Canvas2D constellation
fallback with an explicit `WebGL2 unavailable` label. This closes the silent
renderer-degradation UX gap while keeping the environment-specific WebGL2
limitation open for a supported hardware/Wayland matrix.

The installed WebKitGTK baseline also revealed a first-paint regression in the
Linux default `swarmEmber`: two root-window captures two seconds apart changed
only 256 bytes, so the background was effectively static while its lazy factory
resolved. `1dc1328818` makes the Linux 2D default eager while retaining lazy
loading for shader kernels, and its focused test proves that `fillRect` occurs
during init and again on the first frame. Follow-up commits `907187f767` and
`5b2a647051` keep all lazy 2D fallbacks opaque during chunk resolution, while
`0ae08b3baf` retries cleanly when a loader throws before returning its Promise.
`1f5a158e3d` enables Tauri's release custom protocol and `a01a60824b` makes the
Cargo build script watch every file below `dist`, preventing stale embedded
frontend assets after an in-place Vite output change. `fdd3ff61ad` adds
command-palette/listbox semantics, focus containment, and stable names for
icon-only toolbar actions; `7bcf432bf4` revalidates pinned Computer Use
authority before every inbound controller frame and tears down a stale runtime
before dispatch. A fresh current-head
release build was visually verified in the unlocked UTM guest: the shell and
Canvas2D Aurora fallback rendered, with the explicit `WebGL2 unavailable`
status. The direct tree launch does not start the packaged daemon, so its setup
card reports daemon authority unavailable; current-head package installation
and signed release certification remain release-runner dependencies.

The connected physical iPad was rechecked against this checkout with the
bounded approval/navigation selectors: the existing approval-focused receipt
records **44/44 passed, 0 failures, xcodebuild exit 0**, and the current-head
navigation slice records **21/21 passed, 0 failures, xcodebuild exit 0** in
`evidence/parity-audit-2026-07-10/ipad-navigation-focused-current-2026-07-19.json`.
These receipts remain non-certifying and do not substitute for installed Linux
enrollment or cross-device approval proof.

### Current source hardening — 2026-07-19 UTC

The Activity history parity gap is now implemented on `c94e7b6113`: a daemon-
owned `daemon.usage.history` RPC returns one bounded indexed snapshot with an
explicit `historyComplete` proof, stable conversation identities, tombstone
filtering, and per-session/aggregate body limits. Linux export requires that
proof and refuses paged or partial data. Focused Activity/bridge coverage is
**102 tests**, TypeScript and Rust checks pass. The exact-head arm64 package is
the preceding installed baseline in the UTM guest; its non-certifying receipt is
`evidence/mission-002-reanchor/vm-e2e/current-c94e7b6113/health.json`.

The current source hardening and installed candidate reach `b590d5a77d` (with
the WebKit startup fallback from `6321897d4e`). The exact arm64 DEB was rebuilt
from that commit and installed in the running Ubuntu guest; its non-certifying
receipt is
`evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/live-installed-receipt.json`.
Its release graph builds
the daemon-owned `crates/openburnbar-media` library before Swift linking, so a
signed release cannot silently ship the shell's GStreamer viewer without the
capture backend. The DEB post-install hook registers the package-owned user
service, Linux peer authentication reads and hashes the kernel
`/proc/<pid>/exe` link without `O_NOFOLLOW`, and the daemon binds explicitly to
the packaged FTS5-capable `libsqlcipher.so.0`. The package is installed in the
Ubuntu 24.04 GNOME/X11 guest with service `enabled/active`, authenticated
desktop health, and live media/file capability probes. The earlier daemon/media
receipt remains at
`evidence/mission-002-reanchor/vm-e2e/current-a570c9b087/live-receipt.json`.
This closes the package/service/media-backend/database-bootstrap source slice;
iPad enrollment, two-device media, and signed certification remain dependencies
for parity. The VM's full `MercuryLinuxMediaTests` class passes **21/21**, the
project/code-memory bootstrap slice passes **3/3**, and the Linux peer test
passes **1/1**; `fdbc7d718b` separately gates receive-only media transport in
the Linux UI while preserving daemon RPC calls (focused media UI/state **33/33**);
this is transport/backend proof, not a two-device receipt.

The previous VM follow-up rebuilt and installed the `992ef5c580` settings/media
UI/state files around the existing daemon runtime with the real `media-gst`
shell viewer feature enabled. That receipt is historical:
`evidence/mission-002-reanchor/vm-e2e/current-992ef5c580-settings-index-arm64/live-installed-receipt.json`.
The preceding media-gst receipt remains as a historical baseline under
`current-fdbc7d718b-media-gst-arm64/`, and the earlier non-GStreamer receipt
under `current-fdbc7d718b-ui-arm64/`. All three are non-certifying because they
are not signed exact-head candidates and do not prove cross-device media.

The follow-up hardening is now also source-integrated: `511c8a1049` makes
concurrent native pet summons single-flight; `1397313284` routes notification
body clicks to `open` even when the server has no action capability; and
`82b0fcf11e` retries a missing GStreamer decoder on the next keyframe and runs
Secret Service/KWallet health checks before onboarding writes. Focused proof is
28/28 pet UI tests, 4/4 notification Rust tests, 5/5 media Rust tests in both
feature modes on the VM, and 6/6 Linux onboarding tests on Ubuntu. `992ef5c580`
adds the daemon-backed **Index project** action to General Settings Indexing &
Search; focused settings proof is **34/34** and the latest installed arm64
receipt is `evidence/mission-002-reanchor/vm-e2e/current-992ef5c580-settings-index-arm64/`.

The current source slice adds a verified, capped Insights comparison workspace
(`c31c17aa6e`, `ee679e2ed0`, `eb6a5975d4`) and a secure user-level XDG
**Launch at login** preference (`f6d3843937`, hardened in `1bddc6d22a`). Focused comparison coverage is
**28/28**; autostart Rust coverage is **4/4**, renderer/bridge coverage is
**39/39**, and the Settings/accessibility slice is **32/32**. The exact-head
package is now installed; live checks and limitations are recorded in
`evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/`.
`2e609b4061` also hardens Mercury viewer lifecycle teardown by releasing the
viewer lock before stopping GStreamer; the focused media lifecycle tests pass
6/6 with `media-gst` and 5/5 without it. `d581da37b7` exposes daemon-backed
Mercury capability state in Media & Sharing settings, and `47cbf2e2f0` makes
onboarding fail closed if an ephemeral Secret Service/KWallet probe cannot be
cleaned up; the focused onboarding suite passes 8/8 on Ubuntu.

The installed Linux CLI parity fix is now on `d58b6a958f`: the Swift CLI
resolves the canonical XDG daemon token file when no token environment override
is supplied, matching the Tauri bridge and daemon launcher. Focused tests cover
direct-token, explicit-token-file, and Linux canonical-token precedence. This
removes a real post-install failure where bare `openburnbar-cli health` returned
`Unauthorized` against a healthy daemon. Strict product/environment promotion
is still unchanged until signed current-head receipts exist.

Packaging hardening is now on `13caa70a1e`: DEB/RPM post-install and Arch
post-transaction hooks move an unmanaged stale `/usr/local/bin/openburnbar-cli`
out of PATH to a versioned backup, while leaving package-owned, identical,
symlink, and non-regular paths untouched. Focused migration, Arch, AUR, and
signed-package wiring checks pass. This closes the VM's stale-CLI shadowing
failure without deleting user data.

Two reviewable source slices are now on the candidate branch. `6f57349c66`
keeps Linux settings search and detail-tab selection synchronized, including
an explicit no-results state; its focused settings suite (40 tests), TypeScript
check, production build, and bundle verifier passed. `5624ad1f6b` bounds Linux
Avahi peer discovery, terminates stalled helpers, and reports non-zero exits as
typed failures; focused Linux-only source tests cover timeout, exit status, and
successful parsing. The macOS host can parse/build the Linux-only tests but
cannot execute them because the package runner lacks `SQLCipher.framework`.
Neither slice changes the strict **0/40 product** or **0/7 environment**
certification state; installed Linux and live cross-device receipts remain the
next gate. The complete Linux desktop regression run at this head passed **82
files / 751 tests**, with TypeScript and the production bundle verifier green.
The same candidate also carries `c095761b07` (first-party release-path checks
for signed feed URLs, 19 Rust tests), `50a0684e75` (fail-closed onboarding
symlink protection), and `a5522bfc54` (bounded JSON history import/resume with
duplicate identity checks and 27 focused activity tests). These source slices
improve the implementation baseline but do not create installed Linux,
production, or cross-device certification receipts.
`d1cb5e517d` also corrects the Linux settings section taxonomy to match macOS
exactly; focused settings-catalog coverage passes 4/4. `a5e74fed57` bounds
SmartHub status-helper execution through the existing timeout/output/process-
group contract (six focused Rust tests pass). `0ecdf097a3` adds bounded,
deduplicated Insights evidence citations and an accessible opaque-ID chat
handoff; its 18 focused UI tests are included in the 751-test desktop run.
`f35f5392e7` permits validated Computer Use portal session close during
panic-kill teardown while keeping creation and input blocked; source parse/build
pass, but macOS XCTest runtime is unavailable without SQLCipher. These slices
improve source parity only; installed Linux, live production, and cross-device
receipts remain required for certification.
The subsequent source wave adds `e186d83314` (daemon source re-resolution before
activity export resume, now gated by the explicit `historyComplete` marker), `fba5d8bcc8` (current-checkout P-39 corpus and digest
binding with 29 focused tests), `3d992ce624` (forced-colors metric fallback),
and `c721ec18f8` (removal of a focusable hidden shell sentinel). The desktop
suite is now **82 files / 753 tests**. Segmented Linux evidence-contract suites
pass **607 tests** with **5 explicit fixture skips**. The P-38 proof fixture
also derives its mutation summary from the live 24-test workflow suite instead
of a stale hard-coded count. These checks strengthen source and evidence
contracts only; installed, production, and cross-device receipts remain open.

The next source slices are also complete: `3004da3b72` adds a persisted,
Calendar-enabled default hold-duration selector matching the macOS notification
settings (focused SettingsSurface **30/30**), and `bdd57173e9` makes diagnostics
exports redacted, private, atomic, and symlink-safe (support UI **24/24** and
Tauri Rust **115/115**). `2a80e30921` recovers the Mercury decoder in place
after transient frame failures, and `8131b51aec` adds a portal-backed native
diagnostics save destination with a Rust path-validation boundary and private
atomic output (diagnostics **6/6**, support UI **24/24**). The integrated
desktop suite is now **83 files / 770 tests**, Tauri Rust is **119/119**, and
TypeScript plus production bundle verification pass. A current-checkout focused
physical-iPad approval run also passed **44/44** with xcodebuild exit 0; it
remains non-certifying mobile coverage and does not prove Linux enrollment or
cross-device approval behavior.

The current source wave adds `9fb6e88c33`, which canonicalizes membership RPC
names and maps older-daemon unknown methods to a deterministic capability-absent
state (Tauri Rust **119/119**), and `f9d3b429e5`, which adds persisted Dashboard
Defaults plus truthful daemon-backed Indexing & Search posture and an explicit
unavailable Session Summaries state (focused settings **45/45**, new controls
**3/3**). The full desktop suite is green at **83 files / 770 tests**, with
TypeScript and production bundle verification passing. A current-checkout
focused physical-iPad approval receipt also passed
**44/44**, xcodebuild exit 0; see
`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19.json`.
These source and device results remain non-certifying until the exact Linux
candidate is installed, enrolled, and exercised end to end.

The latest source hardening adds `b0d27caffa`, which validates persisted
Insights workspace snapshots as an all-or-nothing versioned record and falls
back safely on malformed, future-version, or unsafe values (focused Insights
persistence/renderer tests **26/26**). `fec153e40b` and `e6bf98601b` harden
Activity export and resume with an explicit `historyComplete === true` daemon
marker; the bounded recent-usage session bridge cannot satisfy that contract,
so the implementation remains a fail-closed scaffold until a complete-history
bridge is available (focused Activity history/export/resume tests **30/30**).

The latest local recheck keeps the strict ledger at **0/40 product** and **0/7
environment**: Linux desktop **83 files / 770 tests**, TypeScript, production
bundle verification, and Tauri Rust **119/119** pass, while the physical iPad
focused receipt remains **44/44** and non-certifying. The Ubuntu 24.04 GNOME/X11
aarch64 UTM guest is live at `192.168.64.5`; authenticated daemon and bare CLI
health now pass after restoring the package-owned Swift runtime and canonical
token resolution. Signed current-head installation and the remaining live
receipts are still required.

### Historical continuation checkpoint — 2026-07-17 (superseded by the exact-head verification below)

The authoritative ledger is **0/40 product requirements** and **0/7 environment
receipts**; `productParityClaim=false`. The code checkpoint used by the latest
verification is `3a9010e229ccad6263b45de622aa97f4e706b6f5`. Recent source work includes the real P-39 parser differential
producer (`dd7c588db`, **45/45** focused checks) and provider-catalog enforcement
for first-run onboarding (`29fa77791`). Candidate run `29546157464` passed both
architectures and the installed P-40 RPC proof at `46425c540`, but it is stale
after these source commits and cannot certify the current head. Nightly run
`29546158468` passed matched performance, Wayland portal, Arch/wlroots, and
Fedora/KDE jobs; Ubuntu GNOME/X11 shell smoke failed while its **325/325** Linux
Swift tests passed. Run `29587742846` retained the failure diagnosis: the
failing XCTest was
`ComputerUseServiceRunBindingTests/testExpiredSessionReleasesRunBindingBeforeRestart`,
and the Swift result was not uploaded because the Docker container lacked a
host evidence mount. Commit `09e6050d9` fixes the PR/nightly container mounts,
routes output through `/evidence/linux-swift-tests`, and adds workflow mutation
tests. Fresh nightly run `29607854309` validates that correction at the exact
head.

The follow-on source hardening is now committed: `6ef6794ea` serializes
Computer Use expiry teardown and closes the failing run-binding race;
`9db5cca26` plus `d846c95d0`, `7349007e2`, `4925d258d`, `9cee2687a`, and
`33e3bb59b` execute real Linux analytics, Computer Use, and remote-engine
behavior suites (9 suites / 92 minimum tests); `9d8b0895e`, `7f2a4cdd4`, and
`c7bbd4ed6` add deep-link normalization, fail-closed text-expansion state, and
typed SmartHub process/payload boundaries; `832a9b0d2` removes Linux XCTest
actor isolation that crashed discovery; and `bf30c881a` adds a strict
candidate/HEAD-bound P-07 computer-use validator with three mutation tests,
required by PR gate commit `5e6241275`. These are not installed product
receipts and do not change the 0/40 or 0/7 certification state.
The first exact-head release attempt found a Linux-only Swift inference failure
in the teardown task; `a10733cdd` adds its explicit optional result type. A new
candidate must compile both architectures before promotion work resumes.

The current source head also carries Arch/pacman update-channel support and
fail-closed notification payload/route validation (`85b167205`, `a852af8c5`).
These are bounded source improvements; installed update/rollback and desktop
host receipts remain required.

### Historical Release verification - 2026-07-18 (source `1b4c3b1e26`)

Release workflow `29652889294` completed successfully at
`1b4c3b1e269b3d58d38226af1084f88bc7c6f742`. x86_64 job `88102165389`,
aarch64 job `88102165384`, and aggregate/attest job `88105582539` covered
package construction, DEB/RPM/Arch ownership/install/uninstall, packaged
daemon and desktop/tray/accessibility/route sessions, final verification, and
signed closure. The immutable `linux-release-evidence` artifact is `8432407756`
(3,681,156,161 bytes), digest
`sha256:d3d26e5a2d57148babfca11646aeecdb89280b95e16446c7cd186b388cb64bf0`.
Both architecture sessions passed the strict AT-SPI tree contract after
`5e0c7093cb` added bounded meaningful-tree readiness polling and
`1b4c3b1e26` retained diagnostics for initial-capture failures. Lifecycle
update/rollback/data-preservation is still blocked because no compatible
previous same-architecture package was supplied.

### Latest implementation-head Release verification - 2026-07-18 (source `1dced585af`)

Release Candidate `29664085758` completed successfully at
`1dced585af2441ac8ac1d4fdcb2e4666177f0474`. Both native shards and the
aggregate/attestation job passed package construction, install/uninstall,
packaged daemon and desktop/tray/accessibility/route sessions, native
lifecycle checks, signed closure, and installed-product proof closure. The
immutable `linux-release-evidence` artifact is `8435577756` with digest
`sha256:cb4eeed2f2263707bbf5d563200d02367065067b5c6e4ff6deed651f47299807`.
No compatible previous same-architecture package was supplied, so the
resolver kept real update/rollback/data-preservation promotion blocked.

The current-head Nightly is recorded below; the earlier `29652890031` attempt
is historical and was superseded after a transient GitHub artifact-service DNS
failure (`ENOTFOUND`).

### Latest implementation-head Nightly verification - 2026-07-18 (source `1dced585af`)

Nightly `29660228199` completed successfully at
`1dced585af2441ac8ac1d4fdcb2e4666177f0474`. The macOS matched soak
(`88121518808`), Linux matched soak/comparison (`88124270582`), and the
Ubuntu GNOME/X11 packaged shell row (`88127262321`) passed. The explicitly
blocked GNOME Wayland, Arch/wlroots, and Fedora/KDE rows completed their
blocked-row contracts (`88127262305`, `88127262310`, `88127262315`).

The current X11 receipt passed all six shell validators and the full 19-route
packaged session. Native p95s were app start `315.55 ms`, route navigation
`99 ms`, daemon IPC `112.55 ms`, and tray open `72.45 ms`, all below their
respective budgets. The matched 1,800-second workload passed all four
checksum/parity/resource checks. These receipts validate the Linux shell and
performance lane only; they do not promote any of the 40 product rows or the
seven-environment ledger, which remain fail-closed until registered product
evidence and live integration/install/lifecycle proof exist.

### Historical exact-head release verification - 2026-07-18 (source `70ab4eb0b9`)

Exact-head Release workflow `29646670068` completed successfully at
`70ab4eb0b9e66394d709dac246296a3b050e8a3f`. x86_64 job `88086012965`,
aarch64 job `88086012972`, and aggregate job `88089349146` covered package
construction, DEB/RPM/Arch ownership/install/uninstall, packaged daemon and
desktop/tray/accessibility/route sessions, final verification, and signed
closure. The evidence artifact is `8430648757` with zip digest
`sha256:30d67cc9ff465206bdc0a38dad1f0aa910b3a4c7f2205ef811175b37976da13b`.
The candidate's update/rollback/data-preservation lifecycle is explicitly
blocked because no compatible previous same-architecture package was supplied;
the prerelease workflow allowed that blocked lifecycle but did not certify it.

Exact-head Nightly workflow `29646670763` completed successfully at the same
source head. Its matched macOS/Linux soak and runnable Ubuntu GNOME/X11 job
passed; Arch/wlroots, GNOME Wayland, and Fedora/KDE were recorded as explicit
blocked rows. X11 ran all nine Linux Swift
suites (**414/414**), npm install/test/build, the real packaged daemon and
19-route AT-SPI/Orca/keyboard/200%-zoom session, onboarding and text-expansion
flows, and shell smoke. `route.navigation` p95 was `95.6 ms` across 33
samples versus the `120 ms` budget; matched workload/resource checks passed.
The wrapper emitted root-owned transcript `EACCES` warnings but retained raw
evidence and exited successfully with `linux-desktop-session-ok`, so the prior
false shell failure is closed.

The physical iPad preflight and a bounded current-checkout focused approval
run now pass on the paired device (**44/44**, xcodebuild exit 0). This is mobile
coverage only; installed Linux enrollment, fingerprint confirmation, and the
cross-device approval journey remain open.
Production callable inventory is still drifted. The current `utmctl` query
reports the OpenBurnBar Linux guest as stopped, so no live daemon or installed-
product receipt is promoted from this check. These facts are recorded in the
independent audit and do not promote any ledger row.

There is intentionally no numeric source-completion percentage: source tests
measure implementation slices, while the strict release state remains 0/40
product rows and 0/7 environments. The remaining dependency order is: supply a
compatible previous same-architecture package for
update/rollback/data-preservation proof, deploy and verify production App
Check/OAuth callables, run the physical iPad approval journey, close the
remaining Linux desktop/architecture/keyring/portal rows, collect installed
Computer Use, Mercury, SmartHub, IME, accessibility, performance, and update
receipts, and only then promote the 40 product rows.

### Historical source follow-up - 2026-07-18 (source `63f23dcfb1`)

The Release/Nightly receipts above remain bound to `70ab4eb0b9` and are stale
for promotion after the current source commits. The follow-up implementation
is bounded and tested:

- `b6d662d503` + `63f23dcfb1` resolve only a complete two-architecture,
  provenance-backed previous release and inspect each Debian payload for the
  package-owned daemon launcher. The live history has no compatible baseline;
  the resolver reports that fact and leaves lifecycle status blocked.
- `84a34432ed` binds ready environment evidence to declared support-matrix
  identity and detected Linux OS/architecture/desktop/session, and rejects a
  malformed current HEAD. Validator/matrix tests pass **38/38**.
- `dbdfb5b8f1` adds scratch-only pruning of unused Sentry SwiftPM variants for
  physical iPad approval runs. The preflight/prune contract passes; no device
  XCTest method has executed.
- `e85d38acc7` keeps local package contracts honest when external historical
  archives are absent. The combined executable contract lane is **69/69** with
  two explicit fixture skips; workflow wiring is **44/44**.

These changes improve repeatability and evidence integrity. They do not change
the strict ledger: **0/40 product** and **0/7 environment**.

### Execution checkpoint — 2026-07-14

The implementation stack is now split into reviewable, dependency-ordered
PRs rather than one blended progress number: P26 tray/deep links (#1649), P27
native notifications (#1651), P35 diagnostics (#1653), P23 provider/model
workspace (#1655), P16 account/enrollment posture (#1658), P12 quota account
switching (#1659, stacked on P23), P13 onboarding first-data verification
(#1667), P14 chat approval boundary (#1662), P17 activity/session depth (#1661),
P21 insights brief (#1669), P24 settings inventory (#1665), P28 SmartHub
allowlist (#1668), and P29 secure text-expansion storage (#1663). Follow-on
source slices add P07 typed Browser Computer Use actions (#1681), P14 exact
persisted chat threads plus safe loaded-message export (#1684), P22 bounded
database inspection (#1680), P27 native startup/deep-link handoff (#1679), P31
accessibility preference contracts (#1683), and P39 differential evidence
comparison (#1682). P19 project lifecycle is now extended by PR #1688 with
typed delete/reassign RPCs, canonical identity validation, durable reference
migration, and deleted-slug tombstones. Local integration slices now add
typed chat model/thinking-level selection, bounded daemon-owned attachment
refs, persisted activity body replay/native resume, actionable native
notifications/shortcut status, SQLCipher-gated encrypted snapshot/atomic
restore, and macOS-compatible passphrase recovery bundles. The latest source
wave adds `274f67fba0` (explicitly opted-in, signed IBus/Fcitx engine
registration), `ea82fe5140` (bounded Wayland portal capability probing and
an X11-only native pet companion window), `bf0eb36294` (consent-scoped
RemoteDesktop `Notify*` input execution), `d2dbbe8df8` (bounded trigger-only
external text expansion), and `bd9d6a5173` (typed Mission Control
health/history RPC and UI). The
authoritative promotion ledger remains 0/40 ready and 0/7 environment receipts;
no PR in this checkpoint may be treated as full parity or as evidence that the
Linux release candidate is shippable.

Recommended landing order for this wave is P26, then P23 and P12, followed by
P13, P14, P17, P19, P21, P24, P28, P29, P35, and P16; P07, P22, P27, P31, and
P39, plus the P19 lifecycle extension, activity replay/resume, chat model and
attachment transport, notifications/shortcut status, encrypted snapshot/
restore, and recovery bundles can land as
independently reviewable source slices because each preserves an explicit
installed-proof boundary.

The 2026-07-14 integration checkpoint adds three bounded source slices to PR
[#1691](https://github.com/Imagine-That-Ai/BurnBar/pull/1691): chat citations and
daemon-issued tool approvals (`55e2e2ac23`), SmartHub typed allowlisting with
bounds/timeout/cancellation (`2dcd7e3abc`), and daemon-owned text expansion with
AES-GCM sealed storage, native Secret Service/KWallet custody, consent RPC, and
in-app-only Composer expansion (`227d7e3c49`, `46aa7f3c91`, `6cc09bc2c0`,
`930125a53e`, `83ef8e8edf`, `09860849c7`). These improve source parity without
changing the 0/40 product or 0/7 environment certification state. The current
source commit is `8dd319a5e3` (building on `dd864a90be`, `b056423dbd`, `4b1126bfdf`, `3b652f9b9e`, `d7cffc79d6`, `702f59146e`, `814749c8be`, `cba9266277`, `a5485fe238`, and `825e081bda`); it adds a daemon-owned
retention policy in addition to the `daemon.usage.insights`
local-rules response with bounded citations, selected-scope encrypted privacy
export, and independent per-binding native shortcut health. Focused
changed-surface UI/bridge tests, Core privacy crypto tests, the macOS daemon
product build, and the Tauri Rust suite are green; the daemon XCTest bundle
builds but cannot launch on this host because the existing SQLCipher.framework
runtime packaging is absent.
The live UTM Ubuntu 24.04 aarch64 guest now also builds the daemon and runs the
current root-owned Tauri/daemon pair through the trusted launcher with
authenticated health probes; the Linux package suite is 284/284, including
privacy 8/8, text expansion 18/18, peer-manifest 8/8, portal input 26/26, and
mission lifecycle 3/3; the exact smoke receipt is
`docs/linux-port/evidence/parity-audit-2026-07-10/utm-ubuntu-aarch64-installed-runtime-2026-07-14.json`.
After the code stack is review-clean, rerun
the strict ledger on the exact candidate and collect the installed GNOME
X11/Wayland, KDE/wlroots, x86_64/aarch64, accessibility, performance,
update/rollback, and physical-device receipts listed below.

### Continuation checkpoint - 2026-07-15

The exact integration branch now includes three additional source slices:

- `702f59146e`: chat attachment MIME canonicalization and preflight rejection
  for unsupported PDF before durable append/upload, preserving the draft and
  staged attachment.
- `d7cffc79d6`: Linux Tauri provider workspace hydration from both
  `daemon.config.get` and canonical `daemon.catalog`, with an explicit
  config-only degraded state when catalog lookup fails.
- `3b652f9b9e`: bounded pointer/mouse drag and Arrow/Home keyboard movement for
  the Wayland-safe contained pet fallback, including focus metadata and live
  announcements while keeping native overlay/click-through fail-closed.

The shared Hermes insight transport also has an explicit
`AsyncThrowingStream<HermesInsightChunk, Error>` initializer in `702f59146e`,
which fixes the Windows Foundation overlay inference failure in the PR gate;
the local macOS Swift target builds. Focused chat tests are 60/60, pet tests
are 27/27, provider tests are 26 Vitest plus 2 Rust, and the app typecheck and
production bundle pass. These changes improve source parity only. The strict
promotion ledger remains **0/40 product** and **0/7 environment** until the
current-head signed candidate and installed/runtime receipts are complete.

The first candidate after this checkpoint (`29417386163`) failed both native
architecture shards on the public/default-initializer visibility boundary in
the Linux Computer Use adapter. `4b1126bfdf` adds the public production
no-argument initializer and keeps dependency injection internal; the corrected
candidate must pass both architecture shards before any release evidence is
considered current.

The shared Hermes insight transport then exposed a Windows Foundation overload
difference in PR #1691: the Windows toolchain selected the zero-argument
`AsyncThrowingStream` unfolding initializer rather than the continuation
builder. `dd864a90be` selects the continuation initializer explicitly with a
buffering-policy label and typed continuation. Windows FoundationNetworking
also lacks `URLSession.bytes(for:)`; `8dd319a5e3` routes Linux and Windows
through buffered `data(for:)` SSE parsing while retaining incremental bytes on
Apple platforms. The macOS package build passes.
The stale pre-fix candidate was cancelled. A replacement exact-head release
candidate and nightly matrix will be dispatched after this documentation
checkpoint is frozen. Neither run is a parity receipt until it completes and
its evidence is validated against the exact head.

### Continuation checkpoint - 2026-07-15 source follow-on

Commit `dcca8b74b4` adds three bounded implementation units while preserving
the installed-proof boundary:

- **LNX-CHAT-001:** capability-gated PNG/JPEG/WebP/PDF chat attachments. The
  daemon reads the selected model's canonical catalog contract, encodes native
  content only when explicitly accepted, enforces the advertised byte limit,
  and fails closed before provider submission. The renderer performs the same
  preflight and preserves the draft/staged file on unknown or unsupported
  capability. Focused UI/bridge tests, Vite production verification,
  TypeScript typecheck, and all **102/102** Linux Tauri Rust tests pass.
- **LNX-SEC-002:** Secret Service first-use health. A missing probe item is
  normal on a fresh unlocked keyring and is accepted; locked, unavailable, or
  D-Bus failure details still fail closed. The Linux security target builds and
  direct behavior harness pass; environment receipts remain required.
- **LNX-NATIVE-002:** packaged XDG autostart. DEB/RPM/Arch and legacy package
  staging install one canonical `/etc/xdg/autostart/openburnbar.desktop`, and
  `--background` hides the window only after tray initialization succeeds.
  Packaging/wiring tests pass; installed desktop-environment persistence and
  update/rollback receipts remain required.

These source changes advance the branch beyond the candidate run recorded
above. A fresh exact-head release candidate must be built before any of the
new behavior can enter the promotion ledger; the ledger remains **0/40** and
**0/7**.

Candidate `29429549029` then failed both architecture shards during package
preflight because the new XDG autostart member was intentionally outside the
verifier's previous `/usr`-only extraction root. Commit `646270227e` closes
that release-integrity gap without broadening the trust boundary: the verifier
allows and extracts only `etc/xdg/autostart/openburnbar.desktop`, the Arch
source/checksum generator includes the canonical file, and the focused release
suite is **36/36** with one root-toolchain skip. A replacement candidate must
pass both architectures and the aggregate attestation before installation.

Candidate `29432186379` then failed closed before signing. Its x86_64 shard
exposed that archive preflight must accept the parent directories of the one
allowed XDG autostart leaf, while its aarch64 shard hit an independent
`ports.ubuntu.com` package-fetch outage during toolchain-image construction.
The verifier now accepts only that exact leaf plus its parents and retains
sibling/path-traversal rejection coverage; the focused release suite remains
**36/36** with one root-toolchain skip. No artifact or receipt from this run is
certifying; rerun from the new exact head.

Candidate `29434274277` confirmed one remaining source boundary: DEB/RPM
extraction still passed an empty non-`/usr` allowlist even though those bundles
now carry the canonical XDG autostart leaf. The shared native extractor now
uses the exact autostart allowlist for all three formats, and the root-toolchain
DEB/RPM fixture checks the extracted desktop entry. The same run's aarch64
failure was again an independent `ports.ubuntu.com` outage; no artifact or
receipt is certifying and another exact-head candidate is required.

The repeated ARM mirror outage is now addressed in the toolchain itself: its
base-image Ubuntu archive entries are normalized to HTTPS before apt runs, and
the Node/toolchain contract suite asserts all three Ubuntu endpoints. This is a
release-reliability repair, not a product-parity receipt; the next exact-head
candidate must still pass both architectures and installed proof.

Candidate `29436469591` confirmed that the mirror repair is effective: both
architecture shards cleared toolchain construction and reached installed
manifest generation. They then failed closed because the manifest inventory
still enforced a `/usr`-only file boundary and rejected the intentionally
packaged `/etc/xdg/autostart/openburnbar.desktop`. No artifact or certifying
receipt was produced. The next implementation unit must make manifest
generation use the same exact autostart allowlist as native package extraction,
including its required parent directories while preserving ownership and
sibling/path-traversal rejection, then rerun a fresh exact-head candidate before
installation or ledger promotion.

Candidate `29438744035` advanced past both toolchain builds but failed closed in
`bundleRpmFromDeb`: DEB re-extraction and the RPM spec path validator were not
given the canonical non-`/usr` allowlist, so the rebuild rejected
`native package archive member is outside /usr: etc`. No artifact or certifying
receipt was produced. The next implementation unit must thread the shared
allowlist through the RPM rebuild path and then rerun both architecture shards
before installation or ledger promotion.

Candidate `29440745769` advanced through RPM and installed-manifest generation
on both architectures and reached Arch preparation, then failed in
`build-signed-arch-package` with `The path argument must be of type string.
Received undefined`. The source cause was a missing `AUTOSTART_DESKTOP` to
`openburnbar-autostart.desktop` entry in `commonNames`. No artifact or
certifying receipt was produced. The next implementation unit must add that
mapping plus a source-input regression test, then rerun both architecture
shards before installation or ledger promotion.

Candidate `29442734074` produced and verified signed native artifacts for both
architectures, then failed during live package-ownership smoke for DEB/RPM:
the installed verifier still rejected the canonical
`/etc/xdg/autostart/openburnbar.desktop` as a non-`/usr` path. No shard artifact
or certifying receipt was retained. The next implementation unit must extend
the live installed-ownership verifier to the shared exact allowlist and add
focused regression coverage, then rerun both architecture shards before
installation or ledger promotion.

Candidate `29445148032` then passed signed package installation, live ownership,
update/rollback, desktop-route sessions, and evidence upload on both
architecture shards. Aggregate finalization failed because the canonical JSON
schema still required every file path under `/usr`; the exact regular file
`/etc/xdg/autostart/openburnbar.desktop` was rejected. No certifying receipt was
produced. The next implementation unit must add the exact regular-file
exception to the schema while retaining `/usr`-only symlink paths, then rerun
aggregate validation before ledger promotion.

Exact-head candidate `29448108187` at
`ccd9bb3061fc486c06476ccbd75182647927ff41` then passed both architecture jobs
and aggregate finalization with immutable `linux-release-evidence` digest
`sha256:f9d44744b153c4ac33bc09fe743b27529cb1300f8e55e8ed4cfd0ac0c36ff017`.
The exact arm64 DEB was installed in UTM Ubuntu 24.04 GNOME/X11; its signed
manifest SHA-256 is
`441a42936344b61a8f63898278efe3a30efc7d3f9d083537f826cc0e5cbac59f`. The
corrected live P-40 producer passed all checks with session receipt hash
`ddfac322b43cfde7d743c69ae14e1ed13b546f3281472882063664ecf10101cf`. The
candidate-bound artifact digest is the release-evidence digest above, not the
package digest. This closes one P-40 installed proof surface only; the strict
ledger remains **0/40 product** and **0/7 environment** until all validator and
environment receipts are promoted.

### Follow-on source checkpoint — 2026-07-14

The integration branch now includes the next bounded source slices:

- `0d8ee32526`: chat attachment upload/metadata, reconnect and visibility
  continuity, functional options, and browser/Tauri pop-out boundaries. Upload
  bytes remain process-lived by design; a daemon restart requires re-upload.
- `4a2138897c` and `01784940c5`: exact update artifact/channel safety plus
  account context/generation fences that reject stale identity responses.
- `5ddd81245d`: selectable Insights canvas/library/inspector widgets, bounded
  audit disclosure, refresh, and chat follow-up handoff.
- `5f74018422`: normalized notification actions, expanded allowlisted routes,
  and cold-start native-route precedence over onboarding.
- `9a527310f9`: contained pet summon/focus/status and selection/clear controls;
  native overlay and click-through remain explicitly unavailable.
- `618c7286b9`: daemon-authoritative full chat-history export with bounded
  pagination, duplicate/cursor/size checks, and validated daemon re-read
  resume; uploaded attachment bytes remain process-lived.
- `b3002ab3f9`: account-scoped persisted Insights selection/density, validated
  evidence IDs, bounded audit disclosure, and typed qualitative-unavailable
  state when no Linux RPC exists; `825e081bda` adds the daemon-owned
  qualitative response and renderer mapping.
- `d191a1be5f`: typed database recovery status/actions, candidate-key and
  integrity proof, explicit missing-database/device-transfer guidance, and
  fail-closed Tauri controls.
- `c1f6e69514`, `fec153e40b`, and `e6bf98601b`: bounded Activity full-history
  export using verified daemon usage/replay identities, with typed unavailable
  state unless the daemon supplies explicit `historyComplete === true` proof;
  resume carries the same guard so the bounded recent-usage bridge cannot be
  presented as a complete history.
- `e0451afa5e`: strict provider catalog/config mapping, model provenance and
  failover posture, provider workspace, and config-derived backend gates.
- `fcf4667682` and `e4827a4090`: serialized text-expansion mutations with
  stale-generation fencing, plus isolated Linux SwiftPM scratch state for
  deterministic native test runs.
- `274f67fba0`: bounded, signed external IBus/Fcitx engine registration with
  explicit opt-in, owner/path/permission/session checks, and secure-field
  fail-closed policy.
- `a5571694bb`: independent per-binding native shortcut registration with
  typed X11/Wayland/unknown backend health; one failed dashboard grab no longer
  suppresses the Computer Use panic bindings, and unsupported Wayland/unknown
  hosts remain fail-closed.
- `7c8a214ce6` and `825e081bda`: selected-scope encrypted local privacy export
  using an authenticated PBKDF2-HMAC-SHA256/AES-GCM envelope, bounded daemon
  path/owner/permission/race checks, typed Settings/Tauri wiring, and a
  daemon-owned `daemon.usage.insights` local-rules qualitative response with
  bounded usage rows/citations. Full account/transcript export, retention,
  backend erasure, and installed Linux receipts remain separate gates.
- `ea82fe5140`: bounded Wayland/XDG RemoteDesktop capability probing with
  typed consent/denial/timeout/cancellation states and an X11-only Tauri pet
  companion window with explicit click-through control.
- `bf0eb36294`: consent-scoped Wayland RemoteDesktop `Notify*` execution for
  pointer, click, drag, scroll, key, shortcut, and bounded text actions; libei
  and uinput remain explicitly unavailable, and every dispatch is session-,
  timeout-, cancellation-, and kill-switch-bound.
- `d2dbbe8df8`: trigger-only signed external text-engine request/response with
  canonical bounds, secure/excluded/uninspectable denial before write, bounded
  response validation, and cancellation/timeout/kill-switch teardown. The
  engine never receives keyboard, clipboard, surrounding-text, or field data.
- `814749c8be`: Linux pipe reads now consume one bounded POSIX read after
  `poll(2)`, and teardown closes stdin before terminating a blocked engine.
- `4bc52a7961`: Linux parity fixtures now open explicit mutation windows for
  immutable AppImage trees, inject an in-memory mission notification store, and
  assert `gdbus` method/type substrings correctly; the full Ubuntu suite is
  284/284.
- `bd9d6a5173`: daemon-owned Mission Control health/history contract derived
  from the authoritative projection, stable packet/result/burn/takeover event
  IDs, active/failed counters, Core/RPC/Tauri canon, and Missions UI rendering.

The combined frontend suite is **78 files / 685 tests**, the Tauri Rust suite
is **90/90**, TypeScript and the production bundle verifier pass (303
modules), the Linux daemon package suite is **284/284** on Ubuntu 24.04
aarch64, and the daemon target builds. These are source gates only. The promotion ledger remains
0/40 product rows and 0/7 environment receipts until the exact signed
candidate, installed matrix, Linux keyring/portal/D-Bus evidence, update/
rollback proof, and physical-iPad flow are exercised.

> **Execution update through 2026-07-12 UTC:** the implementation wave completed the
> fail-closed 40-requirement inventory, Linux secret custody/native gateway
> boundary, runtime capability manifest, installed accessibility harness,
> matched performance/soak harness, native signed-feed verifier, and native
> aarch64/x86_64 shard/aggregate workflow. A clean aarch64 `.deb` session passed
> GUI/daemon/version/uninstall, all 19 installed routes, AT-SPI/Orca/keyboard/200%
> zoom, 28 package-smoke steps, and repeated startup/tray/IPC measurements.
> Controller-route v2, Linux native iroh runtime composition, daemon-owned
> PKCE/Firebase/App Check credentials, per-install Ed25519 Linux App Check,
> redacted Tauri/account state, signed AppImage peer admission, explicit
> approval-required error semantics with quota-bounded polling, and the
> physical-iPad Linux-device approval source are now implemented. The shared
> Hermes relay challenge schema is canonical across generated Swift and Kotlin;
> Android static analysis is clean, earlier generic iOS build-for-testing coverage
> passes, focused macOS app diff coverage is above its 80% gate, and the
> 2026-07-12 full Linux-native aggregate passed in the Docker Linux toolchain.
> These are
> source milestones, not installed parity. The immediate blocking order is:
> dedicated Desktop OAuth client -> public release variables -> Functions
> deployment -> physical-iPad test execution -> exact signed candidate ->
> install the candidate with the daemon/media/SQLCipher runtime and verify
> service/peer health -> physical-iPad/Linux enrollment and two-device
> media/Browser Computer Use proof -> full desktop/compositor and
> update/rollback certification. The service/media/database slice is
> implemented and live in `a570c9b087`; its remaining dependency is
> cross-device and signed-candidate evidence, not VM startup. The independent
> audit is the current status source:
> `LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md`.

### Integration verification checkpoint - 2026-07-13

The clean integration worktree replayed the current Linux source stack through
the P26 tray/deep-link base and the P19 project-lifecycle extension, then
integrated chat model/attachment state, persisted activity replay/resume, and
SQLCipher-gated encrypted database snapshot/restore. The
following checks passed:

- Linux frontend: 75 Vitest files / 648 tests.
- TypeScript: `npx tsc --noEmit --pretty false`.
- Production bundle: `npm run build` plus the production bundle verifier.
- Tauri Rust: 87/87 library tests.
- RPC canon, Rust formatting, and suppression-policy checks.
- Platform differential oracle: 6/6 tests.
- Linux parity validator, matrix harness, renderer, and workflow contracts:
  53/53 tests.
- Supported SQLCipher-backed daemon chat selector: 9/9 tests.
- P19 daemon project lifecycle selector: 4/4 tests, covering delete,
  reassignment, durable nested/reference migration, collision rejection, and
  deleted-slug protection.
- Activity replay/resume selector: 4/4 Swift tests, including plaintext
  database readability and provider-safe native/fallback resume.
- Database snapshot/recovery selector: 3/3 Swift tests covering traversal,
  size, and insecure-permission rejection. The Linux codec round-trip remains
  conditional on a configured Linux SQLCipher secret and was not claimable on
  this macOS host. Recovery crypto source compiles; the macOS test-bundle
  runtime is blocked by the existing missing SQLCipher.framework packaging.
  Linux Secret Service/KWallet capability and round-trip receipts require a
  Linux host.

This is current source/integration evidence only. It does not satisfy the
installed Linux, public release, compositor matrix, Secret Service/KWallet,
physical-iPad, or same-commit macOS/Linux evidence gates. Linux-only native
notification tests still require a Linux host.

### Source-slice implementation addendum - 2026-07-13

These nine slices are now integrated in [PR #1691](https://github.com/Imagine-That-Ai/BurnBar/pull/1691) and should land as a
reviewable unit before the installed-certification wave; the individual feature
commits remain separately inspectable in the branch history:

| Order | Slice | Dependencies | Acceptance criteria | Remaining boundary |
|---|---|---|---|---|
| 1 | Chat model/options, attachment transport, citations, and approvals | Existing encrypted thread RPCs, gateway model catalog, Composer/ChatSurface stores, daemon private data root | Selected model and thinking level survive the active composer lifecycle and reach the gateway as the exact model ID; daemon-owned attachment refs enforce 10 MiB/file/send caps, 80 MiB registry, 0700/0600 storage, single-use UUIDs, allowlisted text/Markdown/CSV/JSON/PDF policy, text-only gateway payloads, explicit PDF unsupported behavior, bounded citation source handling, daemon-issued approve/reject/cancel IDs, reconnect/visibility handling, functional options, and browser/Tauri pop-out boundaries; no renderer secret, raw path, or fake upload path | Image/binary provider handling, unloaded-history export/resume, attachment re-upload after daemon restart, and remaining backend catalog still require real daemon/provider contracts |
| 2 | Activity body replay and resume | Existing indexed activity search/detail RPCs, canonical `run.resume`, bounded transcript decoder | Body replay is daemon-backed, size-bounded, untrusted-rendered, and honest on missing/offline/error; native resume carries the persisted briefing without launching a process; providers without validated native resume use the same-harness handoff; plaintext legacy SQLite remains readable under SQLCipher builds; Swift 4/4 and frontend/Rust contracts pass | Full-history export, source resolution, resume-from-export, and installed provider/runtime proof remain open |
| 3 | Encrypted project database snapshot/restore | Project-code SQLite store, SQLCipher codec/key custody, watcher lifecycle, canonical RPC generator | Snapshot rejects traversal/symlinks/unsafe ownership, active-db overwrite, and >512 MiB; checkpoints WAL, writes owner-only temporary files, hashes content, atomically installs; restore validates integrity, stops/reopens watchers, and rolls back on failure; bridge/Rust contract suites pass | This is same-key encrypted snapshot recovery only. Key-loss/device-transfer recovery and installed proof remain open |
| 4 | macOS-compatible database recovery bundle | Existing SQLCipher key custody, Swift Crypto, daemon RPC/canon, Database surface | v1 bundle uses exact salt16/PBKDF2-HMAC-SHA256 100k/AES-GCM combined format; parser bounds bundle/version/iterations/key length; export/import uses owner-only 0600 atomic files, candidate-key verification, and native Secret Service/KWallet custody hooks; passphrases never enter renderer persistence; source/build tests pass | Live Linux keyring round-trip, key-loss/device transfer, recovery UX for missing stores, and installed proof remain open |
| 5 | Native notification actions and shortcut status | Tauri shell, freedesktop notify-rust capability probe, tray event bridge, existing shortcut registry | Typed notification IDs/actions/routes are bounded and validated; unsupported hosts report degraded state; action opens only allowlisted routes; independent per-binding shortcut status is visible and additive to existing chords; Rust/TS tests pass | Live GNOME/KDE/wlroots D-Bus receipts, desktop persistence, and accessibility/manual proof remain open |
| 6 | Activity replay/resume hardening | Existing indexed activity RPCs, canonical run.resume, bounded transcript decoder | Body replay is daemon-backed, size-bounded, untrusted-rendered, and honest on missing/offline/error; native resume carries persisted briefing without launching a process; provider-safe fallback and plaintext legacy SQLite readability are tested | Full-history export, source resolution, resume-from-export, and installed provider/runtime proof remain open |
| 7 | Chat citations and tool approvals | Existing chat thread/gateway contracts, approval.respond, citation source identity | Bounded citation metadata is normalized with thread/message validation and source-unavailable fail-closed behavior; daemon-issued approval IDs route approve/reject/cancel with single-flight terminal state; focused chat tests pass | Unloaded-history export/resume, pop-out, remaining backends, and installed reconnect/offline evidence remain open |
| 8 | SmartHub command safety | Existing typed CLI bridge and capability probe | Allowlisted discovery/status/test/cast/device/parity operations validate request IDs and bounded JSON, drain output concurrently, time out at 8 seconds, support cancellation, and expose degraded renderer state; focused TS/Rust tests pass | Real devices, Avahi/DBus, auth, offline/reconnect, and desktop matrix remain open |
| 9 | Daemon-owned text expansion | Existing text expansion surface/Composer, daemon RPC canon, native secret custodian | AES-GCM sealed snapshot with native Secret Service/KWallet key custody, owner-only permissions, consent RPC, in-app-only expansion, no renderer localStorage/global capture, and corruption/missing-key fail-closed tests | Linux keyring runtime, IBus/Fcitx external integration, secure-field exclusions, sync/conflict policy, and Wayland/X11 evidence remain open |
| 10 | Signed text-engine lifecycle | Slice 9 storage/consent boundary, signed engine manifest, daemon RPC canon, Tauri bridge | Registration remains owner/path/permission/session checked; typed status/start/stop RPCs enforce consent, exact executable/session binding, bounded handshake timeout, restricted environment, kill-switch cancellation, and no keyboard/clipboard/surrounding-text capture; Swift/bridge tests pass | Linux Secret Service/KWallet, real IBus/Fcitx engine execution, secure-field matrix, and installed receipt remain open |
| 11 | Wayland Computer Use portal session and executor | Existing Computer Use authority/kill-switch boundary, `org.freedesktop.portal.RemoteDesktop` | Create/select/start/stop consent flow returns typed active/denied/timed-out/cancelled/unavailable state; `bf0eb36294` dispatches only through a consented RemoteDesktop session using typed `Notify*` methods for pointer/key/shortcut/type/scroll/drag, validates session handles, never claims libei/uinput support, and enforces timeout/cancel/kill-switch teardown | Linux GNOME/KDE/wlroots portal receipts, compositor-specific behavior, and installed input execution remain open |
| 12 | Mission Control replay and privacy deletion/export | Existing project journal/checkpoint and daemon-owned local-data stores, RPC canon, Settings wiring, bounded export crypto | Projection checkpoint/tail mismatch rebuilds without resurrecting deleted IDs; local privacy inventory exposes metadata only; preview tokens expire and bind owner/perms/fingerprints; exact confirmation performs idempotent allowlisted unlink and returns a typed receipt; selected local stores can be exported through an authenticated PBKDF2/AES-GCM envelope with owner-only bounded output; no account/transcript/credential deletion claim; Swift/Rust/bridge/Settings tests pass | Installed restart/crash replay, locked keyring, account erasure/full export/retention/recovery policy, native save-picker, and Linux runtime proof remain open |
| 13 | Mission Control health/history authority | Existing mission projection, packet/result/burn/takeover snapshots, RPC canon and Missions UI | `bd9d6a5173` adds `daemon.mission.health` request/response contracts, authoritative health derivation, stable chronological history IDs, active/failed counters, Tauri mapping, store loading/error states, and detail/history rendering; missing missions fail closed; Core/daemon/bridge/UI tests pass | Installed daemon restart/reconnect, active/failed/terminal scenarios, and exact-candidate receipt remain open |

Recommended engineering order after these source slices is: (a) land and
rebase the integration PR; (b) run Linux SQLCipher, Secret Service/KWallet,
notification, and attachment round-trips on a real host; (c) implement
recovery key-loss/device-transfer and remaining chat provider contracts; (d)
certify full chat/activity/database/notification flows in installed packages;
and (e) exercise the new text-engine, portal, Mission Control replay, and
privacy deletion boundaries on the installed candidate before closing the
P-14/P-17/P-22/P-27/P-29/P-40 ledger rows with exact-candidate receipts.

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

## Current Critical Path

The remaining credential work is operational, not a missing daemon architecture.
The daemon now owns PKCE loopback state, refresh-token custody, Firebase ID-token
refresh, App Check enrollment/challenge/mint, account generation, sign-out, and
account-switch teardown. Account-transition RPC state is phase-tagged so cancel
cannot report an account active after teardown has begun, and successful sign-out
permits a fresh browser sign-in. The Functions/daemon contract distinguishes the
explicit pending-approval reason from permanent rejection; only pending or
transient cloud failure retries, using a 15/30/60/120/300-second capped schedule
that stays below the public endpoint quota. Official AppImages authenticate the
final GUI through a signed manifest instead of mutable environment pins. The iPad
source validates the exact Linux device ID and public fingerprint before an
explicit approve or revoke mutation.

Full parity remains **NO-GO** until all of these gates are met in order:

Live recheck on 2026-07-19: the wired paired iPad is booted with Developer
Mode enabled, resolves from its CoreDevice identifier to the hardware UDID, and
passes the current-checkout focused approval run: **44 tests, 0 failures**. The
source-safe Firestore graph (`grpc-ios` plus `BoringSSL-SwiftPM`) and arm64-only
Signal FFI build were used. The non-certifying receipt is
`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19.json`.
This closes focused mobile approval/decoder coverage only, not installed Linux
enrollment, fingerprint confirmation, approve/revoke, or cross-device Computer
Use proof. The current `utmctl` query reports the OpenBurnBar Linux guest as
stopped; it was not modified. The product-parity workflow is not yet on `main`,
and GitHub has no registered self-hosted runners for the seven required Linux
environment labels.

The mobile runner correction in `5cff4281ec` accepts both CoreDevice and
hardware-UDID forms, fails closed for missing or ambiguous mappings, and is
covered by deterministic shell tests. It removes destination-format ambiguity
but does not count as physical approval execution.

1. Provision the dedicated Google Desktop OAuth client.
2. Set and validate the remaining `OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID`; the
   `OPENBURNBAR_FIREBASE_API_KEY` and
   `OPENBURNBAR_LINUX_APP_CHECK_APP_ID` public repository variables were set on
   2026-07-14. Release validation must continue to fail closed when any value is
   absent or malformed.
3. Deploy the Linux App Check callables, policy, and Firestore rules.
4. Keep the focused mobile XCTest receipt green on the connected physical iPad.
   The 2026-07-19 current-checkout focused approval run passed 44/44. This is
   only focused mobile coverage: installed Linux enrollment, fingerprint
   confirmation, approve/revoke, and cross-device action proof remain required.
   The visible iPhone and simulator targets remain invalid substitutes.
5. Build and sign the exact deb/rpm/AppImage candidate, including the final-byte
   AppImage peer manifest. Candidate `0.1.1` is now built and signed by Release
   `29646670068`; compatible previous-package lifecycle proof and public
   promotion remain open.
6. Install the exact candidate and complete PKCE sign-in plus physical-iPad
   enrollment, fingerprint confirmation, approval, refresh, revoke, and sign-out.
7. Prove real Browser Computer Use actions, approval/deny, panic, audit/tamper,
   credential loss, account switch, and daemon restart/replay behavior.
8. Clear the exact-head Ubuntu GNOME/X11 packaged shell gate. **Completed** by
   Nightly `29646670763`: `fb20c38dc2` defers packaged route bodies behind a
   stable skeleton and idle hydration; `440635120f` makes host-side transcript
   normalization best-effort for root-owned Docker evidence; route p95 is
   `95.6 ms` (33 samples, budget `120 ms`) and shell smoke exits successfully.
   Keep the threshold and raw-transcript retention contract in future runs.
9. Complete GNOME X11/Wayland, KDE Wayland, wlroots, architecture,
   accessibility, performance, update/rollback, and release-promotion
   certification.

An iPhone or simulator may support development coverage, but neither is accepted
as a substitute for the physical-iPad authority gate in this plan.

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
   - keep platform fallback `LinuxEmptyTests.swift` files out of the Linux
     execution graph and require behavior suites for supported Linux targets
   - cover analytics, Computer Use, remote engine, media, iroh relay, and
     signal/session transport with non-tautological tests where the target is
     available

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
18. Sign the canonical AppImage peer manifest only after final repacking; bind
    exact GUI identity/path/basename/SHA-256 and verify the final installed bytes.

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
- `VAL-RELEASE-006`: official AppImages fail closed for absent, malformed,
  tampered, wrong-key, path-swapped, hash-mismatched, mutable-root, or oversized
  peer manifests; the final repacked candidate admits only its exact GUI bytes.

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
10. Complete Linux device enrollment and approval on the physical iPad; verify
    the stable device ID and canonical public fingerprint before approving.
11. Run Browser Computer Use action/deny/panic/audit/restart proof against the
    exact installed candidate and the same approved iPad authority.
12. Record blocked rows as `blocked.json` with exact platform reason.

Acceptance:

- `VAL-MATRIX-001`: every supported environment has a dated proof artifact.
- `VAL-MATRIX-002`: unsupported environment/capability combinations are public
  limitations, not hidden failures.
- `VAL-SECURITY-001`: secret, checkout, App Check, support bundle, peer-auth,
  and Tauri URL tests pass.
- `VAL-MATRIX-003`: physical-iPad enrollment, approval, revoke, and signed
  session/action authority pass against the exact installed candidate; an iPhone
  or simulator result does not satisfy this gate.

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

The original foundation sequence is substantially implemented. From the
2026-07-12 source-complete wave, use this dependency-ordered sequence:

1. **Credential authority and account UI PR**
   - Land daemon-owned PKCE/Firebase/App Check authority, redacted RPC/Tauri
     account state, browser launch validation, and focused failure-path tests.
   - Keep the PR explicit that Desktop OAuth provisioning and live deployment
     are operational blockers.

2. **AppImage peer-auth PR**
   - Land signed canonical peer manifests, release-key wiring, final-repacked
     AppImage verification, tamper tests, and fail-closed release configuration.

3. **Physical-iPad approval PR**
   - Land Linux device list/approve/revoke, canonical device-ID/fingerprint
     validation, confirmation UX, serialized mutations, stale-load guards, and
     focused mobile tests.
   - Preserve the passing generic iOS build-for-testing coverage.
   - Run focused tests on the connected physical iPad; do not substitute an iPhone or
     simulator for the final physical-device gate. The current bounded focused
     approval receipt passes 44/44 on the paired device; mobile decoder/approval
     coverage is proven, while installed Linux enrollment and cross-device
     execution remain blocked until the exact Linux candidate is paired.

4. **Production configuration change**
   - Create the dedicated Desktop OAuth client.
   - Set the public Linux release variables and deploy the App Check callables,
     policy, and rules.
   - Record exact app/client IDs and deployment revisions in private release
     evidence without exposing secrets.

5. **Signed candidate PR/run**
   - Build the exact deb/rpm/AppImage candidate, bind source/SBOM/VEX/provenance,
     build/stage the daemon-owned `openburnbar-media` runtime, bind the packaged
     FTS5-capable SQLCipher runtime, include the compositor-safe WebKit startup
     policy, sign the final AppImage peer manifest, and pass strict release
     validation. The release graph must fail closed if the media native
     artifact or SQLCipher runtime is absent.

6. **Installed Linux plus physical-iPad certification**
   - Prove PKCE sign-in, enrollment, fingerprint confirmation, approval, refresh,
     revoke, sign-out/account switch, and token redaction.
   - Prove real Browser Computer Use actions, deny, panic, audit/tamper, crash,
     restart, replay persistence, and permission revocation. In the same exact
     install, prove iPad/Linux file transfer, call, screen-share consent,
     codec fallback, decoder recovery, and teardown.

7. **Desktop and architecture matrix PR/run**
   - Run GNOME X11/Wayland, KDE Wayland, wlroots, x86_64/aarch64,
     accessibility, performance, update/rollback, and package lifecycle proof.

8. **Route performance and evidence-wrapper closure**
   - Validate `fb20c38dc2` plus the root-owned transcript handling fix on the
     exact packaged Ubuntu GNOME/X11 job. Keep the route shell accessible during
     two-frame/idle hydration, confirm fixture and browser previews remain eager,
     and reject any threshold relaxation. Raw Docker-owned transcripts remain
     valid evidence when host-side normalization is not permitted.

9. **Remaining product-parity PRs**
   - Complete installed chat export/resume, pop-out, remaining backends,
     provider/account/cloud, activity source resolution and full-history export,
     passphrase-wrapped recovery bundles, live Insights qualitative/citation
     analysis, memory review, system
     Computer Use, Mercury, external IBus/Fcitx text expansion, companion,
     SmartHub live-device actions, and every other still-open audit row. Project
     lifecycle source parity is covered by PR #1688; installed/release evidence
     and the 10k-session migration acceptance suite remain open.

10. **Promotion and public truth-sync PR**
   - Require zero Critical/High gaps, strict evidence closure, valid signed public
     feed, current support matrix, release/rollback docs, and exact-candidate
     parity before stable promotion.

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
13. Computer Use has installed Browser parity backed by the physical iPad, and
    explicit system-mode proof or Tier C limits.
14. Mercury has real transport/control proof or explicit blocked rows.
15. Account/cloud/App Check/Stripe proof is live against staging/prod, including
    Desktop PKCE, Linux enrollment, physical-iPad fingerprint confirmation,
    approval/revoke, refresh, expiry, sign-out, and account switch.
16. Release verifier passes strict mode without `--allow-blocked`.
17. Public `latest-linux.json` is valid JSON and verified.
18. deb/rpm/AppImage install, launch, update/rollback, and uninstall proof
    exists.
19. Ubuntu GNOME X11, Ubuntu GNOME Wayland, Fedora KDE Wayland, and Arch/wlroots
    are tested or explicitly blocked with public limitations.
20. README, CHANGELOG, release docs, support matrix, known limitations,
    rollback docs, and supply-chain docs match live truth.
21. The signed AppImage peer manifest binds the final repacked GUI bytes and all
    manifest/signature/path/hash/root-mutation attacks fail closed.
22. No Firebase ID token, App Check token, refresh token, enrollment private key,
    OAuth verifier, or approval proof appears in renderer state, local RPC, logs,
    crash reports, clipboard, or diagnostics.
23. Physical-iPad approval and Computer Use proof is attached to the exact
    candidate hash; iPhone and simulator runs are supplemental only.
24. Functions deployment revision, Firebase app ID, Desktop OAuth client type,
    release-variable validation, and installed artifact identity are bound into
    the final evidence graph without exposing secret values.
