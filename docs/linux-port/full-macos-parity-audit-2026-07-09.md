# Linux Full macOS Parity Audit - 2026-07-09

This is the current Linux parity scan against the macOS OpenBurnBar product. It
is deliberately stricter than the existing 64-row Linux parity ledger: the
ledger records a previous infrastructure milestone, while this audit asks the
user-facing question: "Can a Linux user do what a macOS user can do, with the
same safety, release, cloud, and operational guarantees?"

## Current Verdict

Linux is not at full macOS parity.

### Post-main integration status — 2026-07-20 UTC

Source verification extends through `5b52f3f92f`; the current exact-native
checkpoint remains `22fd7dfad9`. Verified source and build
gates are **94 frontend files / 910 tests**, Tauri Rust **133/133**, TypeScript,
the production-bundle verifier, workflow verifier Node tests **28/28**, Linux
Swift verifier Python tests **18/18**, and fresh Ubuntu ARM64 production builds
of `OpenBurnBarDaemon` and `OpenBurnBarCLI`. The later source-only file splits
also pass the zero-oversized-file ratchet and a host CLI product build.

The current merge exposed and fixed two Linux-only compilation problems. Swift
6.1 whole-module compilation could not reliably select the explicit-nonce
`PlatformCrypto` overload, so the shared API now provides an unambiguous named
entry point and the legacy crypto callers qualify it through the platform
support module. The newly cross-platform Insights target also called Apple's
app-group container API unconditionally; non-Apple builds now return an honest
unavailable result instead.

Exact-head package proof now passes. The 152,116,006-byte ARM64 DEB has SHA-256
`72fb15222374ee5231aa53b498aba984e4b281e5c93fa359c4a4f53c29886522`.
Both decomposed resource bundles are packaged and installed; package-versus-
installed desktop, daemon, CLI, iroh, Kernel-resource, and Pretext-resource
hashes match. The daemon is active, CLI health is OK, and a native Codex deep
link passes AT-SPI at 189/108/91/33 nodes/named/actionable/focusable. See the
[`exact-native receipt`](evidence/parity-audit-2026-07-10/linux-arm64-current-22fd7dfad9-exact-native-2026-07-20.json)
and
[`provider deep-link screenshot`](evidence/parity-audit-2026-07-10/linux-arm64-current-22fd7dfad9-provider-deep-link.png).

The strict certification ledger remains **0/40 product rows and 0/7 environment
receipts** because the package manifest is the unsigned `{}` placeholder.
Production OAuth/App Check/callables, signed updater and rollback, real keyring,
compositor/architecture coverage, SmartHub and pet hardware behavior,
physical-iPad Computer Use/Mercury workflows, and a same-commit macOS
differential remain external proof blockers.

Linux now has a real Tauri/React desktop shell, a Swift daemon path, AF_UNIX RPC,
provider gateway work, Linux package metadata, and a public signed aarch64
prerelease. That is meaningful progress. It is still not a macOS-grade product
because several macOS workflows are missing, substituted, fixture-backed,
degraded, or release-only rather than live and user-operable.

Separate these facts:

- Public prerelease assets: yes. `linux-v0.1.0` exists on GitHub, published on
  2026-07-09 at 04:46:23Z, with AppImage, deb, rpm, daemon, checksums, Ed25519
  signatures, Sigstore bundles, SBOM, VEX, and provenance assets.
- Release/update parity: no. `latest-linux.json` is not a JSON update feed on
  the public site in this scan; `https://burnbar.ai/latest-linux.json` returned
  the website HTML shell. Local release verification still reports missing local
  artifacts, blocked draft metadata, update/rollback gaps, and dirty checkout
  state.
- Product parity: no. Computer Use, Mercury/media, full Hermes chat, cloud
  account flows, session transcripts, provider/model detail, memory review,
  project management, text expansion, pet companion, and several ops/security
  flows are not at macOS parity.

## Audit Context

