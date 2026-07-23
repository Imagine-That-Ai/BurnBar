# OpenBurnBar Linux → macOS Full Parity Plan

Generated from a 6-subagent parallel reconnaissance of `AgentLens/`, `apps/linux-desktop/`, `OpenBurnBarCore/`, `OpenBurnBarDaemon/`, design tokens, packaging, and release infrastructure.

**Live status correction (2026-07-20):** the active implementation branch is
`fc0af729e1`, with 91 frontend test files / 877 passing tests, 129/129 host
Tauri Rust tests, and 130/130 media-enabled Rust tests on Ubuntu ARM64. The
current `fc0af729e1` source was synced, built, and installed in the unlocked
Ubuntu GNOME/X11 UTM guest; the non-certifying staged-daemon receipt is
`evidence/parity-audit-2026-07-10/linux-arm64-current-fc0af729e1-ui-staged-daemon-2026-07-20.json`.
The shell matches the source head, while the daemon/CLI remain staged payloads
and the unsigned manifest therefore does not promote an exact-head product row.
The strict certification score remains 0/40 product rows and 0/7 environment
receipts because unsigned local packaging, production configuration,
cross-device flows, and the broader compositor/keyring/macOS differential
matrix are still open. Do not convert the certification score into a source
completion percentage.

**Implementation checkpoint (2026-07-22):** the public Linux download trust
gate is now implemented in
`scripts/ci/verify-public-linux-download-trust.sh`, covered by its contract
test, and wired through `.github/workflows/public-linux-download-trust.yml`.
It parses the exported website `SITE` object, verifies the public AppImage/deb/
rpm and detached Ed25519 signatures, and validates the signed update feed and
version binding. The live GitHub artifact/signature probe passed; the branded
feed was not reachable, so public promotion remains blocked. This closes the
release-gate implementation item, not the signed-candidate certification row.

**Implementation checkpoint (2026-07-22, Reduce Transparency):** the Linux
shell now follows the live `(prefers-reduced-transparency: reduce)` desktop
preference through `apps/linux-desktop/src/a11y.ts`. The shared CSS disables
backdrop filters and maps Liquid Glass surfaces to opaque skin-aware tokens,
including lazy-loaded routes and onboarding; modern and legacy WebKitGTK
listener cleanup is covered by focused tests. The user-controlled
`-1` frostier to `+1` clearer transparency range is persisted by the General
settings slider and maps to bounded skin-aware token presets. Installed
compositor/WebKit receipts are still required.

**Implementation checkpoint (2026-07-22, Linux observability):** the Tauri
shell now initializes Sentry through
`apps/linux-desktop/src-tauri/src/observability.rs`. DSNs are parsed before SDK
initialization, missing or malformed values stay non-fatal outside strict
observability mode, and the held client guard is managed by Tauri for orderly
shutdown draining. Default PII is disabled and the event/breadcrumb scrubber
removes identity and user-content fields. Focused Rust tests cover valid and
invalid DSNs plus event and breadcrumb scrubbing. Production DSN configuration
and live event receipts remain external release evidence.

---

## 1. Current state snapshot

| Area | macOS source | Linux state | Verdict |
|------|--------------|-------------|---------|
| Core / daemon | `OpenBurnBarDaemon/`, `OpenBurnBarCore/` | All RPC handlers implemented; POSIX HTTP gateway, inotify, Secret Service/KWallet, Avahi discovery, Linux security all in place. | Strong |
| UI shell | `AgentLens/Views/`, `AgentLens/Theme/` | `apps/linux-desktop/` has W6 foundation + P01-P15 route surfaces. | Route parity exists, but macOS visual/interaction layer is missing. |
| Design system | `AgentLens/Theme/DesignSystem.swift`, `LiquidGlass.swift`, `KernelBackdropView.swift` | Tokens + 2 skins + 32 kernels + CSS glass exist; user-controlled transparency presets and the OS Reduce Transparency fallback are implemented. | Missing `sidebarThemeGlass`, Pro theme, wallpaper, live wallpaper panels, pet renderer, swarm customization. |
| Desktop integration | `AppDelegate+StatusItem.swift`, `SwarmWallpaperRuntime.swift`, `Hotkey.swift` | Tauri tray exists. | Missing menu-bar popover, global hotkeys, desktop wallpaper, live wallpaper panels. |
| Release / CI | `scripts/build-macos-website-release.sh`, `scripts/upload-macos-downloads-r2.sh`, `scripts/ops/rollback-macos-appcast.sh` | Signed x86_64/aarch64 DEB/RPM/Arch candidate, daemon/desktop sessions, aggregate attestation, and exact-head Nightly matrix are green. | Public feed/promotion, compatible previous-package lifecycle proof, production trust callables, and full environment receipts remain open. |

