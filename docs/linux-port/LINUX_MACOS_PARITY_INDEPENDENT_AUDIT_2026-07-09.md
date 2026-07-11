# Linux/macOS Parity Independent Audit

| Audit field | Value |
|---|---|
| Date | Baseline audit: 2026-07-09; remediation evidence: 2026-07-11 UTC |
| Gold standard | OpenBurnBar for macOS |
| Linux target | `apps/linux-desktop` plus the shared OpenBurnBar daemon |
| Baseline checkout | `windows/liquid-glass-kernel-reskin` at `18836ae40a` |
| Remediation evidence | Account/auth foundation at `0d31d4ee9831e9608df7ecb3e9655cdaa3c8a2ba`; stacked native-shell source through global-panic capture commit `87288baa4b` plus the current provider external-auth, Linux App Check boundary, and daemon attestation ingress bridge packets; clean aarch64 and architecture-correct x86_64 release shards at `391fe2847d`. Source packets are validated but are not promoted by this text without exact-candidate environment evidence. |

**Verdict:** **NO-GO for a full-parity claim or stable Linux promotion**

## Executive Summary

The Linux app now has a substantial production implementation: a 19-route Tauri
shell, all six persisted dashboard layouts, shared daemon RPC access, canonical
XDG path handling, live usage/quota data, missions, durable memory decisions,
database indexing/watch recovery, Browser Computer Use plus guarded system input,
AppImage/deb/rpm construction, and a source-level signed apt/RPM repository
builder and verifier. The remediation wave also replaced the false-
green certification baseline, added Linux-native secret custody, moved gateway
authentication behind native proxies, introduced a runtime capability manifest,
added installed-app accessibility and matched-performance gates, and implemented
a signed update-feed verifier plus two-architecture release assembly. The Linux
channel source now also has four role-isolated Cloudflare Workers, create-only
immutable uploads, no-pointer snapshot preview, conditional repository and feed
per-channel pointers with isolated retained rollback descriptors, exact
public-byte/header verification, rollback/deactivation
containment, generation-plus-ETag ABA defense, write-ahead activation intent,
official-key feed verification with artifact binding, rollback feed rebinding,
and Sigstore-attested publication receipts. Stable remains the legacy root-feed
alias while prerelease and nightly use channel-qualified public routes.
First-cutover compensation restores the applicable legacy direct-R2 paths;
later unrecoverable rollback fails closed behind an inactive tombstone. A
scheduled metadata-only refresh transaction now preserves immutable package
bytes, chains a new signed closure to the verified parent, rebinds the retained
feed, verifies public bytes, compensates post-activation failures, and uploads
Sigstore-verified immutable evidence. This is source closure, not live promotion
evidence: production DNS, credentials, OpenPGP identity, published bytes,
installed lifecycle, and a real scheduled refresh execution remain unproven.

Mercury is no longer a missing code path: Linux now has daemon-owned iroh session
control, inbound and outbound file transfer, call/mirror state, sealed media
frames, portal/PipeWire capture, codec probing, consent/revocation, a call HUD,
and a runtime probe that exposes the route only when the daemon can support it.
It is still **unproven as a parity outcome** until a real Linux-to-macOS/mobile
two-device matrix passes. The largest remaining functional gaps are complete
system Computer Use capture/execution, provider/portal completion inside
transactional onboarding, account membership/cloud/device workflows, chat and session
depth, global text expansion, and freedesktop notification/status-window depth.
Linux now has a single-instance native launch boundary, validated deep links,
background startup, live tray facts/actions, and user-owned XDG login start.
The desktop matrix harness also requires current native-shell evidence before a
support row can become ready, so P-26/P-27 source work cannot be promoted by
package/accessibility evidence alone. The shell verifier now emits
`native-shell-evidence.json` for that gate, and the installed desktop-session
harness now captures the tray action, compact-status, status-window
accessibility, deterministic freedesktop notification action/relaunch, and
secondary deep-link relaunch artifacts named by the producer. The same installed
session now focuses a separate X11 probe window, dispatches the native global
panic fallback chord, and requires daemon-wide kill-path acceptance. It also captures a
deterministic XFCE/AppIndicator StatusNotifier host loss/restart pass that
refreshes recovered menu handles and rejects duplicate registered items or
extra app processes. Current installed evidence remains blocked until VM runs
capture real desktop notification breadth beyond the deterministic test server
and display-manager/package-manager breadth beyond the deterministic
login-start lifecycle harness.
The current auth packet also adds purpose-bound in-app device authorization,
daemon-owned Firebase token exchange and refresh, writable-keyring preflight,
local sign-out, and a strict renderer-redacted account contract. Native Linux
App Check now has a source-level challenge-to-ingress bridge: a durable
five-minute Firestore challenge with atomic replay consumption, a pinned
signed-verdict verifier seam, a fixed 30-minute token TTL, an account-bound
daemon memory-only client, hash-only upload-ticket issuance, exact public
ingress claim, streamed evidence upload, and receipt-native mint evidence.
Endpoint-wide trust authorization now rejects Linux on 73
callables by default, admits 29 audited low-risk operations, and permits 15
high-risk mutations only through the existing nonce plus trusted-device proof
and mandatory-audit step-up; the two prerequisite callables are separately
cataloged. Production minting remains disabled by default. The root-owned broker
and native deb/rpm lifecycle foundation are now source-implemented: systemd
socket activation that defaults disabled, signed installed-file manifests with
recomputed roots, per-request kernel credentials plus exact peer executable
authorization, bounded workers and local IPC, package-owned
install/update/remove hooks, active user-daemon upgrade recovery, and an explicit
destructive purge path. The follow-on broker source packets add explicit
`tpm2_createak` AK lifecycle initialization/rotation, an `ak.ctx`-gated
`/usr/bin/tpm2_quote` collector, and a sealed descriptor builder for IMA,
measured-boot, installed-manifest, and manifest-signature records. The verifier
and Functions mint path now reject revoked or identity-mutated enrollment
records before signing a verdict, consuming a challenge, or minting a token. A
high-risk owner callable now creates the enrollment tombstone before facade
materialization, durably revokes the deterministic ticket slot, terminalizes
its verified ticket, and commits the revocation with its tamper-evident
completion audit event in one Firestore transaction. Ticket issuance and stale
facade workers reject those markers. AppImage remains
intentionally ineligible for host attestation. A real Firebase Web app ID,
remote enrollment activation, physical quote vectors, complete IMA
verification, deployed verifier/revocation operations, public ingress
deployment, production audit evidence, negative vectors, and installed Linux
matrix are still missing, so protected cloud operations, membership/billing,
cloud sync, and trusted devices remain open. This advances the Linux sign-in
and App Check foundations without closing `GAP-010` or `LNX-APPCHECK-001`.
The current provider-auth packet separately adds registry-validated,
daemon-owned Codex and Claude external-login flows with typed
start/status/cancel RPCs, a bounded private terminal launcher, local CLI auth
verification, restart recovery, and a renderer contract that excludes tokens,
callback URLs, paths, arguments, and terminal output. This closes the missing
source workflow in `P-27`; installed provider-login certification and isolated
multi-account profile switching remain open. Linux CLI verification now runs
under a supervised `setsid --fork --wait` session, validates the actual child
session leader through `/proc`, and terminates the complete process group on
timeout. The native integration test proves that both the launcher and a
`SIGTERM`-ignoring descendant are gone before the verifier returns.
The largest certification gaps are an x86_64 installed session, a prior-version
update/rollback baseline, a valid public signed feed, public apt/RPM mirrors,
and real GNOME Wayland/KDE/wlroots proof. Package construction is now green for
both architectures, and signed apt/RPM repository construction is implemented
in source, but that does not substitute for public-mirror verification or live
installed-product outcomes. AUR and Flatpak remain explicitly unpromoted.

The old parity claim is now disabled. The generated product ledger contains all
40 audited requirements, reports **0 ready / 40 blocked**, and cannot promote a
stale or incomplete claim. Every row now invokes one canonical, repository-
confined requirement attester backed by a complete requirement-specific policy
manifest. Receipt schema 2 binds the exact release closure, schema-validated
signed installed-file manifest, candidate package artifact, pre/post runtime
manifests captured from the installed desktop shell, and dispatcher-generated
live environment/install evidence,
registered validator command/source tree, and clean current HEAD. The live probe
must match the matrix OS, architecture, desktop, session, display/session bus,
logind identity, package-manager version, installed package architecture, exact
package-owned path set, root-owned trust files, Ed25519 signature, and every
signed file hash/size/mode/owner/symlink target. The installation, package,
runtime, and session probes repeat after requirement execution; installed bytes
and identity must remain unchanged, while both valid runtime snapshots are
retained so legitimate capability-state transitions remain auditable. Every receipt also
requires a detached GitHub Artifact
Attestation from the pinned product-parity workflow; the verifier pins repository,
workflow, source ref/commit, and exact receipt bytes without trusting caller-
controlled predicate fields. The attester discovers the exact required
validator/environment matrix, re-hashes its artifact union, removes stale output
on failure, and writes only the canonical row evidence path atomically. Missing,
substituted, symlinked, unprovenanced, or noncanonical inputs fail closed.
The producer workflow accepts only the immutable `linux-release-evidence`
artifact from one successful canonical Linux release workflow run at the exact
target SHA; arbitrary artifact names, forks, workflow identities, reruns, failed
runs, stale commits, expired artifacts, and mutable name-based selection fail
closed. The current release artifact does not yet emit the new product-proof
closure shape. Requirement-owned `P-XX` validator modules and the release-
workflow aggregation stage are also not implemented yet, so every registered
runner currently stops before
emitting `passed`; this repairs the admission contract without fabricating semantic
parity. Release verification now checks artifact bytes,
detached signatures, provenance, source/SBOM/VEX inputs, architecture sessions,
and signed-feed closure. This fixes the evidence-admission mechanism; it does not turn blocked
product rows into parity.