- Local checkout: `windows/liquid-glass-kernel-reskin`
- Local HEAD: `aa0d1c44e0`
- Live Linux release workflow: `Linux Release`, run `28994097882`, success,
  `main` at `e265594f054726b60cdf0921c104e1e79fe577d4`
- Local worktree state: dirty before this audit, including Linux desktop UI,
  Linux packaging desktop files, Windows docs/scripts, and generated Linux
  release evidence files
- Method: repo scan, mem0 navigation lookup, live GitHub release check, public
  feed check, local Linux validators, and six focused read-only investigation
  streams

The dirty branch matters. Local generated evidence is useful for diagnosis, but
clean release truth must come from a clean release commit or live GitHub
artifacts.

## Existing Linux Foundation

Linux is not a blank port. Current implemented foundations include:

- Tauri/React desktop shell in `apps/linux-desktop`
- Routed Linux surfaces for overview, insights, database, providers, projects,
  missions, activity, chat, memory, settings, account, updates, support,
  onboarding, pet, and text expansion
- Rust/Tauri command bridge in `apps/linux-desktop/src-tauri/src/lib.rs`
- Linux package metadata in `packaging/linux`
- Linux release workflows in `.github/workflows/linux-*.yml`
- Swift daemon Linux sources under `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux`
- POSIX loopback HTTP gateway for OpenAI-compatible provider paths
- AF_UNIX RPC bridge, socket token auth, and Linux peer-auth substitute
- Linux security abstractions for Secret Service, KWallet, systemd credentials,
  and headless fail-closed modes
- SQLCipher/GRDB Linux test surfaces in `OpenBurnBarCore`
- Some Linux package, shell, parity-ledger, release-config, and docs validators

The issue is not "nothing exists." The issue is that the current Linux product is
a broad shell and engine subset, while macOS is a deeper native application with
live cloud, media, Computer Use, approval, transcript, update, and operational
flows.

## Local Validation Snapshot

Commands run during the scan:

```bash
node scripts/linux-port/validate-linux-release-config.mjs
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
node scripts/linux-port/verify-linux-release.mjs --allow-blocked
gh release view linux-v0.1.0 --json tagName,name,isDraft,isPrerelease,publishedAt,url,assets
gh run view 28994097882 --json databaseId,status,conclusion,createdAt,updatedAt,workflowName,event,headBranch,headSha,url
curl -fsSI https://burnbar.ai/latest-linux.json
```

Results:

- `validate-linux-release-config.mjs`: passed locally.
- `validate-parity-ledger.mjs --allow-blocked`: passed locally.
- `check-linux-docs.mjs`: passed locally, but this audit found docs drift that
  the checker does not catch yet.
- `verify-linux-release.mjs --allow-blocked`: exited in allow-blocked mode, but
  wrote `passed: false` in
  `docs/linux-port/evidence/mission-001-release/release-verification.json`.
- Current `docs/linux-port/parity-ledger.json`: 64 rows, all `ready`, generated
  2026-07-05. That is stale relative to this full-product parity scan.
- Public `https://burnbar.ai/latest-linux.json`: returned `text/html` website
  markup, not JSON update metadata.

## Parity Matrix

Status key:

- Ready: comparable user-facing behavior and proof exist.
- Partial: meaningful implementation exists, but user-visible parity is missing.
- Substitute: Linux intentionally uses a different safer model.
- Missing: macOS behavior has no Linux equivalent yet.
- Blocked: implementation is present or planned, but external/runtime proof is
  absent.