The canonical `docs/linux-port/parity-ledger.json` contains 40 product rows, and
`product-parity-requirements.json` defines the seven required environment rows;
all remain intentionally `blocked` until signed current-HEAD receipts exist.
`productParityClaim` is false; source implementation progress is not a
certification score. `docs/linux-port/ui-parity/README.md` P01-P15 and the
shared daemon foundations are substantially implemented, while the remaining
work is the macOS-level **surface depth**, **installed runtime evidence**,
**visual/system integration**, and **release/promotion** layer.

### Historical continuation checkpoint — 2026-07-17 (superseded by the exact-head verification below)

The code checkpoint used by the latest verification is
`3a9010e229ccad6263b45de622aa97f4e706b6f5`, with executable Linux behavior suites,
desktop-shell hardening, and the real
P-39 parser differential producer (`dd7c588db`, focused suite **45/45**) and
provider-catalog enforcement in first-run onboarding (`29fa77791`). Candidate run
`29546157464` passed both release architectures and the installed P-40 proof at
its then-current head, but the branch has advanced and needs a fresh exact-head
candidate. Nightly run `29546158468` passed the matched workload, Wayland portal,
Arch/wlroots, and Fedora/KDE jobs; Ubuntu GNOME/X11 shell smoke failed after its
Linux Swift suites passed (**325/325**). Hidden nightly evidence was previously
lost and is now retained by the workflow; the shell runner emits a structured
failure manifest before the job is rerun. Run `29587742846` then confirmed the
X11 failure was inside
`ComputerUseServiceRunBindingTests/testExpiredSessionReleasesRunBindingBeforeRestart`,
before shell smoke, and that no Swift artifact survived because the container
did not have a host evidence mount. Commit `09e6050d9` mounts the host evidence
directory into both PR and nightly Swift containers, routes results to
`/evidence/linux-swift-tests`, and regression-tests the workflow wiring. Fresh
nightly run `29607854309` is the first exact-head validation of that correction.

Since that correction, `6ef6794ea` serialized Computer Use expiry teardown so
run-binding replacement cannot race coordinator cleanup. The Linux Swift graph
now executes real analytics, Computer Use, and remote-engine targets (**9
suites / 92 minimum tests**) through `9db5cca26`, `d846c95d0`, `7349007e2`,
`4925d258d`, `9cee2687a`, and `33e3bb59b`; `9d8b0895e`, `7f2a4cdd4`, and
`c7bbd4ed6` add deep-link normalization, fail-closed text-expansion state, and
typed SmartHub process/payload boundaries; `832a9b0d2` removes Linux XCTest
actor isolation that crashed test discovery. The P-07
computer-use validator and mutation suite landed in `bf30c881a` and is required
by the PR gate (`5e6241275`). These changes improve source confidence only; the
ledger remains 0/40 and 0/7 until installed, current-head receipts exist.
The first exact-head release attempt then found a Linux-only type-inference
failure in the new teardown task; `a10733cdd` adds the explicit optional task
type and a replacement candidate is required.

The latest continuation also adds Arch/pacman update-channel handling and
fail-closed notification payload/route validation (`85b167205`, `a852af8c5`).
These source and focused-test improvements do not promote any ledger row.

Exact-head Release run `29646670068` completed successfully at source
`70ab4eb0b9e66394d709dac246296a3b050e8a3f`; x86_64 job `88086012965`,
aarch64 job `88086012972`, and aggregate job `88089349146` passed package
construction, ownership/install/uninstall, daemon/desktop/tray, route/
accessibility sessions, final verification, and signed closure. Evidence
artifact `8430648757` has zip digest
`sha256:30d67cc9ff465206bdc0a38dad1f0aa910b3a4c7f2205ef811175b37976da13b`.
Update/rollback/data-preservation remains blocked because no compatible prior
same-architecture package was supplied.
Exact-head Nightly run `29646670763` completed successfully at the same head.
The macOS/Linux matched soak and runnable Ubuntu GNOME/X11 passed; GNOME
Wayland portal, Arch/wlroots, and Fedora/KDE remained explicit blocked rows.
X11 ran all nine Swift suites (**414/414**), shell,
AT-SPI/Orca/keyboard/200%-zoom, onboarding, text-expansion, matched workload,
and route performance; `route.navigation` p95 was `95.6 ms` versus the
`120 ms` budget. Root-owned transcript normalization emitted warnings but kept
the raw evidence and exited `linux-desktop-session-ok`; the previous false
shell failure is closed. The three non-X11 environments remain blocked because
hosted runners do not provide their required compositor/portal surfaces.