Linux native validation also no longer links Swift's broken Linux Observation
runtime. Shared Swift UI models keep `@Observable` on Apple platforms and
compile as ordinary state classes for the Tauri-owned Linux product; the native
test runner inspects the resulting ELF and fails if `libswiftObservation`
reappears. This removes the upstream Swift 6.1 link/runtime hazard without a
linker suppression.

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

The last complete native integration sweep, before the current auth packet,
recorded this measured source and package evidence beyond that historical
installed baseline:

- **100** fail-closed Swift Core/security/daemon tests passed across XDG paths, provider
  discovery, gateway, switcher, Pensieve/inotify, Computer Use, and Mercury;
- **62 files / 419 tests** passed in the Linux desktop suite, including every
  route under axe, six-layout state, provider-path parity, durable memory, and
  real Mercury RPC decoding plus native-shell lifecycle and settings coverage;
- **24/24** Tauri Rust tests, **3/3** media-crate tests, **40/40** extension
  daemon-client tests, and **78/78** release/workflow contract tests passed;
- clean aarch64 and architecture-correct x86_64 shards at `391fe2847d` each
  produced AppImage, deb, rpm, and daemon artifacts with SHA-256 closure, zero
  blockers, and **28/28** package-smoke steps passed;
- the x86_64 toolchain produced real x86_64 binaries under Rosetta-assisted
  construction rather than relabeling ARM output. A native hosted runner and an
  exact installed x86_64 user session remain required.

The current auth packet separately passed **30/30** Linux security tests,
**8/8** RPC contract tests, **15/15** daemon auth tests, the full **64-file / 457-test**
desktop suite, **26/26** Tauri Rust tests, **34/34** focused Functions auth/grant
tests, and **44/44** website tests. A deployed GNOME/KDE browser-to-keyring run
remains pending; these source results do not certify the production auth outcome.

The current daemon attestation ingress packet passed source-level Linux
verification: **10** network-client selectors, **5** production-provider
selectors, **8** service selectors, and **14** broker selectors in Docker Linux
XCTest; **3/3** Functions client-bridge tests; **99/99** Linux attestation facade
tests; **6/6** schema/contract tests; and the no-suppression plus Linux-native
harness meta gates. The Docker toolchain image required ephemeral
`libpam0g-dev` installation for the linker symlink; this is environment setup
evidence, not installed-product certification.

Promotion remains blocked by several explicit conditions: no previous same-architecture
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
| Native shell | Single-instance/background launch, typed deep links, live tray facts/actions, compact status window, source-level freedesktop notification actions, installed X11 global-panic capture, user XDG login start, daemon-owned provider external login, fail-closed native-shell matrix evidence requirements, and verifier-produced `native-shell-evidence.json` are implemented | Certify rich/icon-only GNOME, KDE, X11, wlroots, accessibility, notification, cloud quick reply, provider external-login, and lifecycle rows |
| Account auth | Purpose-bound device authorization, sealed custom-token delivery, daemon-owned refresh, keyring custody, renderer-redacted status, and local sign-out are source-implemented | Deploy and certify the callable/browser path; complete membership/billing, cloud sync, and trusted-device lifecycle |
| Linux App Check | Durable five-minute challenge, atomic replay defense, pinned signed-verdict boundary, fixed 30-minute TTL, daemon memory-only acquisition/cache, hash-only ticket reservation, exact ingress claim, streamed evidence upload, receipt-native mint evidence, root broker/native deb-rpm packaging, broker-owned `tpm2_createak` AK lifecycle initialization/rotation guard, root-owned enrollment-state binding, private AK context activation, source TPM quote collection, sealed IMA/measured-boot/manifest evidence descriptor, verifier-side enrollment recheck, Functions mint revocation gate, high-risk owner revocation administration, atomic tamper-evident completion audit, and the 16 MiB evidence ceiling are source-implemented; mint kill switch defaults off | Provision the Firebase Web app; activate real remote enrollment, prove physical-TPM quotes and complete IMA verification through deployed verifier/revocation operations, deploy ingress/verifier/revocation callable, capture production audit evidence, run negative/revocation vectors, and certify the installed matrix; Linux remains `linux_lower_trust` |
| Packaging | aarch64 and x86_64 AppImage/deb/rpm/daemon construction and smoke passed; aarch64 installed `.deb` session passed | Produce installed x86_64 session, signed aggregate, rpm/AppImage lifecycle, and prior-version proof |
| Core product workflows | Six dashboard layouts, XDG/provider paths, and daemon-authoritative memory decisions are implemented; several routes remain partial/read-only | Complete onboarding, chat, sessions, account/cloud, and workspace depth |
| Advanced platform features | Mercury implementation and guarded Linux input/panic paths exist; unsupported outcomes remain capability-gated | Certify Mercury; complete system CU capture, SmartHub devices, IBus/Fcitx, and companion overlay |

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

- `npm test --prefix apps/linux-desktop -- --maxWorkers=2`: **64 files, 457 tests passed**.
- `npm run build --prefix apps/linux-desktop`: **passed**; the main JavaScript
  chunk is **678.93 kB** minified and Vite reports a chunk-size warning.
- `cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml`:
  **26/26 passed**, including native deep-link/autostart, account-network,
  capability-catalog,
  Mercury-probe, update-feed, URL, gateway, panic-shortcut, and wire-contract
  coverage.
- ARM64 Ubuntu 24.04 GNOME X11 native-shell pass: production-protocol ELF
  `cfc14d7da1124d32d2370adf515cf4636b7c1c0345376377f71d09bd0099608d`
  stayed at one process through `openburnbar://chat`, rendered the bundled tray
  icon/menu, preserved honest offline state, and completed a native-menu XDG
  login-start off/on/off round trip with canonical `0600` user-owned content.