| Surface | Linux status | Gap to macOS parity | Target state |
| --- | --- | --- | --- |
| Desktop shell and routing | Partial | Linux has a real app shell, but macOS is an `LSUIElement` menu bar app with richer popovers, global chrome, native overlays, and deeper workflows. | Linux has platform-native package-manager UX plus equivalent tray, global actions, route coverage, and keyboard/window ergonomics. |
| Onboarding and daemon startup | Blocked | Tauri/Linux paths, Swift daemon defaults, CLI token handling, and onboarding text are inconsistent. `service foreground` probes health instead of starting the daemon. | One documented socket/token owner, systemd user service, package-owned daemon startup, CLI token-file support, and first-run proof. |
| Updates | Blocked | Linux shell reports update unavailable, public feed returned HTML, and update/rollback smoke is blocked. macOS has a live direct update feed. | Signed `latest-linux.json`, feed parser tests, in-app status, install-update-rollback e2e, and public feed verification. |
| Packaging and install | Partial | AppImage/deb/rpm assets exist live, but local evidence is stale/missing and package integration proof is thin. | deb/rpm/AppImage install, launch, service enablement, autostart, uninstall, and GUI smoke are proven on clean artifacts. |
| Release trust | Partial | Ed25519 and Sigstore sidecars exist, but local verifier does not validate all signature bytes/identity equivalence and source tarball parity is missing. | Source tarball parity, Ed25519 byte verification, cosign identity verification, live post-publish asset checks, and release provenance parity. |
| HTTP provider gateway | Partial | Linux gateway serves chat/responses/messages, but `/v1/models` returns empty and `/v1/models/catalog` parity is missing. | Model list, model catalog, route health, provider failover, rate limiting, and macOS gateway parity tests. |
| Provider configuration and routing | Blocked | Router is shared, but Linux credential writes still hit Keychain-backed stores in key paths. | Linux Secret Service/KWallet/systemd credential stores wired into provider, connector, notification, DB, and phone-pin stores. |
| Hermes/chat | Partial | Live streaming exists, but transcript replay, model menu, attachments, popout/options, memory citations, and tool approvals are disabled or synthetic. | Multi-backend chat, attachments, transcript/workspace controls, citations, approvals, model picker, and replay parity. |
| Tool approvals | Missing | Chat approval buttons are disabled, and Linux CLI capability profile does not match advertised CLI run/approval flows. | Approval queue, allow/deny UI, daemon RPC contract tests, CLI capability alignment, and audit evidence. |
| Computer Use browser path | Partial | RPC surface exists and browser path is plausible, but Linux has no first-class UI route/settings and coverage is not macOS-grade. | Browser Computer Use UI, trust scope, approvals, audit chain, Playwright bridge loopback, and panic proof. |
| Computer Use system path | Missing | macOS privileged input, Virtual HID, watchdog, and remote access products are macOS-only; Linux rejects `agent_watch` and `system`. | Explicit Linux portal/libei/uinput/XTEST/AT-SPI design, user consent, audit, panic kill, and compositor matrix proof. |
| Panic kill paths | Blocked | App/daemon/mobile evidence exists, but global compositor hotkey path is blocked. | GNOME/KDE/Sway or portal-equivalent global panic proof under latency SLO with no input after panic. |
| Mercury/media | Missing | Linux media surface is observe-only and `daemon.media.status` is a proposed/degraded bridge. macOS has calls, file transfer, mirroring, tray/global chrome, and incoming panels. | Linux media RPCs, pair/call/mirror/file/end controls, status, notifications, and real device/session proof. |
| Account and membership | Partial | Linux account is status plus external checkout/restore. Redirect path uses custom schemes that conflict with HTTPS-bounded callable validation. | Firebase auth providers, cloud backup/trust flows, accepted Stripe redirect flow, portal restore, and malicious URL rejection. |
| App Check and cloud security | Blocked | Production Linux App Check, live Firebase/Auth, Stripe restore, and staging cloud sync evidence are blocked by missing credentials/config. | Live staging/prod App Check readback, token exchange, BOLA/plaintext-deny traces, and endpoint-policy proof. |
| Cloud store and remote MCP | Missing | macOS has cloud backup/trust/remote MCP flows in settings. Linux has no equivalent complete UX. | Linux account/cloud settings, trust/device pairing, backup status, conflict handling, and remote MCP proof. |
| Mission control | Partial | Linux can list/create/approve/deny missions, but macOS has a richer operating workbench, runtime health, evidence, freshness, and history. | Full operating workbench with runtime health, evidence drawers, controller history, freshness, and review actions. |
| Connector plane | Blocked | Mission dispatch depends on connector credentials, but connector secrets still use Keychain-style defaults in key paths. | Linux connector secret store wiring, readiness proof, dispatch e2e, and failure-mode tests. |
| Activity and session logs | Partial | Linux lists/searches/details sessions, but lacks macOS transcript panes, cloud/local body resolution, resume, export, pending questions, and mission panels. | Full transcript workflow, source filters, resume/export, pending question handling, and cloud/local resolution. |
| Insights | Partial | Linux shows usage telemetry and charts. macOS has agent insight workspace, canvas, composer, citations, followups, audit actions, and compare UX. | Agent insight workspace with citations, compare, audit actions, followups, and persistence. |
| Database/indexing | Partial | Linux has story/atlas/system index and polling watch controls. macOS has deeper split-view inspector/search/snapshot UI and richer live updates. | Inspector, snapshot, search, watch semantics, encrypted store integration, and inotify/poll parity proof. |
| Projects | Partial | Linux derives project cards. macOS has project hub/editor/register flows. | Project create/register/edit/delete flows, detail navigation, and index integration. |
| Provider/model detail | Partial | Linux provider route maps mostly to quota/status. macOS exposes provider/model detail navigation and lane links. | Provider detail, model catalog, credential state, route health, and quota/failover views. |
| Memory review | Substitute | Linux recall/audit/forget approximates approved memories; true quarantine approve/reject is missing. | Daemon review-row RPCs, approve/reject/quarantine UX, audit trail, and fixture-free proof. |
| Text expansion | Substitute | Linux is intentionally in-app only. macOS uses a passive global keyboard monitor. | Safe Linux IME/fcitx/IBus-style system-wide design, no keylogger, with compositor/desktop proof. |
| Pet companion | Partial | Linux is route/preview/tier behavior. macOS has transparent non-activating panel, chat bubble, toolbar, file drop, and ambient desktop behavior. | Linux ambient overlay where supported, Wayland-safe fallback, click-through/topmost proof, chat/file interactions. |
| Smart display and integrations | Partial | Linux is mostly read-and-explain/status/config via daemon/CLI. | Live control UX, device discovery, permission model, and degraded states. |
| Notifications and observability | Partial | Daemon observability warns when Sentry DSN is missing unless strict mode is set; Linux release fail-closed observability is not proven. | Strict Linux release observability, Sentry readback, alert docs, privacy scrubbed event proof. |
| CLI | Partial | CLI advertises more than the signed Linux capability profile allows; production peer auth can deny advertised flows. | CLI capability allowlist matches commands; Linux behavior tests cover health, preflight, socket, mission, run, approval, and env/token paths. |
| Security hardening | Partial | AF_UNIX auth and systemd basics exist. Tauri CSP is disabled, shell permission is broad, and systemd service can be tightened. | CSP enabled, shell allowlist narrowed, external URL allowlist, stronger systemd sandboxing, tamper/hash-pin tests. |
| Automated tests | Partial | Linux PR gate builds Swift but does not appear to run Linux Swift behavior tests; several off-Apple tests are placeholders. | PR-gated Linux Swift tests, Tauri `cargo test`, package smoke, and real-surface nightly matrix. |
| Docs/user support | Partial | Several docs still read like Linux is non-public/blocked, while a public prerelease exists. No cohesive user setup/support matrix/limitations docs. | User setup, support matrix, known limitations, upgrade/rollback, supply-chain, rollback, CHANGELOG, README, and checker updates. |