The physical iPad preflight passes but approval XCTest execution is blocked by
the worktree hygiene ceiling. Production callable drift remains open. The UTM
Ubuntu 24.04 ARM64 guest is now registered and reachable over SSH, but its
systemd service still launches a stale `/usr/local` daemon that exits `127`
because `libsqlcipher.so.0` is missing; the packaged `/usr/bin` binary carries
the native library. No live daemon or installed-product receipt is promoted
until the launcher state is repaired and rechecked.

The honest status is therefore **0/40 product** and **0/7 environment** certified.
Do not report an approximate maturity percentage as a completion score; the
source/test checkpoint and the certification ledger are separate measures. The
remaining order is: clear the fresh X11 route budget, produce a signed candidate
from that verified head, deploy and verify production App Check/OAuth callables,
execute approval on the physical iPad, close the remaining Linux desktop,
architecture, keyring, and portal rows, collect installed Computer Use/Mercury/
SmartHub/IME/accessibility/performance/update receipts, then promote all 40
requirement rows.

### Current source follow-up — 2026-07-18 (`63f23dcfb1`)

The release/nightly receipts above are intentionally retained for their
original source head and are not promoted to this newer source. The current
branch adds three bounded safeguards: compatible-baseline discovery
(`b6d662d503`, `63f23dcfb1`), declared/detected environment identity binding
(`84a34432ed`), and an opt-in scratch-only iPad SPM cache prune
(`dbdfb5b8f1`). The live resolver rejects historical `0.1.0` because its
two-architecture/provenance and daemon-launcher requirements are incomplete.
Focused contracts pass, but a fresh signed Release/Nightly run is still
required before promotion.

---

## 2. Full parity gap inventory

### Tier 1 — Release & distribution (public availability blocked)

1. **AppImage / RPM / deb artifact closure** from a clean release commit.
2. **Detached Ed25519 package signatures** and **Sigstore/cosign provenance bundles**.
3. **Update / rollback feed** with a first-release seed artifact.
4. **R2 upload script** for Linux artifacts (`scripts/upload-linux-downloads-r2.sh`).
5. **Public download trust verification** CI script (`scripts/ci/verify-public-linux-download-trust.sh` equivalent).
6. **`website/public/downloads/latest-linux.json`** promotion, gated by `verify-linux-release.mjs`.
7. **Sentry integration** for the Tauri shell and Linux daemon. The Tauri shell
   bootstrap is now source-complete; production DSN/event receipts remain open.
8. **Nightly matrix evidence** for Ubuntu GNOME/Wayland, Fedora KDE, Arch/wlroots.
9. **Makefile `release-linux` target** for parity with macOS `release-mas` / `release-website`.

### Tier 2 — Design system & visual parity

10. **Dashboard layout system** (`atelier`, `aurora`, `nebula`, `constellation`, `cockpit`, `classic`) with persistence and a layout switcher.
11. **Complete:** user-controlled Liquid Glass transparency preference (`-1` frostier → `+1` clearer) plus OS Reduce Transparency opaque fallback.
12. **Theme glass palette** per layout.
13. **Glass card / Glass button** primitives with the Reduce Transparency opaque path implemented; installed preference receipts remain.
14. **Pro theme** obsidian foil palette for membership.
15. **Desktop wallpaper runtime** with 11 backgrounds, provider glyph selection, speed, click-to-cycle, sparkles, constellation mode.
16. **Swarm customization** (provider glyph selection, brand-shape exclusion, sparkles, constellation mode).
17. **Kernel-forward layouts** (full-bleed kernel backdrop for atelier/constellation).
18. **Pet companion renderer** (GLB/Three.js runtime, behavior graph, tier matrix, chat bubble, hover toolbar, global summon hotkey).
19. **Provider color themes** (30+ provider color schemes, model color hashing).