- Fail-closed OpenBurnBar Core/security/daemon Linux manifest: **100/100 passed**.
- Linux media crate capability/capture/decode suite: **3/3 passed**.
- Extension daemon-client suite: **40/40 passed**.
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
| P-01 | Release integrity | Signed, notarized, release/update path with installed-app proof | Strict crypto/closure/feed verification and dual-architecture aggregation implemented; clean unsigned construction closures passed for aarch64 and x86_64; final signed two-architecture candidate and update/rollback remain blocked | Partial | Critical |
| P-02 | Parity certification | Product inventory tied to release head and real behavior | Complete 40-row generated inventory now reports 0 ready/40 blocked and fail-closes stale, missing, contradictory, or self-referential proof | Partial | Critical |
| P-03 | Installed runtime | Owned app/daemon lifecycle with recovery and one authoritative supervisor | Package-owned aarch64 GUI/daemon/version/uninstall session passed; x86_64 and prior-version lifecycle remain open | Partial | Critical |
| P-04 | Architecture reach | Published build covers the declared macOS architecture support contract | Native aarch64/x86_64 shard workflow exists and architecture-correct local construction/smoke is green for both; a native hosted x86_64 run, signed aggregate, and installed x86_64 evidence are not yet produced | Partial | Critical |
| P-05 | Credential custody | Keychain-backed provider, connector, auth, and sync secrets | Secret Service, KWallet, and encrypted headless custodians are wired; live keyring/recovery matrix remains incomplete | Partial | Critical |
| P-06 | Gateway credential boundary | Native process owns bearer credentials | Rust owns the bearer and proxies bounded authenticated HTTP/SSE; renderer receives typed data, not the token | Near parity | Critical |
| P-07 | Computer Use | Browser, Agent Watch, Mac System, approval, audit, and three panic paths | Runtime manifest hides unsupported system mode; complete browser action proof and Linux system capture/input adapter remain missing | Partial | Critical |
| P-08 | Mercury media | File transfer, calls, screen share, mirroring, presence, consent | Daemon-owned transport, calls, files, sealed capture, portal consent, HUD, and live capability probing are implemented; real cross-device and compositor proof remains open | Partial | Critical |
| P-09 | Navigation and shell | Dashboard, insights, deep provider/model routes, multi-window flows | All 19 installed routes activate through AT-SPI; validated single-instance dashboard/search/chat/insights/membership deep links now route through typed native events; provider/model depth and native multi-window behavior remain thinner | Near parity | Medium |
| P-10 | Dashboard layouts | Six dense layouts with real live content and persisted state | All six layouts, persistence, loading/error/offline/populated states, tokens, and tests exist; the packaged six-layout visual matrix remains incomplete | Near parity | Medium |
| P-11 | Usage ingestion | 27 parser registrations, API/quota aggregation, recount, projections, cloud mirror | One 15-row Linux path registry now drives shell discovery copy and is contract-tested against Swift; the full macOS/Linux normalized parser corpus remains unproven | Partial | High |
| P-12 | Quota | Provider quotas, histories, account switching, alerts | Strong read surface; account profiles, drain targets, and switching lag | Partial | Medium |
| P-13 | Onboarding | Provider connection, scan, permissions, chat engine, recovery, completion gates | Daemon-owned state, required-step gates, restart recovery, Secret Service readback, XDG write verification, privacy persistence, and strict native/WebView RPC decoding are implemented; provider connection/scan, onboarding integration with deployed account/provider auth, portal, tray, update, and first-data readback remain incomplete | Partial | High |
| P-14 | Chat | Persisted threads, search, streaming, models, attachments, citations, approvals, panes/pop-out | Synthetic transcript rows and multiple disabled controls; five vs twelve backends | Partial | High |
| P-15 | Account and billing | Sign-in/link/sign-out, membership, subscription, recovery | Purpose-bound account auth and Linux App Check foundations are source-implemented: durable challenge/replay state, pinned verifier boundary, fixed 30-minute TTL, daemon memory-only acquisition, hash-only upload tickets, exact ingress claim, streamed evidence upload, receipt-native mint evidence, source revocation/identity-race gates, high-risk owner revocation with an atomic audit completion event, and a root broker/native deb-rpm lifecycle with signed installed manifests and exact peer authorization; production minting defaults off and the real Firebase app ID, physical TPM/IMA policy evidence, remote enrollment, deployed verifier/revocation operations, production audit evidence, ingress deployment, installed proof, membership restore/checkout, and entitlement recovery remain | Partial | High |
| P-16 | Cloud and devices | Backup, sync, conflict handling, remote access, trusted device management | Cloud/trusted-device mutation RPCs explicitly absent | Partial | High |
| P-17 | Activity/session logs | Indexed transcript, search, body, replay, resume, export, source resolution | Recent usage is wrapped as session metadata; no real body/resume/export | Substitute | High |
| P-18 | Memory review | Quarantined candidates, approve/reject, durable state, audit | Approve/reject/forget now use idempotent daemon RPCs and survive reload; Linux still lacks a proven first-class quarantine feed and cross-device review matrix | Partial | High |
| P-19 | Projects | Registered projects, exact associations, detail, management | Read-only cards inferred with fuzzy title matching; no CRUD | Partial | Medium |
| P-20 | Missions | Full run/task state, approvals, questions, evidence, history, health | List/create/approve works; history/evidence/freshness/questions lag | Partial | Medium |
| P-21 | Insights | Editorial brief, evidence, citations, follow-ups, comparison, audit | Usage charts and anomaly-like summaries only | Partial | Medium |
| P-22 | Database | Search/inspect indexed sessions, snapshots, watch/recovery, encrypted storage UX | Index/watch foundation exists; inspector, snapshot, and recovery depth lag | Partial | Medium |
| P-23 | Provider/model workspace | Provider and model deep dives, health, catalog, failover, routing | Quota-centric provider route; no equivalent model workspace/failover flow | Partial | Medium |
| P-24 | Settings | 16 searchable tabs with deep links and writable state | 13 tabs; Model Proxy, Computer Use, Pets omitted; several controls read-only | Partial | Medium |
| P-25 | Updates | Automatic checks, channel, install/restart truth | Native signed-feed availability check fails closed and signed apt/RPM repository closure is source-implemented; valid public feed/mirrors and package-manager install/restart/rollback proof remain open, while AUR/Flatpak remain unpromoted | Partial | High |
| P-26 | Tray and native shell | Rich live menu-bar status, quick switch, chat, quota, update state | Live cost/tokens, quota floor, provider count, freshness, compact status window, dashboard/chat/provider/update/reconnect/login-start/quit actions exist; matrix rows now require and can emit native-shell evidence; deterministic installed tray/status/deep-link/notification/login-start and XFCE/AppIndicator host-loss captures exist; account quick switch and full installed desktop matrix proof remain | Near parity | High |
| P-27 | Notifications/deep links | Actionable notifications, provider external login, global commands, login start | Single-instance validated deep links, membership return, background launch, XDG login start, source-level freedesktop notification actions, deterministic installed notification server/action/response/relaunch capture, an installed X11 global panic chord reaching the daemon-wide kill path, and a typed daemon-owned Codex/Claude external-login workflow exist; cloud agent-reply listener/quick reply, installed provider-login and rich notification breadth, multi-account provider switching, and cross-desktop shortcut proof remain | Partial | High |
| P-28 | SmartHub | Discovery, status, allowlisted device actions | Runtime requires a trusted root-owned packaged CLI and otherwise fails closed; real device outcomes remain unproven | Partial | High |
| P-29 | Text expansion | Global, secure-field-aware expansion, persistence, sync, previews | Preview-only in-app engine, plaintext localStorage, no normal composer hook | Substitute | High |
| P-30 | Pet companion | Animated ambient overlay, click-through, summon, selection, interactions | Route-contained point-cloud preview with optimistic capability detection | Partial | High |
| P-31 | Accessibility | Semantic UI, keyboard flows, assistive announcements, reduced effects | All routes pass axe; installed aarch64 AT-SPI/Orca/keyboard/200% evidence passed; desktop/architecture breadth remains | Near parity | High |
| P-32 | Performance | Startup/recovery/frame/cadence budgets and mature profiling | Matched macOS/Linux harness and ARM installed percentiles exist; final candidate and environment matrix remain | Partial | High |
| P-33 | Reliability | Backoff, supervisor, recovery, subscriptions, migrations, long-idle stability | Daemon-owned bounded start/resume/stop subscriptions, monotonic restart recovery, offline-aware single-flight cadence, cancellation, coalesced route refresh, and soak contracts exist; native push and installed suspend/portal/keyring/matrix certification remain | Partial | High |
| P-34 | Security hardening | Native URL/secret/process boundaries | Generic renderer shell permission and token exposure removed; production fixtures disabled; full installed adversarial matrix remains | Near parity | Critical |
| P-35 | Diagnostics/support | Native export, privacy choices, accurate runtime/package facts | Useful redaction base; copy and save behavior differ; fixture toggle exposed | Partial | Medium |
| P-36 | Visual/interaction polish | Consistent components, responsive density, animations, native affordances | Nonblack installed route captures now exist; raw diagnostics, interaction polish, and multi-environment regressions remain | Partial | Medium |
| P-37 | Linux matrix | N/A; macOS supported versions are exercised | Environment-bound fail-closed harness exists, requires package/accessibility/native-shell evidence, emits the native-shell matrix input from shell verification, and aarch64 X11/XFCE passed; GNOME Wayland, KDE Wayland, wlroots, x86_64, and real portal/keyring rows remain open | Partial | Critical |
| P-38 | CI/release automation | Test, sign, package, and promotion jobs fail closed | Strict gates, mutation tests, native architecture shards, sessions, and aggregate closure are implemented; a full hosted two-architecture release run remains unproven | Partial | Critical |
| P-39 | Cross-platform differential proof | Same contract/corpus compared at the same product version | Later Linux-labeled canonical evidence reuses preexisting fixtures rather than producing a current macOS-vs-Linux diff | Unproven | High |
| P-40 | Data and Privacy | Vault/export/deletion/retention/recovery/consent/telemetry/panic workflows | Inventory/copy exists, but important controls are read-only or no complete local/account destructive and recovery workflow is proven | Partial | High |

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

- **Baseline difference (2026-07-09):** macOS release confidence comes from a signed product and a
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

- **Baseline difference (2026-07-09):** macOS owns its daemon lifecycle, startup recovery, and app
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

- **Baseline difference (2026-07-09):** macOS uses Keychain-backed secret stores and keeps privileged
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

- **Baseline difference (2026-07-09):** the audited baseline Linux release workflow produced ARM64 artifacts
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

**Implementation update (2026-07-10): honesty gap closed; capability gap open.**
The typed runtime manifest now marks Linux system Computer Use unavailable and
prevents the route from offering a guaranteed-failure action. Browser Computer
Use remains the supported Linux mode. Full browser action/result E2E and a real
portal/PipeWire/AT-SPI/libei or constrained X11 system adapter are still required.

- **Baseline difference (2026-07-09):** macOS ships Browser, Agent Watch, and Mac System behavior with
  approval, audit, and panic paths. Linux presents browser, agent-watch, and
  system choices, but the daemon rejects non-browser modes, the surface has no
  real target/action/result workflow, and no Linux capture/input adapter exists.
- **Why it matters:** this is a safety-sensitive feature. Offering guaranteed-
  failure modes and unproven panic behavior is both misleading and dangerous.
- **Recommended solution:** first return a typed runtime capability manifest and
  hide unsupported modes; complete browser actions over the real Playwright
  bridge; then build portal/PipeWire capture, AT-SPI inspection, libei input,
  constrained X11/XTest, and explicitly consented uinput fallback.
- **Priority:** **Critical**.
- **Implementation notes:** preserve approval as ground truth; trust elevation
  remains Mac/desktop local; the Linux-native daemon-wide global panic path and
  deterministic installed X11 chord proof now exist, while lock/sleep/
  permission-revocation kill paths and real-desktop latency certification remain;
  audit every action and terminal entry; capability-gate per compositor and
  session type.
- **QA verification:** navigate/click/type/screenshot against real browser
  targets; exercise manual/step/trusted policy, approval races, denial, audit
  tampering, lock/sleep, portal revocation, daemon crash, and panic latency on
  GNOME/KDE/Sway Wayland and X11.

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
reordered requirements, and prerequisite jumps. At that onboarding packet's
commit, the native Linux manifest passed 98 Swift XCTest selectors and 18 Rust
tests; the desktop suite passed all 400 TypeScript/React tests plus its production
bundle verifier.

This does **not** close GAP-008 or P-13. Provider account connection and real log
scan, onboarding integration with deployed account/provider authentication,
portal permission readback, tray host verification, update-channel verification,
chat-engine selection, and first-data confirmation are still explicit optional
acknowledgements or separate workflows. Installed Ubuntu/Fedora keyboard,
screen-reader, restart, denial, and repair evidence also remains required.

- **Baseline difference (2026-07-09):** macOS onboarding connects providers, scans, requests system
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
  desktop grants, resume/export, and pop-out. Linux uses five backend choices,
  synthesizes two history rows, and disables model, agent, attachment, option,
  citation, tool-decision, restore, close, and pop-out controls.