## P0 Blockers

These block any honest "full macOS parity" claim.

1. **Daemon startup, socket, token, and package ownership are inconsistent.**
   Swift daemon defaults, Tauri defaults, CLI token discovery, package systemd
   units, and onboarding do not form one production contract. Fix this before
   building higher-level parity on top.

2. **Linux credential custody is not wired into the daemon stack.** Linux
   security abstractions exist, but provider, connector, notification, DB-key,
   and phone-pin stores still rely on Apple Keychain-oriented paths or in-memory
   fallbacks in critical places.

3. **Computer Use is not full parity.** Browser-path pieces exist, but Linux has
   no first-class Computer Use UI and no system-control parity for macOS
   privileged input, Virtual HID, watchdog, and global panic hotkey behavior.

4. **Mercury/media is not ported.** Linux currently reports media readiness or
   capability absence; macOS has user-operable calls, screen-share/mirroring,
   file transfer, incoming panels, tray status, and global chrome.

5. **Hermes/chat is only partial.** Streaming exists, but disabled model menu,
   attachments, popout/options, memory citations, tool approvals, and transcript
   parity keep it below macOS.

6. **Release/update parity is incomplete.** Public prerelease assets exist, but
   `latest-linux.json` is not a usable JSON feed in this scan, local verifier
   evidence is stale/failing, update/rollback is blocked, source tarball parity
   is missing, and package integration proof is not macOS-grade.