### Tier 3 — Core UI surface depth

20. **Menu bar popover** with sections: `insights`, `summary`, `providers`, `mercury`, `chat`, `quickSwitch`.
21. **Session logs / pane workspace** (indexed conversation browsing, detail pane, cloud consent).
22. **Provider deep-dive** and **model deep-dive** surfaces.
23. **Quota cockpit / subscription** (subscription constellations, quota reset atlas, pacing UI).
24. **Computer Use approval flow** (approval sheet, scope rules, audit chain, Agent Watch).
25. **Elder Wand / fusion router UI** (provider fusion, model fusion, gateway configurator).
26. **Chat advanced features** (attachments, retrieval, memory extraction, text-expansion drafts, backend routing, thinking disclosure, tool cards).
27. **Mission console** (flight-ops lane, dedicated window, controller workbench).
28. **Onboarding** (provider scan, system permissions, chat engine, tour).

### Tier 4 — Daemon / core Linux gaps

29. **Pensieve knowledge watcher** (currently stubbed; replace with inotify implementation).
30. **Switcher shell / CLI shim installer** (currently unavailable on Linux).
31. **Privileged input / HID bridge** (entire subsystem excluded on Linux).
32. **Remote access agent** (entire subsystem excluded).
33. **Code signature verification** for peer auth (currently excluded on Linux).
34. **IPv6 loopback** in the HTTP gateway (currently IPv4 only).
35. **Remaining compatibility test sources** retain `LinuxEmptyTests.swift`
    only for Apple/off-Linux fallbacks and targets intentionally excluded from
    the Linux graph. Linux Computer Use and remote-engine targets now execute
    behavior suites, alongside the existing Core, media, analytics, security,
    and daemon suites.

### Tier 5 — macOS-only accepted divergences

- App Store / StoreKit / notarization / XPC / `Network.framework` / `FSEvents` / `CGEvent` system-wide text expansion / Apple-specific entitlements. These are explicitly macOS-only; the Linux equivalents (Stripe, POSIX sockets, inotify, Secret Service, systemd credentials) are already in place.

---

## 3. Phased implementation plan

### Phase 1 — Foundation & release unblockers (6 parallel lanes)

| Lane | Scope | Files owned | Verification |
|------|-------|-------------|--------------|
| R1 | Release scripts: `upload-linux-downloads-r2.sh`, update/rollback feed, `verify-public-linux-download-trust.sh`. | `scripts/linux-port/`, `scripts/ci/`, `Makefile` | `verify-linux-release.mjs --allow-blocked` passes; scripts run green. |
| R2 | Sentry + observability: add `sentry-rust` to Tauri and daemon, configure DSN. | `apps/linux-desktop/src-tauri/`, `OpenBurnBarDaemon/` | Tauri bootstrap and focused Rust privacy tests pass; production DSN/event receipt remains external. |
| R3 | Nightly matrix: fix Wayland/Fedora/Arch runners, add `xdg-desktop-portal` consent test. | `.github/workflows/linux-nightly.yml` | Nightly matrix produces artifacts. |
| R4 | **Complete:** `fb20c38dc2` packaged route-body skeleton/idle hydration plus the root-owned transcript normalization fix were validated on Ubuntu GNOME/X11; eager fixture/browser behavior remains intact. | `apps/linux-desktop/src/surfaces/SurfaceRouter.tsx`, `SurfaceRouter.test.tsx`, `system/system.css`, `scripts/linux-port/run-shell-desktop-session.mjs`, `scripts/linux-port/accessibility-harness-contract.test.mjs`, `.github/workflows/linux-nightly.yml` | Nightly `29646670763`: route p95 `95.6 ms` <= `120 ms`, shell smoke success, route shell accessible during hydration, raw Docker-owned transcripts retained as evidence. |
| D1 | Pensieve watcher: replace stub with inotify. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/PensieveKnowledgeWatcherLinux.swift` | `OpenBurnBarDaemonLinuxGatewayTests` pass. |
| D2 | Switcher shell: implement `BurnBarCLIShellExecutor` and `ShimInstaller` for Linux. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/OpenBurnBarSwitcherShellLinux.swift` | CLI tests pass. |
| D3 | Test backfill: replace Linux compile-only paths with deterministic behavior suites; retain placeholders only as platform fallbacks. | `OpenBurnBarCore/Tests/*/Linux*BehaviorTests.swift`, `OpenBurnBarCore/Package.swift`, `scripts/linux-port/linux-swift-test-manifest.json` | Linux manifest declares 9 suites / 92 minimum tests; each selected target executes non-tautological tests and `swift test` passes on the release runner. |