- **Why it matters:** chat is a primary workflow; synthetic history and inert
  controls create false confidence and data-loss risk.
- **Recommended solution:** introduce real session-body and chat-thread RPCs,
  shared backend/model catalog, attachment store/content policy, streaming event
  contract, citation navigation, approval state machine, resume/export, and a
  Linux-native secondary window.
- **Priority:** **High**.
- **Implementation notes:** keep the daemon authoritative for thread state;
  reconcile reconnect/cancel/idempotency; do not expose controls until their
  capability is live; port macOS controller contracts into cross-platform tests.
- **QA verification:** exact transcript replay, every supported backend/model,
  image/PDF/text/audio/video attachment, tool approve/reject/race, citation open,
  cancel/retry, offline/reconnect, restart, pop-out/rejoin, export, and large
  transcript performance.

### GAP-010 - Complete account, cloud, billing, and trusted devices

**Implementation update (2026-07-10): Linux account-auth foundation
implemented; broader account/cloud parity remains open.** The Linux desktop now
starts a single daemon-owned `desktop_auth` device flow, opens only the exact
allowlisted HTTPS approval URL, polls without overlap, exchanges a sealed
custom token inside the daemon, persists only the refresh token in an approved
writable Secret Service/KWallet backend, refreshes before use, projects a
redacted profile, and signs out locally and idempotently. The website approval
path now initializes App Check, authenticates with Google or Apple, binds the
attestation claim, refreshes the ID token, obtains a high-risk nonce, and
completes the exact requested purpose. The server stores no plaintext
credential; credential material is limited to a verifier and sealed envelope
alongside bounded non-secret link metadata. It enforces purpose/flow binding and
supports secret-authenticated cancellation. The renderer and Rust bridge never
receive device secrets or Firebase credentials. Token-bearing daemon requests
refuse redirects and require an exact final endpoint URL. A durable keyring
affinity marker binds restore, rotation, preflight, and sign-out to one backend;
the retained signed-out tombstone keeps stale secondary-keyring credentials
inert. The App Check source foundation now adds a durable five-minute challenge,
atomic cross-instance replay consumption, exact signed-verdict verification, a
fixed 30-minute token TTL, an account-bound daemon memory-only client, hash-only
upload-ticket issuance, exact ingress claim, streamed evidence upload, and
receipt-native mint evidence. The high-risk owner revocation callable requires
App Check, a fresh nonce, and trusted-device proof; it creates durable
enrollment and deterministic-slot tombstones even before facade materialization,
fences ticket issuance and stale activation workers, and atomically appends the
tamper-evident completion audit event. The root-owned broker foundation adds
default-disabled systemd socket activation,
per-request `SCM_CREDENTIALS` plus exact executable authorization, signed
package manifests with recomputed inventory roots, bounded worker/IPC limits,
native deb/rpm lifecycle ownership, active user-daemon upgrade recovery, and
explicit purge semantics; AppImage is excluded from host attestation.
Production minting defaults off. This work does not claim a deployed Firebase
Web app, remote hardware enrollment, physical TPM quote vectors, deployed IMA
policy proof, remote-verifier approval, deployed revocation execution,
production audit evidence, installed-environment proof, or protected
membership/billing, backup/sync, or trusted-device parity.

- **Difference:** macOS can sign in/link/sign out, manage membership, cloud
  backup, conflicts, remote access, and trusted devices. Linux now implements
  the source-level sign-in/link/local-sign-out foundation, but its deployed
  outcome is unproven; membership and billing are incomplete, the Linux App
  Check protocol, root-broker boundaries, and owner revocation administration
  exist in source but production TPM/IMA host attestation and deployed
  revocation/audit proof are unavailable,
  cloud mutations are absent, and trusted-device
  mutation is explicitly unavailable.
- **Why it matters:** cross-device continuity, entitlements, remote workflows,
  recovery, and paid product behavior cannot be completed in the app.
- **Recommended solution:** retain the implemented daemon-owned device auth,
  validated approval origin, secure refresh-token custody, and local sign-out;
  complete `LNX-AUTH-DEPLOY-001`, `LNX-APPCHECK-001`,
  `LNX-MEMBERSHIP-001`, `LNX-SYNC-001`, and `LNX-DEVICE-001` in that dependency
  order; keep Remote MCP and safe web billing restore inside their existing
  purpose and entitlement boundaries.
- **Priority:** **High**.
- **Implementation notes:** preserve the `desktop_auth` purpose boundary and v2
  P-256/AES-GCM flow binding; keep custom/device/ID tokens memory-only and the
  refresh token in an approved writable native backend; external URLs must be
  exact HTTPS allowlisted; do not substitute all-device Admin revocation for
  ordinary local sign-out; define conflict and offline semantics before UI;
  surface Apple-only history honestly. Keep Linux `linux_lower_trust`, the mint
  kill switch default off, App Check tokens daemon-memory-only, and high-risk
  actions behind trusted-device proof plus a fresh single-use nonce. Do not
  promote generic VMs, no-TPM/Secure-Boot-off hosts, source builds, containers,
  WSL, Flatpak, or Snap without an independently reviewed trust policy.
- **QA verification:** deploy-time auth success, cancel, purpose/state mismatch,
  expiry, malicious redirect rejection, replay/tamper rejection, restart,
  refresh rotation, locked/missing keyring, local sign-out, device
  add/revoke/transfer, backup/restore/conflict/offline, checkout/restore,
  entitlement refresh, and clock skew. For App Check, verify challenge races,
  every identity-binding mutation, expiry/replay/revocation, bad signatures and
  verifier identity, verifier outage, fixed token expiry, account switching,
  daemon restart, renderer/log/support-bundle redaction, kill-switch behavior,
  and each supported/unsupported installed environment.

### GAP-011 - Replace activity and memory substitutes with true domain state

- **Difference:** macOS exposes indexed session transcripts and a real memory
  review queue. Linux still wraps recent usage as session entries. Memory
  approve/reject/forget decisions are now daemon-authoritative and idempotent,
  but recalled durable memories do not yet prove a first-class quarantine feed.
- **Why it matters:** users cannot inspect or resume actual work, and the memory
  UI describes semantics the backend does not provide.
- **Recommended solution:** add session list/body/search/source/resume/export RPCs
  and complete the daemon-owned memory quarantine source and cross-device audit
  model; retain the implemented durable decision path.
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

- **Difference:** Linux has index/watch foundations but lacks macOS inspector,
  snapshot, deep search, encrypted-store recovery, and equivalent watch UX.
- **Why it matters:** users cannot diagnose missing sessions, inspect canonical
  records, recover corruption, or trust that updates are current.
- **Recommended solution:** add daemon-owned inspect/search/snapshot/watch/rebuild/
  recovery RPCs with pagination, cancellation, query tracing, and clear encryption
  state.
- **Priority:** **Medium**.
- **Implementation notes:** unify inotify ownership rather than layering another
  poller; use `OpenBurnBarQueryTracer`; keep raw sensitive content behind explicit
  reveal/export policy.
- **QA verification:** search/inspect/snapshot/watch/rebuild/recover; N+1 limits,
  10k/100k rows, corruption, locked key, permission loss, path move, event burst,
  cancellation, and restart.

### GAP-012E - Complete provider and model workspaces

- **Difference:** macOS has provider/model deep dives, health, account profiles,
  catalog, routing, and failover. Linux's provider route is quota-centric and has
  no equivalent model workspace or full failover workflow.
- **Why it matters:** users cannot understand availability or control routing
  when quotas, credentials, models, or providers change.
- **Recommended solution:** build daemon-owned provider/account/model catalog,
  health, priority, drain target, routing, and failover contracts with deep links.
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

**Implementation update (2026-07-10): native launch/tray/startup foundation,
compact status window, source-level freedesktop notification action primitive,
deterministic installed notification action capture, fail-closed native-shell
matrix evidence requirements, and verifier-produced `native-shell-evidence.json`
implemented; installed X11 global panic capture is producer-backed; typed
daemon-owned Codex/Claude external login is source-implemented; installed matrix
certification, cloud quick reply, and provider-login certification remain open.**
Rust now owns single-instance arbitration,
background launch, an allowlisted `openburnbar://` parser,
listener-race-safe delivery, window focus, live tray actions/facts, lazy compact
status-window lifecycle, freedesktop notification capability/delivery commands,
and atomic user XDG autostart mutation. The renderer accepts only correlated
typed route/action pairs. deb, rpm, AppImage, and AUR packaging share the
canonical autostart entry. The environment matrix harness now requires a current
`OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE` file proving tray host/actions,
compact-status accessibility, notification server/actions/relaunch, deep-link
relaunch, global panic shortcut, login-start, and tray-host-loss recovery before a requested support
row can become ready; `verify-shell-evidence.mjs` emits that JSON from
installed-session artifacts and records missing rows instead of claiming false
success. The packaged desktop-session harness now records tray route actions,
compact status accessibility, deterministic freedesktop notification
server/action/response/relaunch routing, secondary deep-link relaunch,
an X11 foreground-probe global panic chord with daemon-wide acceptance,
fresh-session login-start lifecycle, and XFCE/AppIndicator host-loss/restart
recovery artifacts. Direct ARM64 GNOME X11 evidence still proves hidden background
launch, one-process Chat routing, the bundled icon/native menu, and an exact
login-start off/on/off round trip. This is not full installed desktop-matrix,
rich notification-host, cross-desktop tray-host, or lifecycle certification. See
`LINUX_NATIVE_SHELL_AUTHORITY.md` and
`evidence/mission-003-native-shell/runtime-transcript.txt`.