7. **Cloud/App Check/Stripe live proof is blocked.** Production Linux App Check,
   Firebase/Auth, Stripe checkout/restore, and cloud sync proof are blocked by
   missing credentials/config and a redirect contract mismatch.

8. **Linux PR/test gates are too shallow.** Linux Swift behavior tests are not
   visibly PR-gated, several off-Apple test targets are placeholders, and
   package/real-surface proof is mostly nightly/release-only or blocked.

9. **Docs and ledgers overstate or blur truth.** The old parity ledger says all
   64 rows are ready, while this scan finds product gaps. Some docs still say
   Linux is not public, while GitHub now has a public prerelease.

## Execution Plan

### Wave 0 - Truth and Contract Reset

Goal: stop stale docs/ledgers from hiding real product gaps.

Work:

- Rebaseline `docs/linux-port/README.md` around three states: public prerelease
  exists, update-channel promotion is not complete, full macOS parity is not
  complete.
- Mark `docs/LINUX_PORT_MASTER_PLAN.md` as historical or replace it with this
  audit as the current plan.
- Split the current parity ledger into infrastructure rows and product-parity
  rows, or add a `scope` field so "ready" cannot mean both "gateway row ready"
  and "macOS product parity ready."
- Add docs for `user-setup.md`, `support-matrix.md`,
  `known-limitations.md`, and `upgrade-and-rollback.md`.
- Strengthen `scripts/linux-port/check-linux-docs.mjs` to catch stale blocked
  release language, missing user docs, missing CHANGELOG Linux release notes,
  public feed returning HTML, and AUR/Flatpak drift.

Verification:

```bash
node scripts/linux-port/check-linux-docs.mjs
node scripts/linux-port/validate-parity-ledger.mjs
```

### Wave 1 - Linux Foundation and Security

Goal: make the daemon, shell, CLI, credentials, and package install contract
coherent and secure.

Work:

- Choose one production socket path and token location, likely
  `$XDG_RUNTIME_DIR/openburnbar/daemon.sock` for runtime socket and an XDG
  state/config location for durable auth material.
- Update Swift daemon, Tauri bridge, CLI, package service, onboarding, and tests
  to use the same contract.
- Make CLI read token files in addition to env vars.
- Make `service foreground` either actually start the daemon or stop presenting
  it as a start command.
- Wire Linux Secret Service/KWallet/systemd credential backends into provider,
  connector, notification, DB-key, and phone-pin stores.
- Fix Linux peer PID rate-limit keying and add root/hash-pin package tamper
  tests.
- Tighten Tauri CSP, shell permissions, external checkout URL allowlist, and
  systemd hardening.

