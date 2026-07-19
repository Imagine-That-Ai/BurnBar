# Linux/macOS Parity Independent Audit

| Audit field | Value |
|---|---|
| Date | Baseline audit: 2026-07-09; remediation evidence through 2026-07-19 UTC |
| Gold standard | OpenBurnBar for macOS |
| Linux target | `apps/linux-desktop` plus the shared OpenBurnBar daemon |
| Baseline checkout | `windows/liquid-glass-kernel-reskin` at `18836ae40a` |
| Remediation evidence | Documentation head `6c4e809e7aacc1646c9cc8c28d9510e2e100ece1`; latest behavioral evidence is bound to implementation checkpoint `1dced585af2441ac8ac1d4fdcb2e4666177f0474`. Release `29664085758` and Nightly `29660228199` passed at that implementation checkpoint. Full certification remains intentionally blocked because product evidence and live integration receipts are still missing. |

**Verdict:** **NO-GO for a full-parity claim or stable Linux promotion**

## Execution Status — 2026-07-19

The strict ledger is unchanged at **0/40 product requirements ready** and
**0/7 environment receipts complete**. A focused physical-iPad receipt is now
closed: source commit `e0d295e92a` built the arm64 Signal FFI slice and the
source-safe Firestore graph (`grpc-ios` plus `BoringSSL-SwiftPM`) and executed
**44 selected XCTest cases with 0 failures** on Alberto's paired iPad. The
receipt is
`evidence/parity-audit-2026-07-10/ipad-approval-focused-2026-07-19.json`.
This is non-certifying mobile coverage; it does not prove installed Linux
enrollment, fingerprint confirmation, approve/revoke, or cross-device
Computer Use behavior. The current live UTM query reports the Linux guest as
stopped, so no VM evidence was claimed or modified in this check.

## Execution Status — 2026-07-18

The audit remains the source of truth for the parity claim. The current Linux
ledger is still **0/40 product requirements ready** and **0/7 environment
receipts complete**; implementation progress must not be reported as a release
percentage. The active remediation stack now contains these reviewable slices:

### Historical Release verification - 2026-07-18 (source `1b4c3b1e26`)

- **Exact-head Release:** run `29652889294` completed successfully at
  `1b4c3b1e269b3d58d38226af1084f88bc7c6f742`. x86_64 job `88102165389`,
  aarch64 job `88102165384`, and aggregate/attest job `88105582539` passed
  native package construction, DEB/RPM/Arch ownership/install/uninstall,
  packaged daemon, desktop/tray/accessibility/route sessions, finalization,
  and signed closure. The immutable `linux-release-evidence` artifact is
  `8432407756` (3,681,156,161 bytes) with zip digest
  `sha256:d3d26e5a2d57148babfca11646aeecdb89280b95e16446c7cd186b388cb64bf0`.
  Both packaged sessions passed accessibility after the readiness fix:
  aarch64 recorded 34 nodes/22 named/15 actionable with two readiness
  attempts, and x86_64 recorded the same tree with one attempt. Update/
  rollback/data-preservation remains blocked because no compatible previous
  same-architecture package was supplied.
- **Accessibility race correction:** `5e0c7093cb` makes the packaged AT-SPI
  capture wait for a meaningful tree without lowering thresholds, and
  `1b4c3b1e26` retains app/daemon/Orca diagnostics when the initial capture
  fails. The exact-head x86_64 Release session now passes; the earlier
  four-node race is closed as a Release blocker, not promoted as a product
  parity receipt.

### Current-head Release verification - 2026-07-18 (source `1dced585af`)

- **Exact-head Release Candidate:** run `29664085758` completed successfully at
  `1dced585af2441ac8ac1d4fdcb2e4666177f0474`. x86_64 job `88131531712`,
  aarch64 job `88131531733`, and aggregate/attest job `88134572099` passed
  native package construction, DEB/RPM/Arch ownership/install/uninstall,
  packaged daemon, desktop/tray/accessibility/route sessions, native
  update/rollback/data-preservation checks, finalization, and signed closure.
  The immutable `linux-release-evidence` artifact is `8435577756`
  (3,681,812,676 bytes) with zip digest
  `sha256:cb4eeed2f2263707bbf5d563200d02367065067b5c6e4ff6deed651f47299807`.
  Compact receipt: `evidence/mission-005-exact-head-release-1dced585af/`.
- **Lifecycle boundary:** the candidate passed the lifecycle contract without
  a compatible previous same-architecture package. The resolver correctly
  left update/rollback/data-preservation promotion blocked; this run must not
  be described as proof of a real upgrade or rollback.

### Current-head Nightly verification - 2026-07-18 (source `1dced585af`)

- **Full matrix:** run `29660228199` completed successfully at
  `1dced585af2441ac8ac1d4fdcb2e4666177f0474`. macOS matched soak job
  `88121518808`, Linux matched soak/comparison job `88124270582`, and the
  Ubuntu GNOME/X11 job `88127262321` passed. The three intentionally blocked
  environment rows also completed their explicit blocked-row checks:
  GNOME/Wayland `88127262305`, Arch/wlroots `88127262310`, and Fedora/KDE
  Wayland `88127262315`. The X11 artifact is `8435091387` (the immutable
  GitHub artifact remains the source of the full screenshots/logs); small
  ranged JSON extracts are archived under
  `evidence/mission-004-exact-head-1dced585af/`.
- **X11 packaged shell gate:** Ubuntu 24.04.4 aarch64 under Xvfb/X11 with
  XFCE/openbox passed all six shell validators (`VAL-A11Y-001`,
  `VAL-SHELL-005`, `VAL-ONBOARDING-001`, `VAL-PET-001`, `VAL-TEXTEXP-001`,
  and `VAL-PERF-001`). The 19-route packaged session and daemon health passed;
  native p95s were app start `315.55 ms` (10 samples, 2,500 ms limit), route
  navigation `99 ms` (31 samples, 120 ms limit), daemon IPC `112.55 ms` (10
  samples, 800 ms limit), and tray open `72.45 ms` (10 samples, 400 ms
  limit). The route-startup measurement boundary fixed by `1dced585af` is
  therefore verified in the decisive X11 row.
- **Matched workload:** the nightly 1,800-second macOS/Linux soak passed all
  four checksum-matched workloads, absolute/parity budgets, and resource
  checks. Linux RSS growth was `81,920` bytes; no workload errors were
  reported. This is a performance/reliability receipt, not a product-parity
  claim.
- **Certification boundary:** the fail-closed ledger remains **0/40 product**
  and **0/7 environment**, with `productParityClaim=false`. The blocked rows
  above are explicit infrastructure declarations, not successful Wayland or
  wlroots product sessions. Current remaining blockers are the unregistered
  product-parity workflow/evidence for P-01 through P-40, production callable
  deployment proof, compatible previous-release lifecycle proof, physical iPad
  approval execution, live UTM daemon repair, and installed Mercury/Computer
  Use/SmartHub/IME/keyring/accessibility/update receipts.

### Fresh local device and infrastructure recheck — 2026-07-18

- **Physical iPad:** after the wired reconnection, `xcrun devicectl` sees
  Alberto's paired, booted iPad with Developer Mode enabled and a mounted
  developer image. The physical XCTest readiness preflight passes when the
  hardware UDID (`00008132-001158191E9A401C`) is used; the earlier failed
  attempt supplied the CoreDevice identifier instead. XCTest execution still
  has no promoted result because the worktree is over the 10 GiB hygiene
  ceiling, so the focused approval build has not started.
- **UTM:** live `utmctl list` now reports the OpenBurnBar Linux guest as
  started. No VM was modified during this recheck; the historical stale
  `/usr/local` launcher diagnosis remains an open repair gate.
- **iPad runner correction:** `5cff4281ec` makes the mobile test driver accept
  either the CoreDevice identifier shown by `devicectl` or the hardware UDID
  required by Xcode. Deterministic tests cover successful mapping, an already
  hardware-shaped UDID, missing devices, and ambiguous mappings. This fixes
  destination selection; it does not substitute for executing the focused
  physical approval XCTest.
- **Product evidence infrastructure:** the product-parity workflow is absent
  from `main`, and the repository has zero registered self-hosted runners.
  The strict product validator cannot produce the required P-01 through P-40
  environment receipts until the workflow is landed and those runners exist.

### Historical exact-head Release/Nightly verification - 2026-07-18 (source `70ab4eb0b9`)

- **Exact-head Release:** run `29646670068` completed successfully at
  `70ab4eb0b9e66394d709dac246296a3b050e8a3f`. x86_64 job `88086012965`,
  aarch64 job `88086012972`, and aggregate job `88089349146` passed native
  package construction, DEB/RPM/Arch ownership/install/uninstall, packaged
  daemon, desktop/tray/accessibility/route sessions, final verification, and
  signed closure. The evidence artifact is `8430648757` with zip digest
  `sha256:30d67cc9ff465206bdc0a38dad1f0aa910b3a4c7f2205ef811175b37976da13b`.
  Update/rollback/data-preservation remains explicitly **blocked** because no
  compatible previous same-architecture package was supplied; the prerelease
  workflow allowed that blocked lifecycle but did not certify it.
- **Exact-head Nightly:** run `29646670763` completed successfully at the same
  source head. Matched macOS/Linux soak and the runnable Ubuntu GNOME/X11 job
  passed; Arch/wlroots, GNOME Wayland, and Fedora/KDE were recorded as explicit
  blocked rows. Ubuntu GNOME/X11 passed all nine Linux Swift
  suites (**414/414**), npm install/test/build, the real packaged daemon and
  19-route AT-SPI/Orca/keyboard/200%-zoom session, onboarding and text-
  expansion flows, and shell smoke. `route.navigation` p95 was `95.6 ms`
  across 33 samples versus the `120 ms` budget; matched workload and resource
  checks passed. The wrapper transcript ends `linux-desktop-session-ok` with
  no shell failure summary, confirming the root-owned transcript fix.
- **Route-performance and evidence follow-up:** source commit `fb20c38dc2`
  adds the packaged-only route-body skeleton and two-frame/idle hydration
  boundary, preserving eager fixture/browser behavior; the fresh X11 evidence
  proves the route budget is now below threshold. The follow-up wrapper change
  treats transcript normalization as best-effort when a root-owned bind-mounted
  file returns `EACCES`/`EPERM`, retaining the raw evidence without converting a
  passed packaged session into a false shell-smoke failure.
- **Physical iPad:** the paired iPad preflight passed again (Xcode device ID
  `00008132-001158191E9A401C`, CoreDevice ID
  `407C0B12-010B-5970-8E85-D0E43DA8F457`). A focused seven-selector approval
  build reused the existing cache and FFI, but the hygiene guard stopped it at
  `10,428,780 KB` / `9.94566 GiB` before XCTest discovery. The log contains no
  `Test Suite` or `Executed` markers; exit `143` is a guard stop, not an app
  result. No iPad XCTest method is promoted.
- **Production and VM state:** cached Firebase CLI auth lists 152 functions,
  but production is drifted from this parity head (`d6f3098...`); the Linux
  App Check/trust callable set is not deployed at this head. UTM now has the
  `OpenBurnBar Linux` guest registered and reachable at `192.168.64.5` over the
  existing SSH key. The guest is Ubuntu 24.04.4 ARM64, but its installed
  `openburnbar-daemon.service` is crash-looping with exit `127`: the service
  still points to `/usr/local/bin/openburnbar-daemon`, whose `libsqlcipher.so.0`
  is missing. The package-owned `/usr/bin/openburnbar-daemon` has its bundled
  native library, but no live daemon health or installed-product receipt is
  promoted until the VM launcher is repaired and rechecked.
- **Certification boundary:** the fail-closed ledger remains **0/40 product**
  and **0/7 environment**, with `productParityClaim=false`. The Release pass is
  an engineering/release signal, not promotion. Production callable parity,
  physical approval execution, four unproven desktop environments plus the
  broader architecture/keyring/portal rows, installed IME/SmartHub/Mercury/
  Computer Use/accessibility/performance/update receipts, and current-head
  validator promotion remain open. The fresh X11 gate is now clear; remaining
  P-32/P-37/P-38 work is broader environment and promotion evidence.

### Historical source follow-up - 2026-07-18 (source `63f23dcfb1`)

- **Lifecycle discovery:** `b6d662d503` and `63f23dcfb1` add
  `resolve-linux-previous-release.mjs`. Automatic selection now requires a
  complete two-architecture asset/provenance matrix and inspects each Debian
  payload for the exact package identity and
  `/usr/libexec/openburnbar-daemon-launch`. The live resolver rejected
  `linux-v0.1.0` with explicit missing-asset reasons; it did not select or
  download an incompatible baseline. A compatible historical package is still
  required for update/rollback/data-preservation certification.
- **Environment evidence integrity:** `84a34432ed` binds ready environment
  receipts to declared support-row identity and independently detected Linux
  OS, architecture, desktop, and session, and rejects malformed current-head
  inputs. The focused validator/matrix lane passed **38/38**.
- **Physical iPad build hygiene:** `dbdfb5b8f1` adds an opt-in,
  scratch-root-only SPM cache prune that retains static Sentry and removes
  unused binary variants before XCTest. Preflight/prune contracts passed; no
  device XCTest method ran, so iPad approval remains unproven.
- **Local fixture hygiene:** `e85d38acc7` marks absent historical DEB/RPM
  archives as explicit external-evidence skips while retaining full assertions
  when CI supplies the archives. The combined executable contract lane passed
  **69/69** with **2** explicit fixture skips; workflow wiring passed **44/44**.

### Historical continuation delta - 2026-07-17 (superseded by the exact-head verification above)

- **Current source checkpoint:** `85b167205` carries executable Linux Computer Use
  and remote-engine behavior suites, replacing the two Linux compile-only
  placeholder paths. The manifest now declares **9 suites / 92 minimum tests**;
  platform fallback `LinuxEmptyTests.swift` files remain excluded from the
  Linux execution graph.
- **Update and notification hardening:** `85b167205` adds strict Arch
  (`pacman`) package-channel detection, signed artifact selection, typed bridge
  decoding, and fail-closed install/rollback guidance. `a852af8c5` rejects
  orphan notification payload arguments and prevents aliases from targeting
  unregistered shell routes. Focused Rust/TypeScript/Node regressions pass;
  installed package/update and desktop-host receipts remain open.
- **P-39 source checkpoint:** `dd7c588db` adds a real P-39 differential parser
  producer. It writes and validates the committed macOS golden corpus, checks all
  26 fixtures across 15 parser families, rejects synthetic payloads, and binds the
  producer output to the candidate head/version/host. The focused producer suite
  is **45/45**; this is source evidence, not a product receipt.
- **Onboarding source checkpoint:** `29fa77791` makes the daemon's canonical
  provider catalog a required first-run invariant. Empty provider catalogs now
  block onboarding rather than presenting a false completed state; actor-level
  coverage is present. The focused Linux package compiles, while macOS cannot
  launch the XCTest bundle here because the existing SQLCipher framework is
  unavailable at `@rpath`.
- **Latest candidate:** run `29546157464` at `46425c540` passed both signed
  architecture shards, aggregate finalization, and the installed P-40 RPC proof.
  Aggregate digest: `sha256:6fccc6bf0bb7450b4ee1d95cc633cf68ab6769dfc5ddf0b2bc95bb55b6461b59`.
  The branch has advanced since that candidate, so it is historical until a
  fresh exact-head candidate is produced.
- **Nightly matrix:** run `29546158468` passed the matched macOS/Linux workload,
  Wayland portal, Arch/wlroots, and Fedora/KDE jobs. Ubuntu GNOME/X11 shell job
  `87787948444` failed its Docker desktop smoke/evidence/performance wrappers,
  while the Linux Swift suites passed (**7 suites, 325 tests, 0 failures**).
  The failure was not diagnosable from the retained artifact because hidden
  `.linux-evidence` files were not uploaded; the parity lane is adding hidden-file
  retention and a structured shell failure summary before rerunning the job.
- **Certification boundary:** the strict ledger remains **0/40 product** and
  **0/7 environment**, with `productParityClaim=false`. A non-certifying source
  maturity estimate is approximately **68%**; it must never be confused with
  the evidence score. Remaining work is current-head candidate production,
  production callable deployment, real iPad approval execution, six remaining
  Linux environments, installed Computer Use/Mercury/SmartHub/IME/keyring/
  accessibility/performance receipts, update/rollback proof, and promotion of
  all 40 requirement receipts.

### Latest CI correction - 2026-07-17

- **Nightly run `29587742846`:** macOS and Linux matched-performance jobs and
  the three blocked-environment records passed. Ubuntu GNOME/X11 executed all
  **325** Linux Swift tests but failed
  `ComputerUseServiceRunBindingTests/testExpiredSessionReleasesRunBindingBeforeRestart`.
  The failure happened before shell smoke, and no diagnostic artifact was
  uploaded because the Swift runner wrote its results inside the Docker
  container rather than the host evidence tree.
- **Correction:** `09e6050d9` mounts the host evidence directory into both PR and
  nightly Swift-test containers, routes results to
  `/evidence/linux-swift-tests`, uploads hidden evidence, and adds mutation tests
  so the wiring cannot regress. Fresh nightly run `29607854309` is exercising
  this correction; the failing XCTest remains open until its retained log is
  reviewed and the test passes on the Linux runner.

### Latest source hardening - 2026-07-17

- **Expiry race:** `6ef6794ea` coalesces Computer Use teardown, makes polling
  and run lookup await revocation, and prevents a replacement browser run from
  racing the old coordinator's cleanup. It directly addresses the X11 failure
  named above; the existing regression test remains unchanged.
- **Linux test coverage:** `9db5cca26` adds four real analytics behavior tests;
  `d846c95d0`, `7349007e2`, and `4925d258d` put the target back into the Linux
  Swift graph with an explicit source name. `9cee2687a` and `33e3bb59b` add
  deterministic Computer Use and remote-engine behavior suites. The contract
  is now **9 suites / 92 minimum tests** instead of silently excluding those
  targets.
- **P-07 certification guard:** `bf30c881a` adds a fail-closed
  `feature.computer-use` validator and three mutation tests covering candidate,
  HEAD, target, rejection-policy, dependency, and source-hash binding. Commit
  `5e6241275` makes the mutation suite mandatory in the PR parity gate. These
  are source/contract improvements; no product receipt is promoted.
- **Linux compile correction:** The first exact-head release attempt exposed
  Swift's inability to infer the `nil` branch of the shared halt task on Linux.
  `a10733cdd` supplies the explicit `Task<ComputerUseSessionEndRecord?, Never>`
  type; the next candidate must prove both architectures compile before any
  installed receipt is considered.
- **Desktop shell hardening:** `9d8b0895e` normalizes padded and
  case-insensitive `openburnbar://` startup arguments without silently routing
  malformed links to Overview. `7f2a4cdd4` makes text expansion fail closed when
  secure-field state is unknown and treats daemon `ready` as an active engine.
  `c7bbd4ed6` enforces typed SmartHub payload shapes and kills helper process
  groups on cancellation, timeout, oversized output, or wait failure. Focused
  Rust/TypeScript regressions are present; installed desktop receipts remain
  open.
- **Linux XCTest discovery correction:** `832a9b0d2` removes `@MainActor` from
  the Linux analytics behavior test target so Swift XCTest discovery can cast
  generated methods on Ubuntu aarch64. The preceding nightly caught the
  runtime discovery crash; the focused source parse is green and a fresh
  exact-head nightly is required before the Linux suite is considered passed.

### Latest verification delta — 2026-07-14

- **Source implementation:** the Linux parity wave is integrated on `95cd65c235`; the focused source gates previously passed at **287 Swift**, **95 Tauri Rust**, and **693 frontend** tests, and the current release/evidence contract slice passes **34/34** tests (receipt: `evidence/parity-audit-2026-07-10/linux-source-tests-2026-07-14.json`). The release toolchain now pins Node `22.23.1` with per-architecture SHA-256 verification. These are engineering signals, not product attestations.
- **UTM Linux:** Ubuntu 24.04.4 aarch64 GNOME/X11 installed `.deb` smoke passed with authenticated daemon health and clean shutdown. The receipt is tied to an earlier source commit and remains explicitly non-certifying. The corrected RPM path was separately reproduced with valid metadata, `Requires: libsecret`, `rpm2cpio` exit 0, and signed-manifest extraction.
- **Release candidate:** run `29342758329` failed in native package preparation on both architectures because Tauri's generated RPM was rejected by `rpm2cpio`; `b325c76eb8` corrected that path. Follow-up run `29346971968` completed both native builds and DEB/RPM preparation but failed in the Arch `makepkg package()` step on both architectures; its diagnostic receipt is `evidence/parity-audit-2026-07-10/linux-release-candidate-29346971968.json`. An Arch packaging repair and fresh exact-head candidate are required before any release claim.
- **Physical iPad:** the connected iPad focused suite produced **46 passes** and **one XCTest infrastructure crash**, with no app/fake-provider frame. The approval selector is therefore blocked by test infrastructure, not counted as an app pass; see `evidence/parity-audit-2026-07-10/ipad-approval-focused-2026-07-14.json`.
- **Certification:** strict status remains **0/40 product** and **0/7 environment**, with `productParityClaim=false`. Current-head installed evidence, deployed production callables, approval execution, Browser Computer Use, Mercury, SmartHub, IBus/Fcitx, accessibility, performance, reliability, and the seven-environment matrix are still required.

### Latest verification delta - 2026-07-15

- **Release candidate:** first-attempt run `29401347808` passed at exact head
  `a91132e059c3400029cabd1a7e14f63d79006066`. The resolved immutable
  `linux-release-evidence` artifact is
  `sha256:73b1a0c638ef58a4b28e310dbdcbd8912515f7693c838118a3aa7b8559ac8f22`;
  x86_64 and aarch64 package/runtime/accessibility/tray/route shards passed.
- **UTM installed proof:** the signed arm64 Debian candidate was installed in
  Ubuntu 24.04 GNOME/X11 aarch64 UTM. The package-owned launcher selected
  `/usr/bin/openburnbar-daemon`, the isolated authenticated socket came up,
  and the real P-40 inventory/deletion/export/retention RPC producer passed.
  The candidate-bound session is recorded in
  [`P40_UTM_EVIDENCE_RUNBOOK.md`](P40_UTM_EVIDENCE_RUNBOOK.md) with session
  SHA `ea8f8d4ab8aadac1bcbe5e83090f22900c5845052246f652bce3fbeb3556337f`.
- **Certification boundary:** this closes one installed P-40 proof surface,
  but it does not promote the ledger. The canonical state remains
  **0/40 product requirements** and **0/7 environment receipts**, because
  validator receipts must be generated and promoted on a clean current HEAD;
  the other six P-40 environments and the remaining requirement rows still
  lack installed evidence.

### Latest verification delta - 2026-07-16

- **Exact-head release candidate:** run `29475397312` completed successfully
  at `a8fb43090f1afd1cb18b1338c7f6e99e96d36ff8`. The immutable aggregate
  `linux-release-evidence` digest is
  `sha256:33df8b7d9fdbe85e1db9c36003e3681f10d78506d24f71113b95fdab1fcace6e`;
  both signed architecture shards passed the native build, package,
  installed-runtime, accessibility, tray, and route sessions.
- **Candidate-bound UTM P-40 proof:** Ubuntu 24.04 GNOME/X11 aarch64 installed the
  exact arm64 Debian package (`sha256:
  1c8e187ccf7f264954cde7b7aec4e64ce186d16c26ddb2cef149a9c61715cce9`). The
  installed manifest is bound to `a8fb43090f1afd1cb18b1338c7f6e99e96d36ff8`
  with SHA-256
  `0410282de4169eb2d6fe9266f17b87172595fe26f762bfc3259907e48f056f45`.
  The real installed daemon producer passed inventory, scoped deletion,
  encrypted export, retention, malformed-store fail-closed, and idempotency
  checks; the redacted session report SHA-256 is
  `fef96b38e8a96b0b86161a559e8e9de9d1486994ec402b862fdc2d97c88920a2`.
- **Physical iPad attempt:** the iPad was available and paired, but the
  canonical approval selector exited 66 before `xcodebuild` because
  `Vendor/OpenBurnBarSignalFfiIOS.xcframework` is absent. No app test or
  infrastructure crash is counted; the attempt is a non-certifying blocker.
- **Certification boundary:** the exact-head candidate and one live P-40
  environment are now current, but the strict ledger remains **0/40 product**
  and **0/7 environment**. Six Linux environments, current-head validator
  receipts for all 40 rows, production callable deployment, browser/approval
  execution, Mercury/SmartHub/IME/accessibility breadth, and update/recovery
  evidence are still required.

### Latest continuation delta - 2026-07-16

- **Credential custody:** commits `7b14c006c` and `292736fe4` harden the
  systemd-credential fallback with strict credential-ID/path validation,
  `O_NOFOLLOW`/owner-only regular-file checks, bounded UTF-8 single-line
  values, dynamic `systemd_credential` trust metadata, and redacted reader
  failures. Focused macOS security tests pass **28/28**; Linux-only runtime
  permission/symlink execution remains an environment receipt.