The provider workflow is registry-driven and admits only the Codex and Claude
browser-login methods. The daemon owns a single five-minute flow, a private
two-phase terminal handshake, whole-process-group cancellation, restart-safe
verification grace, and local auth verification. Active renderer polling is
bound to the exact provider, method, and flow. The renderer receives sanitized
state and display metadata, never tokens, callback URLs, filesystem paths,
arguments, stdout, or stderr.
Default CLI credential directories are used; isolated multi-account profiles are
not claimed by this packet.

- **Difference:** macOS provides a rich menu-bar experience with live cost,
  quota, providers, quick switch, chat, freshness, and update state. Linux now
  exposes live cost/tokens, quota floor, provider count, freshness, a compact
  status window, primary navigation/reconnect/login-start actions, validated
  membership/navigation links, source-level freedesktop notification actions,
  background launch, and a producer-backed certification gate for native-shell
  evidence. It still lacks account quick switch, cloud agent-reply quick reply,
  installed notification and provider-login breadth, cross-desktop tray-host
  breadth, and isolated provider multi-account switching.
- **Why it matters:** repeated daily workflows, alerts, recovery, auth, and panic
  controls feel incomplete or cannot work outside the main window.
- **Recommended solution:** certify the implemented tray, compact status
  window, typed deep links, source-level freedesktop notifications,
  daemon-backed panic, XDG startup, and typed provider CLI external login across
  installed environments; then add cloud agent-reply listener/quick reply,
  durable isolated provider profiles/account switching, and portal/global-
  shortcut coverage beyond the X11 fallback proof.
- **Priority:** **High**.
- **Implementation notes:** support GNOME's icon-only limitations; use shared
  live view models and freshness semantics; never depend on the tray as the sole
  panic path; extend host-loss proof beyond the deterministic XFCE/AppIndicator
  row into the full supported desktop matrix.
- **QA verification:** icon-only and rich hosts, stale/offline/reconnect state,
  keyboard/screen-reader navigation, notification actions/relaunch, provider
  external login, global panic latency, login start, multi-monitor, and cross-desktop tray
  crash/recovery.

### GAP-015 - Implement honest update UX

**Implementation update (2026-07-09): partially closed in the implementation
branch.** The Linux shell now performs the availability check in native Rust,
pins the release-signing public key and SPKI fingerprint, verifies detached
Ed25519 signatures, validates schema/product/platform/channel/semantic version,
requires both supported architectures, rejects downgrade/replay and untrusted
URLs, and exposes only typed validated state to the renderer. The installed
`.deb` route was exercised through AT-SPI and correctly rendered **Update
metadata rejected** against the currently invalid public endpoint. A follow-on
source packet builds and independently verifies signed, architecture-specific
apt and RPM repositories after aggregate release assembly. Apt uses signed
Release/InRelease metadata; RPM package copies and `repomd.xml` use the same
pinned OpenPGP identity so clients can enforce package and repository signature
checks. The production channel config intentionally keeps that identity
unconfigured until a recoverable public key/fingerprint and matching private
CI secret are provisioned. The package-manager-owned install/rollback
lifecycle, signed public feed and mirrors, exact-candidate repository closure,
and prior-version upgrade/rollback evidence remain open; AUR and Flatpak remain
explicitly unpromoted. This row is therefore still **Partial**, not closed.

- **Baseline difference (2026-07-09):** macOS exposes version, automatic checks, channel, install, and
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

- **Difference:** macOS has typed SmartHub integrations. Linux's surface calls
  an optional `runCli` bridge that neither the Tauri bridge nor command handler
  implements, so the production path always errors while fixture mode can hide
  the failure.
- **Why it matters:** a visible route is nonfunctional, and adding arbitrary
  shell execution would create a security regression.
- **Recommended solution:** expose structured, allowlisted daemon/Tauri commands
  for discovery, status, test, cast, and supported device actions.
- **Priority:** **High**.
- **Implementation notes:** parse Avahi output structurally; validate device IDs,
  URLs, payload sizes, timeouts, and cancellation; never expose generic shell;
  reuse shared SmartHub contracts where possible.
- **QA verification:** real Cast, Home Assistant, AWTRIX, and Pixel Clock devices;
  escaped names, absent dependency, malformed input, timeout, auth failure,
  offline/reconnect, cancellation, and command-injection attempts.

### GAP-017 - Make text expansion real and safe

- **Difference:** macOS provides global, accessibility-aware expansion with
  persistence and sync. Linux stores snippets in plaintext localStorage and only
  exercises expansion in a preview/test surface, not normal app composers.
- **Why it matters:** even the claimed in-app substitute is not a daily-use
  feature, and sensitive snippets lack appropriate custody.
- **Recommended solution:** first integrate expansion into every app composer and
  move storage to the encrypted daemon database; then implement an opt-in
  IBus/fcitx input method with secure-field and application exclusions.
- **Priority:** **High**.
- **Implementation notes:** avoid global keylogging; preserve clipboard contents;
  capability-gate Wayland/X11 behavior; define import/export/sync conflicts and
  LLM preview privacy.
- **QA verification:** normal app inputs, GTK/Qt/Electron apps, password/secure
  fields, excluded apps, clipboard restore, IME composition, Unicode, recursion,
  import/export, sync, GNOME/KDE Wayland, and X11.

### GAP-018 - Ship a real compositor-aware pet companion

- **Difference:** macOS has an animated desktop companion with overlay behavior
  and interaction. Linux renders a route-contained point-cloud preview and
  assumes overlay capability in nearly every environment except GNOME Wayland.
- **Why it matters:** the visible result is materially less polished and can
  steal focus or block input when optimistic compositor assumptions are wrong.
- **Recommended solution:** render the real glTF mesh/material/animation in a
  separate transparent always-on-top/pass-through window only after capability
  proof; add summon, selection, chat/file interactions, multi-monitor behavior,
  and a clearly labeled contained fallback.
- **Priority:** **High**.
- **Implementation notes:** maintain a compositor capability matrix; use reduced
  motion and GPU budgets; do not claim click-through from environment variables
  alone; isolate crashes from the main app.
- **QA verification:** GNOME/KDE/Sway Wayland and X11 focus, click-through,
  topmost, drag, scaling, animation, reduced motion, multi-monitor, hotkey,
  restart, GPU fallback, and unsupported contained mode.

### GAP-019 - Replace synthetic accessibility evidence with assistive-tech proof

**Implementation update (2026-07-09): closed in the implementation branch.**
All 19 routes and important states now run through axe; the installed `.deb`
is exercised through AT-SPI actions, Orca process/focus observation,
keyboard-only traversal, and requested 200% zoom. The full shell verifier
rejects missing or synthetic accessibility artifacts. GNOME/KDE matrix breadth
remains tracked under GAP-004 rather than keeping this implementation gap open.

- **Baseline difference (2026-07-09):** macOS has broad semantic labels/actions and targeted tests.
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

- **Difference:** Linux now has daemon-owned bounded pull subscriptions, a
  single-flight data supervisor, packaged startup/reopen/reconnect percentiles,
  a matched Swift workload harness, Rust boundary tests, and a 30-minute soak
  contract. It still lacks a native push stream. The built main chunk is 662.74
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

- **Baseline difference (2026-07-09):** macOS uses narrow native service APIs. Linux has CSP, but still
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