Verification:

```bash
docker build -t openburnbar-linux-toolchain:mission-001 tools/linux-toolchain
docker run --rm -v "$PWD:/workspace" -w /workspace openburnbar-linux-toolchain:mission-001 \
  swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarDaemonLinuxGatewayTests
docker run --rm -v "$PWD:/workspace" -w /workspace openburnbar-linux-toolchain:mission-001 \
  swift test --package-path OpenBurnBarCore --filter OpenBurnBarLinuxSecurityTests
cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml
npm test --prefix apps/linux-desktop
```

### Wave 2 - Release, Install, and Update Parity

Goal: make Linux release promotion as defensible as macOS direct release.

Work:

- Publish Linux source tarball parity and require it in release verification.
- Add Ed25519 signature byte verification and cosign identity/payload
  verification.
- Produce and publish a real JSON `latest-linux.json`.
- Add consumer-side feed parser tests and app update-state tests.
- Make deb/rpm install daemon binary, systemd user unit, desktop file, icons,
  and autostart files as intended.
- Add AppImage GUI launch smoke and RPM GUI launch smoke, not just metadata
  checks.
- Add previous-version install -> update -> version verify -> rollback smoke
  once there is a prior stable Linux artifact.
- Fix AUR `PKGBUILD` tag/asset/hash drift or mark it unpublished.
- Keep Flatpak explicitly non-promotable until portal, update, and Flathub
  evidence exist.

Verification:

```bash
node scripts/linux-port/build-linux-release.mjs --version 0.1.0
node scripts/linux-port/smoke-linux-packages.mjs
node scripts/linux-port/verify-linux-release.mjs
curl -fsS https://burnbar.ai/latest-linux.json | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))'
```

### Wave 3 - Daemon/Core Feature Parity

Goal: close shared-engine gaps before polishing UI that depends on missing
backend behavior.

Work:

- Port Linux gateway model catalog and `/v1/models/catalog`.
- Add provider route health, model availability, failover, quota exhaustion,
  cooldown, local/cloud model selection, and large AF_UNIX payload tests.
- Align CLI capability profile with actual CLI run, approval, subscription, and
  mission commands.
- Add connector plane readiness and dispatch e2e with Linux secrets.
- Stabilize SQLCipher packaging and DB key provisioning.
- Decide whether legacy index DB remains plaintext-compatible or moves behind
  the encrypted store.
- Add Linux memory review/quarantine daemon RPCs.
- Add transcript body resolution, export/resume, pending question, and mission
  session contracts.

Verification:

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace openburnbar-linux-toolchain:mission-001 \
  swift test --package-path OpenBurnBarDaemon --filter OpenBurnBarDaemonLinuxGatewayTests
docker run --rm -v "$PWD:/workspace" -w /workspace openburnbar-linux-toolchain:mission-001 \
  swift test --package-path OpenBurnBarCore --filter OpenBurnBarDataLinuxTests