- **SmartHub:** commit `ac62e6b4d` bounds Avahi discovery with concurrent
  output draining, a 24 KiB transcript cap, a 4-second default timeout
  (0.1-10 seconds from CLI), termination/SIGKILL fallback, and typed
  `status`/`blocker` outcomes surfaced in the Linux renderer. Focused UI and
  decoder tests pass **15/15**; Linux source/tests compile, while the UTM
  Swift linker is blocked by its pre-existing `libswiftObservation` runtime
  mismatch. Live device/Avahi proof remains open.
- **Production Computer Use gate:** commit `0fe51cc1e` adds a tagged-release
  post-deploy catalog check for all six Linux App Check callables. A live
  `firebase functions:list --project burnbar --json` check currently fails
  closed because all six callables are absent from production; no direct
  deploy was attempted outside the tag-bound workflow.
- **Physical iPad:** Alberto's iPad (`00008132-001158191E9A401C`) was used for
  a fourth focused approval attempt. Xcode reached dependency compilation but
  was stopped at **9.5 GiB** before XCTest execution to honor worktree disk
  hygiene; the cumulative receipt records four non-certifying attempts and
  **0 app tests executed**.
- **Account/cloud erasure:** commit `6329d8244` adds the typed
  `daemon.account.cloud_data.delete` RPC, daemon-owned trusted-device
  authorization delegation, redacted transport errors, and a confirmation /
  retry surface in Linux Settings. The focused bridge/settings suite passed
  **96/96**, with TypeScript, Cargo, IPC-canon, Swift-parse, and formatting
  checks green. The production authorizer remains fail-closed until the
  trusted-device bridge and deployed callables are available; no installed
  deletion receipt is claimed.
- **Strict status:** the ledger intentionally remains `productParityClaim=false`,
  **0/40 product requirements ready**, and **0/7 environment receipts complete**.
  Source progress is not a release percentage; current-head candidate,
  production deployment, iPad approval, six remaining Linux environments,
  and the installed backend/accessibility/performance matrix are still required.

### Latest source deltas - 2026-07-15 continuation

- **Native chat attachments:** `dcca8b74b4` adds daemon-catalog capability
  lookup for PNG/JPEG/WebP/PDF inputs, provider-native content payloads,
  bounded per-model byte limits, and fail-closed UI preflight before upload or
  durable append. Text attachments retain the existing UTF-8 path; unsupported
  or unknown binary capabilities preserve the draft and staged file. Focused
  chat/bridge/UI tests and the full Linux Tauri unit suite pass; installed
  provider/backend receipts remain open.
- **Credential first-use reliability:** `dcca8b74b4` treats a missing
  Secret Service probe item as healthy on a freshly unlocked keyring while
  continuing to fail closed for locked, unavailable, or D-Bus-error states.
  The Linux security target build and direct behavior harness pass; live
  GNOME/KDE/headless keyring and recovery receipts remain open.
- **Native startup packaging:** `dcca8b74b4` installs the canonical XDG
  autostart entry in DEB/RPM/Arch packages and honors `--background` only when
  the tray initializes, with focused packaging tests and 102/102 Tauri Rust
  tests passing. Installed desktop-environment persistence and tray/update
  receipts remain open.
- **Candidate freshness:** because these source changes advance the head past
  `32f3988558`, the previous candidate run `29421777733` and its P-40 receipt
  are historical evidence only. No new source claim is promoted until a fresh
  candidate is built, installed, and validated against the final documentation
  head.
- **Release preflight repair:** candidate `29429549029` exposed that the
  native archive verifier allowed only `/usr`, so both architecture shards
  rejected the intentionally packaged `/etc/xdg/autostart/openburnbar.desktop`
  before signing. `646270227e` adds a single exact non-`/usr` allowlist entry,
  extracts only that path for Arch verification, and binds its checksum/source
  slot through the AUR metadata generator. The focused release suite is
  **36/36** (one root-toolchain skip); a fresh exact-head candidate is still
  required.
- **Release candidate `29432186379`:** the x86_64 shard reached package
  preparation and correctly rejected the archive's `etc` parent directory
  entries because the first allowlist repair accepted only the leaf; the
  aarch64 shard independently failed earlier while Ubuntu could not fetch
  toolchain packages from `ports.ubuntu.com`. The source fix now permits only
  the exact autostart path and its required parent directories, with the
  sibling/path-traversal rejection tests still green. This run produced no
  candidate artifact and remains non-certifying; a fresh exact-head run is
  required.
- **Release candidate `29434274277`:** after the parent-directory repair,
  x86_64 still rejected the same autostart parent because DEB/RPM extraction
  had not received the shared non-`/usr` allowlist; aarch64 again failed on the
  independent Ubuntu package-mirror outage. The shared extractor now applies
  the exact autostart exception to DEB, RPM, and Arch, and the real-tool
  fixture asserts the `/etc/xdg/autostart` payload for DEB/RPM when the root
  toolchain is available. This run produced no artifact or certifying receipt.
- **Toolchain mirror hardening:** repeated ARM preflight failures were traced
  to plaintext Ubuntu mirror connectivity, not package or source behavior. The
  pinned Docker toolchain now rewrites Ubuntu archive endpoints to HTTPS before
  apt installation, with a regression contract in
  `linux-toolchain-node-runtime.test.mjs`; the next candidate must prove both
  architectures through the same image.
- **Release candidate `29436469591`:** both architecture shards cleared the
  HTTPS mirror/toolchain stage, confirming that reliability repair, then failed
  during installed-manifest generation because the inventory still rejected the
  intentionally packaged `/etc/xdg/autostart/openburnbar.desktop` as a
  non-`/usr` file. The run produced no artifact or certifying receipt. The next
  source fix must share the exact autostart allowlist with manifest generation
  while retaining parent-directory, ownership, and sibling/path-traversal
  rejection, followed by a fresh exact-head candidate.
- **Release candidate `29438744035`:** both architecture shards built their
  toolchains, then failed closed in `bundleRpmFromDeb`: DEB re-extraction and
  the RPM spec path validator did not receive the canonical non-`/usr`
  allowlist, producing `native package archive member is outside /usr: etc`.
  No artifact or certifying receipt was produced. The next fix must wire the
  shared allowlist through the RPM rebuild path and rerun both architectures.
- **Release candidate `29440745769`:** both architecture shards cleared RPM
  and installed-manifest generation and reached Arch preparation, then failed
  in `build-signed-arch-package` with `The path argument must be of type string.
  Received undefined`. The root cause was a missing `AUTOSTART_DESKTOP` to
  `openburnbar-autostart.desktop` mapping in `commonNames`. No artifact or
  certifying receipt was produced. The next fix adds that mapping and a source-
  input regression test before rerunning both architectures.
- **Release candidate `29442734074`:** both architecture shards produced and
  verified signed native artifacts, then failed during live package-ownership
  smoke for DEB/RPM because the verifier still rejected the canonical
  `/etc/xdg/autostart/openburnbar.desktop` as a non-`/usr` path. No shard
  artifact or certifying receipt was retained. The next fix must extend the
  live installed-ownership verifier to the shared exact allowlist and add
  focused coverage before rerunning both architectures.
- **Release candidate `29445148032`:** both architecture shards fully passed
  signed package installation, live ownership, update/rollback, and desktop-
  route sessions and uploaded their evidence. Aggregate finalization then
  rejected the manifests because the canonical JSON schema still required
  every file path to start under `/usr`; the exact
  `/etc/xdg/autostart/openburnbar.desktop` record failed that check. No
  certifying receipt was produced. The next fix must add an exact regular-file
  exception to the schema while keeping symlink paths `/usr`-only, then rerun
  aggregate validation.
- **Exact-head candidate `29448108187` at `ccd9bb3061fc486c06476ccbd75182647927ff41`:**
  both architecture jobs and aggregate finalization passed with immutable
  `linux-release-evidence` digest
  `sha256:f9d44744b153c4ac33bc09fe743b27529cb1300f8e55e8ed4cfd0ac0c36ff017`.
  The exact arm64 DEB was installed in UTM Ubuntu 24.04 GNOME/X11; its signed
  manifest SHA-256 is
  `441a42936344b61a8f63898278efe3a30efc7d3f9d083537f826cc0e5cbac59f`.
  The corrected live P-40 producer passed all checks, with session receipt hash
  `ddfac322b43cfde7d743c69ae14e1ed13b546f3281472882063664ecf10101cf`.
  The candidate-bound artifact digest is the release-evidence digest above,
  not the package digest. This closes one P-40 installed proof surface only;
  the strict ledger remains **0/40 product** and **0/7 environment** until all
  validator and environment receipts are promoted.

- **Onboarding hardening:** `238ee56975` validates every daemon snapshot before
  renderer/cache mutation, preserves the last valid state on malformed or
  forged responses, exposes `aria-busy` during active actions, and passes the
  focused onboarding/App suite (**27/27**). This is source evidence only; the
  installed Secret Service, provider, portal, and first-data probes remain
  unreceipted.
- **Linux Computer Use system path:** `4423a0934d` adds a daemon-owned,
  session-scoped Wayland RemoteDesktop manager. It obtains consent only after
  normal Computer Use approval, reuses the broker handle for subsequent
  actions, removes revoked handles, and closes grants on panic, entitlement
  revocation, or session teardown. Linux-only runtime/compositor receipts are
  still required, and no receipt is promoted by this source change.
- **Mercury viewer:** `56af093923` adds a shell-local GStreamer capability
  probe for VP9, `autovideosink`, and PipeWire factories plus an explicit
  no-GStreamer stub state; the no-GStreamer contract and Tauri tests pass
  (**98/98** combined). The release path is now wired to compile
  `--features media-gst` and declare GStreamer runtime dependencies, but
  GStreamer-enabled builds and two-device screen-share receipts remain open.
- **Chat attachment boundary:** `702f59146e` adds extension-derived MIME
  canonicalization and a preflight that rejects unsupported PDF uploads before
  daemon append/upload, preserving the draft and staged attachment. The
  provider-native binary/PDF contract and installed chat receipts remain open.
- **Provider catalog hydration:** `d7cffc79d6` makes the Linux bridge fetch
  `daemon.config.get` and the canonical `daemon.catalog` separately, preserving
  an explicit config-only degraded state when catalog lookup fails. Live
  credential routing/failover and installed lifecycle receipts remain open.
- **Wayland-safe pet fallback:** `3b652f9b9e` adds bounded pointer/mouse drag,
  Arrow/Home keyboard movement, focus metadata, and live status announcements
  to the contained fallback without claiming desktop overlay or click-through.
  Native compositor/window-manager receipts remain open.
- **Linux candidate compile repair:** exact-head candidate run
  `29417386163` failed both architecture shards because the public
  `LinuxComputerUseInputSessionManager` default referenced an internal adapter
  initializer. `4b1126bfdf` adds a public production no-argument initializer
  while retaining the injected test initializer as internal; the replacement
  exact-head candidate is required before release evidence can be counted.
- **Windows shared-core portability repair:** PR #1691's Windows x86_64 and
  aarch64 jobs exposed a Swift overload difference in the shared Hermes
  transport: the Windows Foundation overlay selected the zero-argument
  `AsyncThrowingStream` unfolding initializer instead of the continuation
  builder. `dd864a90be` selects the continuation initializer explicitly with a
  buffering-policy label and typed continuation. The same Windows
  FoundationNetworking surface lacks `URLSession.bytes(for:)`, so
  `8dd319a5e3` routes Linux and Windows through buffered `data(for:)` SSE
  parsing; the macOS package build passes and fresh Windows checks are
  required from the final documentation head.
- **Current candidate and nightly runs:** the replacement exact-head Linux
  release candidate and nightly matrix will be dispatched after this
  documentation checkpoint is frozen. Prior runs from `dd864a90be` were
  cancelled because later commits made them stale; no evidence is bound to
  those runs.
- **Certification boundary:** despite these source slices, the canonical
  ledger remains **0/40 product requirements** and **0/7 environment receipts**
  with `productParityClaim=false`. A source test count is not a product or
  environment attestation.

| Slice | Current state | Scope and limit |
|---|---|---|
| P26 tray/deep links | PR #1649, merge-clean | Native tray routes, refresh/reconnect actions, and validated deep-link routing; does not certify every desktop host. |
| P27 notifications | PR #1651 + `07153ac3d5`, merge-clean | Bounded native `notify-send` adapter with typed failures plus typed freedesktop `open`/`reply` actions; Reply preserves intent, opens chat, and focuses the composer without pretending to provide macOS inline notification text input. Actionable host receipts and lifecycle proof remain open. |
| P35 diagnostics | PR #1653, checks in progress | Metadata-only diagnostics preview/export, redaction and `0600` enforcement; installed support workflow remains open. |
| P23 provider/model workspace | PR #1655 + integration `e0451afa5e` + provider mutation lane | Canonical daemon catalog/config mapping, strict model provenance, health and failover state, provider/model workspace, config-derived chat backend availability gates, and daemon-backed custom-model add/remove with fixture-safe local behavior; credential custody, live routing, and installed lifecycle remain separate. |
| P16 account/enrollment posture | PR #1658 updated + integration `01784940c5` | Daemon-owned account status, sign-out, rejected-identity recovery, and context-aware generation/bridge fences now decode transitional phases fail-closed; stale responses cannot overwrite a newer identity or busy state. Device ID/fingerprint copy actions and trusted-iPad guidance are present. Trusted-device list/approve/revoke remains a native mobile/Firebase boundary, and cloud backup remains unavailable. |
| P12 quota account switching | PR #1659, stacked on P23 + `be375903f0` | Redacted credential-slot selection through canonical config get/update now includes a preferred provider account selector, explicit daemon auto-routing reset, fixture coverage, and fail-closed read-only behavior when `config.update` is unavailable; does not provide cloud account or trusted-device management. |
| P13 onboarding first-data probe | PR #1667 updated + `238ee56975` | Provider setup now loads the daemon catalog and submits a credential once through native Secret Service storage, clears the web-view field, and keeps completion daemon-authoritative. `238ee56975` validates every daemon snapshot before renderer/cache mutation, preserves the last valid state on malformed or forged responses, and adds `aria-busy` coverage (**27/27** focused onboarding/App tests); OAuth-only auth, portal consent, and desktop integration remain open. |
| P14 chat approval/citation boundary | PR #1662 + integration PR #1691 | Gateway tool cards now carry daemon-issued approval IDs and support approve/reject/cancel with terminal-state and single-flight handling. Bounded citations normalize safely, focus/open the originating thread when available, and fail closed for unavailable sources; daemon-authoritative full-history export/resume and the browser/Tauri pop-out boundary are implemented, while installed reconnect/export/resume proof and remaining backends remain open. |
| P17 activity/session depth | PR #1661 + PR #1685 + integration PR #1691 + `c1f6e69514` + `7ae2412143` | Canonical daemon-backed search/detail/resume with indexed transcript excerpts and bounded persisted body replay are integrated. Native resume uses the existing `run.resume` contract with provider-safe handoff fallback; full-history export now re-reads bounded usage rows and verified replay bodies while preserving source/provider/session/project identity, and fails closed to a typed unavailable state when proof is incomplete. Replay/resume now require a verified daemon `sourceID` and never fall back to a usage-row identifier. Installed source-resolution and resume-from-export evidence remain open. |
| P21 insights workspace | PR #1669 + integration `5ddd81245d` + `b3002ab3f9` + `825e081bda` | Provenance-labeled brief now sits above a selectable three-pane canvas/library/inspector workspace with trend, provider, model, and cache widgets, account-scoped persisted selection/density, validated evidence IDs, bounded audit disclosure, refresh, a daemon-owned `daemon.usage.insights` qualitative/citation response using local rules and bounded usage rows, and a chat follow-up composer. Installed evidence and comparison against the macOS qualitative workflow remain open. |
| P24 settings inventory | PR #1665, merge-clean | Restores Model Proxy, Computer Use, and Pets destinations for a 16-tab searchable inventory with honest capability routing. |
| P28 SmartHub | PR #1668 + integration PR #1691 | Typed root-owned CLI allowlist now validates request IDs, bounds JSON depth/items/strings/output, drains stdout concurrently, enforces an 8-second timeout, and supports cancellation/degraded renderer states; live device/Avahi outcomes remain separate. |
| P29 text expansion | PR #1663 + integration PR #1691 + `6c76df084f` + `1ddc8bc33a` + `274f67fba0` + `9598c0b9e8` + `d2dbbe8df8` | Daemon-owned AES-GCM sealed snapshots use native Secret Service/KWallet key custody, consent RPC, owner-only permissions, corruption/tamper fail-closed behavior, and in-app-only Composer expansion without renderer localStorage/global capture. Live renderer controls remain disabled with explicit degraded copy until daemon storage hydration succeeds, including missing-storage and error paths. `274f67fba0` adds a bounded, explicitly opted-in, signed IBus/Fcitx engine manifest/registration gate; `9598c0b9e8` adds typed engine status/start/stop RPC and a Tauri bridge; `d2dbbe8df8` adds trigger-only JSONL expansion requests with strict response bounds, secure/excluded/uninspectable denial before write, cancellation/timeout/kill-switch teardown, and no keyboard/clipboard/surrounding-text payloads. It still does not claim Linux keyring/IME runtime receipts, sync, or installed secure-field proof. |
| P18 memory authority | PR #1671, merge-clean | Live memory inboxes now remain daemon-authoritative; stale renderer status cannot resurrect or hide live items; first-class quarantine and cross-device review remain open. |
| P19 projects depth | PR #1670 + PR #1688 + `9598c0b9e8`, source stack green | Canonical project list/get/upsert plus typed delete/reassign lifecycle, fail-closed slug/id/alias validation and collision handling, durable reference migration across reviews/questions/followups/missions/simulators/nested takeover history, deleted-slug tombstones, checkpoint/journal-tail replay protection against resurrection after a crash, detail/register/edit UI, confirmation, and visible error recovery; installed proof remains open. |
| P20 missions depth | PR #1677 + `bd9d6a5173`, source checks green | Canonical mission get/cancel, typed packet/result/evidence/burn/takeover/PR snapshot mapping, freshness, expandable detail, and a daemon-owned `daemon.mission.health` RPC with typed health/history, stable event IDs, active/failed counts, and UI rendering are integrated; live mission integrations and installed proof remain open. |
| P25 updates | PR #1673 + integration `4a2138897c` | Signed-feed freshness, exact package-channel/architecture selection, shell/daemon compatibility, and fail-closed package/download guidance now disable generic AppImage and downgrade fallbacks when no verified artifact exists; valid public feed and installed rollback remain open. |
| P30 pet companion | PR #1674 + integration `9a527310f9` + `ea82fe5140` + `5c3caab2e` + `2b85f1431` | Native runtime-manifest probe replaces optimistic environment detection; contained fallback now supports accessible summon/focus/status and selection/clear controls with explicit action state. `ea82fe5140` adds a real Tauri companion child window on X11 with explicit focus and click-through toggles; `5c3caab2e` adds the typed X11-only `Ctrl+Alt+Super+P` summon event and `2b85f1431` exposes its accessibility metadata. Wayland and unknown sessions remain degraded and the native overlay still needs compositor-installed proof. |
| P40 data/privacy | PR #1672, `4cdc505537`, `9598c0b9e8`, `7c8a214ce6`, `825e081bda`, `cba9266277` | Daemon-backed telemetry/privacy/cloud-sync writes with pending/error states, plus a daemon-owned, allowlisted local-store inventory and preview/execute deletion contract wired through typed RPC/Tauri and a confirmation UI for the proxy-route log and encrypted text-expansion store. `7c8a214ce6` adds selected-scope encrypted export with PBKDF2-HMAC-SHA256 100k, AES-GCM authenticated headers, owner-only bounded output, race/path/permission checks, and passphrase clearing. `cba9266277` adds bounded age/size retention rules with fail-closed policy validation and atomic trimming limited to the same allowlist. Account erasure, full transcript/account export, recovery-key workflows, native save-picker polish, and backend erasure receipts remain open. |
| P11 usage catalog | PR #1676, checks green | All 33 canonical provider identities and Swift discovery paths/patterns are contract-tested against the exact 27 ParserRegistry entries; four API-backed and two unavailable sources are labeled explicitly in Settings/onboarding; normalized corpus and runtime/install evidence remain open. |
| P14 exact chat threads | PR #1684 + integration PR #1691 + `0d8ee32526` + `618c7286b9` + `5fdcccabfa` | Canonical encrypted thread list/get/search, idempotent append, older-message pagination, strict Tauri decoding, durable send ordering, daemon-authoritative full-history JSON/Markdown export with bounded cursor/duplicate/size checks, exact model/thinking selection, daemon-owned bounded attachment refs, validated path-free attachment metadata in exports, citations, approval actions, and validated daemon re-read resume are integrated. Composer uploads bounded text documents through the daemon and persists path-free metadata; reconnect/visibility handling, functional options, and browser/Tauri pop-out boundaries are explicit. Uploaded bytes remain process-lived and require re-upload after daemon restart; remaining backends and installed reconnect evidence remain open. |
| P07 browser Computer Use panel | PR #1681, merge-clean | Typed navigate/screenshot/click/fill actions are bound to the selected run/call/generation and fail closed when the packaged capability is absent; physical-iPad approval, production credentials, and installed browser/panic/audit/restart evidence remain open. |
| P22 database inspection | PR #1680 + integration PR #1691 + `d191a1be5f` | Bounded daemon-owned code search/context packs with pagination and untrusted-source warnings remain integrated. SQLCipher-gated encrypted snapshots enforce owner-only paths, 512 MiB bounds, integrity hashes, atomic replacement, rollback, and watcher stop/reopen. A macOS-compatible v1 recovery bundle now uses salt16/PBKDF2-HMAC-SHA256 100k/AES-GCM, bounded atomic 0600 files, candidate-key verification, typed recovery status, explicit missing-database/device-transfer guidance, and native Secret Service/KWallet custody hooks; live Linux keyring/device-transfer and installed proof remain open. |
| P27 native startup/deep links | PR #1679 + PR #1686 + integration PR #1691 + `5f74018422` + `a5571694bb` | Strict membership/OAuth callback parsing, one-shot startup handoff, background tray startup, XDG autostart, package desktop registration, owner-checked per-user single-instance forwarding, normalized freedesktop notification actions, explicit route aliases, cold-start precedence, and additive per-binding shortcut health are integrated. X11 registration is independent per binding; Wayland/unknown sessions fail closed with typed backend states. Installed host integration remains open. |
| P31 accessibility preferences | PR #1683 + `7cd30e2e71`, merge-clean | Shared reduced-motion, prefers-contrast, forced-colors, focus, and status/alert contracts; reduced-motion now follows live OS preference changes with WebKitGTK legacy-listener cleanup; installed GNOME/KDE/AT-SPI/Orca/high-contrast evidence remains open. |
| P39 differential oracle | PR #1682, merge-clean | Same-schema normalization, credential redaction, explicit volatile-path handling, path-level diff output, and fail-closed exit codes; a same-commit macOS/Linux artifact run remains required. |
| Integrated Linux validation | PR #1691 plus commits through `b012a53a6c`, `5fdcccabfa`, `4cdc505537`, `dda966ff3a`, `573184422d`, `7ae2412143`, `1ddc8bc33a`, `be375903f0`, `274f67fba0`, `ea82fe5140`, `9598c0b9e8`, `d2dbbe8df8`, `bf0eb36294`, `bd9d6a5173`, `ffc0c58cd9`, `10babe9c30`, `814749c8be`, `4bc52a7961`, and `5a80e82b89`, current 2026-07-14 | Replayed the current P07/P11/P12/P13/P14/P16/P17/P19/P20/P21/P22/P23/P24/P25/P27/P28/P29/P30/P31/P35/P39/P40 source stack: TypeScript, production bundle verification, targeted mission/bridge/UI tests **108/108**, Tauri Rust **90/90**, RPC canon/formatting/suppression checks, bounded trigger-only text-engine lifecycle tests, consent-scoped portal input tests, daemon mission health/history contract tests, Mission Control replay/tombstone tests, privacy inventory/preview/execute contract tests, Linux privacy service **8/8**, Linux external text-expansion adapter **18/18**, peer-manifest **8/8**, portal input **26/26**, mission lifecycle **3/3**, and full Swift package **284/284** on Ubuntu 24.04 aarch64. The full Vitest run was attempted but host contention caused unrelated 5-second timeouts and one unhandled media fixture error; it is not treated as a green release gate. The macOS host cannot execute Linux-only Secret Service/KWallet/IBus/Fcitx/portal/input branches, and the broad Swift package build is also blocked by existing macOS-only Linux privacy exclusions and missing SQLCipher packaging. This is engineering evidence only, not installed-product certification. |

### Execution checkpoint — 2026-07-14 source integration