- **Baseline difference (2026-07-09):** macOS release automation has mature behavioral gates. Linux PR
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
| LNX-GATE-001, LNX-REL-VERIFY-001, LNX-CI-001 | Admission contract implemented; semantic producers blocked | Complete blocked inventory, canonical policy-driven requirement attester, exact installed-subject binding, GitHub Artifact Attestation verification, crypto/closure mutations, strict workflow wiring | Implement all 40 requirement-owned validators, run the seven-environment exact-candidate producer matrix, aggregate its signed receipts after candidate assembly, and make all required rows green |
| LNX-SEC-001, LNX-IPC-001, LNX-CAP-001 | Implemented | Native secret custodian, native gateway proxy, production fixture boundary, runtime capability manifest | GNOME/KDE/headless environment certification |
| LNX-A11Y-HARNESS-001 | Implemented | All-route axe plus installed AT-SPI/Orca/keyboard/zoom contract | Full architecture/desktop/high-contrast matrix |
| LNX-PERF-HARNESS-001 | Implemented | Matched workload tools, p50/p95/p99/resource capture, nightly soak contract | Final candidate results on comparable hardware and environments |
| LNX-RUN-001 | Partially proven | Clean aarch64 package-owned GUI/daemon/version/uninstall session | x86_64, prior-version lifecycle, suspend/resume, compositor breadth |
| LNX-PKG-001 | Implemented in workflow; construction proven | Four-artifact aarch64 and architecture-correct x86_64 shards green with 28/28 smoke checks each; native dual-architecture aggregation is fail closed | Native hosted x86_64 run, installed x86_64 session, signed aggregate, and channel lifecycle |
| LNX-UPD-001 | Partially implemented | Native signed-feed availability verifier rejects invalid public metadata | Valid feed plus deb/rpm/AppImage update, rollback, and data preservation |
| LNX-CHANNEL-001 | Role-isolated atomic publication and scheduled-refresh source implemented; live deployment, refresh execution, and lifecycle blocked | Fail-closed apt/RPM builder and verifier; checksum-addressed indices; seven-day apt expiry; pinned signing-subkey policy; immutable RPM identity proof; closure-addressed R2 snapshots; separate upload/control/serving/feed Workers with least-privilege routes and distinct control credentials; create-only upload with bounded legacy-byte adoption and mandatory large-object digest metadata; no-pointer preview lifecycle; snapshot/generation/ETag repository CAS and per-channel feed CAS/history; write-ahead activation intent; official-key Ed25519 feed verification plus signed-artifact R2 binding; channel-isolated retained feed descriptor rebinding after rollback; channel-qualified snapshot/bootstrap/feed routing; exact public header/byte proof; legacy direct-R2 first-cutover restoration or later fail-closed deactivation; scheduled metadata-only refresh with signed parent chaining, immutable package-byte proof, retained feed rebind, public verification, compensation, and Sigstore-verified durable receipts; draft-aware, repeated-absence GitHub cleanup; explicit AUR/Flatpak non-promotion | Provision the production OpenPGP identity and CI key, Cloudflare credentials/DNS and distinct upload/activation secrets; deploy and exercise all four Workers; exercise the scheduled refresh against production; prove an installed keyring overlap/rotation lifecycle; publish the exact candidate; fault-inject upload/activation/feed/rollback/deactivation and ambiguous responses; prove clean install, update, rollback, and uninstall on both architectures; resolve AUR/Flatpak promotion decisions |
| LNX-EVT-001 | Implemented in source; installed certification pending | Bounded pull authority, restart/offline recovery, cancellation, and coalesced refresh | Native push and exact-candidate suspend/offline matrix |
| LNX-ONB-001 | Partially implemented | Daemon-owned transactional state and required prerequisite probes | Provider scan, deployed auth, portal, tray, update, chat, and first-data readback |
| LNX-AUTH-001 family | Source foundation implemented; deployment and product depth open | Purpose-bound sealed device auth, daemon refresh/keyring custody, redacted state, local sign-out, and the App Check challenge/verifier/daemon-client/ingress bridge boundary | Deploy account auth; complete the App Check verifier, rollout, and installed proof; then membership, sync, and trusted devices |
| LNX-APPCHECK-001 | Source daemon bridge, root-broker, and revocation administration implemented; production blocked | Five-minute Firestore challenge, atomic replay consumption, exact signed-verdict binding, fixed 30-minute token TTL, kill switch default off, account-bound daemon memory cache, hash-only upload-ticket reservation, exact ingress claim, streamed evidence PUT, receipt-native mint evidence, root `openburnbar-attestd`, signed installed manifest, exact peer authorization, broker-owned `tpm2_createak` AK lifecycle initialization/rotation guard, private root-owned AK-bound enrollment-state binding, private `ak.ctx` activation, `tpm2_quote` collection, sealed IMA/measured-boot/manifest descriptor, verifier-side active-enrollment recheck before verdict signing, Functions-side revocation gate before challenge consumption/token minting, high-risk owner revocation with atomic tombstone/audit persistence, stale-worker tombstone preservation, systemd socket activation, native deb/rpm lifecycle, AppImage exclusion, and the 16 MiB descriptor ceiling | Real Firebase Web app ID, remote enrollment activation, physical-TPM quote vectors, complete IMA verification, deployed remote verifier/revocation operation and production audit evidence, ingress/verifier deployment, negative vectors, and exact-candidate GNOME/KDE/headless installed matrix |
| LNX-NATIVE-001 | Partially implemented | Single-instance launch, typed deep links, live tray facts/actions, compact status window, source-level freedesktop notification actions, deterministic installed notification action capture, installed X11 global-panic capture, deterministic login-start lifecycle capture, deterministic tray-host-loss/restart capture, XDG login start, daemon-owned typed provider external login, native-shell evidence requirements in the matrix harness, and verifier-produced native-shell evidence JSON | Cloud quick reply, installed provider-login and rich notification-host breadth, durable provider multi-account profiles, display-manager/package-manager breadth, and full installed desktop matrix evidence |
| LNX-CAT-001, LNX-DIFF-001 | Open | Existing provider/path contracts retained | Shared catalog plus same-commit macOS/Linux differential proof |
| Phase 2 core workflows | Open/partial | Existing routes and bounded mutations retained | Complete product outcomes and daemon-authoritative state |
| Phase 3 native features | In progress | Mercury core, Linux CU input, panic, and outbound capture foundations are implemented; unsupported outcomes remain capability-gated | Cross-device Mercury proof, system CU capture, SmartHub, IBus/Fcitx, pet adapters |
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
    -> auth deploy -> Linux App Check -> membership -> sync -> trusted devices
    -> provider catalog + native shell + updates
      -> sessions/chat/memory + operational workspaces
        -> Computer Use + Mercury + SmartHub + text expansion + pet
          -> accessibility/performance/matrix certification
            -> stable promotion