npm test --prefix apps/linux-desktop
```

### Wave 4 - User-Facing Workflow Parity

Goal: make the Linux app feel like the same product, not a status dashboard.

Work:

- Computer Use: add route/settings tab, trust mode UI, approvals, audit export,
  panic controls, browser-session UX, portal permission explanations, and
  degraded system-control states.
- Mercury/media: add daemon RPCs and UI for pairing, call state, incoming calls,
  screen-share/mirror, file transfer, end controls, and notifications.
- Chat: enable model picker, attachments, memory citation navigation, tool
  approvals, transcript replay, popout/options, and multi-backend status.
- Account/cloud: add Firebase auth providers, cloud backup/trust device state,
  remote MCP/account settings, and Stripe redirect-safe checkout/portal restore.
- Activity/session logs: add transcript pane, body resolution, resume, export,
  pending questions, and mission context.
- Insights: port agent insight workspace, canvas/composer, citations, compare,
  followups, and audit actions.
- Projects/provider/model: add project register/edit/detail flows and provider
  model detail navigation.
- Memory: replace recall-as-approved substitute with real review inbox
  approve/reject/quarantine semantics.
- Text expansion: design and implement a safe Linux IME/fcitx/IBus route for
  system-wide expansion without global keylogging.
- Pet companion: move from route preview to ambient overlay where the desktop
  environment allows it, with clear Wayland-safe fallback.

Verification:

```bash
npm test --prefix apps/linux-desktop
npm run build --prefix apps/linux-desktop
OB_SHELL_FORCE_DESKTOP_SESSION=1 node scripts/linux-port/run-shell-smoke.mjs
```

### Wave 5 - Real-Surface Matrix and Promotion

Goal: prove the product on the desktops users actually run.

Work:

- Promote Ubuntu GNOME X11/Xvfb smoke from preview proof to gate.
- Add Ubuntu GNOME Wayland, Fedora KDE Wayland, and Arch/wlroots real-surface
  runs.
- Add packaged AppImage/deb/rpm GUI screenshots and route interaction evidence.
- Add Secret Service and KWallet live store/read/locked-keyring tests.
- Add global panic proof on each supported compositor or explicitly document
  unsupported states.
- Add App Check, Firebase/Auth, Stripe checkout/portal, cloud sync, and support
  bundle redaction staging/prod evidence.
- Publish public support matrix and known limitations after proof exists.

Verification:

```bash
node scripts/linux-port/verify-linux-release.mjs
bash scripts/ops/verify-production-ops-plane.sh
bash scripts/ci/verify-ops-readiness.sh
```

## Parallel Workstreams

The implementation should stay parallel, but each stream needs a bounded owner
surface.

| Stream | Mission | Owns | Non-goals | Required proof |
| --- | --- | --- | --- | --- |
| A. Shell and workflow UI | Port missing user workflows and remove fixture/degraded UI where backend is ready. | `apps/linux-desktop/src`, UI tests, shell smoke scripts | Daemon security rewrites | Vitest, build, packaged route smoke, screenshots |
| B. Daemon/core contract | Unify socket/token/startup, provider gateway, model catalog, CLI capabilities, memory/session RPCs. | `OpenBurnBarDaemon`, `OpenBurnBarCore`, CLI tests | Tauri visual polish | Linux Swift tests in Docker, IPC negative tests |
| C. Credentials/security | Wire Linux credential stores, cloud/App Check proof, URL allowlists, Tauri/systemd hardening. | `OpenBurnBarCore/Sources/OpenBurnBarLinuxSecurity`, secret stores, Functions checkout/App Check, security docs | Media feature UI | Secret Service/KWallet proof, malicious URL tests, support redaction |
| D. Release/package/update | Close Linux release parity with macOS direct channel. | `packaging/linux`, `.github/workflows/linux-*.yml`, `scripts/linux-port`, website feed | Product feature behavior | Strict verifier, signature/cosign checks, package install/update/rollback |
| E. Computer Use and Mercury | Build Linux-safe CU and media capabilities with honest degraded states. | CU daemon/core, media RPCs, Linux UI surfaces, panic proof | General account/project screens | Browser/system CU tests, media e2e, panic matrix |
| F. Tests/docs/ledger | Make truth fail closed and user-facing docs accurate. | `docs/linux-port`, `CHANGELOG.md`, check scripts, parity ledger | Feature implementation except small checker fixes | Docs checker, ledger validator, stale-claim tests |

## Acceptance Criteria For Full macOS Parity

Do not call Linux "full parity" until all of this is true:

1. A clean Linux release commit runs `node scripts/linux-port/verify-linux-release.mjs`
   without `--allow-blocked` and passes.
2. Public `latest-linux.json` is valid JSON, signed/verified, consumed by the
   shell, and covered by update/rollback e2e.
3. deb, rpm, and AppImage install/launch/uninstall proof exists, including
   daemon service, desktop file, icon, autostart, and GUI smoke.
4. Linux Swift behavior tests run in PR CI, not only Swift builds.
5. Tauri `cargo test`, Linux desktop Vitest/build, and packaged smoke are gated.
6. Linux credential stores are live-proven on GNOME Secret Service and KDE
   KWallet, with headless/systemd fallback documented and fail-closed.
7. Provider/model catalog, route health, quota/failover, connector dispatch, and
   mission control are feature-equivalent or explicitly documented substitutes.
8. Computer Use has Linux browser parity and a documented/proven system-control
   story with approval, audit, and panic-kill guarantees.
9. Mercury/media has user-operable call, mirror, file transfer, notification,
   and session controls.
10. Chat has model selection, attachments, transcript workflows, citations, tool
    approvals, and replay/export parity.
11. Account/cloud/App Check/Stripe flows are live-proven against staging/prod.
12. Activity, insights, projects, provider detail, memory review, text expansion,
    pet companion, and smart-display surfaces meet their macOS workflow
    contracts or carry explicit, safe Linux substitutes.
13. Real-surface proof covers Ubuntu GNOME X11, Ubuntu GNOME Wayland, Fedora KDE
    Wayland, and Arch/wlroots, or unsupported rows are explicit public
    limitations.
14. Linux docs, README, CHANGELOG, supply-chain, rollback, support matrix, and
    known limitations match live truth.

## Immediate PR Sequence

Recommended smallest coherent PRs:

1. **Truth reset PR:** rebaseline Linux docs, support matrix, known limitations,
   upgrade/rollback docs, and docs checker. No feature changes.
2. **Startup contract PR:** unify socket/token/startup paths across daemon, CLI,
   Tauri, packaging, onboarding, and tests.
3. **Linux secrets PR:** wire Secret Service/KWallet/systemd credentials through
   provider, connector, notification, DB-key, and phone-pin stores.
4. **CI behavior PR:** add Linux Swift tests, Tauri `cargo test`, and slim
   packaged route smoke to PR gates.
5. **Release promotion PR:** source tarball parity, signature/cosign
   verification, real `latest-linux.json`, and package integration proof.
6. **Chat/provider PR:** model catalog, model picker, route health, attachments,
   citations, and approval plumbing where backend contracts exist.
7. **Computer Use PR:** Linux browser CU route/settings/approval/audit/panic
   parity with system-control limitations explicit.
8. **Mercury/media PR:** daemon media RPCs plus Linux call/mirror/file controls.
9. **Workflow parity PRs:** account/cloud, activity/session transcripts,
   insights, projects, provider detail, memory review, text expansion, and pet
   companion.

## Stale Or Misleading Artifacts To Fix

- `docs/LINUX_PORT_MASTER_PLAN.md`: reads as current but says no Linux shell,
  packaging metadata, updater, or release workflow exists.
- `docs/linux-port/README.md`: still frames Linux as non-public/blocked in places,
  despite a public prerelease.
- `docs/linux-port/release-runbook.md` and
  `docs/linux-port/factory-pr-handoff.md`: need prerelease vs full parity
  rewording.
- `docs/linux-port/parity-ledger.json`: all 64 rows are `ready`, but it should
  not be used as full product parity truth.
- `CHANGELOG.md`: under-reports the public Linux prerelease and its limitations.
- `docs/security/SUPPLY_CHAIN_PROVENANCE.md`, `docs/RELEASE_ROLLBACK.md`, and
  `docs/RUNBOOK.md`: macOS-centric, missing Linux asset/feed/rollback details.
- `packaging/linux/aur/PKGBUILD`: placeholder hashes and tag/asset mismatch with
  `linux-v0.1.0`.
- `packaging/linux/flatpak/dev.openburnbar.OpenBurnBar.yml`: correctly says
  tail metadata only, but user docs do not surface that limitation clearly.