The current branch adds three more bounded source slices without changing the
certification ledger: `a5571694bb` exposes independent per-binding native
shortcut registration and typed X11/Wayland/unknown backend health;
`7c8a214ce6` adds encrypted selected-scope local privacy export; and
`825e081bda` wires the daemon-owned `daemon.usage.insights` response, local-rules
analysis, strict RPC canon, and renderer evidence mapping. `cba9266277` then
adds daemon-owned retention policy, bounded age/size enforcement, atomic
allowlisted trimming, and Settings controls. Verification on the macOS host is
**134/134** targeted Vitest tests, **92/92** Tauri Rust tests, TypeScript
typecheck, Core privacy crypto **3/3**, the retention bridge/Settings tests, Core
package build/test coverage for the new response, and a successful macOS daemon
product build.
The daemon XCTest bundle built but could not launch because this host lacks the
existing SQLCipher.framework runtime packaging. Linux-only service, keyring,
portal, compositor, and installed-candidate receipts still require a Linux
host; these source results do not advance the **0/40** product or **0/7**
environment certification totals.

The current source checkpoint is also proven by the live UTM Ubuntu 24.04
aarch64 guest: `swift build -c release --product OpenBurnBarDaemon
-Xlinker --allow-shlib-undefined` completed successfully from the current branch
commit `5a80e82b895c5d13de1432f9241128cadb17b6c8` (warnings only). The resulting
daemon was installed at `/usr/local/bin/openburnbar-daemon` and its exact
SHA-256 is recorded in the installed-runtime receipt. This is an installed
development binary, not a signed release package. The connected
physical-iPad launch/liveness/console receipt is recorded separately in
`docs/linux-port/evidence/parity-audit-2026-07-10/ipad-current-launch-2026-07-14.json`.

The same guest then ran the current Tauri client and daemon from root-owned
trusted system paths under GNOME/X11 for 25 seconds. The packaged launcher
started the daemon, authenticated `daemon.health` probes completed, and both
processes shut down cleanly. The exact hashes and capability limitations are
recorded in
`docs/linux-port/evidence/parity-audit-2026-07-10/utm-ubuntu-aarch64-installed-runtime-2026-07-14.json`.
This is a current installed smoke receipt, not signed-release or full-matrix
certification.

These slices reduce concrete gaps, but they do not change the NO-GO verdict:
transactional provider/auth onboarding, installed chat export/resume/pop-out
and remaining backends, cloud/device mutations, live recovery key-loss and
device-transfer flows, system Computer Use capture, Mercury two-device proof,
live SmartHub device evidence, IBus/Fcitx/global secure-field integration,
mission/session depth,
packaging/update rollback, and the seven-environment installed matrix remain
required.

### Windows comparator semantics

Windows parity is a real ship milestone, and the current ledger is **48/48
Real for F1 Ship Peer**. That is not a claim that Windows is behaviorally
identical to macOS in every native integration and installed environment:
Windows documents a separate **F2 True 1:1** finish line, and `100% parity`
means F2. This Linux audit uses that stricter macOS gold-standard contract:
each requirement also needs failure/recovery behavior, accessibility and
performance evidence, packaging and update proof, and current-head
installed-environment receipts. Windows remains the comparator for shared
product intent; its F1 result is not a substitute for macOS-native behavior or
Linux-native integration proof.

## Executive Summary

The Linux app now has a substantial production implementation: a 19-route Tauri
shell, all six persisted dashboard layouts, shared daemon RPC access, canonical
XDG path handling, live usage/quota data, missions, durable memory decisions,
database indexing/watch recovery, Browser Computer Use safety/routing foundations
plus capability-gated system-input primitives, and AppImage/deb/rpm
construction. The remediation wave also replaced the false-
green certification baseline, added Linux-native secret custody, moved gateway
authentication behind native proxies, introduced a runtime capability manifest,
added installed-app accessibility and matched-performance gates, and implemented
a signed update-feed verifier plus two-architecture release assembly.

The Browser Computer Use source safety boundary is materially stronger. Agent
browser tools now pause for an exact run/call/generation-bound Computer Use
session, then dispatch through the shared scope, approval, panic, Playwright,
and tamper-evident audit coordinator with no direct-Playwright fallback.
Exact-generation leases, terminal revocation, durable failure handling, and
Linux-only verification of fresh phone-signed action responses are implemented;
replay counters persist across daemon restart and fail closed if their store is
unreadable. Session-start intent signs the exact run, call, and generation.
Pin provisioning binds the source-device and transport-peer identities in one
atomic alias-set commit. Waiting sessions restore as unleased requirements;
an interrupted in-flight Browser action is instead durably failed as outcome-
unknown and can only be retried with a new call/generation. Every later action
in an already-bound session is checkpointed before external dispatch, so
restart cannot regenerate or redispatch it. The Linux surface lists waiting
runs, renders exact-session approval context, and retires only the exact
selected session after authoritative terminal state without mistaking a
transport failure for termination. The source now also has a daemon-owned
session-grant broker, versioned mobile challenge validation/signing on iOS and
Android, live iOS reception, and Android reception bound to the exact
authenticated iroh route with expiry-bounded foreground recovery,
native-only Tauri challenge custody, and a fresh peer-bound polkit desktop-owner
gate. A server-verified controller-route v2 registry now separates authority
bootstrap from renewable transport proof: bootstrap verifies the transport and
authority keys and advances generation, while an exact active tuple can renew
the lease with transport proof alone without changing generation. Authoritative
absence, expiry, revocation, and generation replacement close routes rather than
preserving stale access. iOS and Android publish and renew that protocol, and
the macOS host applies exact tuple, lease-extension, generation-replacement, and
lifecycle ownership policy. The Linux daemon now has the corresponding route
directory client and native iroh runtime composition for grant, approval, panic,
media, route teardown, metadata, and readiness. The renderer can neither submit
nor receive proof, signature, challenge, key, password, or forged authorization
fields.

This is still source closure, not an available release workflow. The Linux
release graph builds the Rust iroh shared library before Swift, compiles the
generated UniFFI bridge, stages the exact ELF in AppImage/deb/rpm/AUR payloads,
and fails closed when it is absent. The daemon now owns Google PKCE sign-in,
refresh-token custody, Firebase ID-token refresh, per-install Ed25519 App Check
identity, trusted-native enrollment approval, challenge signing, short-lived
App Check minting, account generation, sign-out, account-switch teardown, and
the controller runtime credential lifecycle. Local RPC status is redacted and
the renderer receives neither bearer material nor the authorization URL. A
dedicated production Firebase web app exists for Linux, and release validation
rejects missing or non-Linux App Check configuration.

The current authority packet also closes two reliability boundaries in source.
Account transitions are phase-tagged: once old-account teardown starts, a cancel
request is rejected instead of reporting a new account active while its runtime
is stopped, and successful sign-out re-enables a fresh browser sign-in. The
Functions challenge endpoint emits a bounded
`linux_device_approval_required` reason only for explicit pending approval.
The daemon polls only that state or a transient cloud failure; permanent device
rejection terminates immediately. Poll delays are capped at
15/30/60/120/300 seconds and then five minutes, limiting a continuously pending
device to 16 challenge requests in the first hour under the public 20/hour quota.

The remaining availability boundary is operational and must not be blurred:
the dedicated Google **Desktop app** OAuth client was provisioned on 2026-07-14,
and its public client ID, Firebase API key, and dedicated Linux App Check app ID
are now registered as GitHub release variables. The first exact-candidate
dispatch (`29341165795`) correctly failed closed on a version-metadata mismatch;
the branch metadata is now aligned to `0.1.1` and the later exact-head candidate
completed successfully.
Production is still drifted from the parity head: five App Check/trust
callables are active, while `mintLinuxAppCheckToken` is absent. Exact-head
release run `29635748727` passed both architectures and the installed
package/runtime sessions, but no current-head production callable proof or
physical-iPad approval execution exists. The iPad
approval surface is implemented against the exact nonce-bound trusted-device
signature contract. The assigned physical iPad is now connected and unlocked;
current-branch OpenBurnBarMobile 1.0.2 (build 82) installed, launched, stayed
alive for 29 seconds, terminated and relaunched cleanly, and produced 20
seconds of console output without crash/fatal markers. This launch receipt is
recorded at
`docs/linux-port/evidence/parity-audit-2026-07-10/ipad-current-launch-2026-07-14.json`.
It does not yet prove the Linux approval workflow or exact-candidate Browser
Computer Use actions. Real installed browser actions, grant/approval/panic/
audit/restart certification, Agent Watch, Linux system capture/input, and the
supported-desktop matrix remain open.

Official AppImages no longer depend on mutable environment hash pins for daemon
peer authentication. The final embedded GUI is described by a bounded canonical
manifest, signed with the Linux release Ed25519 key, re-extracted after repack,
and verified against the running `/proc/<pid>/exe` bytes. The daemon also
enforces no-follow reads, exact key IDs, immutable/read-only AppImage roots, and
the installed root-owned path policy; raw hash pins exist only in debug builds.

Mercury is no longer a missing code path: Linux now has daemon-owned iroh session
control, inbound and outbound file transfer, call/mirror state, sealed media
frames, portal/PipeWire capture, codec probing, consent/revocation, a call HUD,
and a runtime probe that exposes the route only when the daemon can support it.
It is still **unproven as a parity outcome** until a real Linux-to-macOS/mobile
two-device matrix passes. The largest remaining functional gaps are complete
system Computer Use capture/execution, provider/auth/portal completion inside
transactional onboarding, account/cloud/device workflows, chat and session depth, global text expansion, and richer
Linux-native shell integrations. The largest certification gaps are an x86_64
installed session, a prior-version update/rollback baseline, a valid public
signed feed, and real GNOME Wayland/KDE/wlroots proof. Package construction is
now green for both architectures, but that does not substitute for those live
installed-product outcomes.

The old parity claim is now disabled. The generated product ledger contains all
40 audited requirements, reports **0 ready / 40 blocked**, and cannot promote a
stale or incomplete claim. Release verification now checks artifact bytes,
detached signatures, provenance, source/SBOM/VEX inputs, architecture sessions,
and signed-feed closure. Allow-blocked validation is structurally green, but the
current strict verifier exits nonzero for missing exact artifacts/provenance/
evidence, all 40 blocked product rows, and the incomplete distro matrix. This
fixes the audit mechanism; it does not turn blocked product rows into parity.

The strongest installed-product baseline remains an aarch64 `.deb` session from
commit `9886a6ac0b`:

- exact package GUI and daemon binaries launched from `/usr/bin`;
- shell version `OpenBurnBar 0.1.0` and daemon version `0.1.0` matched;
- native AF_UNIX health passed and uninstall completed cleanly;
- all 19 routes were activated through installed AT-SPI actions with route
  screenshots and accessibility trees;
- Orca 46.1 was active, keyboard traversal produced 10 named focus targets, and
  requested 200% zoom passed;
- 28 package-smoke steps passed with zero failures;
- 10-sample p95 results were 349.2 ms process start, 61.85 ms tray reopen, and
  112.55 ms daemon health round-trip.

The current integration branch adds measured source and package evidence beyond
that historical installed baseline:

- **100** focused Swift Core/security/daemon tests passed across XDG paths, provider
  discovery, gateway, switcher, Pensieve/inotify, Computer Use, and Mercury;
- **62 files / 457 tests** passed in the Linux desktop suite, including every
  route under axe, six-layout state, provider-path parity, durable memory, and
  real Mercury RPC decoding;
- **44/44** Tauri Rust tests, **3/3** media-crate tests, **213/213** extension
  daemon-client tests, and **78/78** release/workflow contract tests passed;
- the controller/mobile packet passed **18/18** focused Linux App Check Functions
  tests and a current Android matrix of **1,315** unit tests with **1** skipped;
  Android debug Kotlin compilation passes and Detekt reports zero findings
  without suppressions. The
  canonical `HermesRealtimeRelaySessionGrantChallenge` schema/codegen packet
  passes **18/18** checks across generated Swift and Kotlin. Strict SwiftLint is
  clean and earlier generic iOS build-for-testing coverage passed; the physical
  iPad launch/liveness/console receipt is now current, while approval execution
  remains unverified. The earlier focused Linux daemon suite passed
  **32/32** tests: **13** grant broker, **3** panic authority, **4** directory,
  **8** runtime, **2** Mercury teardown, and **2** service lifecycle tests. The
  final macOS focused host aggregate passed **34/34** tests: **16** callable-security
  and **18** host lifecycle/policy tests;
- the account-lifecycle and approval-policy packet adds regression coverage for
  cancel during teardown, fresh sign-in after sign-out, explicit pending
  approval, permanent rejection, rate-limit-safe polling, UID/account transition
  fences, auth-socket redaction, and runtime teardown races; the 2026-07-12 full
  Linux-native aggregate passed in the Docker Linux toolchain, including the
  hardened runtime cancellation selector and **44/44** Tauri tests;
- focused changed-line coverage for the touched macOS app paths is **81.89%**
  (**104/127** executable lines), above the 80% gate, with **28/28** selected app
  tests passing;
- clean aarch64 and architecture-correct x86_64 shards at `391fe2847d` each
  produced AppImage, deb, rpm, and daemon artifacts with SHA-256 closure, zero
  blockers, and **28/28** package-smoke steps passed;
- the x86_64 toolchain produced real x86_64 binaries under Rosetta-assisted
  construction rather than relabeling ARM output. A native hosted runner and an
  exact installed x86_64 user session remain required.

Promotion remains blocked for three explicit reasons: no previous same-architecture
Linux package exists to prove update, rollback, and data preservation; no x86_64
installed architecture session has been produced; and the minimum compositor,
desktop, keyring, and portal matrix is not green. The public update endpoint also
remains invalid until it serves the signed JSON contract rather than website HTML.

The correct release posture is therefore:

1. Keep the product-parity claim false and treat the public build as a prerelease.
2. Run the installed x86_64 architecture session and supply a prior version to
   the package lifecycle gate.
3. Complete the Critical product capabilities, then the High daily-use workflows.
4. Certify the exact signed candidate on the declared Linux desktop matrix.
5. Promote only when every required product row is current, reproducible, and
   exercised in installed packages.

### Remediation Progress Snapshot

| Workstream | Current measured state | Remaining promotion work |
|---|---|---|
| Truth and release gates | Implemented; 40 requirements fail closed and the parity claim is false | Produce a fully green exact-candidate evidence graph |
| Credential custody | Secret Service, KWallet, and explicit encrypted headless backends are wired | Prove unlocked, locked, missing, rotation, and recovery behavior on GNOME/KDE/headless |
| Gateway/IPC boundary | Bearer remains native; HTTP/SSE is proxied; production fixture activation is disabled | Complete adversarial installed-package review on every supported build profile |
| Capability honesty | Typed runtime manifest gates unavailable and substitute routes | Add the missing native adapters rather than leaving capability-gated substitutes |
| Accessibility | Route axe plus installed AT-SPI/Orca/keyboard/200% proof passed on aarch64 X11 | Repeat on GNOME Wayland, KDE Wayland, wlroots, x86_64, and high-contrast rows |
| Performance/reliability | Matched harness, supervisor, percentiles, and nightly soak contracts implemented | Produce final same-hardware macOS/Linux candidate results and desktop-matrix runs |
| Updates | Native signed-feed verification implemented; invalid endpoint fails honestly | Serve valid signed feed and prove package-manager update/rollback/data preservation |
| Packaging | aarch64 and x86_64 AppImage/deb/rpm/daemon construction and smoke passed; aarch64 installed `.deb` session passed | Produce installed x86_64 session, signed aggregate, rpm/AppImage lifecycle, and prior-version proof |
| Core product workflows | Six dashboard layouts, XDG/provider paths, and daemon-authoritative memory decisions are implemented; several routes remain partial/read-only | Complete onboarding, chat, sessions, account/cloud, and workspace depth |
| Advanced platform features | Mercury implementation and guarded Linux input/panic paths exist; Computer Use routing, controller-route v2, exact-generation authority, durable replay protection, daemon-owned PKCE/Firebase/App Check credential lifecycle, and signed AppImage peer admission are implemented in source and fail closed | Deploy the new callables, then certify installed physical-iPad-backed Browser CU actions/restart; continue with system CU capture, Mercury, SmartHub devices, IBus/Fcitx, and companion overlay |

### What "full parity" means

Parity is outcome and quality parity, not an Apple API clone. Linux-native
substitutions are expected where they preserve capability, safety, discoverable
UX, reliability, and supportability:

| macOS mechanism | Linux-native parity mechanism |
|---|---|
| `NSStatusItem` and menu-bar popover | StatusNotifierItem/AppIndicator with a rich status window and an icon-only fallback |
| Keychain/Security.framework | Secret Service/libsecret, KWallet, or explicit systemd credential policy; never plaintext |
| ServiceManagement login item | `systemd --user` plus XDG autostart fallback |
| ScreenCaptureKit, AX, CGEvent | xdg-desktop-portal, PipeWire, AT-SPI, libei, constrained X11/XTest, and opt-in uinput |
| Sparkle/MAS/Homebrew | Signed release metadata plus apt/dnf/Flatpak/AppImage-native update flows |
| iCloud and StoreKit | Firestore/sealed archive sync and web billing with identical account outcomes |
| UserNotifications | `org.freedesktop.Notifications` with actionable deep links |
| Global text expansion | IBus/fcitx input-method integration with secure-field exclusions |
| Desktop pet overlay | Compositor-capability-driven transparent window with a contained fallback |

Unsupported Linux environments may use a documented Tier C substitute. The UI
must disclose the substitute before action and must not call it full parity.

## Audit Method And Confidence

This audit compared current source, tests, generated evidence, public delivery
surfaces, and a running Ubuntu 24.04 ARM64 UTM guest. macOS behavior was treated
as the gold-standard contract, with its implementation and tests used as the
oracle. Generated evidence was accepted only when the underlying mechanism and
live product state were independently reproducible.

### Verification performed

- `npm test --prefix apps/linux-desktop -- --maxWorkers=2`: **62 files, 457 tests passed**.
- `npm run build --prefix apps/linux-desktop`: **passed**; the main JavaScript
  chunk is **655.47 kB** minified and Vite reports a chunk-size warning.
- `cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml`:
  **44/44 passed**, including capability-catalog, Mercury-probe, update-feed,
  URL, gateway, panic-shortcut, and wire-contract coverage.
- `bash scripts/linux-port/run-linux-native-tests.sh` in the Docker Linux
  toolchain: **passed** on 2026-07-12, covering the Linux Swift/XCTest manifest
  with fresh-process retry isolation plus the Tauri Rust suite.
- Fail-closed OpenBurnBar Core/security/daemon Linux manifest: **100/100 passed**.
- Linux media crate capability/capture/decode suite: **3/3 passed**.
- Extension daemon-client focused suite: **213/213 passed**, including the
  Computer Use waiting phase and operator/computer-use denial projections.
- macOS Computer Use compatibility selector: **1/1 passed**, executing an
  approved `browser.goto` through the direct Playwright driver while proving no
  Linux managed-run binding was acquired.
- Controller/mobile focused suites: Linux App Check Functions **18/18** and
  Android **1,315** unit tests with **1** skipped passed; Android debug Kotlin
  compilation and strict Detekt pass with no suppressions. Canonical Hermes relay
  schema/codegen checks passed **18/18**, strict SwiftLint passed, and earlier
  generic iOS build-for-testing coverage passed. On 2026-07-14 the assigned
  physical iPad was unlocked and the current-branch app launch/liveness/console
  receipt passed; approval execution and exact-candidate pairing remain open.
  The earlier Linux daemon packet passed
  **32/32**. That total comprises **13** grant broker, **3** panic
  authority, **4** directory, **8** runtime, **2** Mercury teardown, and **2**
  service lifecycle tests. The final macOS focused host aggregate passed
  **34/34** tests: **16** callable-security and **18** host lifecycle/policy tests.
- Focused changed-line coverage for touched macOS app paths: **81.89%**
  (**104/127** executable lines), with **28/28** selected app tests passing.
- Account-lifecycle/App Check regression cases cover teardown-time cancel, fresh
  sign-in after sign-out, explicit approval pending, permanent rejection, and
  quota-safe retry. The 2026-07-12 full Linux-native aggregate passed.
- Linux release/config/packaging/matrix contract suites: **78/78 passed**.
- Current source comparison of macOS routes, settings, chat, parser registry,
  daemon lifecycle, cloud/account, Computer Use, Mercury, SmartHub, text
  expansion, accessibility, and recovery behavior.
- Current source comparison of Linux routes, stores, Tauri commands, platform
  adapters, capability grants, packaging, CI, and evidence generators.
- Live UTM inspection of process ownership, window state, service installation,
  daemon multiplicity, X11 capture, and installed executable state.
- Independent checksum and Ed25519 verification of both the four mission-002
  local candidate artifacts and the four downloaded public prerelease assets.
- Live check of `https://burnbar.ai/latest-linux.json` and the public website.

### Exact architecture-construction snapshot

The current source-bound construction proof targets commit
`391fe2847d7a9f1446174575e533112952f99e82`. Both closures report a clean
checkout, four required artifacts, zero blockers, and 28 passed smoke steps.
Hashes were recomputed independently after closure generation:

| Architecture | Artifact | SHA-256 |
|---|---|---|
| aarch64 | `OpenBurnBar_0.1.0_aarch64.AppImage` | `389fd6ec5814037d0c748738ce5370d084054714def2c360d9d63bb996ea291e` |
| aarch64 | `OpenBurnBar_0.1.0_arm64.deb` | `2cd2e2966394cbd76061b0177b4d8215ab2e841fe48b9ef221cb82659f48a1ff` |
| aarch64 | `OpenBurnBar-0.1.0-1.aarch64.rpm` | `cd32744330cc6da29a9e3e304bbf6ada4535b715b157f2f9ce41d486f35b9e38` |
| aarch64 | `openburnbar-daemon-0.1.0-linux-aarch64` | `82f5c9ce5bc3484fcddbd8d6bbd1d3b0946354e38b7b279d774bd9a87de7a11a` |
| x86_64 | `OpenBurnBar_0.1.0_amd64.AppImage` | `6b5152717ff77f6ced25a1fe059d11f56fc1431079a393637c67ee8666ee9aa3` |
| x86_64 | `OpenBurnBar_0.1.0_amd64.deb` | `900af78f61842341ebc4e4087192cbb61b88b594f1c3b129b340dd62fff055f6` |
| x86_64 | `OpenBurnBar-0.1.0-1.x86_64.rpm` | `c1c9e52370e49ffc884b30a0d6120d4c2a868c2412a1564d5ad28b854de3c119` |
| x86_64 | `openburnbar-daemon-0.1.0-linux-x86_64` | `95890f08f130f75a3a76f5119f464d08c5c98b84f8203780bbf0fd25703a58a6` |

This closes architecture-correct local package construction. It does **not**
close installed x86_64 GUI/compositor/keyring/portal behavior, native hosted
runner evidence, candidate signing, public-feed activation, or lifecycle proof.

### Release-integrity snapshot

The public `linux-v0.1.0` prerelease assets, detached signatures, and public key
were downloaded directly from GitHub during this audit. All four public assets
pass raw Ed25519 verification against public-key SHA-256
`077ac305e16cf5c86cdcf168d600ea40a5f167ad919fcbc1264c98c12735c930`:

| Public artifact | SHA-256 | Ed25519 |
|---|---|---|
| `OpenBurnBar_0.1.0_aarch64.AppImage` | `e545e6e452e054278b66b92af293ba607e8bd7b1c812e37e3d2400ad9183d0f5` | Passed |
| `OpenBurnBar_0.1.0_arm64.deb` | `0c6f59962bc0820d249e9a520f4f33c68c5aa720a7960d17e3a58b41898c5fd4` | Passed |
| `OpenBurnBar-0.1.0-1.aarch64.rpm` | `03e1bf42480c592dec0c36ed3ed57a36b13a2de50a9c214bb65b2df96fc2d20e` | Passed |
| `openburnbar-daemon-0.1.0-linux-aarch64` | `e8c85f6086222c75314b1cdda1ffc84bb72096e98defc409127b0e75f297ea19` | Passed |

The exact mission-002 local artifacts also match their checked-in package
closure, but all four fail against the local detached signatures. Only the local
AppImage artifact hash matches its public counterpart; its local signature hash
does not. The local deb, rpm, and daemon hashes also differ from the published
assets. Therefore the checked-in mission-002 closure is not a valid reproduction
of the public prerelease even though `release-verification.json` reports success.

Verification form used for each downloaded public artifact:

```bash
openssl pkeyutl -verify -pubin \
  -inkey openburnbar-linux-ed25519.pub.pem \
  -rawin -in "$artifact" -sigfile "$artifact.ed25519.sig"
```

This narrows the critical finding to certification integrity: the published
Ed25519 pairs are valid, while the local evidence bundle is divergent and the
strict verifier is capable of accepting its invalid pairs. Sigstore identity
verification, source binding, public feed, and update/rollback remain separate
required gates and were not made green by the Ed25519 result.

### Status vocabulary