### Phase 2 — Design system foundation

- Implement `DashboardLayout` enum and persistence, `LayoutSwitcher` UI, and 6 layout skeletons.
- Add `GlassCard` / `GlassButton` / `ThemeGlassPalette` / `ProTheme`.
- Add `sidebarThemeGlass` to complete the remaining per-layout Liquid Glass palette surface; the transparency slider and OS Reduce Transparency fallback are implemented.
- Implement kernel-forward layout support in `KernelBackdrop`.
- Verification: visual proof book, `npm test`, `npm run build`, `prefers-reduced-motion` test.

### Phase 3 — Desktop integration & visual features

- Desktop wallpaper runtime with background selection, provider glyph selection, speed, sparkles, click-to-cycle, constellation mode.
- Swarm customization settings.
- Pet companion renderer (GLB/Three.js or `@openburnbar/gl-engine` reuse), behavior graph, tier matrix, global hotkey, drag-and-drop.
- Provider color themes and model color hashing.
- Verification: packaged smoke captures screenshots, AT-SPI snapshots, perf budgets.

### Phase 4 — Core UI surface depth

- Menu bar popover with tray sections.
- Session logs / pane workspace.
- Provider and model deep-dive surfaces.
- Computer Use approval surface and Elder Wand / fusion UI.
- Mission console and advanced onboarding.
- Verification: surface tests pass, `npm run build`, `tsc --noEmit`.

### Phase 5 — Final validation & ledger

- Update `docs/linux-port/parity-ledger.json` with new Tier A/B/C rows for the W5 visual, desktop, and release features.
- Run `validate-parity-ledger.mjs`, `verify-linux-release.mjs`, `run-shell-smoke.mjs`.
- Update `docs/linux-port/ui-parity/README.md` and P15 proof book.
- Produce `latest-linux.json` only after strict verification exits 0.

---

## 4. Cross-cutting rules for parallel execution

1. **Shared file seams** (append-only): `SurfaceRouter.tsx`, `tauriBridge.ts`, `src-tauri/src/lib.rs`, `daemonFixture.ts`, `styles/app.css`.
2. **Nav geometry frozen** — `scripts/linux-port/linux-desktop-session.sh` clicks fixed coordinates; never alter nav padding/order without updating P15.
3. **RPC contract** — use exact `BurnBarRPCMethod` strings from `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPC*.swift`.
4. **Evidence contracts pinned** — repeated `app.start`, post-paint `route.navigation`, repeated `ipc.health.roundtrip`, repeated `tray.click.open`, production-linked matched workload IDs, a11y landmarks, and `localStorage` keys must not be renamed without updating their fail-closed validators.
5. **Design tokens only** — no hex literals in surfaces; provider accents live in `src/providerGlyphs.ts`.
6. **Reduced motion absolute** — all animation must be suppressible via `body.reduced-motion` or `prefers-reduced-motion`.

---

## 5. Risks & accepted divergences

- **macOS-only platform APIs** (StoreKit, FSEvents, Network.framework, HID, XPC) will not be ported; Linux equivalents are the target.
- **Parallel UI work** has high conflict risk; lanes must own distinct files and integrate through `App.tsx` / `SurfaceRouter.tsx` / `tauriBridge.ts` via a single integration owner.
- **Release credentials** (Ed25519 key, OIDC, AUR/Flathub credentials) are external blockers; release scripts can be written and verified structurally, but artifact signing/publishing requires operator secrets.
- **Nightly matrix** may require self-hosted runners or nested compositor VMs; the plan starts by fixing the `ubuntu-gnome-x11` path and documents the Wayland/Fedora/Arch blockers.

---

## 6. Next action

Approve this plan and Phase 1 will launch with the same 6-subagent pattern used for reconnaissance. The first integration checkpoint will be a clean `make release-linux` dry-run, `node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked`, and `npm test`/`npm run build` in `apps/linux-desktop`.