```

### Phase 0 - Stop false green and recover the product baseline

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-GATE-001 | None | Replace the partial parity ledger with a complete product inventory; bind all Tier A/B evidence to target HEAD, a trusted immutable release-workflow artifact, the signed package subject, exact live package ownership and file inventory, pre/post installed-shell runtime captures, and a logind-anchored environment through a registered-validator, GitHub-provenance-verified attester; generate Markdown from JSON | Current-head or requirements-manifest drift, missing row/policy/validator, substituted producer, wrong release subject, package-owned-path or installed-byte drift, opaque runtime capture, mislabeled logind session, untrusted evidence run/artifact, hand-authored receipt, wrong GitHub repository/workflow/ref, blocked required row, and contradictory docs fail CI |
| LNX-PROOF-001 | LNX-GATE-001, LNX-PKG-001, all product tasks | Implement each deterministic `product-validators/P-XX.mjs`; run it on the exact seven-environment installed matrix; upload the receipt and Sigstore bundle; after signed candidate assembly, download one complete matrix, verify every bundle, invoke all 40 attesters, then run strict ledger validation | No validator accepts caller pass state; all 280 check/environment receipts bind one release closure and the environment-installed package/runtime; any missing job, bundle, subject digest, producer identity, or matrix pair blocks promotion |
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
| LNX-CHANNEL-001 | LNX-PKG-001, LNX-REL-VERIFY-001 | Fail-closed apt/RPM construction, bounded freshness, signing identity proof, immutable release URLs, release-root binding, create-only authenticated uploads, closure-addressed snapshots, shared immutable leaves, role-isolated upload/control/serving/feed Workers, snapshot/generation/ETag repository CAS, independent per-channel feed CAS with retained-descriptor rebinding, pre-activation snapshot lifecycle, channel-qualified bootstrap/feed routing, exact public-byte/header proof, write-ahead intent and ambiguous-result reconciliation, official-key feed/artifact validation, rollback/deactivation compensation, draft-aware GitHub cleanup with repeated dual-source absence proof, scheduled signed metadata-only refresh, and attested publication receipts are source-implemented; provision and deploy the production identities/infrastructure, exercise refresh against production, prove installed keyring overlap/rotation, publish and verify exact-candidate mirrors, correct and certify AUR, and retain Flatpak as unpromoted until its portal/keyring contract passes | Each declared channel installs the correct architecture and verifies repository/package metadata; failed, interrupted, ambiguous, drifted, ABA-raced, concurrent, or downstream publication cannot mutate immutable bytes or leave an unverified candidate active; stale CAS and malformed/missing targets fail closed; rollback selects a retained unexpired generation and restores its same-channel signed feed without consuming another channel's history; first activation restores applicable legacy direct-R2 behavior when deactivated; unavailable rollback disables mutable routes; metadata refresh completes before expiry without changing package/RPM bytes; public bytes match the signed closure; unpromoted channels remain absent from install copy |
| LNX-EVT-001 | LNX-CAP-001 | Bounded pull subscription authority, cadence, cancellation, restart/offline recovery, and coalesced route refresh are implemented; add native push and exact-candidate installed certification | Kill/stall/suspend/offline tests recover without stale or frozen UI |
| LNX-ONB-001 | LNX-SEC-001, LNX-RUN-001, LNX-CAP-001 | Daemon-owned transactional state/readback foundation is implemented; add provider/auth/portal/tray/update/chat/first-data probes | A clean user cannot finish required setup while any declared required prerequisite is missing |
| LNX-AUTH-001 | LNX-SEC-001, LNX-IPC-001 | Umbrella account outcome, delivered through the five child packets below; the source-level sign-in/sign-out and App Check protocol foundations are implemented | Every auth child packet is accepted at one release head; full sign-in/out/keyring/device/backup/restore/checkout matrix passes without credential exposure |
| LNX-NATIVE-001 | LNX-CAP-001 | Single-instance/background launch, typed navigation/membership deep links, live tray facts/actions, compact status window, source-level freedesktop notification actions, installed X11 global-panic capture, XDG startup, daemon-owned provider external login, fail-closed native-shell matrix evidence requirements, and verifier-produced native-shell evidence JSON are implemented; add cloud quick reply, durable provider multi-account profiles, and exact-candidate matrix certification | Repeated native workflows, including provider login success/cancel/timeout/missing-CLI/terminal-close/restart, pass on GNOME/KDE/wlroots, rich and icon-only hosts, accessibility, notification, and lifecycle rows |
| LNX-UPD-001 | LNX-PKG-001, LNX-CHANNEL-001, LNX-NATIVE-001 | Signed check, compatibility, package/channel-native install/restart/rollback UX | Tamper/replay/arch/version tests fail; prior-version update and rollback succeed for every declared channel |
| LNX-CAT-001 | LNX-CAP-001 | Shared provider/model/parser/path manifest and golden fixtures | Equivalent normalized provider results on macOS/Linux |
| LNX-DIFF-001 | LNX-CAT-001, LNX-CI-001 | Same-commit macOS/Linux binaries run one attested corpus and workflow suite | Mutations on either platform fail the normalized differential oracle |

#### LNX-AUTH-001 child packets

All five packets bind their proof to the same release head under
`docs/linux-port/evidence/auth/<release-head>/<task-id>/`. An individual packet
may merge independently, but `LNX-AUTH-001` remains open until all five are
accepted together.

| Task | Depends on | Engineering work | Required evidence | Rollback/containment | Acceptance criteria |
|---|---|---|---|---|---|
| LNX-AUTH-DEPLOY-001 | LNX-SEC-001, LNX-IPC-001 | Deploy the reviewed Functions and website revisions; certify the exact approval origin, purpose-bound callable, daemon exchange, keyring persistence, restart, and local sign-out | Source/deployment revision binding, CSP and endpoint checks, Google and Apple approval transcripts, GNOME Secret Service and KDE KWallet runs, captured IPC/DOM/log redaction scan | Roll back Functions and website to their prior revisions; keep the Linux client local-only and surface auth as unavailable without deleting local product data | Google and Apple sign-in, cancel, expiry, retry, restart, refresh rotation, locked/missing keyring, and double sign-out pass through production endpoints with no credential exposure |
| LNX-APPCHECK-001 | LNX-AUTH-DEPLOY-001, LNX-CAP-001 | The lower-trust model, durable challenge/replay store, pinned signed-verdict seam, fixed 30-minute mint, default-off kill switch, daemon memory-only client, hash-only upload-ticket reservation, exact ingress claim, streamed evidence PUT, receipt-native mint evidence, root broker/native deb-rpm lifecycle, broker-owned `tpm2_createak` AK lifecycle initialization/rotation guard, private AK-bound enrollment-state binding, `ak.ctx` activation, source TPM quote collector, sealed IMA/measured-boot/manifest descriptor, verifier-side active-enrollment recheck, Functions-side revocation gate, high-risk owner revocation callable, atomic tombstone/audit transaction, stale-worker tombstone guards, and 16 MiB descriptor ceiling are source-implemented; provision the real Firebase Web app, add remote enrollment activation and complete verifier-side IMA evidence policy, deploy the pinned ingress/verifier/revocation callable, collect production audit evidence, and enforce installed-environment capability policy | ADR 015, Functions/daemon/broker negative vectors, TPM quote and complete IMA-log vectors or short-lived upload receipts, replay/revocation/clock-skew/offline tests, server decision and audit logs, release measurements, direct Firestore/Storage surface inventory, and GNOME/KDE/headless capability results | Keep `LINUX_APP_CHECK_MINT_ENABLED=false` and remove the Linux app ID from the allow-list; Functions deny immediately, direct Firebase-product access drains within the fixed 30-minute token TTL, and local account/SQLite workflows continue | Forged, replayed, expired, revoked, wrong-user/app/device/version/architecture/release/policy attestations fail; valid supported physical-TPM environments renew without renderer/log/disk token exposure; unsupported hosts fail before action |
| LNX-MEMBERSHIP-001 | LNX-AUTH-DEPLOY-001, LNX-APPCHECK-001, LNX-NATIVE-001 | Add daemon-ID-token membership reads, Linux-safe checkout/manage endpoints, validated browser return, restore, entitlement refresh, and recovery; do not use Apple JWS as a Linux substitute | Free/Pro and stale/offline fixtures, checkout/return/restore transcripts, signed webhook/entitlement receipts, restart recovery, and malicious-return tests | Disable billing mutations and retain read-only entitlement/local mode; never erase local data or fabricate Pro state during outage | Free, Pro, checkout, manage, cancel, restore, renewal, expiry, refund, offline, and callback-tamper cases converge on server-authoritative entitlement state across restart |
| LNX-SYNC-001 | LNX-APPCHECK-001, LNX-MEMBERSHIP-001, LNX-EVT-001, LNX-SEC-001 | Implement daemon-owned encrypted backup, append/merge replication, offline journal, restore, conflict policy, remote access, and explicit sync status while preserving local authority | Two-device encrypted payload inspection, deterministic conflict fixtures, offline/reconnect/retry transcripts, corruption/partial-failure recovery, and 10k-record performance | Pause remote replication and preserve local data plus the durable pending journal; never resolve uncertainty by deleting or overwriting the local authority | Backup, incremental sync, restore, conflict, duplicate retry, offline recovery, corruption recovery, account switch, and entitlement loss complete without plaintext or local data loss |
| LNX-DEVICE-001 | LNX-APPCHECK-001, LNX-SYNC-001, LNX-SEC-001 | Add trusted-device list/add/approve/revoke/forget/transfer and encrypted credential-transfer lifecycle with daemon-owned authorization and audit | Linux-to-macOS/iOS/Android two-device matrix, approval/revocation races, transfer readback, stolen/replayed invitation tests, audit trail, and restart/offline recovery | Disable new pairing and transfers server-side while preserving revocation/audit records and local credentials; a revoked device remains denied | Add, reject, approve, revoke, forget, replace, and transfer are idempotent, survive restart, propagate across devices, and prevent revoked or replayed peers from reading new data |

### Phase 2 - Core workflow parity

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-SESS-001 | LNX-EVT-001 | Session repository: list/body/search/source/resume/export | Real transcript replay and recovery, no synthetic rows |
| LNX-CHAT-001 | LNX-SESS-001, LNX-CAT-001 | Backends/models, streaming, attachments, citations, approvals, options, secondary window | Mac-equivalent chat contract suite and installed E2E green |
| LNX-MEM-001 | LNX-EVT-001 | Real quarantine/review/forget/audit RPCs | Daemon-authoritative decisions persist across restart/devices |
| LNX-PROJ-001 | LNX-SESS-001 | Project CRUD, exact associations, detail/history, inferred-row migration | Stable-ID project lifecycle and 10k-session migration suite green |
| LNX-MISSION-001 | LNX-EVT-001 | Mission questions, evidence, history, health, freshness, cancel/recovery | Full mission operating lifecycle survives restart/reconnect |
| LNX-INSIGHT-001 | LNX-SESS-001, LNX-CAT-001 | Insight evidence/citations, compare, follow-up, and audit | Every insight is source-linked and comparable with stale/error handling |
| LNX-DB-001 | LNX-EVT-001, LNX-SEC-001 | Inspector, search, snapshots, inotify ownership, rebuild/recovery, query budgets | Search/watch/rebuild/corruption/100k-row suite green without N+1 drift |
| LNX-PROVIDER-001 | LNX-CAT-001, LNX-SEC-001 | Provider/model deep dives, accounts, health, routing, drain and failover | Catalog, switch, quota-exhaustion and failover lifecycle green |
| LNX-PRIV-001 | LNX-SEC-001, LNX-AUTH-001, LNX-SESS-001, LNX-MEM-001 | Export, retention, local/account deletion, recovery, consent, telemetry, panic | Scoped destructive/recovery workflows and multi-device propagation green |
| LNX-SET-001 | LNX-CAP-001, LNX-AUTH-001, LNX-PRIV-001 | Shared settings schema, missing tabs, deep links, writable configuration | Search, persistence, readback, and policy tests green |

### Phase 3 - Native high-complexity features

| Task | Depends on | Engineering work | Acceptance criteria |
|---|---|---|---|
| LNX-CU-BROWSER-001 | LNX-CAP-001, LNX-IPC-001, LNX-SESS-001, LNX-NATIVE-001, LNX-EVT-001 | Real target/action/result Browser CU workflow with native panic/lifecycle | Navigate/type/click/screenshot/approval/panic/audit/restart E2E green |
| LNX-CU-SYSTEM-001 | LNX-CU-BROWSER-001, LNX-CAP-001, LNX-NATIVE-001 | Portal/PipeWire/AT-SPI/libei plus constrained X11/uinput adapters | Safety and compositor matrix green; unsupported modes hidden |
| LNX-MEDIA-001 | LNX-CAP-001, LNX-IPC-001, LNX-SEC-001, LNX-AUTH-DEPLOY-001, LNX-APPCHECK-001, LNX-NATIVE-001, LNX-EVT-001 | Mercury transport, secure pairing, files, calls, share, codecs, consent, notification/lifecycle | Real two-device matrix green on supported desktops |
| LNX-IOT-001 | LNX-IPC-001 | Typed SmartHub discovery/action APIs | Real device and hostile-input tests green |
| LNX-TEXT-001 | LNX-SEC-001, LNX-EVT-001 | App composer integration, encrypted storage/sync, then IBus/fcitx | Secure-field and desktop/input-method matrix green |
| LNX-PET-001 | LNX-CAP-001, LNX-NATIVE-001 | Real glTF renderer, companion window, capability fallback | Visual, focus, compositor, GPU, and reduced-motion tests green |

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
| 3 | **Mainstream install** | Package construction and apt/RPM repository source foundation complete; signing identity, public mirrors, installed lifecycle, and AUR/Flatpak decisions remain | LNX-PKG-001, LNX-CHANNEL-001 | Both architectures and every declared package/repository channel install locally |
| 4 | **Daily-use native foundation** | In progress; onboarding, bounded event refresh, single-instance/deep-link, live-tray, compact status, source-level notifications, installed X11 global-panic capture, XDG login-start, account-auth foundations, Linux App Check challenge/verifier/daemon-client/ingress boundaries, root broker/native deb-rpm lifecycle, source owner revocation administration with atomic audit persistence, and typed provider external login implemented; production TPM/IMA evidence, deployed remote verification/revocation and audit proof, membership/cloud/device depth, cloud quick reply, provider-login installed certification/multi-account profiles, and installed matrix remain | LNX-EVT-001, LNX-ONB-001, LNX-AUTH-DEPLOY-001, LNX-APPCHECK-001, LNX-MEMBERSHIP-001, LNX-SYNC-001, LNX-DEVICE-001, LNX-NATIVE-001, LNX-UPD-001, LNX-CAT-001, LNX-DIFF-001 | Setup, deployed auth, production attestation, data freshness, alerts/tray, update lifecycle, and current provider diff green |
| 5 | **Core product workflows** | Open/partial | LNX-SESS-001, LNX-CHAT-001, LNX-MEM-001, LNX-PROJ-001, LNX-MISSION-001, LNX-INSIGHT-001, LNX-DB-001, LNX-PROVIDER-001, LNX-PRIV-001, LNX-SET-001 | No synthetic state; every primary workspace and privacy workflow completes |
| 6 | **Browser automation parity** | Open/partial | LNX-CU-BROWSER-001 | Real actions, approval, panic, audit, restart recovery |
| 7 | **Media and system integration** | In progress; Mercury code complete | LNX-CU-SYSTEM-001, LNX-MEDIA-001 | Supported compositor safety and two-device media proof |
| 8 | **Extended features** | Pending | LNX-IOT-001, LNX-TEXT-001, LNX-PET-001 | SmartHub, input-method, and companion outcomes proven or honestly substituted |
| 9 | **Candidate and certification** | Blocked on milestones 3-8 | LNX-REL-CANDIDATE-001, LNX-A11Y-CERT-001, LNX-PERF-CERT-001, LNX-QA-001, LNX-DOC-001 | Exact signed candidate, assistive-tech, performance, architecture, desktop matrix, and docs green |
| 10 | **Stable promotion** | Blocked by design | LNX-PROMOTE-001 | Zero Critical/High gaps and a current reproducible evidence graph |

### Parallelization and ownership

After Milestone 2, these workstreams can proceed in parallel when their shared
contracts are frozen:

- delivery: package architectures, update provider, release verification;
- auth and cloud: deploy, native attestation, membership, sync, and trusted
  devices; keep those five child packets sequential inside this lane;
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
- [ ] Every product row uses the exact canonical attester command and evidence
  path; the attester and requirement-specific policy exist, are repository-
  confined, and cannot be replaced through a symlink or alternate command.
- [ ] Every ready row has the exact registered validator/environment matrix;
  each schema-2 receipt binds release/package subjects, exact live installed
  ownership/inventory, pre/post installed-shell runtime captures, and the live
  logind environment manifest plus a
  GitHub Artifact Attestation from the pinned repository, workflow, source ref,
  source commit, and exact receipt digest.
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
- [ ] The repository OpenPGP public key and full fingerprint are recoverable,
  committed, and match `OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY`; missing,
  placeholder, wrong, expired, or mismatched keys fail before metadata signing.
- [ ] Apt clients verify `InRelease`/`Release.gpg`; RPM clients enforce both
  `gpgcheck=1` and `repo_gpgcheck=1`; one-byte mutations of a package, index,
  repository signature, or `repository-closure.json` fail verification.
- [ ] Repository publication uploads package bytes before signed root metadata,
  and a clean public-mirror download verifies against the exact release closure
  before any apt/dnf installation copy is enabled.
- [ ] Release package smoke launches the real GUI and daemon, not only inspects
  archive contents.

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

- [x] Native launch arguments and secondary instances deliver only allowlisted,
  correlated route/action pairs after the renderer listener is installed.
- [x] Settings and tray share one atomically written, package-pinned user XDG
  login-start entry with source and packaging drift tests.
- [x] Source-level account contracts cover purpose/flow binding, sealed-envelope
  tamper rejection, exact approval URLs and response endpoints, redirect refusal,
  non-overlapping and loss-tolerant polling, persistence before signed-in
  publication, restart/refresh rotation, renderer redaction, backend-affinity
  tombstones, and atomic local sign-out.
- [x] Source-level Linux App Check contracts cover a durable five-minute
  challenge, atomic replay rejection, exact identity/release/policy binding,
  pinned signed-verdict verification, a fixed 30-minute token TTL, a default-off
  mint kill switch, account-bound daemon memory-only acquisition, hash-only
  upload-ticket reservation, exact ingress claim, streamed evidence upload, and
  receipt-native mint evidence.
- [x] Source-level revocation contracts require the authenticated owner, App
  Check, a fresh high-risk nonce, and trusted-device proof; preserve AK/EK
  identity material as an idempotent tombstone; create enrollment and
  deterministic-slot tombstones before facade materialization; clear pending
  leases; reject later ticket issuance and stale worker mutation; atomically
  append the completion audit event; and deny subsequent verifier and mint use.
- [x] Every callable has a generated lower-trust desktop policy enforced in the
  shared callable wrapper; unknown IDs and uncataloged callables fail closed,
  Linux deny/low-risk/prerequisite/step-up sets are cardinality-locked, and
  step-up rows retain AST-validated trusted-device wiring and helper runtime
  proofs. The production browser Firebase ID is exact-registered and checked
  against both shipped Web clients before deploy.
- [x] Root-owned `openburnbar-attestd` foundation authenticates the exact
  package-owned daemon through a signed complete installed manifest,
  per-request `SCM_CREDENTIALS`, inode/owner/mode/hash checks, a recomputed
  inventory root, bounded socket-activated workers, and per-UID rate limits.
  Fresh installs keep the privileged socket disabled until enrollment and an
  explicit rollout marker exist. The broker parses the private root-owned
  enrollment state and returns a binding only when the AK TPM blob hashes to
  the enrolled `ak-sha256:*` device ID. Native deb/rpm packages own lifecycle
  hooks, active user-daemon upgrade recovery, and state preservation. Their
  prepare, isolated-signing, and finalize phases bind a canonical complete
  signer-input root to a signed exact-package receipt; final RPM extraction
  rejects payload mutation by rpmbuild. AppImage is explicitly ineligible, and
  destructive identity purge requires an explicit confirmation flag.
- [x] Broker source can collect PCR-bound quote artifacts through
  `/usr/bin/tpm2_quote` using a private root-owned `ak.ctx`, keeps quote outputs
  in anonymous memfds, builds the canonical sealed evidence descriptor, and
  rejects missing enrollment, AK context, manifest mismatch, unavailable logs,
  and malformed quote output before upload or mint.
- [x] Broker source can initialize and rotate AK lifecycle material through
  explicit `initialize-ak` / `--rotate` operator actions, using private
  root-owned EK inputs, `/usr/bin/tpm2_createak`, atomic private state writes,
  and a machine-readable receipt for the enrollment flow.
- [ ] Provision the real Firebase Web app ID; activate remote enrollment,
  physical quote vectors, complete verifier-side IMA evidence policy,
  deployed revocation plus production audit evidence, public ingress
  deployment, and the pinned remote verifier; pass forgery/replay/expiry/
  wrong-binding/outage vectors and the exact-candidate GNOME/KDE/headless
  installed matrix.
- [ ] Verify Linux App Check tokens and raw evidence never persist to disk or
  cross renderer, RPC status, logs, crash reports, process metadata, or support
  bundles; unsupported hosts fail before protected cloud action.
- [x] Source-level provider external-auth contracts admit only registry-approved
  Codex/Claude methods, bound one flow to five minutes, preserve terminal state,
  and redact tokens, callbacks, paths, arguments, and terminal output from the
  renderer.
- [ ] Sign-in/link/sign-out, state validation, expiry, refresh, local credential
  deletion, offline, and clock-skew cases pass.
- [ ] Trusted-device and server-side credential revocation propagate securely.
- [ ] Trusted device add/revoke/transfer and credential transfer are secure.
- [ ] Backup, restore, conflict resolution, remote access, checkout, restore, and
  entitlement refresh work across restart.
- [ ] Tray/status UI works in rich and icon-only hosts, with stale/offline states.
- [ ] Notifications deliver actionable deep links and recover after relaunch.
- [ ] Provider external login, login startup, and global panic work on GNOME/KDE/wlroots.

### Computer Use, media, and extended features

- [ ] Unsupported Computer Use modes are unavailable before session start.
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

- Linux account-auth source revision:
  `0d31d4ee9831e9608df7ecb3e9655cdaa3c8a2ba`
- Linux account-auth authority and primary implementation:
  `docs/linux-port/LINUX_ACCOUNT_AUTH_AUTHORITY.md`,
  `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/LinuxDesktopAuthEnvelope.swift`,
  `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity/OpenBurnBarLinuxSecurity.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarAccountAuthService.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarAccountAuthNetworkClients.swift`,
  `apps/linux-desktop/src/state/accountStore.ts`,
  `functions/src/callables/cliLink.ts`, and `website/src/pages/link.astro`
- Linux account-auth reproducible verification entry points:
  `bash scripts/linux-port/run-linux-native-tests.sh`,
  `npm test --prefix apps/linux-desktop -- --maxWorkers=2`,
  `npx vitest run` in `functions/`, and `npm test --prefix website`
- macOS route oracle: `AgentLens/Views/Dashboard/DashboardNavigationModel.swift`
- macOS settings oracle: `AgentLens/Views/Settings/SettingsTab.swift`
- Linux settings manifest: `apps/linux-desktop/src/surfaces/settings/settingsTabs.ts`
- Linux chat controls/state: `apps/linux-desktop/src/surfaces/chat/` and
  `apps/linux-desktop/src/state/chatStore.ts`
- Linux Tauri capability/commands: `apps/linux-desktop/src-tauri/src/lib.rs`
- Linux provider external-auth authority:
  `docs/architecture/014-linux-provider-external-auth.md`,
  `OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProviderContracts.swift`,
  `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarProviderExternalAuthService.swift`,
  `apps/linux-desktop/src/state/providerExternalAuthStore.ts`, and
  `apps/linux-desktop/src/surfaces/settings/ProviderExternalAuthPanel.tsx`
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
- Native shell matrix evidence producer:
  `scripts/linux-port/verify-shell-evidence.mjs` ->
  `native-shell-evidence.json`
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