| Status | Meaning |
|---|---|
| Parity | Equivalent user outcome is implemented and independently proven. |
| Near parity | Core outcome exists; bounded polish or edge-case work remains. |
| Partial | A meaningful subset exists, but a normal macOS workflow cannot be completed. |
| Substitute | Linux implements a narrower or different behavior under parity-like copy. |
| Missing | No production implementation exists. |
| Broken | The shipped/live path is known to fail. |
| Unproven | Code may exist, but evidence does not prove the product outcome. |

## Parity Matrix

| ID | Area | macOS gold standard | Linux current state | Status | Priority |
|---|---|---|---|---|---|
| P-01 | Release integrity | Signed, notarized, release/update path with installed-app proof | Exact-head run `29646670068` passed signed x86_64/aarch64 package construction, aggregate attestation, install/uninstall, and package-owned runtime checks; lifecycle is blocked without a compatible prior same-architecture package, while public feed promotion and notarized distribution remain open | Partial | Critical |
| P-02 | Parity certification | Product inventory tied to release head and real behavior | Complete 40-row generated inventory now reports 0 ready/40 blocked and fail-closes stale, missing, contradictory, or self-referential proof | Partial | Critical |
| P-03 | Installed runtime | Owned app/daemon lifecycle with recovery and one authoritative supervisor | Exact-head run `29646670068` package-owned x86_64 and aarch64 GUI/daemon/version/uninstall sessions passed; update/rollback/data-preservation is blocked without a compatible prior same-architecture package, and broader desktop-matrix lifecycle and promotion receipts remain open | Partial | Critical |
| P-04 | Architecture reach | Published build covers the declared macOS architecture support contract | Exact-head run `29646670068` native x86_64/aarch64 shards, signed aggregate, package install, and architecture-specific runtime sessions passed; lifecycle baseline, public release promotion, and wider environment coverage remain open | Partial | Critical |
| P-05 | Credential custody | Keychain-backed provider, connector, auth, and sync secrets | Secret Service, KWallet, and encrypted headless custodians are wired; fresh unlocked Secret Service first-use health now succeeds without a sentinel item while locked/unavailable states still fail closed; live keyring/recovery matrix remains incomplete | Partial | Critical |
| P-06 | Gateway credential boundary | Native process owns bearer credentials | Rust owns the bearer and proxies bounded authenticated HTTP/SSE; renderer receives typed data, not the token | Near parity | Critical |
| P-07 | Computer Use | Browser, Agent Watch, Mac System, approval, audit, and three panic paths | Exact run/call/generation authority, signed session/action responses, replay protection, waiting-run selection, shared scope/panic/Playwright/audit routing, and fail-safe restart/terminal behavior are implemented. Controller-route v2 provides dual-signature bootstrap, exact-tuple same-generation transport renewal, and authoritative absence/revocation. The Linux daemon now composes that runtime with daemon-owned PKCE sign-in, secure refresh-token custody, fresh Firebase ID/App Check credentials, per-install Ed25519 App Check enrollment, account-generation invalidation, phase-safe account transition RPCs, and scoped old-account revocation. Pending approval has an explicit bounded reason and quota-safe retry; permanent rejection stops polling. Official AppImages authenticate the final GUI bytes through a signed manifest rather than mutable environment pins. [PR #1681](https://github.com/Imagine-That-Ai/BurnBar/pull/1681) adds typed navigate/screenshot/click/fill requests with exact selected run/call/generation binding and daemon-owned result decoding; `bf0eb36294` adds a consent-scoped RemoteDesktop `Notify*` executor for pointer/key/shortcut/type/scroll/drag with typed libei/uinput-unavailable states and bounded cancellation/timeout/kill-switch teardown. System mode stays hidden when unavailable. A dedicated Linux Firebase web app exists, but the Desktop OAuth client, production callable deployment, release variables, current physical-iPad approval execution, installed browser/panic/audit/restart proof, Agent Watch, and compositor-installed portal receipts remain missing | Partial | Critical |
| P-08 | Mercury media | File transfer, calls, screen share, mirroring, presence, consent | Daemon-owned transport, calls, files, sealed capture, portal consent, HUD, and live capability probing are implemented; real cross-device and compositor proof remains open | Partial | Critical |
| P-09 | Navigation and shell | Dashboard, insights, deep provider/model routes, multi-window flows | All 19 installed routes activate through AT-SPI; deep links and native multi-window behavior remain thinner | Near parity | Medium |
| P-10 | Dashboard layouts | Six dense layouts with real live content and persisted state | All six layouts, persistence, loading/error/offline/populated states, tokens, and tests exist; the packaged six-layout visual matrix remains incomplete | Near parity | Medium |
| P-11 | Usage ingestion | 27 parser registrations, API/quota aggregation, recount, projections, cloud mirror | All 33 canonical provider identities and Swift path/pattern cases are cataloged; the exact 27 registered local parsers plus four API-backed and two unavailable sources are labeled and tested. The normalized macOS/Linux corpus, recount/projection parity, and installed runtime evidence remain unproven | Partial | High |
| P-12 | Quota | Provider quotas, histories, account switching, alerts | Strong read surface with provider credential-slot account switching, explicit auto-routing reset, preferred-slot persistence through daemon config, and per-slot quota/status labels; cloud account profiles, drain targets, and switching-lag telemetry remain open | Partial | Medium |
| P-13 | Onboarding | Provider connection, scan, permissions, chat engine, recovery, completion gates | Daemon-owned state, required-step gates, restart recovery, Secret Service readback, XDG write verification, privacy persistence, strict native/WebView RPC decoding, catalog-backed credential setup, and first-data readback are implemented; OAuth-only provider auth, provider scan depth, portal consent, tray, and update completion remain open | Partial | High |
| P-14 | Chat | Persisted threads, search, streaming, models, attachments, citations, approvals, panes/pop-out | Exact encrypted thread list/get/search, idempotent user/assistant persistence, older-message pagination, strict Tauri decoding, durable send ordering, and safe JSON/Markdown export of loaded durable messages are implemented in [PR #1684](https://github.com/Imagine-That-Ai/BurnBar/pull/1684). Model selection/thinking level propagates the exact selected model through the gateway; bounded text and capability-gated PNG/JPEG/WebP/PDF attachments now upload through the daemon and encode provider-native content with enforced model byte limits; `5fdcccabfa` preserves validated attachment ID/name/MIME/size/SHA-256 metadata in JSON/Markdown exports without raw bytes or paths; `702f59146e` canonicalizes extension-derived MIME and `dcca8b74b4` preserves the draft/staged file when native capability is unsupported or unavailable; citations normalize with source/thread validation; tool approvals use daemon-issued IDs with approve/reject/cancel terminal handling; reconnect/visibility and functional options/pop-out boundaries are explicit. `dd705ca1dd` adds strict page/thread/cursor identity checks, bounded load-all traversal, unloaded citation paging, full-history export safety, and validated chat-only pop-out lifecycle. Uploaded bytes are intentionally process-lived and require re-upload after daemon restart. Remaining provider-specific backend coverage and installed proof remain open | Partial | High |
| P-15 | Account and billing | Sign-in/link/sign-out, membership, subscription, recovery | Daemon-owned Desktop PKCE, redacted account RPC/Tauri state, sign-out, phase-safe account switching, and the typed cloud-erasure request path are implemented in source; production OAuth/callable configuration and installed account/erasure proof remain absent, while subscription/recovery depth still lags | Partial | High |
| P-16 | Cloud and devices | Backup, sync, conflict handling, remote access, trusted device management | Linux account/enrollment and cloud-data-control posture is daemon-owned with fail-closed transitional states and copyable device verification values. Trusted-device list/approve/revoke and erasure authorization stay on the native mobile/Firebase nonce-bound contract; production deployment, current physical-iPad execution, backup/sync/conflict, and broader remote-device outcomes remain unproven or absent | Partial | High |
| P-17 | Activity/session logs | Indexed transcript, search, body, replay, resume, export, source resolution | Canonical daemon search/detail/resume and indexed excerpts are wired; persisted body replay and native resume through `run.resume` with provider-safe handoff fallback are source-integrated, and loaded activity rows export through an explicit allowlisted JSON/Markdown path (PR #1685). Replay/resume now require a verified daemon `sourceID` (`7ae2412143`) rather than a usage-row fallback. Full-history export, source resolution, and resume-from-export remain open | Partial | High |
| P-18 | Memory review | Quarantined candidates, approve/reject, durable state, audit | `752f6e9745` adds a daemon-owned review-status column, quarantine/approved/rejected/forgotten lifecycle, opt-in quarantine feed, metadata tombstones, audit hashes, typed RPC coverage, and renderer fail-closed decisions. Cross-device replication and installed proof remain open | Partial | High |
| P-19 | Projects | Registered projects, exact associations, detail, management | Canonical list/get/upsert and exact identity are wired with register/edit UI; typed delete/reassign lifecycle, tombstones, durable migration, and checkpoint-tail replay protection are source-integrated; installed proof remains open | Partial | Medium |
| P-20 | Missions | Full run/task state, approvals, questions, evidence, history, health | List/create/approve plus canonical get/cancel and typed packet/result/evidence/burn/takeover/PR snapshot detail are wired; `bd9d6a5173` adds authoritative typed health/history over `daemon.mission.health` and renders it in the detail surface; live/installed proof remains open | Partial | Medium |
| P-21 | Insights | Editorial brief, evidence, citations, follow-ups, comparison, audit | Provenance-labeled brief plus selectable canvas/library/inspector workspace, normalized trend/provider/model/cache widgets, bounded audit disclosure, refresh, and chat follow-up handoff are implemented. Daemon-backed citations, qualitative comparison, and persisted canvas state remain open | Partial | Medium |
| P-22 | Database | Search/inspect indexed sessions, snapshots, watch/recovery, encrypted storage UX | Index/watch foundation plus bounded daemon-owned code search/context-pack inspection are wired in [PR #1680](https://github.com/Imagine-That-Ai/BurnBar/pull/1680), with pagination, trust warnings, and fail-closed capability handling. SQLCipher-gated encrypted snapshots provide owner-only path validation, bounded atomic copy, SHA-256 integrity, rollback, and watcher reopen; `f5d562da82`/`238577c904` add typed recovery status/export/import state, key-loss/device-transfer guidance, partial-capability rendering, passphrase/path validation, and redacted outcomes. Installed proof and backend recovery on real keyrings remain open | Partial | Medium |
| P-23 | Provider/model workspace | Provider and model deep dives, health, catalog, failover, routing | Daemon-backed provider/model workspace, canonical catalog/config mapping, model variants/aliases, health/failover posture, account chips, config-derived chat backend gates, and source-integrated custom-model add/remove mutation state are integrated. `d7cffc79d6` makes the bridge fetch canonical `daemon.catalog` separately from `daemon.config.get` and exposes an explicit config-only degraded state on catalog failure; live credential routing and installed lifecycle proof remain open | Partial | Medium |
| P-24 | Settings | 16 searchable tabs with deep links and writable state | 16-tab searchable inventory and deep routes are wired; deeper per-tab backend writes and installed proof remain open | Partial | Medium |
| P-25 | Updates | Automatic checks, channel, install/restart truth | Native signed-feed freshness, exact package-channel/architecture selection, shell/daemon compatibility, fail-closed mutation guidance, and run `29646670068` package construction/install checks passed; update/rollback/data-preservation remains blocked without a compatible previous same-architecture package, and valid public feed/promoted history remain open | Partial | High |
| P-26 | Tray and native shell | Rich live menu-bar status, quick switch, chat, quota, update state | Native tray now exposes dashboard/chat/usage/updates/settings routes, daemon health, recent usage, signed-update state, refresh/reconnect, and quit actions; `dcca8b74b4` packages the canonical XDG autostart entry and honors tray-first `--background` startup; compositor/DE persistence and installed receipts remain open | Partial | High |
| P-27 | Notifications/deep links | Actionable notifications, OAuth return, global commands, login start | Native startup/deep-link handoff, background tray launch, XDG autostart package installation, desktop MIME registration, strict membership/OAuth URL validation, owner-checked per-user single-instance forwarding, normalized freedesktop `open`/`reply` actions, explicit route aliases, and cold-start precedence are implemented in [PR #1679](https://github.com/Imagine-That-Ai/BurnBar/pull/1679), [PR #1686](https://github.com/Imagine-That-Ai/BurnBar/pull/1686), `5f74018422`, `07153ac3d5`, and `dcca8b74b4`; Reply preserves intent, opens chat, and focuses the composer rather than providing inline notification text input. Global shortcut and installed host integration remain open | Partial | High |
| P-28 | SmartHub | Discovery, status, allowlisted device actions | Runtime requires a trusted root-owned packaged CLI and otherwise fails closed. Typed operation allowlists, request/output bounds, concurrent drain, bounded Avahi timeout, cancellation, and degraded renderer states are integrated; real device/Avahi outcomes remain unproven | Partial | High |
| P-29 | Text expansion | Global, secure-field-aware expansion, persistence, sync, previews | Daemon-owned AES-GCM persistence with native Secret Service/KWallet custody, owner-only sealed files, consent, in-app Composer expansion, no renderer localStorage/global capture, and fail-closed corruption/missing-key handling are integrated. Renderer consent/import/snippet/edit/delete controls now fail closed until live daemon storage hydration succeeds (`1ddc8bc33a`). The daemon exposes a bounded IBus/Fcitx reachability and secure-field policy probe (`6c76df084f`) and `d2dbbe8df8` adds a trigger-only signed-engine request/response path with strict bounds, secure-field denial before write, and cancellation/kill-switch teardown. Linux keyring/IME runtime receipts, sync/conflict handling, and installed secure-field proof remain open | Partial | High |
| P-30 | Pet companion | Animated ambient overlay, click-through, summon, selection, interactions | Typed runtime-manifest probe, contained draggable fallback, accessible summon/focus/status, and selection/clear controls are honest. `3b652f9b9e` adds bounded pointer/mouse drag and Arrow/Home keyboard repositioning with focus metadata and announcements for the Wayland-safe contained substitute. `5c3caab2e` adds a fixed-marker X11-only `Ctrl+Alt+Super+P` native summon route and `2b85f1431` exposes `aria-keyshortcuts`; native overlay/click-through and installed compositor proof remain open | Partial | High |
| P-31 | Accessibility | Semantic UI, keyboard flows, assistive announcements, reduced effects | All routes pass axe; global reduced-motion, forced-colors, and prefers-contrast styling plus keyboard/status contracts are implemented in [PR #1683](https://github.com/Imagine-That-Ai/BurnBar/pull/1683), with live reduced-motion preference updates and cleanup in `7cd30e2e71`; Nightly `29646670763` passed 19-route X11 AT-SPI/Orca, keyboard, 200% zoom, onboarding, and text-expansion evidence, while broader desktop/high-contrast breadth remains | Near parity | High |
| P-32 | Performance | Startup/recovery/frame/cadence budgets and mature profiling | Nightly `29646670763` passed matched 30-minute macOS/Linux correctness/resource soak and packaged X11 thresholds: `route.navigation` p95 `95.6 ms` across 33 samples versus the `120 ms` budget, app start p95 `333.9 ms`, IPC health p95 `111.65 ms`, and tray-open p95 `123.55 ms`; comparable hardware, suspend/keyring recovery, and broader matrix profiling remain open | Near parity | High |
| P-33 | Reliability | Backoff, supervisor, recovery, subscriptions, migrations, long-idle stability | Daemon-owned bounded start/resume/stop subscriptions, monotonic restart recovery, offline-aware single-flight cadence, cancellation, coalesced route refresh, and soak contracts exist; native push and installed suspend/portal/keyring/matrix certification remain | Partial | High |
| P-34 | Security hardening | Native URL/secret/process boundaries | Generic renderer shell permission and token exposure removed; production fixtures disabled; full installed adversarial matrix remains | Near parity | Critical |
| P-35 | Diagnostics/support | Native export, privacy choices, accurate runtime/package facts | Metadata-only redacted export and support preview are wired; installed support workflow remains open | Partial | Medium |
| P-36 | Visual/interaction polish | Consistent components, responsive density, animations, native affordances | Nonblack installed route captures now exist; raw diagnostics, interaction polish, and multi-environment regressions remain | Partial | Medium |
| P-37 | Linux matrix | N/A; macOS supported versions are exercised | Environment-bound fail-closed harness binds installed/accessibility evidence to exact environment, architecture, session, and desktop identity (`b012a53a6c`); Nightly `29646670763` passed the runnable Ubuntu GNOME/X11 packaged session while recording Arch/wlroots, GNOME Wayland portal, and Fedora/KDE as explicit blocked rows; current-head promotion and architecture/keyring/portal rows remain open | Partial | Critical |
| P-38 | CI/release automation | Test, sign, package, and promotion jobs fail closed | Strict gates, mutation tests, native architecture shards, sessions, and signed aggregate closure are implemented; Release `29646670068` and Nightly `29646670763` passed their current-head gates, including the root-owned evidence wrapper fix; lifecycle, production, and product/environment promotion remain open | Partial | Critical |
| P-39 | Cross-platform differential proof | Same contract/corpus compared at the same product version | A bounded evidence comparator is implemented in [PR #1682](https://github.com/Imagine-That-Ai/BurnBar/pull/1682): it normalizes object order, redacts credential values, supports explicit volatile paths, emits path-level differences, and fails closed with machine-readable exit codes. A same-commit macOS/Linux artifact run is still required | Partial | High |
| P-40 | Data and Privacy | Vault/export/deletion/retention/recovery/consent/telemetry/panic workflows | Daemon-backed telemetry/privacy/cloud-sync consent, allowlisted inventory, preview/execute deletion, selected-scope encrypted export, bounded age/size retention, and a typed account-erasure request path are implemented. The installed candidate now has a live Ubuntu 24.04 GNOME/X11 aarch64 RPC proof; trusted-device account erasure, backend deletion receipts, and the other six environment rows remain open | Partial | High |

Every matrix row maps to a detailed record containing all six requested fields:

| Matrix row | Detailed gap record |
|---|---|
| P-01, P-02 | GAP-001, GAP-023 |
| P-03 | GAP-002 |
| P-04, P-37 | GAP-004 |
| P-05, P-06 | GAP-003 |
| P-07 | GAP-005 |
| P-08 | GAP-006 |
| P-09, P-10 | GAP-025 |
| P-11 | GAP-007, GAP-024 |
| P-12 | GAP-026 |
| P-13 | GAP-008 |
| P-14 | GAP-009 |
| P-15, P-16 | GAP-010 |
| P-17, P-18 | GAP-011 |
| P-19 | GAP-012A |
| P-20 | GAP-012B |
| P-21 | GAP-012C |
| P-22 | GAP-012D |
| P-23 | GAP-012E |
| P-24 | GAP-013, GAP-027 |
| P-25 | GAP-015 |
| P-26, P-27 | GAP-014 |
| P-28 | GAP-016 |
| P-29 | GAP-017 |
| P-30 | GAP-018 |
| P-31 | GAP-019 |
| P-32, P-33 | GAP-020 |
| P-34 | GAP-003, GAP-021, GAP-023 |
| P-35, P-36 | GAP-022 |
| P-38 | GAP-023 |
| P-39 | GAP-024 |
| P-40 | GAP-027 |

## Detailed Gap Register

### GAP-001 - Repair release integrity and parity certification

**Implementation update (2026-07-10): partially closed in the implementation
branch.** The parity claim is now false, the generated ledger has all 40 audit
requirements at 0 ready/40 blocked, and strict verification cryptographically
binds artifacts, signatures, source, SBOM/VEX, provenance, feed, architecture
sessions, and Sigstore inputs. Clean aarch64 and architecture-correct x86_64
shards at `391fe2847d` each produced all four required artifacts and passed 28
package-smoke steps. Promotion remains blocked until an installed x86_64
session, native hosted x86_64 run, final signed aggregate, valid public feed,
and prior-version update/rollback/data-preservation proof all exist.

- **Difference:** macOS release confidence comes from a signed product and a
  delivery path that can be exercised. Linux's four public Ed25519 artifact pairs
  pass, but the mission-002 local closure diverges and all four local pairs fail.
  `verify-linux-release.mjs` checks only recorded signature entries and still
  reports green. It also accepts blocked update/rollback evidence, does not
  exercise the live feed, and delegates to a product ledger whose staleness is
  disabled. The JSON ledger says parity is true while the Markdown ledger says
  false.
- **Why it matters:** automation can certify evidence that does not reproduce the
  public candidate, and every downstream parity claim inherits a false-green
  gate even though the public Ed25519 pairs themselves are valid.
- **Recommended solution:** mark the mission-002 local evidence non-promotable
  and determine why its artifacts/signatures differ from GitHub; verify each
  artifact byte-for-byte in the release workflow and verifier; add Sigstore
  identity and source binding; require a current full product inventory,
  update/rollback, and live-feed success; make contradictions or blocked rows
  fatal.
- **Priority:** **Critical**.
- **Implementation notes:** add Ed25519/minisign/Sigstore verification to
  `scripts/linux-port/verify-linux-release.mjs`; bind artifact hash, public-key
  fingerprint, signature, provenance, SBOM, and source commit in one manifest;
  remove `staleWhenHeadDiffers: false` for Tier A/B product rows; generate the
  Markdown ledger from JSON; check the public feed's status, MIME type, schema,
  architecture, hash, version monotonicity, and signature.
- **QA verification:** reproduce the downloaded GitHub asset hashes and passing
  Ed25519 checks; assert the current divergent mission-002 bundle fails; mutate
  one byte in every artifact/sidecar/manifest and assert failure; assert blocked
  update, stale head, HTML feed, missing architecture, dirty release checkout,
  and Markdown/JSON disagreement all stop promotion.

### GAP-002 - Establish a healthy installed runtime

**Implementation update (2026-07-10): partially closed in the implementation
branch.** A clean aarch64 `.deb` installed and launched the exact package-owned
GUI and daemon from `/usr/bin`, returned matching `0.1.0` versions over the native
AF_UNIX health path, exercised tray reopen/quit, and uninstalled cleanly. All 19
routes produced nonblack installed-app screenshots. This closes the observed
deleted-binary/duplicate-daemon baseline for that package session, but not the
x86_64, prior-version, suspend/resume, or compositor matrix.

- **Difference:** macOS owns its daemon lifecycle, startup recovery, and app
  executable. One inspected mutable UTM guest had a running deleted executable,
  two daemons, no detected `systemd --user` unit, and completely black desktop
  and window captures. The live process/service observation was not captured as
  package-provenance evidence, so it invalidates that guest as parity proof but
  does not by itself prove every clean package has the same defect.
- **Why it matters:** successful unit tests and package contents do not mean the
  installed product launches, renders, upgrades, or recovers reliably.
- **Recommended solution:** define one package-owned service/lifecycle model;
  make upgrades atomic; prevent duplicate daemons; add renderer capability and
  safe-mode fallback; make onboarding repair ownership drift.
- **Priority:** **Critical**.
- **Implementation notes:** ship and enable a versioned user unit or a single
  socket-activated supervisor; use lock/peer/version checks before daemon start;
  stop old processes during upgrade; never execute an unlinked binary; detect
  WebGL2/WebGL1/software-renderer capability and persist an explicit safe-mode
  choice; distinguish X11 capture failure from an actually blank WebView.
- **QA verification:** install, launch, upgrade, crash, restart, suspend/resume,
  logout/login, uninstall, and interrupted-upgrade tests; assert one daemon and
  one owned executable; validate nonblank canvas pixels and route screenshots
  under hardware and software rendering.

### GAP-003 - Implement Linux credential custody and contain gateway tokens

**Implementation update (2026-07-10): implementation complete; environment
certification remains.** Provider and connector paths now use one Linux secret
custodian with root-owned Secret Service and KWallet command discovery plus an
explicit encrypted headless backend. The renderer no longer receives the gateway
bearer; Rust performs bounded authenticated HTTP/SSE proxying. The remaining work
is live GNOME/KDE/headless verification for locked, missing, rotate, recovery,
and diagnostics-redaction states.

- **Difference:** macOS uses Keychain-backed secret stores and keeps privileged
  credentials in native code. Linux provider and connector services still
  default to Apple Keychain implementations whose non-Security paths can throw,
  while Tauri returns a gateway bearer token into WebView JavaScript.
- **Why it matters:** provider setup, routing, connectors, auth, cloud, and
  recovery cannot be called reliable or secure; an XSS could obtain the daemon
  credential.
- **Recommended solution:** create one injected cross-platform secret-store
  protocol with read/write/delete/rotate/health/trust metadata; implement Secret
  Service, KWallet, and an explicit headless systemd-credential policy; proxy
  authenticated gateway HTTP/SSE through Rust IPC so JavaScript never sees the
  bearer.
- **Priority:** **Critical**.
- **Implementation notes:** wire the Linux custodian into provider, connector,
  notification, phone-pin, auth, database, and cloud stores; never add plaintext
  fallback; zero temporary buffers where practical; restrict logs and support
  exports; add a locked-keyring recovery state.
- **QA verification:** save/read/rotate/delete every secret on GNOME and KDE
  across restart; test locked/missing keyring and headless policy; scan config,
  DB, logs, DOM, JavaScript globals, frontend network traces, crash reports, and
  diagnostics for tokens.

### GAP-004 - Ship the architectures and desktop environments users have

**Implementation update (2026-07-10): partially closed in the implementation
branch.** The release workflow now builds native `aarch64` and `x86_64` shards
on separate GitHub runners, asserts runner architecture, runs per-architecture
package inspection/install/uninstall smoke, and aggregates only after both
hash-bound shard closures pass. The schema-3 verifier requires every
AppImage/deb/rpm/daemon and architecture pair, exact detached-signature and
checksum coverage, a hash-bound signed feed, source/SBOM/VEX/provenance/parity,
and final Sigstore bundles. Mutation tests cover missing, duplicate,
cross-commit, dirty, cross-architecture, and extra shard inputs. Clean local
construction at `391fe2847d` now proves four architecture-correct artifacts and
28/28 smoke checks for both aarch64 and x86_64. The x86_64 run used
Rosetta-assisted construction and extracted AppImage inspection, so a native
hosted x86_64 workflow run, installed x86_64 session, and the GNOME Wayland,
KDE Wayland, and wlroots certification rows remain open. GAP-004 and P-37 are
therefore not closed.

- **Difference:** the audited baseline Linux release workflow produced ARM64 artifacts
  only, and live evidence covers Ubuntu 24.04 GNOME ARM64. macOS parity is being
  claimed without x86_64, KDE Wayland, GNOME Wayland, or wlroots proof.
- **Why it matters:** most desktop Linux users cannot install the current build,
  and the exact integrations that differ most by compositor remain untested.
- **Recommended solution:** build signed x86_64 and aarch64 AppImage/deb/rpm
  artifacts; add Ubuntu GNOME X11/Wayland, Fedora KDE Wayland, and an Arch/wlroots
  lane; publish an honest support matrix.
- **Priority:** **Critical**.
- **Implementation notes:** make release metadata architecture-specific; audit
  bundled Swift/WebKit/system libraries; prefer native runners for portal,
  keyring, GPU, tray, and global-input tests; use Flatpak only after portal and
  sandbox contracts are explicit.
- **QA verification:** clean install, launch, upgrade, rollback, uninstall,
  daemon start, tray, keyring, portal, screenshots, and accessibility on both
  architectures and every supported desktop row.

### GAP-005 - Complete Computer Use rather than exposing unsupported modes

**Implementation update (2026-07-13): controller-route v2, cross-platform mobile
renewal, macOS host policy, Linux native runtime composition, daemon-owned
PKCE/Firebase/App Check credentials, Linux App Check enrollment and policy, and
signed AppImage peer admission are implemented in source. The active browser
panel lane adds typed navigate/screenshot/click/fill requests, strict
lower-camel Tauri-to-Swift ID translation, exact run/call/generation binding,
and daemon result decoding; system mode remains unavailable when the runtime
manifest cannot prove it. The physical-iPad approval surface is implemented in
the active worktree. Production provisioning, an exact signed candidate, and
installed Linux plus physical-iPad capability proof remain open.**
The typed runtime manifest now marks Linux system Computer Use unavailable and
prevents the route from offering a guaranteed-failure action. Browser is the
only exposed source mode, but the release workflow is not yet operational.
Daemon-managed browser tools now require a live session bound to the exact
agent run/call/generation, reserve concurrent starts, release expired bindings,
store that run ID in the hashed manifest, and execute through the shared
Computer Use scope, approval, panic, Playwright, and audit coordinator. Unbound,
halted, mismatched-result, persistence-error, and coordinator-error paths fail
closed with no legacy Playwright fallback; every terminal path revokes the exact
generation before cleanup. Every already-bound action is durably checkpointed
before external dispatch. A waiting requirement restores without a lease, while
an action interrupted in flight is durably normalized to an outcome-unknown
failure and can only retry with a fresh call/generation. The surface has a
waiting-run picker and exact-row approval context; filtered polling carries
authoritative session liveness, so it retires only that exact terminal session
and retains it across transport errors.

Linux release verification now requires the exact session, approval ID, pending-
request hash, pinned transport-peer key and key kind, 30-second freshness,
strictly increasing durable counter, canonical response-intent hash, and valid
signature. Corrupt replay state fails closed, and the source-device/peer-node
pin alias is provisioned as one atomic set on both the Linux file store and the
macOS Keychain. Backings without atomic multi-alias support fail before writing.

The callable-backed controller directory now implements the canonical
`OpenBurnBar-IrohControllerRoute-v2` protocol. A bootstrap challenge requires
both transport and authority signatures and advances route generation. Once
that exact source-device, connection, transport, authority, and registration
tuple is active, a transport-only renewal extends its lease without changing
generation or `registeredAt`. The resolver returns authoritative empty routes
for known absent, expired, or revoked state. iOS and Android renew autonomously
with the same protocol and refuse a background renewal if the server unexpectedly
requires an authority bootstrap proof. Generated TypeSpec, TypeScript, Swift,
and Kotlin models carry the same proof-kind and route contract.

The macOS host treats authoritative absence as revocation, preserves an admitted
stream across a same-generation lease extension, and closes it when the principal
or generation changes. Lifecycle epochs and serialized teardown prevent an old
start or policy refresh from resurrecting a stopped or replaced host runtime.

Session-start authority now has a versioned challenge bound to the canonical
session intent, exact trust, and capability subset. Both phone clients bound
device identifiers before intent comparison, admit at most one user-facing
challenge at a time, retain a bounded replay set, and mark a challenge terminal
when device-owner authentication begins; only pre-authentication setup or route
failures remain retryable. iOS validates and routes the challenge from both
persistent control and request-stream side channels. Android preserves the receiving stream's uid, connection, signed
pairing target, authenticated QUIC peer, liveness, and response sink as one
immutable route; route rotation cannot redirect a response. Background delivery
posts a private high-priority Computer Use notification, waits only through the
signed expiry for a resumed activity, gives the OS the same expiry timeout,
clears orphaned tagged notifications after process restart, then revalidates before biometric signing
and an expiry-capped frame write on that exact stream. A bounded daemon actor publishes only to an authenticated paired
transport peer, separately binds the signing-key authority peer, prevalidates
the pinned-phone proof without consuming it, and reserves it only after fresh
peer-bound polkit owner authorization and exact run revalidation. Concurrent
starts cannot reuse that reservation. A definite session-construction failure
restores the still-fresh grant, while cancellation, expiry, or an ambiguous
outcome consumes it fail closed; terminal phone-proof and broker consumption
occurs only after session creation succeeds, and any post-start commit failure
panic-halts the new session. Tauri retains the opaque challenge and original proof-free
request outside the renderer. Its idle state calls a typed daemon readiness RPC
and advertises availability only when the operational broker, validator,
metadata resolver, readiness provider, and trusted pairing path all confirm;
the daemon reports unavailable while signed out, pending trusted-device
approval, or unable to refresh native Firebase/App Check credentials rather than
offering a guaranteed-failure Start action. Native deb/rpm/AUR packages install
the root-owned polkit action with fresh `auth_self`; the Computer Use path has no PAM fallback, and
standalone AppImage/Flatpak sessions fail closed when the policy is absent.

The Linux release graph now builds the Rust iroh cdylib before Swift, enables the
generated UniFFI bridge only when that exact library exists, stages it as a
regular `0644` package resource, binds its digest into release preparation, and
requires it in installed manifests and package smoke. A real aarch64 VM proves
the ALPN loopback, Swift factory activation, daemon ELF dependency, `ldd`
resolution, staged payload probe, and staged daemon launch. The Linux daemon now
has a production composition seam that publishes a signed host identity, resolves
the server-verified controller route, accepts only the exact transport peer, and
routes grant, approval, panic, Mercury, route teardown, metadata, and readiness
through the native iroh runtime. Account-generation changes, route expiry,
authoritative absence, identity replacement, and higher-generation replacement
invalidate the affected route and sessions. Same-generation renewal is accepted
only when the principal and original registration epoch are unchanged and the
lease does not shorten. Stale overlapping refreshes and stop-during-start cannot
resurrect a route.

The shipping daemon entry point now injects a native credential authority. It
owns PKCE loopback state validation, refresh-token persistence, Firebase ID-token
refresh, per-install Ed25519 App Check enrollment/challenges, 30-minute token
minting, exact account generation, account-switch teardown, sign-out, and scoped
old-account route revocation. Shared refresh work is generation-checked, stale
waiters cannot resurrect credentials, and HTTP cancellation propagates to the
underlying transport. Account-transition phases prevent a late cancel from
reporting a stopped runtime as active, and successful sign-out permits a new
browser sign-in. The Functions error contract exposes an explicit bounded
pending-approval reason; the daemon retries only pending approval or transient
cloud failure on a quota-safe capped schedule, while permanent rejection stops.
The local RPC surface exposes only redacted state. The earlier focused Linux
verification passed 35 tests across Core token access, credential authority,
loopback OAuth, directory, scoped revoke, cancellation, and adjacent runtime
behavior; the newly added lifecycle and polling cases still require the final
clean Linux-native aggregate.

The dedicated Linux Firebase web app and separate Google Desktop OAuth client
have been created, and the public release variables are registered. Functions
deployment, signed release artifact, and installed physical-iPad approval/action
proof are still missing. Source wiring cannot stand in for installed behavior. Full
installed iPad-backed browser action/result/panic/audit/restart E2E and a real
portal/PipeWire/AT-SPI/libei or constrained X11 system adapter are still
required. AppImage, deb, and rpm payloads now stage
the canonical bridge under `/usr/lib/openburnbar/playwright`; deb/rpm signed
installed manifests hash it, and the daemon launcher selects the package path
before development overrides. A read-only probe enforces Node 18+, exact
`playwright@1.49.1`, an executable Playwright-managed Chromium, and a real
headless launch without installing anything. Packaged launches discard ambient
process and Node injection variables, pin `/usr/lib/node_modules/playwright`,
`/usr/lib/node_modules/playwright-core`, and
`/usr/lib/openburnbar/playwright-browsers`, and recursively require uid-0
ownership with no group/world write before loading or launching. Playwright and
Chromium remain external root-provisioned prerequisites, so this closes a
fail-closed trust boundary, not installed
Browser Computer Use parity.

- **Baseline difference (2026-07-09):** At the 2026-07-09 baseline, macOS shipped
  Browser, Agent Watch, and Mac System behavior with approval, audit, and panic
  paths. Linux presented browser, agent-watch, and system choices, but the daemon
  rejected non-browser modes, the surface had no real target/action/result
  workflow, and no Linux capture/input adapter existed.
- **Why it matters:** this is a safety-sensitive feature. Offering guaranteed-
  failure modes and unproven panic behavior is both misleading and dangerous.
- **Recommended solution:** deploy the Linux App Check callables and ship
  the already implemented daemon-owned credential authority. Keep account
  changes terminal for the active route. Then exercise exact signed grants,
  approvals, and panic frames
  over the installed iroh path; certify polkit-agent availability without adding
  a PAM fallback; preserve restart-safe authority state; complete browser actions
  over the real Playwright bridge; then build portal/PipeWire
  capture, AT-SPI inspection, libei input, constrained X11/XTest, and explicitly
  consented uinput fallback.
- **Priority:** **Critical**.
- **Implementation notes:** credential acquisition is native and remains out of
  the renderer; Firebase ID and App Check state refresh before directory
  operations; unavailable or changed credentials terminate the active route;
  mobile approval is nonce-bound to the trusted native signing identity. Keep
  approval as ground truth; trust elevation
  remains Mac/desktop local; the Linux-native daemon-wide global panic path and
  deterministic installed X11 chord proof now exist, while lock/sleep/
  permission-revocation kill paths and real-desktop latency certification remain;
  never redispatch an action whose pre-dispatch checkpoint may have crossed the
  external boundary; audit every action and terminal entry; capability-gate per
  compositor and session type.
- **QA verification:** first prove credential unavailable, expiry, refresh,
  account switch, App Check rejection, authoritative empty route, renewal, and
  generation replacement behavior in an installed package. Then navigate/click/
  type/screenshot against real browser targets with the physical iPad; exercise
  manual/step/trusted policy, approval races, denial, audit
  tampering, lock/sleep, portal revocation, daemon crash before and after a later
  bound action dispatch, explicit retry, and panic latency on GNOME/KDE/Sway
  Wayland and X11.

### GAP-006 - Build the Mercury Linux media host

**Implementation update (2026-07-10): core implementation closed; parity
certification open.** Linux now owns Mercury sessions in the daemon, handles
call/mirror control, inbound and outbound files, portal/PipeWire capture,
GStreamer codec probing, bounded frame queues, sealed outbound frames, consent
and revocation, and exposes the resulting state through typed daemon/Tauri/UI
contracts. The shell capability catalog now probes the real daemon rather than
hard-disabling the route.

- **Difference:** macOS has production-proven Mercury behavior across supported
  Apple/mobile peers. Linux now implements the same core outcomes, but no current
  installed two-device/compositor matrix proves calls, mirroring, and transfers
  end to end against the exact candidate.
- **Why it matters:** media failures are permission-, portal-, codec-, network-,
  and peer-dependent; source and unit tests alone cannot certify the user outcome.
- **Recommended solution:** preserve the current daemon-owned architecture, then
  close the installed Linux-to-macOS/iOS/Android matrix and feed any observed
  portal, codec-negotiation, notification, or lifecycle defects back into the
  shared contracts.
- **Priority:** **Critical**.
- **Implementation notes:** transport, media engine, portal capture, codec probe,
  sealed-frame boundary, file service, and UI state are separate. Runtime
  capability is available/degraded/unavailable with a reason; absence of the
  daemon probe fails closed. Keep fixture paths disabled in production.
- **QA verification:** Linux-to-macOS/iOS/Android pair/unpair, file send/receive,
  call, screen share, cancel/reject, packet loss, reconnect, suspend, permission
  denial/revocation, codec absence, cleanup, and multi-monitor selection on each
  supported compositor and architecture.

### GAP-007 - Make usage/provider coverage authoritative

- **Difference:** macOS registers 27 parsers and combines local logs, APIs,
  quotas, recount, persistence, projections, and cloud mirroring. Linux's UI
  path registry has 15 rows and no generated proof that the shared daemon
  parsers, Linux path discovery, settings, and UI share one complete catalog.
  The registry count alone does not prove the remaining parser implementations
  are absent; it proves coverage and wiring are not authoritatively demonstrated.
- **Why it matters:** missing or mislabeled usage silently breaks the app's core
  value and makes parity counts unreliable.
- **Recommended solution:** generate macOS and Linux provider/model/path
  capabilities from one manifest while allowing platform-specific path rules;
  reuse identical golden parser/quota fixtures.
- **Priority:** **High**.
- **Implementation notes:** include feature flags for local scan, API polling,
  quota, chat backend, account switching, model catalog, and secret needs; map
  XDG, symlink, Flatpak, Snap, malformed log, and multi-account cases.
- **QA verification:** identical input corpus produces equivalent normalized
  usage, cost, quota, model/provider identity, timestamps, and deduplication on
  macOS and Linux; every declared provider has path, parser, empty, error, and
  migration tests.

### GAP-008 - Replace informational onboarding with transactional setup

**Implementation update (2026-07-10): authority foundation complete; end-to-end
setup remains partial.** Linux onboarding no longer trusts browser completion.
The daemon owns a schema-versioned atomic state file with `0600` permissions in
a daemon-enforced `0700` support directory,
derives completion from fixed required/optional invariants, rejects future-step
mutation and required-step skips, and exposes capability-scoped
`snapshot`/`action`/`reset` RPCs through narrow Tauri commands. Required probes
now prove authenticated daemon reachability, perform an ephemeral approved
Secret Service/KWallet write-read-delete cycle on Linux, verify writable XDG
support storage, and persist explicit telemetry/cloud-sync choices. Failed probes
remain blocked with bounded diagnostics and can retry after restart; the WebView
cache is non-authoritative and strict decoding rejects forged completion,
reordered requirements, and prerequisite jumps. The current full native Linux
manifest passes 100 Swift XCTest selectors and 19 Rust tests; the desktop suite
passes all 411 TypeScript/React tests plus its production bundle verifier.

This does **not** close GAP-008 or P-13. Provider account connection and real log
scan, cloud authentication, portal permission readback, tray host verification,
update-channel verification, chat-engine selection, and first-data confirmation
are still explicit optional acknowledgements or separate workflows. Installed
Ubuntu/Fedora keyboard, screen-reader, restart, denial, and repair evidence also
remains required.

- **Difference:** macOS onboarding connects providers, scans, requests system
  permissions, configures chat, and gates completion. Linux advances local state
  with Continue/Skip; only daemon retry is active and prerequisite acknowledgments
  are never established by real readback.
- **Why it matters:** users can finish setup with no service, secret backend,
  provider data, auth, portal permission, or working tray.
- **Recommended solution:** make every required step an idempotent action plus
  verification: install/enable service, unlock/test secret store, discover logs,
  connect provider/auth, select chat engine, request portals, validate tray and
  update channel, and run a first-data check.
- **Priority:** **High**.
- **Implementation notes:** persist daemon-owned progress, not browser-local
  assertions; support resume, rollback, diagnostics, distro-specific copy, and
  explicit optional skips; link failures directly to repair actions.
- **QA verification:** clean-user journeys on Ubuntu/Fedora; missing daemon,
  locked keyring, no provider, offline auth, portal denial, icon-only tray,
  partial completion, app restart, upgrade migration, screen reader, and keyboard.

### GAP-009 - Finish the chat workspace

- **Difference:** macOS supports persisted/searchable threads, twelve backends,
  model selection, streaming, attachments, citations, tool approvals, panes,
  desktop grants, resume/export, and pop-out. Linux now has real encrypted
  thread persistence/search/pagination, exact model/thinking-level selection,
  daemon-owned bounded single-use attachment refs, citations, approvals, and
  bounded unloaded-history/export/resume/pop-out behavior. Remaining backend
  breadth, binary attachment parity, and installed proof remain incomplete.
- **Why it matters:** chat is a primary workflow; presenting a file or model
  control without a real transport still creates false confidence and data-loss
  risk.
- **Recommended solution:** extend the implemented attachment ref store into
  provider-native binary/image handling, finish the remaining backend adapters,
  and certify the existing citation/approval/history/pop-out contracts against
  an installed daemon; retain the typed model catalog and fail closed until each
  capability is live.
- **Priority:** **High**.
- **Implementation notes:** keep the daemon authoritative for thread state;
  reconcile reconnect/cancel/idempotency; do not expose controls until their
  capability is live; port macOS controller contracts into cross-platform tests.
- **QA verification:** exact transcript replay, every supported backend/model,
  image/PDF/text/audio/video attachment, tool approve/reject/race, citation open,
  cancel/retry, offline/reconnect, restart, pop-out/rejoin, export, and large
  transcript performance.

### GAP-010 - Complete account, cloud, billing, and trusted devices

- **Difference:** macOS can sign in/link/sign out, manage membership, cloud
  backup, conflicts, remote access, and trusted devices. Linux mostly projects
  status and checkout; auth must be completed elsewhere, cloud mutations are
  absent, and trusted-device mutation is explicitly unavailable.
- **Why it matters:** cross-device continuity, entitlements, remote workflows,
  recovery, and paid product behavior cannot be completed in the app.
- **Recommended solution:** add daemon-owned PKCE/device-code auth with validated
  callbacks, secure refresh-token custody, sign-out/revocation, App Check,
  membership, backup/conflict state, trusted-device lifecycle, remote MCP, and
  safe web billing restore.
- **Priority:** **High**.
- **Implementation notes:** external URLs must be HTTPS allowlisted; deep links
  must validate scheme/host/state; secrets stay native; define conflict and
  offline semantics before UI; surface Apple-only history honestly.
- **QA verification:** auth success/cancel/state mismatch/expiry, malicious
  redirect rejection, restart, sign-out revocation, device add/revoke/transfer,
  backup/restore/conflict/offline, checkout/restore, entitlement refresh, and
  clock skew.

### GAP-011 - Replace activity and memory substitutes with true domain state

- **Difference:** macOS exposes indexed session transcripts and a real memory
  review queue. Linux now replays bounded persisted session bodies and resumes
  through the canonical `run.resume` contract, with provider-safe handoff
  fallback and explicit untrusted/error states. The daemon-owned memory
  quarantine lifecycle is now source-integrated; full-history source resolution,
  cross-device replication, and installed proof remain incomplete.
- **Why it matters:** users cannot inspect or resume actual work, and the memory
  UI describes semantics the backend does not provide.
- **Recommended solution:** complete session source/full-history/export RPCs and
  cross-device memory audit replication; retain the implemented durable
  quarantine decision path and bounded replay/resume.
- **Priority:** **High**.
- **Implementation notes:** preserve exact source/session/project IDs; support
  local/cloud conflict and missing-body recovery; make review decisions
  idempotent and auditable; never infer transcript content from usage metadata.
- **QA verification:** exact replay, full-text search, source filters, export,
  resume, large pagination, missing/corrupt body, cloud conflict; pending memory
  create/approve/reject/reload/audit/forget/chat retrieval across devices.

### GAP-012A - Complete Projects

- **Difference:** macOS treats projects as registered domain objects with exact
  session associations and detail. Linux renders read-only cards derived from
  session data and fuzzy title matching, with no create/register/edit/delete flow.
- **Why it matters:** grouping can be wrong, users cannot correct it, and project
  context cannot reliably drive search, insights, missions, or chat.
- **Recommended solution:** add daemon-owned project CRUD, exact stable IDs,
  explicit session reassignment, detail/history, and migration from inferred rows.
- **Priority:** **Medium**.
- **Implementation notes:** never use display titles as identity; define deletion
  and orphan behavior; share the domain schema with macOS; paginate large projects.
- **QA verification:** create/edit/delete/register/reassign/reload; duplicate
  names, moved repositories, orphan sessions, cloud/local conflict, 10k sessions,
  and migration from current fuzzy associations.

### GAP-012B - Complete Missions

- **Difference:** Linux can list, create, and approve mission decisions, but lacks
  macOS depth for questions, evidence, operating history, freshness, health,
  cancellation, and recovery.
- **Why it matters:** users cannot understand or safely operate a long-running
  mission from Linux when state changes, stalls, or requires intervention.
- **Recommended solution:** expose typed mission event/history/evidence/question/
  health RPCs and build actionable stale, blocked, approval, and recovery states.
- **Priority:** **Medium**.
- **Implementation notes:** keep ordering and idempotency daemon-owned; separate
  mission state from transient UI state; preserve evidence IDs and audit links.
- **QA verification:** create/start/approve/deny/answer/cancel/retry/recover;
  history ordering, stale/fresh transitions, missing evidence, daemon restart,
  concurrent decisions, and offline/reconnect.

### GAP-012C - Complete Insights

- **Difference:** macOS insights include editorial analysis, source evidence,
  citations, follow-ups, comparison, and audit actions. Linux primarily renders
  usage charts and summary/anomaly projections.
- **Why it matters:** the Linux surface can show a pattern but cannot establish
  why it exists or let the user investigate and act on it.
- **Recommended solution:** add a typed insight document/evidence model, citation
  navigation, compare periods/providers/models, follow-up actions, and audit state.
- **Priority:** **Medium**.
- **Implementation notes:** preserve source IDs and generated-at freshness; make
  unsupported inference explicit; share calculation and citation fixtures.
- **QA verification:** evidence-linked insight generation, stale data, missing
  source, compare filters, follow-up navigation, audit history, keyboard/screen
  reader, and large-period performance.

### GAP-012D - Complete Database and indexing operations

- **Difference:** Linux has index/watch foundations and bounded daemon-owned
  code search/context-pack inspection through [PR #1680](https://github.com/Imagine-That-Ai/BurnBar/pull/1680). It now also has SQLCipher-gated encrypted snapshot/restore with owner-only path checks, size bounds, integrity hashes, atomic replacement, rollback, and watcher reopen, plus a macOS-compatible v1 passphrase recovery bundle with PBKDF2/AES-GCM and native key-custody hooks. It still lacks the macOS-equivalent record inspector, key-loss/device-transfer recovery, deep rebuild UX, live Secret Service/KWallet proof, and installed proof.
- **Why it matters:** users cannot diagnose missing sessions, inspect canonical
  records, recover corruption, or trust that updates are current.
- **Recommended solution:** finish daemon-owned inspect/search/snapshot/watch/
  rebuild/recovery-bundle RPCs with pagination, cancellation, query tracing, and
  clear encryption/key-custody state; add recovery key-loss/device-transfer
  handling and live Secret Service/KWallet verification; preserve the atomic
  same-key snapshot path as the rollback primitive.
- **Priority:** **Medium**.
- **Implementation notes:** unify inotify ownership rather than layering another
  poller; use `OpenBurnBarQueryTracer`; keep raw sensitive content behind explicit
  reveal/export policy.
- **QA verification:** search/inspect/snapshot/watch/rebuild/recover; N+1 limits,
  10k/100k rows, corruption, locked key, permission loss, path move, event burst,
  cancellation, restart, passphrase bundle import/export, key loss, and device
  transfer. Run the Linux SQLCipher round-trip with the production daemon secret
  before marking the row ready.

### GAP-012E - Complete provider and model workspaces

- **Difference:** macOS has provider/model deep dives, health, account profiles,
  catalog, routing, and failover. Linux now has the corresponding daemon-backed
  workspace and strict catalog/config mapping, but live credential routing,
  mutation persistence, and installed failover proof remain incomplete.
- **Why it matters:** users cannot understand availability or control routing
  when quotas, credentials, models, or providers change.
- **Recommended solution:** finish the daemon-owned provider/account/model
  catalog, health, priority, drain target, routing, and failover lifecycle with
  deep links, live credentials, and explicit unavailable states.
- **Priority:** **Medium**.
- **Implementation notes:** depend on the shared capability catalog and secure
  custody; keep policy mutations typed/audited; explain unavailable providers and
  Linux-specific discovery paths.
- **QA verification:** catalog refresh, credential/account switching, health
  degradation, quota exhaustion, manual/automatic failover, drain target,
  unavailable model, restart persistence, and audit history.

### GAP-013 - Complete and centralize settings

- **Difference:** macOS has 16 searchable settings tabs. Linux has 13 and omits
  Model Proxy, Computer Use, and Pets from settings; cloud/device/media/privacy
  controls are incomplete or read-only even when route-level UI exists.
- **Why it matters:** configuration is scattered, capabilities are hard to
  discover, and users cannot exercise privacy or operational agency.
- **Recommended solution:** generate settings metadata from a shared capability
  schema, provide searchable deep links, add Linux-native detail pages, and back
  all mutable controls with typed daemon configuration plus readback.
- **Priority:** **Medium**.
- **Implementation notes:** unavailable controls must explain the native
  substitute; store UI navigation locally but product policy in the daemon;
  preserve distro/compositor-specific help without forking the schema.
- **QA verification:** search/deep-link every setting, keyboard navigation,
  persistence/restart, policy conflicts, telemetry opt-out at emission source,
  unavailable capability copy, and migration from existing localStorage keys.

### GAP-014 - Build native tray, notifications, deep links, shortcuts, and startup

- **Difference:** macOS provides a rich menu-bar experience with live cost,
  quota, providers, quick switch, chat, freshness, and update state. Linux now
  has a validated startup/deep-link handoff, background tray launch, XDG
  autostart, desktop MIME registration, freedesktop action routing, and
  per-binding shortcut health in [PR #1679](https://github.com/Imagine-That-Ai/BurnBar/pull/1679),
  `5f74018422`, and `a5571694bb`; it still lacks complete installed host
  lifecycle and cross-desktop receipts.
- **Why it matters:** repeated daily workflows, alerts, recovery, auth, and panic
  controls feel incomplete or cannot work outside the main window.
- **Recommended solution:** finish StatusNotifier/AppIndicator host behavior,
  preserve the typed per-binding X11/Wayland/unknown shortcut states, and add
  installed freedesktop lifecycle receipts without treating unsupported
  compositors as available.
- **Priority:** **High**.
- **Implementation notes:** support GNOME's icon-only limitations; use shared
  live view models and freshness semantics; never depend on the tray as the sole
  panic path; handle multi-monitor placement and tray host loss.
- **QA verification:** icon-only and rich hosts, stale/offline/reconnect state,
  keyboard/screen-reader navigation, notification actions/relaunch, OAuth return,
  global panic latency, login start, multi-monitor, and tray crash/recovery.

### GAP-015 - Implement honest update UX

**Implementation update (2026-07-09): partially closed in the implementation
branch.** The Linux shell now performs the availability check in native Rust,
pins the release-signing public key and SPKI fingerprint, verifies detached
Ed25519 signatures, validates schema/product/platform/channel/semantic version,
requires both supported architectures, rejects downgrade/replay and untrusted
URLs, and exposes only typed validated state to the renderer. The installed
`.deb` route was exercised through AT-SPI and correctly rendered **Update
metadata rejected** against the currently invalid public endpoint. The
package-manager-owned install/rollback lifecycle, signed public feed,
two-architecture artifacts, and prior-version upgrade/rollback evidence remain
open; this row is therefore still **Partial**, not closed.

- **Difference:** macOS exposes version, automatic checks, channel, install, and
  restart behavior. Linux appropriately delegates installation to package
  mechanisms but cannot check signed availability or present reliable
  compatibility, restart, and rollback state.
- **Why it matters:** users cannot tell whether they are secure/current, and
  shell/daemon version drift can break the app.
- **Recommended solution:** verify signed release metadata in native code; show
  installed/channel/latest and daemon compatibility; route actions to apt, dnf,
  Flatpak, or AppImage semantics; provide restart and rollback guidance.
- **Priority:** **High**.
- **Implementation notes:** never self-mutate distro-owned files; protect against
  downgrade/replay/architecture mismatch; cache a last-known-good signed
  manifest; couple daemon/schema compatibility to release metadata.
- **QA verification:** current/update/offline/tampered/replayed/downgrade/mismatched
  architecture and daemon versions; interrupted deb/rpm/AppImage upgrade,
  rollback, restart, and feed outage.

### GAP-016 - Replace broken SmartHub command execution

- **Difference:** macOS has typed SmartHub integrations. Linux now has a typed,
  root-owned allowlist for discovery/status/test/cast/device/parity operations,
  bounded request and output decoding, timeout/cancellation, and explicit
  degraded states; it still lacks live device/Avahi outcomes.
- **Why it matters:** a visible route must remain useful and safe when the
  optional native CLI or device is absent; generic shell execution would be a
  security regression.
- **Recommended solution:** keep the structured daemon/Tauri commands and add
  a Linux-host matrix for real Cast, Home Assistant, AWTRIX, and Pixel Clock
  behavior.
- **Priority:** **High**.
- **Implementation notes:** parse Avahi output structurally; validate device IDs,
  URLs, payload sizes, JSON depth/items, request IDs, timeout, cancellation, and
  concurrent stdout drain; never expose generic shell; reuse shared SmartHub
  contracts where possible.
- **QA verification:** focused typed/Rust tests cover hostile input, bounds,
  cancellation, and timeout. Remaining QA is real Cast, Home Assistant, AWTRIX,
  and Pixel Clock devices; escaped names, absent dependency, auth failure,
  offline/reconnect, and command-injection attempts on supported Linux hosts.

### GAP-017 - Make text expansion real and safe

- **Difference:** macOS provides global, accessibility-aware expansion with
  persistence and sync. Linux now keeps snippets and consent in daemon-owned
  AES-GCM sealed storage with native Secret Service/KWallet key custody and
  applies expansion in the in-app Composer only; global IBus/fcitx integration,
  external secure-field exclusions, and sync are not implemented.
- **Why it matters:** durable snippets must not live in renderer storage, and an
  honest in-app substitute must never silently become a global keylogger.
- **Recommended solution:** retain the daemon boundary and explicit in-app-only
  consent, then implement an opt-in IBus/fcitx input method with secure-field
  and application exclusions plus conflict-aware sync.
- **Priority:** **High**.
- **Implementation notes:** no renderer localStorage or global capture; use the
  daemon RPC canon, AES-GCM associated data, owner-only permissions, native key
  custody, consent gating, secure-field hooks for supported in-app controls, and
  fail-closed missing-key/corruption behavior. Capability-gate Wayland/X11
  behavior and define import/export/sync conflicts and LLM preview privacy.
- **QA verification:** focused tests cover consent gating, Composer expansion,
  RPC wire names, encrypted persistence/restart, permissions, tamper/corruption,
  missing native secret backend, and no-global-capture scans. Remaining QA is
  normal app inputs, GTK/Qt/Electron apps, password/secure fields, excluded
  apps, clipboard restore, IME composition, Unicode, recursion, import/export,
  sync, GNOME/KDE Wayland, and X11.

### GAP-018 - Ship a real compositor-aware pet companion

- **Difference:** macOS has an animated desktop companion with overlay behavior
  and interaction. Linux renders a route-contained point-cloud preview and
  assumes overlay capability in nearly every environment except GNOME Wayland.
- **Why it matters:** the visible result is materially less polished and can
  steal focus or block input when optimistic compositor assumptions are wrong.
- **Recommended solution:** retain the X11 child-window and fixed-marker summon
  contract now present in source, then render the real glTF mesh/material/animation
  in a separate transparent always-on-top/pass-through window only after capability
  proof; add selection, chat/file interactions, multi-monitor behavior, and a
  clearly labeled contained fallback for Wayland/unknown sessions.
- **Priority:** **High**.
- **Implementation notes:** maintain a compositor capability matrix; use reduced
  motion and GPU budgets; do not claim click-through from environment variables
  alone; isolate crashes from the main app.
- **QA verification:** GNOME/KDE/Sway Wayland and X11 focus, click-through,
  topmost, drag, scaling, animation, reduced motion, multi-monitor, hotkey,
  restart, GPU fallback, and unsupported contained mode.

### GAP-019 - Replace synthetic accessibility evidence with assistive-tech proof

**Implementation update (2026-07-13): source polish is now explicit; certification
remains open.** All 19 routes and important states run through axe; the installed
`.deb` is exercised through AT-SPI actions, Orca process/focus observation,
keyboard-only traversal, and requested 200% zoom. PR #1683 adds shared
`prefers-reduced-motion`, `prefers-contrast: more`, and `forced-colors: active`
tokens/focus/status rules with DOM keyboard/status contracts. The full shell
verifier rejects missing or synthetic accessibility artifacts. GNOME/KDE matrix
breadth, high-contrast visual captures, and physical assistive-tech execution
remain open.

- **Difference:** macOS has broad semantic labels/actions and targeted tests.
  Linux has useful landmarks, a skip link, ARIA live regions, focus styling, and
  reduced-motion CSS, but its automated scan returns hardcoded rows and its
  purported AT-SPI proof contains only bus/window properties, not accessible
  nodes and actions.
- **Why it matters:** visual/component tests do not prove keyboard completion,
  screen-reader meaning, focus order, contrast, reflow, or live announcements.
- **Recommended solution:** run axe on every route and important state; add
  Playwright keyboard/zoom/forced-colors/reduced-motion checks; exercise the
  packaged app with Orca and AT-SPI; fix focusable `aria-hidden` elements and any
  focus rules that remove the indicator.
- **Priority:** **High**.
- **Implementation notes:** subscribe to media-query changes, test dynamic
  state, standardize names/roles/states/errors, and record the actual AT-SPI tree
  plus action transcript; include hardware/software rendering and high contrast.
- **QA verification:** zero serious axe violations, every flow keyboard-complete,
  visible focus, no focus trap, 200% zoom/reflow, Orca names/roles/states/actions,
  live regions, GNOME High Contrast, reduced motion, and no color-only meaning.

### GAP-020 - Add real reliability, performance, and installed-shell gates

**Implementation update (2026-07-10): foundation implemented; certification remains open.**
Linux now records repeated packaged process-start, tray-open, daemon-reconnect,
and post-paint route percentiles. A production-linked Swift harness runs the
same deterministic SQLite, FTS, JSONL, and Hermes stream-parser workloads on
macOS and Linux and compares correctness, p95/p99, RSS, CPU, and soak duration.
PR and nightly workflows fail closed on missing or malformed evidence; nightly
uses 100,000 rows and a 30-minute soak. The daemon now owns bounded
start/resume/stop subscription state with monotonic cursors, restart recovery,
cancellation tombstones, and explicit degraded-pull metadata. The renderer has
one offline-aware, lifecycle-aware data supervisor with bounded exponential
backoff and coalesced mounted-route reloads. See
`performance-reliability-validation.md` and
`LINUX_EVENT_SUBSCRIPTION_AUTHORITY.md`.

**Exact-head evidence (2026-07-18):** Release `29646670068` passed both native
architecture package/runtime shards and signed aggregate attestation at
`70ab4eb0b9e66394d709dac246296a3b050e8a3f`; its evidence artifact is
`8430648757` with zip digest
`sha256:30d67cc9ff465206bdc0a38dad1f0aa910b3a4c7f2205ef811175b37976da13b`.
Package update/rollback/data-preservation remains blocked because no compatible
previous same-architecture package was supplied. Nightly `29646670763` then
passed matched 30-minute macOS/Linux correctness/resource soak and the runnable
Ubuntu GNOME/X11 gate; Arch/wlroots, GNOME Wayland, and Fedora/KDE remained
explicitly blocked rows. It also passed 9 Linux Swift suites (**414/414**), the packaged X11
19-route accessibility/onboarding/text-expansion session, and the route budget
(`95.6 ms` p95, 33 samples, budget `120 ms`). Its wrapper transcript ended
`linux-desktop-session-ok`; the former root-owned `EACCES` false failure is
closed, but these are still engineering receipts rather than full product
promotion.

- **Difference:** Linux now has daemon-owned bounded pull subscriptions, a
  single-flight data supervisor, packaged startup/reopen/reconnect percentiles,
  a matched Swift workload harness, Rust boundary tests, and a 30-minute soak
  contract. It still lacks a native push stream. The built main chunk is 655.47
  kB minified and still triggers the Vite size warning. Exact-candidate
  suspend/portal/keyring recovery, comparable-hardware macOS/Linux p95/p99, and
  the full desktop matrix remain unproven.
- **Why it matters:** UI stalls, stale data, daemon death, suspend/resume, leaks,
  and renderer failures will escape the current unit suite.
- **Recommended solution:** certify the implemented cursor/cancellation contract
  in installed packages, add native push delivery without weakening bounded
  backpressure or degraded-state truth, split route code, and enforce comparable
  real-workload budgets. Gate on packaged-shell E2E and Linux Swift behavior
  tests.
- **Priority:** **High**.
- **Implementation notes:** remove diagnostic probes from the critical boot path
  or run them asynchronously with cache/timeouts; measure cold/warm startup,
  first meaningful content, route p50/p95/p99, IPC, parser scan, DB query, chat
  first token excluding upstream, RSS/CPU/GPU, and 30-minute soak/leak behavior.
- **QA verification:** daemon kill/restart/socket stall, offline/online,
  suspend/resume, clock change, locked DB/keyring, 10k/100k sessions, large
  transcript, low-memory, software rendering, 30-minute idle/use soak, and
  macOS-relative workflow budgets on equivalent hardware.

### GAP-021 - Harden the Tauri command boundary and remove fixture leakage

**Implementation update (2026-07-10): closed in the implementation branch.**
The renderer capability set is `core:default`; generic shell execution is not
granted. Native URL opening stays behind scheme/host validation, gateway secrets
stay in Rust, and production builds replace daemon fixtures with a fail-closed
module whose activation is unavailable. Mutation tests cover the IPC, URL,
fixture, and production-bundle boundaries.

- **Difference:** macOS uses narrow native service APIs. Linux has CSP, but still
  grants broad `shell:default`; the support UI exposes a persistent daemon
  fixture toggle in normal product UI; sensitive operations are not uniformly
  typed and allowlisted.
- **Why it matters:** WebView compromise has more process-launch leverage, and
  users/evidence can silently mistake fake data for live state.
- **Recommended solution:** remove generic shell capability, expose narrow Rust
  commands with strict URL/argument allowlists, compile fixtures only into
  development/evidence builds, and show an unavoidable test-mode banner.
- **Priority:** **Critical** for bearer/shell containment; **High** for fixture
  leakage.
- **Implementation notes:** centralize external URL validation; add command-level
  authorization and schema validation; make release profiles fail if fixture
  code or test flags are reachable; record live vs fixture provenance in every
  evidence artifact.
- **QA verification:** arbitrary command, local-file URL, unexpected scheme,
  non-HTTPS host, argument injection, oversized payload, path traversal, and XSS
  probes all fail; release artifacts have no fixture activation path; debug mode
  shows a banner on every route and never contaminates release evidence.

### GAP-022 - Finish diagnostics and visual/interaction polish

- **Difference:** macOS provides mature native windows, consistent controls,
  recovery states, and polished data density. Linux has a strong token base but
  retains inline styles, Unicode/emoji control glyphs, raw JSON panels, inaccurate
  save-dialog copy, disabled text controls, and no trustworthy current visual
  regression set.
- **Why it matters:** the product reads as an engineering console in several
  routes and support bundles may not contain the facts needed to recover users.
- **Recommended solution:** use shared components and iconography, complete
  loading/empty/error/recovery states, add native save dialogs and privacy tiers,
  and capture packaged visual regressions at supported sizes and renderers.
- **Priority:** **Medium**.
- **Implementation notes:** diagnostics should include redacted daemon/package/
  renderer/capability/version facts with 0600 permissions; users preview content
  and choose destination; remove raw JSON from normal flows; keep compact-density
  and responsive behavior aligned with macOS outcomes, not SwiftUI pixels.
- **QA verification:** desktop/compact/200% scale screenshots, no clipping or
  overlap, consistent hover/focus/disabled/error states, dark/high-contrast,
  save/cancel/permission behavior, corrupted daemon/package mismatch bundles,
  and token/path/session-content redaction.

### GAP-023 - Make CI and release automation fail closed

**Implementation update (2026-07-10): implementation complete; hosted closure
pending.** PR/nightly/release workflows run Linux-native behavior gates, preserve
strict failures, resolve versions on tag and manual paths, build native aarch64
and x86_64 shards, finalize package lifecycle sessions, and assemble only when
both commit-bound sessions pass. Workflow mutation tests protect this wiring.
The remaining proof is a real hosted two-architecture candidate run with a prior
version and final signing/publication credentials.

- **Difference:** macOS release automation has mature behavioral gates. Linux PR
  CI builds Swift targets without running their behavior tests; the
  `--allow-blocked` verifier mode can return success for unrelated failures; the
  Make release target swallows strict verifier failure; PR artifact paths point
  at older mission output; and tag-triggered release code consumes a dispatch-
  only version input. Source-archive and live package behavior are not enforced.
- **Why it matters:** the repository can report green while testing the wrong
  output, skipping behavior, or failing the command that is meant to block
  promotion.
- **Recommended solution:** split diagnostic reporting from exit status; run all
  Linux Swift and Cargo tests; run package-launched UI/service E2E; upload only
  the current evidence directory; derive and validate version from either the
  dispatch input or tag; require source offer and full closure verification.
- **Priority:** **Critical**.
- **Implementation notes:** `--allow-blocked` may downgrade only explicitly
  classified environmental blockers and must still fail integrity, security,
  stale-evidence, or structural errors; Make must propagate the strict verifier
  exit code; tag and manual dispatch paths must share one validated version
  resolver; generated evidence paths must be single-sourced.
- **QA verification:** mutation tests for every gate; run both tag and manual
  dispatch flows; force Swift/Cargo/UI/signature/feed/source/update failures and
  assert red; assert only a named environmental blocker can produce the
  documented open-with-blocker state.

### GAP-024 - Build a real current-version differential oracle

**Implementation update (2026-07-13):** [PR #1682](https://github.com/Imagine-That-Ai/BurnBar/pull/1682)
adds the reusable evidence comparator and focused tests. It sorts object keys,
redacts credential-shaped values, supports explicit dotted-path volatile-field
ignores, computes normalized SHA-256 checksums, reports stable path-level
differences, and returns `0` for exact match, `1` for differences, and `2` for
invalid input. This closes the comparison mechanism only; it does not provide
the same-commit macOS/Linux artifacts or installed workflow evidence.

- **Difference:** macOS is the gold standard, but current Linux provider/Hermes
  evidence can promote a Linux-labeled canonical pass from preexisting contract
  files rather than building and comparing both implementations at the same
  commit, corpus, and schema.
- **Why it matters:** shared fixtures can prove internal consistency while the
  real macOS and Linux products have drifted in parsing, normalization, routes,
  RPC behavior, or UI outcomes.
- **Recommended solution:** build the macOS oracle and Linux target from the same
  release commit, run both over the same versioned corpus and scripted workflows,
  normalize platform-only fields, and diff domain results and user-visible
  outcomes directly.
- **Priority:** **High**.
- **Implementation notes:** attest binary hashes, OS/runtime, corpus hash, schema
  version, feature flags, clock/timezone, and normalization rules; keep expected
  divergences explicit and reviewed; never let a Linux-generated file stand in
  for the macOS side.
- **QA verification:** inject a mutation unique to macOS and then one unique to
  Linux; each must fail the differential job. Repeat for parser output, quota,
  route inventory, settings, chat/session events, memory decisions, and every
  shared daemon RPC.

### GAP-025 - Prove dashboard, navigation, and window behavior in the product

**Implementation update (2026-07-10): partially closed in the implementation
branch.** The installed aarch64 `.deb` activated all 19 routes through AT-SPI
command-palette actions and captured a screenshot, window record, and accessible
tree for each route. The remaining gap is the six-layout live-data visual matrix,
deep-link/secondary-window behavior, responsive sizes, and supported compositor
coverage.

- **Difference:** Linux registers 19 routes, aligns the seven primary sections,
  and implements six React dashboard layouts with unit tests. macOS additionally
  provides provider/model deep navigation, mature multi-window/pop-out behavior,
  persisted live layout state, and proven dense content. Linux's current six-
  layout visual evidence is incomplete; installed route captures are now
  nonblank, but do not cover every layout/state/viewport combination.
- **Why it matters:** source and JSDOM tests do not prove that users can see,
  navigate, resize, restore, deep-link, or use the real packaged dashboard.
- **Recommended solution:** complete typed deep links and Linux-native secondary
  windows, then run installed-package navigation and visual regression with live
  data across all layouts and responsive sizes.
- **Priority:** **Medium**.
- **Implementation notes:** preserve route/state on restart; use stable responsive
  constraints; restore focus after navigation/window close; separate renderer
  safe mode from layout choice; do not use a static HTML board as product proof.
- **QA verification:** every route and deep link, back/forward, keyboard commands,
  layout persistence, pop-out/rejoin, restart, multi-monitor, compact/desktop/200%
  widths, empty/error/stale/live data, nonblank pixels, and focus restoration.

### GAP-026 - Complete quota account and switching behavior

- **Difference:** Linux has a strong quota read surface, while macOS also ties
  quota history to provider accounts, switching profiles, drain targets, alerts,
  and routing decisions.
- **Why it matters:** users can see exhaustion but cannot complete the response
  workflow from Linux or verify which account/model will receive new traffic.
- **Recommended solution:** connect quota rows to the provider/account catalog,
  expose audited switch/drain/priority actions, and integrate alert thresholds and
  failover explanations.
- **Priority:** **Medium**.
- **Implementation notes:** depend on secure credential custody and provider
  catalog; keep routing mutations daemon-owned; distinguish stale, unavailable,
  unknown, and unlimited states; preserve account privacy in diagnostics.
- **QA verification:** multi-account refresh, quota reset windows, stale/error/
  unlimited states, switch and rollback, drain target, threshold notification,
  quota-driven failover, restart persistence, and concurrent clients.

### GAP-027 - Complete Data and Privacy workflows

- **Difference:** macOS Data & Privacy covers vault inventory, export, deletion,
  recovery, consent, telemetry, and panic controls. Linux exposes inventory and
  support/privacy copy, but important controls are read-only or incomplete and no
  equivalent account/local deletion and recovery workflow is proven.
- **Why it matters:** users lack full control over sensitive transcripts,
  memories, credentials, analytics, and cloud/local retention; destructive actions
  without clear scope or recovery can cause irreparable loss.
- **Recommended solution:** implement daemon-owned privacy policy, scoped export,
  local/account deletion, retention, recovery, telemetry consent, and panic
  workflows with explicit previews, confirmations, audit, and cloud coordination.
- **Priority:** **High**.
- **Implementation notes:** define deletion scope and retention before UI; use
  native save/confirmation dialogs, secure erase where meaningful, server-side
  deletion receipts, export encryption, and recovery-key custody; keep MAS/Apple-
  only behaviors labeled rather than silently omitted.
- **QA verification:** export preview/cancel/encrypt/import, telemetry opt-out,
  local-only deletion, cloud/account deletion, partial failure/retry, retention
  expiry, recovery success/failure, panic, multi-device propagation, offline
  queueing, locked keyring, and redaction.

## Linux Parity Implementation Plan

### Execution status after the remediation wave

| Task group | State | Evidence/acceptance reached | Remaining dependency |
|---|---|---|---|
| LNX-GATE-001, LNX-REL-VERIFY-001, LNX-CI-001 | Implemented | Complete blocked inventory, crypto/closure mutations, strict workflow wiring | Exact signed candidate and all required rows green |
| LNX-SEC-001, LNX-IPC-001, LNX-CAP-001 | Implemented | Native secret custodian, native gateway proxy, production fixture boundary, runtime capability manifest | GNOME/KDE/headless environment certification |
| LNX-A11Y-HARNESS-001 | Implemented | All-route axe plus installed AT-SPI/Orca/keyboard/zoom contract and PR #1683 forced-colors/contrast/reduced-motion source tests | Full architecture/desktop/high-contrast matrix |
| LNX-PERF-HARNESS-001 | Implemented | Matched workload tools, p50/p95/p99/resource capture, nightly soak contract | Final candidate results on comparable hardware and environments |
| LNX-RUN-001 | Partially proven | Clean aarch64 package-owned GUI/daemon/version/uninstall session | x86_64, prior-version lifecycle, suspend/resume, compositor breadth |
| LNX-PKG-001 | Implemented in workflow; construction proven | Four-artifact aarch64 and architecture-correct x86_64 shards green with 28/28 smoke checks each; native dual-architecture aggregation is fail closed. Official AppImages now admit the GUI only through a signed canonical manifest bound to the exact final bytes; focused peer-admission verification passed 8 Swift and 28 Node tests | Provision the release signing secret, produce the exact signed aggregate, then complete native hosted x86_64, installed x86_64, rpm/AppImage lifecycle, and channel proof |
| LNX-UPD-001 | Partially implemented | Native signed-feed availability verifier rejects invalid public metadata | Valid feed plus deb/rpm/AppImage update, rollback, and data preservation |
| LNX-CHANNEL-001 through LNX-DIFF-001 | Open/partial | Existing package/channel/product foundations retained; P-39 comparator mechanism is implemented in [PR #1682](https://github.com/Imagine-That-Ai/BurnBar/pull/1682) | Daily-use platform foundation, same-commit macOS/Linux artifact generation, and current differential proof |
| P07/P11/P13/P14/P16/P17/P18/P19/P20/P22/P25/P27/P28/P29/P30/P31/P40 implementation slices | In review | Checked browser Computer Use panel, 33-provider catalog, daemon-backed onboarding credential setup, exact encrypted chat persistence/pagination/export plus bounded citations, approvals, unloaded-history traversal and pop-out, loaded activity export, fail-closed account/enrollment posture, daemon-authoritative memory quarantine, project management plus typed delete/reassign lifecycle, mission detail/cancel/evidence snapshots plus authoritative health/history RPC, bounded database code inspection/recovery UX, signed update freshness/compatibility, native startup/deep-link handoff plus single-instance forwarding, SmartHub allowlist/bounds/cancellation, daemon-owned AES-GCM text expansion with native key custody and consent plus trigger-only external expansion, accessibility preference styling, fail-closed pet capability, and daemon-backed privacy consent are implemented in PRs [#1681](https://github.com/Imagine-That-Ai/BurnBar/pull/1681), #1676, #1667, [#1684](https://github.com/Imagine-That-Ai/BurnBar/pull/1684), `dd705ca1dd`, [#1685](https://github.com/Imagine-That-Ai/BurnBar/pull/1685), #1658, #1671, #1670, [#1688](https://github.com/Imagine-That-Ai/BurnBar/pull/1688), #1677, #1680, `f5d562da82`, `238577c904`, #1673, #1679, [#1686](https://github.com/Imagine-That-Ai/BurnBar/pull/1686), [#1683](https://github.com/Imagine-That-Ai/BurnBar/pull/1683), #1674, #1672, #1691, `752f6e9745`, `bf0eb36294`, `d2dbbe8df8`, `bd9d6a5173`, `702f59146e`, `d7cffc79d6`, and `3b652f9b9e` | Merge/rebase onto the release head, then prove installed behavior; remaining backends/binary attachments, activity source resolution, normalized provider corpus, OAuth/portal auth, trusted-device mobile execution, cross-device memory replication, database key-loss/device-transfer backend proof, installed mission health/history, freedesktop live notification receipts/global shortcut breadth, Linux keyring/IBus/Fcitx runtime, secure-field matrix, native pet adapters, and destructive privacy/deletion/retention contracts remain separate dependencies |
| LNX-CHAT-CITATIONS-APPROVALS-001 | Implemented in source; installed proof blocked | Bounded citation normalization/source focus and daemon-issued approval IDs with approve/reject/cancel single-flight handling; attachment upload/metadata, path-free attachment metadata in JSON/Markdown export, extension-derived MIME preflight, explicit unsupported-PDF rejection before append/upload, reconnect/visibility, functional options, pop-out boundary, daemon-authoritative full-history JSON/Markdown export, strict unloaded-page traversal, validated resume, and config-derived backend availability are now integrated in `0d8ee32526`, `618c7286b9`, `e0451afa5e`, `dd705ca1dd`, `5fdcccabfa`, and `702f59146e`; focused chat lane: 60/60 tests plus app TypeScript/build pass | Run unloaded-history/reconnect/pop-out/backend catalog flows against an installed Linux daemon; re-upload staged attachments after daemon restart; compare with macOS behavior; add provider-native binary/PDF support before claiming those formats |
| LNX-MEMORY-QUARANTINE-001 | Implemented in source; installed proof blocked | `752f6e9745` adds daemon-owned review-status persistence, quarantine/approved/rejected/forgotten transitions, opt-in review feed, metadata tombstones, audit hashes, typed RPC/capability/socket coverage, strict Tauri mapping, and fail-closed renderer decisions; focused memory/bridge tests: 22 + 81 pass, app TypeScript pass | Exercise pending creation, approve/reject/forget/reload, normal-recall exclusion, audit continuity, and cross-device behavior against an installed daemon and real cloud-sync authority |
| LNX-PRIVACY-ROUTE-RETENTION-001 | Implemented in source; installed proof blocked | `4cdc505537` plus `9598c0b9e8` add daemon-backed local-store inventory and exact preview/execute deletion for the allowlisted proxy-route log and encrypted text-expansion store. `7c8a214ce6` and `825e081bda` add selected-scope encrypted export with authenticated PBKDF2/AES-GCM envelope, bounded payloads, owner-only output, race/path/permission checks, typed daemon/Tauri wiring, passphrase clearing, and Settings controls. The control binds a five-minute scoped token to owner/perms/fingerprints, requires exact confirmation, uses idempotent unlink, and explicitly excludes transcripts, credentials, and account data; Settings/bridge and Core/daemon contract tests pass | Exercise inventory, scope selection, preview expiry, confirm/cancel, clear/export success/failure, restart, locked keyring, tamper/permission rejection, native save destination, and ensure unrelated transcript/credential/account data remains intact; retention/account erasure/backend receipts remain separate |
| LNX-QUOTA-ACCOUNT-SWITCHING-001 | Implemented in source; installed proof blocked | `be375903f0` adds preferred provider credential-slot switching through the existing daemon config contract, explicit auto-routing reset by omission, fixture-safe behavior, no-secret rendering, and disabled/read-only live behavior when `config.update` is unavailable; focused Settings tests 23/23 pass | Exercise switching between ready/exhausted/cooling slots against an installed daemon, verify persisted preferred routing after restart, auto-routing recovery, quota/status refresh, and cloud-account/trusted-device boundaries |
| LNX-SMARTHUB-HARDENING-001 | Implemented in source; live device proof blocked | Typed operation allowlist, request ID validation, bounded JSON depth/items/strings/output, concurrent stdout drain, bounded Avahi timeout (4 seconds by default; 0.1-10 seconds from CLI), cancellation registry, degraded renderer state; 15 focused UI/decoder tests and 3 Rust SmartHub tests pass | Provision supported devices and trusted packaged CLI on GNOME/KDE/wlroots hosts; verify Avahi discovery and offline/reconnect outcomes |
| LNX-TEXT-EXPANSION-001 | Implemented in source; Linux keyring/IME proof blocked | Daemon-owned AES-GCM sealed snapshot, native Secret Service/KWallet key custody, owner-only permissions, consent RPC, in-app Composer expansion, no renderer localStorage/global capture, corruption/tamper/missing-key fail closed; live renderer controls stay disabled until storage hydration succeeds (`1ddc8bc33a`); `274f67fba0` adds signed registration, `9598c0b9e8` adds typed engine status/start/stop RPC with Tauri mapping, and `d2dbbe8df8` adds bounded trigger-only external expansion with response validation, denial-before-write, cancellation/timeout/kill-switch teardown, and no forbidden context payloads; focused persistence/Composer/RPC/lifecycle tests pass | Run on Linux with Secret Service/KWallet, then certify opt-in IBus/Fcitx external execution, secure-field exclusions, sync/conflict policy, and Wayland/X11 matrix |
| LNX-MISSION-HEALTH-001 | Implemented in source; installed proof blocked | `bd9d6a5173` adds typed `daemon.mission.health` Core/daemon/Tauri contracts, authoritative projection-derived health, stable packet/result/burn/takeover history, active/failed counters, and Missions UI rendering; focused Swift parse, bridge, UI, and RPC contract tests pass | Run against an installed daemon through restart/reconnect and failed/active/terminal mission scenarios; capture exact-candidate health/history receipts and close the P-20 row |
| LNX-INSIGHT-001-FOLLOWON | Implemented in source; installed proof blocked | `5ddd81245d` and `b3002ab3f9` add a three-pane canvas/library/inspector, selectable evidence widgets, account-scoped persisted selection/density, validated evidence IDs, bounded audit disclosure, refresh, and chat follow-up handoff above the provenance-labeled brief; `825e081bda` adds the daemon-owned `daemon.usage.insights` response, local-rules analysis, bounded usage rows, source identity, citations, and renderer qualitative brief mapping; focused Insights, bridge, and axe tests pass | Exercise the live daemon response against real ledger rows, compare qualitative output/citations with macOS, verify restart/reconnect behavior, and certify the installed workflow |
| LNX-ACTIVITY-001-FOLLOWON | Implemented in source; installed proof blocked | `c1f6e69514` adds bounded daemon-authoritative Activity export, verified source/provider/session/project identity, replay-body completeness checks, and typed unavailable state instead of partial/full-history fabrication; `7ae2412143` requires a verified `sourceID` for replay/resume and removes usage-row fallback; focused Activity/bridge tests (24/24) pass | Exercise installed source resolution, full-history replay, export, and resume-from-export against real daemon data |
| LNX-NOTIFY-001-FOLLOWON | Implemented in source; installed proof blocked | `5f74018422` normalizes direct and second-instance notification actions, validates bounded payloads, expands route aliases, and gives validated cold-start native routes precedence over onboarding; `a5571694bb` adds independent per-binding shortcut registration with typed X11/Wayland/unknown backend health and fail-closed unsupported states; 92 Rust and focused bridge tests pass | Capture GNOME/KDE/wlroots D-Bus action and shortcut receipts, verify host persistence/accessibility, and exercise panic paths under partial registration |
| LNX-PET-001-FOLLOWON | Implemented in source; native overlay proof blocked | `9a527310f9` adds contained summon/focus/status and selection/clear controls with typed capability states; `ea82fe5140` adds a Tauri X11-only companion child with explicit focus and click-through toggles; `3b652f9b9e` adds bounded pointer/mouse drag and Arrow/Home keyboard repositioning with focus and announcement metadata for the Wayland-safe contained substitute; `5c3caab2e` adds the fixed-marker X11-only `Ctrl+Alt+Super+P` summon event and `2b85f1431` exposes accessibility metadata. Wayland and unknown sessions remain fail-closed | Certify the X11 child and summon shortcut on supported desktops and decide/prove the Wayland-native substitute, including GPU, focus, click-through, keyboard, and reduced-motion behavior |
| LNX-CU-CREDENTIALS-001 | Implemented in source; production deployment blocked | Daemon-owned PKCE loopback sign-in, secure refresh-token custody, Firebase ID refresh, per-install Ed25519 App Check enrollment/challenge/mint, 30-minute production token ceiling, account-generation invalidation, phase-safe sign-out/account-switch RPC teardown, scoped old-account route revoke, cancellable HTTP, and redacted RPC state. Explicit pending approval retries on a capped 15/30/60/120/300-second schedule below the public quota; permanent rejection stops polling. The earlier focused daemon credential/runtime packet passed 35/35 and App Check backend packet passed 34/34; the lifecycle/polling regression cases are now covered by the 2026-07-12 full Linux-native aggregate. A dedicated Linux Firebase web app, Desktop OAuth client, and public release variables exist | Deploy the new Functions callables/policy and prove the flow from an installed signed candidate |
| LNX-CU-BROWSER-001 | Source authority/runtime complete; mobile approval source present; installed proof blocked | Exact run/call/generation authority, controller-route v2, mobile renewal, macOS lifecycle policy, Linux native iroh composition, durable replay, polkit owner gate, root-owned Playwright runtime, daemon credential authority, signed AppImage peer admission, and redacted Tauri/account UI are implemented. The active worktree also contains iPad list/approve/revoke UI, canonical device-ID/fingerprint validation, nonce-bound mutation descriptors, stale-load protection, serialized mutations, and focused store/parser tests. The canonical relay challenge is generated consistently for Swift/Kotlin, Android compile/static-analysis and focused tests pass, and earlier generic iOS build-for-testing coverage passes. The assigned physical iPad now has a current-branch install/launch/liveness/console receipt; approval execution and installed certification remain separate gates | Run focused parser/store/mutation tests on the connected physical iPad, then use it to approve the exact Linux install and prove real browser actions, grant/approval/deny/panic, audit/tamper, credential expiry, account switch, and restart behavior |
| Phase 2 core workflows | Open/partial | Existing routes and bounded mutations retained | Complete product outcomes and daemon-authoritative state |
| Phase 3 native features | In progress | Mercury core, Linux CU input, panic, outbound capture, typed SmartHub safety, and daemon-owned text-expansion persistence foundations are implemented; unsupported outcomes remain capability-gated | Cross-device Mercury proof, system CU capture, live SmartHub devices, IBus/Fcitx, external secure-field expansion, sync, pet adapters |
| Phase 4 certification/promotion | Blocked by design | No false stable promotion is possible | All product work plus exact-candidate environment matrix |

### Architectural target

Parity work should converge on shared contracts and narrow platform adapters,
not duplicate the macOS app inside React.

1. **Shared product capability manifest**
   - Provider/model/parser capabilities, settings metadata, RPC versions,
     platform feature states, and reasoned unavailable/substitute states.
   - Generated Swift/TypeScript/Rust types and contract tests.
2. **Daemon-owned domain state**
   - Sessions, chat, memory review, projects, missions, configuration, secrets,
     auth, updates, and sync remain authoritative outside the WebView.
3. **Linux platform services**
   - `LinuxSecretStore`, `LinuxNativeShell`, `LinuxComputerUseAdapter`,
     `LinuxMediaHost`, `LinuxUpdateProvider`, and `LinuxCompanionWindow`.
   - Each exposes capabilities and failure reasons per desktop environment.
4. **Narrow Tauri boundary**
   - Typed IPC and Rust/native proxies; no bearer disclosure, arbitrary shell,
     invented method strings, or unvalidated external URLs.
5. **Release-head evidence graph**
   - Every product row binds requirement, implementation, tests, installed-run
     evidence, environment, artifact hash, and target commit.

### Dependency graph

```text
truth gates + installed baseline
  -> secret custody + narrow IPC + capability manifest
    -> auth/cloud + provider catalog + native shell + updates
      -> sessions/chat/memory + operational workspaces
        -> Computer Use + Mercury + SmartHub + text expansion + pet
          -> accessibility/performance/matrix certification
            -> stable promotion
```

### Phase 0 - Stop false green and recover the product baseline

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-GATE-001 | None | Replace the partial parity ledger with a complete product inventory; bind all Tier A/B evidence to target HEAD; generate Markdown from JSON | Current-head drift, missing row, blocked required row, and contradictory docs fail CI |
| LNX-REL-VERIFY-001 | LNX-GATE-001 | Repair verifier primitives: cryptographic signature/key/identity checks, closure/source binding, feed schema/live-response checks, and mutation tests; do not publish or sign a candidate yet | Known-bad local signatures, one-byte mutations, HTML feed, stale closure, and missing source fail for the correct reason |
| LNX-CI-001 | LNX-GATE-001 | Run Linux Swift/Cargo/installed-shell behavior; repair tag/version and evidence-path wiring; propagate every strict exit code | Tag/manual paths and all mutation tests fail closed for the correct reason |
| LNX-RUN-001 | None | Define package/service ownership, eliminate duplicate daemon starts, add atomic handoff and renderer fallback in development/current ARM package baseline | Development and current-baseline runs are nonblank, use one daemon, recover after crash/restart, and emit package/build provenance |
| LNX-SEC-001 | None | Implement/inject Secret Service, KWallet, and headless credential backends; remove WebView bearer access | All high-value secrets survive securely; JS/logs/files contain no credential |
| LNX-IPC-001 | LNX-SEC-001 | Replace broad shell and ad hoc bridges with generated typed commands and native HTTP/SSE proxy | Command-injection/XSS/URL tests fail closed; no production fixture path |
| LNX-CAP-001 | LNX-IPC-001 | Runtime capability/version manifest for providers, settings, portals, media, CU, native shell, and substitutes | UI never offers an action the runtime is guaranteed to reject |
| LNX-A11Y-HARNESS-001 | None | Add route-state axe/keyboard/zoom harness and packaged AT-SPI/Orca capture before feature UI work | Every UI PR runs the baseline accessibility contract and stores real node/action evidence |
| LNX-PERF-HARNESS-001 | None | Define matched macOS/Linux workload protocol, clocks, p50/p95/p99 and resource/soak capture before feature work | Reproducible baseline and provisional budgets exist for startup, navigation, IPC, data, chat, CPU/RSS/GPU |

Every implementation task in every phase owns its permission, recovery, support,
and known-limitation documentation. The final documentation task is a public
truth-sync, not the first time behavior is documented.

### Phase 1 - Platform and delivery foundation

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-PKG-001 | LNX-REL-VERIFY-001, LNX-CI-001, LNX-RUN-001 | Dual-architecture AppImage/deb/rpm construction and architecture-aware manifest | Unsigned/local x86_64 and aarch64 lifecycle green on Ubuntu/Fedora before candidate signing |
| LNX-CHANNEL-001 | LNX-PKG-001, LNX-REL-VERIFY-001 | apt and rpm repository metadata/signing, correct AUR recipe, and a portal-safe Flatpak channel | Each declared channel installs the correct architecture and verifies repository/package metadata; unpromoted channels are explicitly labeled |
| LNX-EVT-001 | LNX-CAP-001 | Bounded pull subscription authority, cadence, cancellation, restart/offline recovery, and coalesced route refresh are implemented; add native push and exact-candidate installed certification | Kill/stall/suspend/offline tests recover without stale or frozen UI |
| LNX-ONB-001 | LNX-SEC-001, LNX-RUN-001, LNX-CAP-001 | Daemon-owned transactional state/readback foundation is implemented; add provider/auth/portal/tray/update/chat/first-data probes | A clean user cannot finish required setup while any declared required prerequisite is missing |
| LNX-AUTH-001 | LNX-SEC-001, LNX-IPC-001 | PKCE/device auth, membership, App Check, sync, trusted devices, safe billing callbacks | Full sign-in/out/device/backup/restore/checkout matrix passes |
| LNX-NATIVE-001 | LNX-CAP-001 | Tray/status window, notifications, deep links, shortcuts, startup | Repeated native workflows pass on GNOME/KDE and icon-only fallback |
| LNX-UPD-001 | LNX-PKG-001, LNX-CHANNEL-001, LNX-NATIVE-001 | Signed check, compatibility, package/channel-native install/restart/rollback UX | Tamper/replay/arch/version tests fail; prior-version update and rollback succeed for every declared channel |
| LNX-CAT-001 | LNX-CAP-001 | Shared provider/model/parser/path manifest and golden fixtures | Equivalent normalized provider results on macOS/Linux |
| LNX-DIFF-001 | LNX-CAT-001, LNX-CI-001 | Same-commit macOS/Linux binaries run one attested corpus and workflow suite | Mutations on either platform fail the normalized differential oracle |

### Phase 2 - Core workflow parity

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-SESS-001 | LNX-EVT-001 | Session repository: list/body/search/source/resume/export | Real transcript replay and recovery, no synthetic rows |
| LNX-CHAT-001 | LNX-SESS-001, LNX-CAT-001 | **Implemented in source:** canonical encrypted thread list/get/search, exact-thread idempotent append, older-message pagination, strict Tauri decoders, production synthetic-history removal, durable send ordering, daemon-authoritative bounded full-history JSON/Markdown export and verified daemon re-read resume in [PR #1684](https://github.com/Imagine-That-Ai/BurnBar/pull/1684), `618c7286b9`, `e0451afa5e`, `dd705ca1dd`, and `5fdcccabfa` | Mac-equivalent chat contract suite and installed E2E green; attachments retain path-free metadata in exports, while citations, approvals, options, secondary window, live backend routing, and installed unloaded-history evidence remain required |
| LNX-MEM-001 | LNX-EVT-001 | Real quarantine/review/forget/audit RPCs | Daemon-authoritative decisions persist across restart/devices |
| LNX-PROJ-001 | LNX-SESS-001 | Project CRUD, typed delete/reassign, exact associations, detail/history, inferred-row migration, collision/tombstone protection, and checkpoint/journal replay recovery | Stable-ID project lifecycle, durable-reference migration, restart/replay without resurrection, and 10k-session migration suite green |
| LNX-MISSION-001 | LNX-EVT-001 | Mission questions, evidence, history, health, freshness, cancel/recovery | Full mission operating lifecycle survives restart/reconnect |
| LNX-INSIGHT-001 | LNX-SESS-001, LNX-CAT-001 | Insight evidence/citations, compare, follow-up, and audit | Every insight is source-linked and comparable with stale/error handling |
| LNX-DB-001 | LNX-EVT-001, LNX-SEC-001 | Inspector, search, snapshots, inotify ownership, rebuild/recovery, query budgets | Search/watch/rebuild/corruption/100k-row suite green without N+1 drift |
| LNX-PROVIDER-001 | LNX-CAT-001, LNX-SEC-001 | Provider/model deep dives, accounts, health, routing, drain and failover; `e0451afa5e` adds strict catalog/config mapping, provenance, model variants/aliases, health/failover posture, provider workspace, and config-derived backend gates; `d7cffc79d6` wires canonical `daemon.catalog` hydration alongside config with explicit degraded fallback; the provider lane adds validated custom-model add/remove mutations with fail-closed bridge handling | Catalog, switch, quota-exhaustion and failover lifecycle green on installed daemon; live credentials and routing remain external |
| LNX-PRIV-001 | LNX-SEC-001, LNX-AUTH-001, LNX-SESS-001, LNX-MEM-001 | Export, retention, local/account deletion, daemon-owned cloud-erasure authorization, recovery, consent, telemetry, panic | Scoped destructive/recovery workflows and the typed account-erasure handoff are implemented; trusted-device execution, backend receipts, and multi-device propagation remain required |
| LNX-SET-001 | LNX-CAP-001, LNX-AUTH-001, LNX-PRIV-001 | Shared settings schema, missing tabs, deep links, writable configuration | Search, persistence, readback, and policy tests green |

### Phase 3 - Native high-complexity features

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-CU-CREDENTIALS-001 | LNX-AUTH-001, LNX-SEC-001, LNX-IPC-001, LNX-NATIVE-001 | **Implemented in source:** daemon-owned PKCE loopback sign-in, secure refresh-token custody, Firebase ID refresh, per-install Ed25519 App Check enrollment/challenge/mint, account generation, phase-safe sign-out/account-switch teardown, scoped old-account revoke, cancellable HTTP, redacted RPC/Tauri account state, explicit pending-approval reason mapping, permanent-rejection termination, and quota-safe capped polling. **Operational remainder:** deploy the Functions policy/callables, then exercise the exact release configuration | Source acceptance passed the 2026-07-12 full Linux-native aggregate for lifecycle/polling regression cases plus token-redaction checks. Delivery acceptance requires a signed installed candidate to complete sign-in, approval, refresh, expiry, rejection, sign-out, and account switch against deployed production services without token material in renderer, local RPC, logs, or diagnostics |
| LNX-CU-BROWSER-001 | LNX-CU-CREDENTIALS-001, LNX-CAP-001, LNX-IPC-001, LNX-SESS-001, LNX-NATIVE-001, LNX-EVT-001 | **Implemented in source:** exact waiting-run picker; signed run/call/generation intent; controller-route v2 bootstrap/renewal/revocation; iOS/Android renewal; canonical generated Swift/Kotlin relay-challenge schema; macOS lifecycle policy; Linux directory, identity, endpoint, publisher, broker, metadata/readiness, approval/panic/media/teardown; durable replay; polkit owner gate; checkpoint/restart handling; root-owned packaged runtime; daemon credential authority; signed AppImage peer manifest; redacted account UI; and physical-iPad Linux App Check list/approve/revoke source. **Remaining:** current physical-iPad test execution, production provisioning, signed-candidate installation, and physical-iPad/browser/restart certification | Release build completes navigate/type/click/screenshot with the physical iPad as real paired authority; exact App Check device ID and fingerprint are confirmed before approval; unsigned/forged/replayed/stale/wrong-session/wrong-request responses and swapped transport/authority identities fail; credential expiry/account switch/App Check rejection and route absence/replacement terminate the exact route; deny/panic/timeout/cancel/journal failure revoke only the exact generation; restart never redispatches an in-flight action, requires fresh session authority, and retains replay high-water marks; audit/tamper proof passes |
| LNX-CU-SYSTEM-001 | LNX-CU-BROWSER-001, LNX-CAP-001, LNX-NATIVE-001 | Portal/PipeWire/AT-SPI/libei plus constrained X11/uinput adapters | `ea82fe5140` adds the bounded fixed-command portal probe; `4423a0934d` adds the consent-backed, session-scoped RemoteDesktop Notify executor and teardown wiring. X11/AT-SPI selection remains authoritative when the portal is not ready. | Run the exact signed candidate through GNOME/KDE/wlroots compositor safety, approval, panic, revocation, restart, and accessibility matrices; unsupported modes stay hidden |
| LNX-MEDIA-001 | LNX-CAP-001, LNX-IPC-001, LNX-SEC-001, LNX-AUTH-001, LNX-NATIVE-001, LNX-EVT-001 | Mercury transport, secure pairing, files, calls, share, codecs, consent, notification/lifecycle | `56af093923` adds a truthful shell-local GStreamer viewer capability contract (VP9 decoder, native sink, PipeWire factories), explicit no-feature degradation, release feature wiring, and package/runtime dependency declarations. | Run GStreamer-enabled builds and a real two-device file/call/screen-share matrix on supported desktops; prove consent, codec, sink, lifecycle, restart, and teardown receipts |
| LNX-IOT-001 | LNX-IPC-001 | Typed SmartHub discovery/action APIs | Real device and hostile-input tests green |
| LNX-TEXT-001 | LNX-SEC-001, LNX-EVT-001 | **Implemented in source:** app Composer integration and encrypted persistence/safe consent are complete; `6c76df084f` adds bounded IBus/Fcitx reachability, `274f67fba0` adds an explicitly opted-in signed registration gate, and `9598c0b9e8` adds daemon lifecycle status/start/stop RPCs with owner/path/permission/session checks, without keyboard/clipboard/surrounding-text capture. Live engine execution, secure-field hooks, sync, and conflict resolution remain required | Secure-field and desktop/input-method matrix green with a registered engine; unsupported or uninspectable contexts stay disabled |
| LNX-PET-001 | LNX-CAP-001, LNX-NATIVE-001 | Real glTF renderer, companion window, capability fallback | X11 child/summon source contract is present; visual, focus, compositor, GPU, shortcut, and reduced-motion tests green |

### Phase 4 - Quality certification and promotion

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-REL-CANDIDATE-001 | LNX-PKG-001, LNX-CHANNEL-001, LNX-UPD-001, LNX-REL-VERIFY-001, all product/platform tasks | Build and sign the exact candidate; bind signatures, source, SBOM/VEX/provenance and feed; run real update/rollback | Candidate and public-asset copies verify byte-for-byte; every declared channel updates and rolls back |
| LNX-A11Y-CERT-001 | LNX-A11Y-HARNESS-001, all UI tasks | Final axe, Playwright, Orca/AT-SPI, keyboard, zoom, high contrast, reduced motion certification | No serious violations; every critical workflow assistive-tech complete |
| LNX-PERF-CERT-001 | LNX-PERF-HARNESS-001, LNX-EVT-001, all primary workflows | Final cold/warm/tail/resource/soak benchmarks compared with matched macOS outcomes | Agreed p95/resource budgets green with no leaks/regressions |
| LNX-QA-001 | LNX-REL-CANDIDATE-001, all platform tasks | Exact-candidate packaged E2E on the minimum supported GNOME X11/Wayland, KDE Wayland, wlroots, x86_64/aarch64 matrix | Every minimum-support row is green; only additional environment rows may be publicly scoped out |
| LNX-DOC-001 | LNX-QA-001, per-feature docs | Final install, permissions, limitations, update/rollback, security, support, and public-site truth-sync | Docs and public site match the exact candidate and supported matrix |
| LNX-PROMOTE-001 | All tasks | Re-run fail-closed ledger and release graph at final commit | Zero Critical/High gaps; no missing product capability or blocked/stale required row; stable feed promoted |

## Prioritized Roadmap

| Order | Milestone | Current state | Included tasks | Exit gate |
|---|---|---|---|---|
| 0 | **Disable false parity** | Complete | LNX-GATE-001 | Machine claim is off; ledger cannot certify stale/incomplete evidence |
| 1 | **Trustworthy engineering baseline** | Complete in code; dual-architecture construction and aarch64 installed proof live | LNX-REL-VERIFY-001, LNX-CI-001, LNX-RUN-001, LNX-A11Y-HARNESS-001, LNX-PERF-HARNESS-001 | Add installed x86_64 and prior-version package sessions without regressing strict gates |
| 2 | **Security foundation** | Complete in code; matrix pending | LNX-SEC-001, LNX-IPC-001, LNX-CAP-001 | GNOME/KDE/headless credential and installed adversarial verification green |
| 3 | **Mainstream install** | Package construction complete; installed/channel proof in progress | LNX-PKG-001, LNX-CHANNEL-001 | Both architectures and every declared package/repository channel install locally |
| 4 | **Daily-use native foundation** | In progress; onboarding and bounded event-refresh foundations implemented, installed matrix pending | LNX-EVT-001, LNX-ONB-001, LNX-AUTH-001, LNX-NATIVE-001, LNX-UPD-001, LNX-CAT-001, LNX-DIFF-001 | Setup, auth, data freshness, alerts/tray, update lifecycle, and current provider diff green |
| 5 | **Core product workflows** | Pending | LNX-SESS-001, LNX-CHAT-001, LNX-MEM-001, LNX-PROJ-001, LNX-MISSION-001, LNX-INSIGHT-001, LNX-DB-001, LNX-PROVIDER-001, LNX-PRIV-001, LNX-SET-001 | No synthetic state; every primary workspace and privacy workflow completes |
| 6 | **Browser automation parity** | In progress; controller routing, native iroh runtime, authority/replay/restart safety, polkit owner gate, daemon-owned PKCE/Firebase/App Check credentials, phase-safe account lifecycle, bounded approval polling, redacted account UI, signed AppImage peer admission, and physical-iPad approval source are implemented. Earlier generic iOS build-for-testing coverage passes, and the 2026-07-12 Linux-native aggregate passes. Production OAuth/callable configuration, current physical-iPad execution, signed-candidate installation, and real-device evidence remain open | LNX-CU-CREDENTIALS-001, LNX-CU-BROWSER-001 | Provision Desktop OAuth and release variables, deploy Functions, complete physical-iPad tests, build the signed candidate, then prove iPad-backed sign-in, approval, real actions, panic, audit, and restart recovery |
| 7 | **Media and system integration** | In progress; Mercury code complete | LNX-CU-SYSTEM-001, LNX-MEDIA-001 | Supported compositor safety and two-device media proof |
| 8 | **Extended features** | Pending | LNX-IOT-001, LNX-TEXT-001, LNX-PET-001 | SmartHub, input-method, and companion outcomes proven or honestly substituted |
| 9 | **Candidate and certification** | Blocked on milestones 3-8 | LNX-REL-CANDIDATE-001, LNX-A11Y-CERT-001, LNX-PERF-CERT-001, LNX-QA-001, LNX-DOC-001 | Exact signed candidate, assistive-tech, performance, architecture, desktop matrix, and docs green |
| 10 | **Stable promotion** | Blocked by design | LNX-PROMOTE-001 | Zero Critical/High gaps and a current reproducible evidence graph |

### Immediate blocking order from the 2026-07-12 source-complete wave

These gates are deliberately sequential because each later result depends on
the identity, configuration, and artifact bytes established by the earlier one:

1. Deploy the Linux App Check enrollment, challenge, mint, list, approve, revoke,
   and policy callables/rules; verify the dedicated Linux Firebase app ID.
2. Run the focused approval tests on the connected physical iPad. Generic iOS
   build-for-testing and current-branch launch/liveness already pass; the final
   authority proof must still use this iPad, not an iPhone or simulator.
3. Build and sign the exact deb/rpm/AppImage candidate, including the AppImage
   peer manifest over the final repacked GUI bytes.
4. Install that exact candidate on Linux and complete PKCE sign-in, device
   enrollment, physical-iPad fingerprint confirmation, approval, token refresh,
   and revoke/sign-out/account-switch failure paths.
7. Certify Browser Computer Use navigate/type/click/screenshot, approval/deny,
   panic, tamper detection, audit export, daemon crash/restart, and replay
   persistence against a real browser.
8. Run the same candidate through the GNOME X11/Wayland, KDE Wayland, and
   wlroots matrix, then complete update/rollback and stable-promotion gates.

### Parallelization and ownership

After Milestone 2, these workstreams can proceed in parallel when their shared
contracts are frozen:

- delivery: package architectures, update provider, release verification;
- product data: provider catalog, sessions, projects, missions, insights;
- native shell: tray, notifications, deep links, startup, global shortcuts;
- high-complexity platform: Computer Use and Mercury as separate lanes;
- quality: accessibility/performance harnesses can start early and become gates.

Keep one integration owner at a time for `routes.ts`, `tauriBridge.ts`, the Tauri
`lib.rs`, shared capability schemas, app-wide CSS, and release validators.

## QA Checklist

### Release and supply chain

- [ ] Every AppImage/deb/rpm/daemon artifact verifies against its detached
  signature and committed/published public-key fingerprint.
- [ ] One-byte mutation of artifact, signature, provenance, checksum, SBOM, VEX,
  source archive, or feed fails promotion.
- [ ] Ledger evidence and artifact provenance target the exact release commit.
- [ ] A missing, blocked, stale, duplicated, or contradictory product row fails.
- [ ] Linux Swift, Cargo, frontend, and installed-shell behavior tests run rather
  than compile-only substitutes.
- [ ] Manual-dispatch and tag-triggered release paths derive the same validated
  version and upload the current evidence directory.
- [ ] Make, scripts, and workflows propagate strict failures; allow-blocked mode
  cannot hide structural, security, integrity, or stale-evidence failures.
- [ ] The source archive and source offer are bound to the same commit and
  verified as part of the artifact closure.
- [ ] `latest-linux.json` is valid signed JSON with correct MIME type, version,
  architecture, hashes, URLs, and monotonicity.
- [ ] x86_64 and aarch64 AppImage/deb/rpm install, launch, upgrade, rollback, and
  uninstall cleanly.
- [ ] apt and rpm repository metadata/signing, AUR recipe, and Flatpak manifest
  install only the declared version/architecture; any unpromoted channel is
  excluded from public install copy rather than presented as ready.
- [ ] Release package smoke launches the real GUI and daemon, not only inspects
  archive contents.
- [x] Source AppImage peer admission verifies a signed canonical manifest, exact
  final GUI path/basename/hash, immutable or read-only AppImage root, and
  no-follow file access; tampered manifest/signature/path/hash cases fail.
- [ ] The exact signed AppImage candidate proves the same peer-admission contract
  after final repacking and from an installed launch.

### Installation, service, and onboarding

- [ ] Exactly one package-owned daemon runs and matches the shell/RPC version.
- [ ] No live process executes a deleted or unowned binary.
- [ ] Fresh install, login start, logout/login, crash recovery, suspend/resume,
  interrupted upgrade, downgrade, and uninstall behave correctly.
- [ ] App window and each route render nonblank under hardware, WebGL1, WebGL2,
  and supported software fallback.
- [ ] Onboarding verifies daemon, keyring, provider, auth, portal, tray, renderer,
  and update channel before required completion.
- [ ] Every denial/failure offers an idempotent repair path and survives restart.

### Security and privacy

- [ ] Provider, connector, auth, cloud, notification, device, and DB secrets
  persist through Secret Service/KWallet/systemd credential policy.
- [ ] Locked/unavailable secret stores fail closed with actionable UI.
- [ ] No secrets appear in plaintext config, DB, logs, DOM, JS globals, frontend
  requests, crash reports, screenshots, clipboard, or diagnostics.
- [ ] WebView JavaScript never receives the gateway bearer.
- [ ] Arbitrary shell, file URLs, untrusted hosts/schemes, argument injection,
  traversal, oversized payloads, and hostile deep links are rejected.
- [ ] Release builds cannot activate fixtures or synthetic evidence modes.
- [ ] Privacy/telemetry choices are writable, persist, and stop emission at source.

### Core product workflows

- [ ] All declared providers match macOS-normalized parser/quota golden fixtures.
- [ ] macOS and Linux differential outputs are generated at the same commit from
  attested binaries and corpus; a platform-specific mutation fails the job.
- [ ] Provider discovery handles XDG paths, symlinks, sandbox paths, malformed
  logs, duplicates, multiple accounts, and large histories.
- [ ] Usage, quota, projections, model/provider identity, alerts, and freshness
  update without manual navigation refresh.
- [ ] Real session transcripts replay exactly, search, paginate, export, resume,
  and recover from missing/corrupt/cloud-conflicted bodies.
- [ ] Chat supports each declared backend/model, streaming, cancellation,
  attachments, citations, approvals, restart/reconnect, export, and pop-out.
- [ ] Memory candidates quarantine, approve, reject, forget, audit, and retrieve
  from daemon-authoritative state across restart/devices.
- [ ] Projects support CRUD and exact session association.
- [ ] Missions expose questions, approvals, evidence, history, health, freshness,
  cancellation, and recovery.
- [ ] Insights expose evidence/citations, comparison, follow-up, and audit actions.
- [ ] Database supports inspect/search/snapshot/watch/recovery without N+1 drift.
- [ ] Provider/model deep dives support catalog, health, account switching,
  routing, and failover.

### Account, cloud, and native shell

- [ ] Sign-in/link/sign-out, state validation, expiry, refresh, revocation, offline,
  and clock-skew cases pass.
- [ ] Trusted device add/revoke/transfer and credential transfer are secure.
- [ ] Backup, restore, conflict resolution, remote access, checkout, restore, and
  entitlement refresh work across restart.
- [ ] Tray/status UI works in rich and icon-only hosts, with stale/offline states.
- [ ] Notifications deliver actionable deep links and recover after relaunch.
- [ ] OAuth deep links, login startup, and global panic work on GNOME/KDE/wlroots.

### Computer Use, media, and extended features

- [x] The source surface exposes Browser only and fails closed when signed phone
  authority or Linux owner authorization is unavailable.
- [ ] The exact installed candidate proves unsupported Computer Use modes hidden.
- [x] Source daemon-managed agent browser tools require an exact live run/session
  binding and use the same scope, approval, panic, Playwright, and audit
  authority as explicit Computer Use actions, with no direct-dispatch fallback.
- [x] Source session authority defines exact challenge-bound iOS/Android signing
  primitives, serialized and replay-bounded device-owner interaction, live iOS
  inbound routing, Android exact-authenticated-route reception with signed-expiry
  notification and foreground recovery, daemon-only proof custody,
  single-use consumption after polkit and run revalidation, and no renderer
  proof/password/key fields.
- [x] Source controller routing uses v2 dual-signature bootstrap, exact-tuple
  same-generation transport-only renewal, authoritative empty-route revocation,
  autonomous iOS/Android renewal, macOS lifecycle/lease enforcement, and Linux
  native directory/endpoint/broker/readiness/action-response composition.
- [x] The source shipping daemon owns PKCE, refresh-token custody, fresh Firebase
  ID-token and App Check credentials, per-install Ed25519 enrollment, account
  generation, sign-out/account-switch teardown, and scoped route revocation;
  focused failure-path and token-redaction tests pass.
- [x] Account transition state is phase-safe, successful sign-out permits a
  fresh browser sign-in, explicit pending approval is distinct from permanent
  rejection, and capped retry remains below the public endpoint quota.
- [x] The physical-iPad source surface lists Linux App Check devices, displays
  the canonical stable device ID and verified public fingerprint, and requires
  explicit approve/revoke confirmation with serialized, nonce-bound mutations.
- [x] Generic iOS build-for-testing and the canonical Swift/Kotlin relay schema
  generation pass; Android compile, focused tests, and strict static analysis pass.
- [ ] The focused parser/store/mutation tests execute on the connected physical
  iPad without using an iPhone or simulator as a substitute. The current
  launch/liveness/console receipt passes; the approval workflow itself remains
  open.
- [ ] The Linux App Check callables/rules are deployed to production.
- [ ] A paired physical iPad supplies the exact signed session grant and action
  response;
  unsigned, forged, replayed, stale, wrong-session, and wrong-request vectors fail.
- [ ] Browser actions, approvals, deny, panic, audit, tamper detection, restart,
  and permission revocation pass against a real browser.
- [ ] System capture/input/inspection passes the declared GNOME/KDE/Sway and
  Wayland/X11 matrix with explicit consent and bounded fallbacks.
- [ ] All panic paths stop future input within the latency budget.
- [ ] Mercury pairing, files, calls, screen share, cancel/reject, packet loss,
  reconnect, suspend, permissions, and cleanup pass on two real devices.
- [ ] SmartHub uses typed allowlisted commands and passes real device/offline/
  hostile-input tests.
- [ ] Text expansion works in app composers and supported IBus/fcitx contexts,
  excludes secure fields, and restores clipboard/input state.
- [ ] Pet overlay passes focus, click-through, topmost, animation, scaling,
  multi-monitor, GPU, reduced-motion, and honest-fallback tests.

### Accessibility, performance, reliability, and polish

- [ ] axe finds no serious violations on every route, important state, modal,
  loading, empty, error, disabled, and fixture-disabled release state.
- [ ] Every workflow is keyboard-complete with visible focus and no focus trap.
- [ ] Orca/AT-SPI exposes correct names, roles, states, actions, order, and live
  announcements in the installed app.
- [ ] 200% zoom/reflow, font scaling, GNOME High Contrast, forced colors, reduced
  motion, and non-color status cues pass.
- [ ] Cold/warm startup, first meaningful content, route and IPC p50/p95/p99,
  parser/database scale, chat first token, RSS/CPU/GPU, and 30-minute soak meet
  agreed macOS-relative budgets.
- [ ] Packaged Ubuntu GNOME/X11 route navigation clears `route.navigation` p95
  <= 120 ms after the route-body hydration fix; the loading shell stays
  accessible, while fixture/browser previews remain eager.
- [ ] Daemon kill/restart, socket stall, offline/online, suspend/resume, keyring
  lock, DB corruption, clock change, low memory, and renderer fallback recover.
- [ ] Packaged screenshots show no black frames, clipping, overlap, unreadable
  contrast, raw diagnostic artifacts, or inconsistent interaction states.

### Required promotion matrix

- [ ] Ubuntu 24.04 GNOME X11, x86_64 and aarch64.
- [ ] Ubuntu 24.04 GNOME Wayland, x86_64 and aarch64.
- [ ] Fedora KDE Wayland, x86_64 and aarch64 where infrastructure permits.
- [ ] Arch or equivalent wlroots/Sway row, at minimum x86_64.
- [ ] Secret Service and KWallet.
- [ ] AppImage, deb, and rpm package paths.
- [ ] apt/rpm repository, AUR, and Flatpak rows for every publicly declared
  channel; undeclared experimental channels remain visibly unpromoted.
- [ ] Hardware and software renderer paths.
- [ ] Clean user, upgrade user, offline user, locked-keyring user, and assistive-
  technology user journeys.

## Promotion Exit Criteria

Linux may be called full parity only when all of the following are true:

1. Zero open Critical or High gaps in this audit.
2. Every non-negotiable macOS product capability is implemented with an equivalent
   user outcome on at least one minimum-supported Linux environment. A missing
   product capability cannot be converted into parity by documenting it away.
3. The minimum supported environment matrix is declared before certification and
   fully green. Only additional environments outside that minimum may be publicly
   scoped out or assigned a documented Tier C substitute.
4. Product ledger, evidence, artifacts, and public feed target the exact release
   commit and pass strict verification without exceptions.
5. Real installed packages, not fixtures/static boards/archive inspection, prove
   every primary workflow on the required matrix.
6. macOS/Linux contract fixtures produce equivalent domain results.
7. Accessibility, performance, reliability, security, update/rollback, and
   supply-chain gates all pass.
8. README, website, release notes, support matrix, onboarding copy, known
   limitations, and operator runbooks match live behavior.

## Evidence Index

Primary current evidence and implementation references:

- macOS route oracle: `AgentLens/Views/Dashboard/DashboardNavigationModel.swift`
- macOS settings oracle: `AgentLens/Views/Settings/SettingsTab.swift`
- Linux settings manifest: `apps/linux-desktop/src/surfaces/settings/settingsTabs.ts`
- Linux chat controls/state: `apps/linux-desktop/src/surfaces/chat/` and
  `apps/linux-desktop/src/state/chatStore.ts`
- Linux Tauri capability/commands: `apps/linux-desktop/src-tauri/src/lib.rs`
- Controller-route v2 registry and clients:
  `functions/src/callables/irohControllerRouteCallables.ts`,
  `functions/src/callables/irohControllerRouteSecurity.ts`,
  `OpenBurnBarMobile/Services/ComputerUse/PhoneControlAuthorityPublisher.swift`,
  `android/app/src/main/java/com/openburnbar/data/computeruse/IrohControllerRouteRegistrar.kt`,
  `AgentLens/Services/IrohRelay/FirestoreIrohInboundPeerAllowlist.swift`, and
  `AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift`
- Linux Browser Computer Use authority and lifecycle:
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseAuthorizationRegistry.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseSessionGrantBroker.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxComputerUseOwnerAuthorizationCoordinator.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/DaemonComputerUseApprovalAuthorityVerifier.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/DaemonComputerUsePanicAuthorityVerifier.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/DaemonComputerUseApprovalReplayCounterStore.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxIrohControllerCredentials.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxIrohControllerDirectoryClient.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxIrohControllerRuntime.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxIrohHostIdentityStore.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonPhoneKeyPinStore.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService+ToolDispatch.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRunService+Lifecycle.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarRunService.swift`,
  `OpenBurnBarMobile/Services/ComputerUse/MobileAgentPermissionGrantController.swift`,
  `android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSessionGrantChallengeValidator.kt`,
  `apps/linux-desktop/src-tauri/src/lib.rs`, and
  `apps/linux-desktop/src/surfaces/computerUse/ComputerUseSurface.tsx`
- Linux credential authority and redacted account RPC boundary:
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/LinuxDaemonCloudCredentialAuthority.swift`,
  and `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCAuth.swift`
- Linux Browser Computer Use native contract gate:
  `scripts/linux-port/run-linux-native-tests.sh` and
  `scripts/linux-port/run-linux-native-tests.test.mjs`
- Linux Mercury runtime: `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/MercuryLinux*`,
  `apps/linux-desktop/src/state/mediaStore.ts`, and
  `apps/linux-desktop/src/surfaces/media/`
- Canonical Linux paths/provider registry:
  `OpenBurnBarCore/Sources/OpenBurnBarCore/Platform/OpenBurnBarLinuxPaths.swift`
  and `apps/linux-desktop/src/providerPathRegistry.ts`
- Linux daemon secret stores: `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/`
- Current ledger: `docs/linux-port/parity-ledger.json` and
  `docs/linux-port/parity-ledger.md`
- Ledger validator: `scripts/linux-port/lib/parity-ledger-validate.mjs`
- Release verifier: `scripts/linux-port/verify-linux-release.mjs`
- Environment-bound matrix harness: `scripts/linux-port/run-linux-matrix-harness.mjs`
- Packaging path drift gate: `scripts/linux-port/check-packaging-path-sync.mjs`
- Release evidence: `docs/linux-port/evidence/mission-002-reanchor/`
- Current aarch64 installed-session audit summary:
  `docs/linux-port/evidence/parity-audit-2026-07-10/aarch64-installed-session-summary.json`
- Current clean aarch64 package closure and smoke:
  `docs/linux-port/evidence/parity-audit-2026-07-10/aarch64-391fe2847d-architecture-closure.json`
  and `docs/linux-port/evidence/parity-audit-2026-07-10/aarch64-391fe2847d-architecture-smoke.json`
- Current architecture-correct x86_64 package closure and smoke:
  `docs/linux-port/evidence/parity-audit-2026-07-10/x86_64-391fe2847d-architecture-closure.json`
  and `docs/linux-port/evidence/parity-audit-2026-07-10/x86_64-391fe2847d-architecture-smoke.json`
- Earlier clean aarch64 remediation closure retained for history:
  `docs/linux-port/evidence/parity-audit-2026-07-10/aarch64-c4e85dbbd0-architecture-closure.json`
- Existing implementation plan and accepted substitutions:
  `docs/linux-port/FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`
- Public prerelease: `https://github.com/Imagine-That-Ai/BurnBar/releases/tag/linux-v0.1.0`
- Historical failing marketing-root probe:
  `https://burnbar.ai/latest-linux.json`
- Production update-feed target after remediation:
  `https://downloads.burnbar.ai/latest-linux.json`. Live DNS/R2 activation is
  still a named release blocker until the release environment runs the
  Cloudflare domain-setup and verified upload steps successfully.

This audit intentionally treats source existence and generated evidence as
necessary but insufficient. A parity row becomes ready only when its real user
outcome is reproducible from an installed release artifact on a declared,
supported Linux environment.
