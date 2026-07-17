# OpenBurnBar Linux → macOS Full Parity Plan

Generated from a 6-subagent parallel reconnaissance of `AgentLens/`, `apps/linux-desktop/`, `OpenBurnBarCore/`, `OpenBurnBarDaemon/`, design tokens, packaging, and release infrastructure.

---

## 1. Current state snapshot

| Area | macOS source | Linux state | Verdict |
|------|--------------|-------------|---------|
| Core / daemon | `OpenBurnBarDaemon/`, `OpenBurnBarCore/` | All RPC handlers implemented; POSIX HTTP gateway, inotify, Secret Service/KWallet, Avahi discovery, Linux security all in place. | Strong |
| UI shell | `AgentLens/Views/`, `AgentLens/Theme/` | `apps/linux-desktop/` has W6 foundation + P01-P15 route surfaces. | Route parity exists, but macOS visual/interaction layer is missing. |
| Design system | `AgentLens/Theme/DesignSystem.swift`, `LiquidGlass.swift`, `KernelBackdropView.swift` | Tokens + 2 skins + 32 kernels + CSS glass exist. | Missing dashboard layouts, Liquid Glass transparency, Pro theme, wallpaper, pet renderer, swarm customization. |
| Desktop integration | `AppDelegate+StatusItem.swift`, `SwarmWallpaperRuntime.swift`, `Hotkey.swift` | Tauri tray exists. | Missing menu-bar popover, global hotkeys, desktop wallpaper, live wallpaper panels. |
| Release / CI | `scripts/build-macos-website-release.sh`, `scripts/upload-macos-downloads-r2.sh`, `scripts/ops/rollback-macos-appcast.sh` | Toolchain, workflows, Tauri build, release manifest, scripts exist. | Missing AppImage/RPM closure, update feed, R2 upload, public trust verification, Sentry, nightly matrix evidence. |

The canonical `docs/linux-port/parity-ledger.json` contains 40 product rows, and
`product-parity-requirements.json` defines the seven required environment rows;
all remain intentionally `blocked` until signed current-HEAD receipts exist.
`productParityClaim` is false; source implementation progress is not a
certification score. `docs/linux-port/ui-parity/README.md` P01-P15 and the
shared daemon foundations are substantially implemented, while the remaining
work is the macOS-level **surface depth**, **installed runtime evidence**,
**visual/system integration**, and **release/promotion** layer.

### Current continuation checkpoint — 2026-07-17

The integration branch is at `33e3bb59b` with two recent source slices plus
nightly evidence hardening: the real
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
`4925d258d`, `9cee2687a`, and `33e3bb59b`. The P-07
computer-use validator and mutation suite landed in `bf30c881a` and is required
by the PR gate (`5e6241275`). These changes improve source confidence only; the
ledger remains 0/40 and 0/7 until installed, current-head receipts exist.
The first exact-head release attempt then found a Linux-only type-inference
failure in the new teardown task; `a10733cdd` adds the explicit optional task
type and a replacement candidate is required.

The honest status is therefore **0/40 product** and **0/7 environment** certified.
A non-certifying engineering maturity estimate is approximately **68%**. The
remaining order is: recover the X11 failure evidence and rerun nightly, produce a
fresh exact-head signed candidate, deploy and verify production App Check/OAuth
callables, execute approval on the physical iPad, close the six Linux desktop
matrix rows, collect installed Computer Use/Mercury/SmartHub/IME/keyring/
accessibility/performance/update receipts, then promote all 40 requirement rows.

---

## 2. Full parity gap inventory

### Tier 1 — Release & distribution (public availability blocked)

1. **AppImage / RPM / deb artifact closure** from a clean release commit.
2. **Detached Ed25519 package signatures** and **Sigstore/cosign provenance bundles**.
3. **Update / rollback feed** with a first-release seed artifact.
4. **R2 upload script** for Linux artifacts (`scripts/upload-linux-downloads-r2.sh`).
5. **Public download trust verification** CI script (`scripts/ci/verify-public-linux-download-trust.sh` equivalent).
6. **`website/public/downloads/latest-linux.json`** promotion, gated by `verify-linux-release.mjs`.
7. **Sentry integration** for the Tauri shell and Linux daemon.
8. **Nightly matrix evidence** for Ubuntu GNOME/Wayland, Fedora KDE, Arch/wlroots.
9. **Makefile `release-linux` target** for parity with macOS `release-mas` / `release-website`.

### Tier 2 — Design system & visual parity

10. **Dashboard layout system** (`atelier`, `aurora`, `nebula`, `constellation`, `cockpit`, `classic`) with persistence and a layout switcher.
11. **Liquid Glass transparency preference** (`-1` frostier → `+1` clearer).
12. **Theme glass palette** per layout.
13. **Glass card / Glass button** primitives with Reduce Transparency opaque path.
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
| R2 | Sentry + observability: add `sentry-rust` to Tauri and daemon, configure DSN. | `apps/linux-desktop/src-tauri/Cargo.toml`, `OpenBurnBarDaemon/` | Build passes; errors captured in dev. |
| R3 | Nightly matrix: fix Wayland/Fedora/Arch runners, add `xdg-desktop-portal` consent test. | `.github/workflows/linux-nightly.yml` | Nightly matrix produces artifacts. |
| D1 | Pensieve watcher: replace stub with inotify. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/PensieveKnowledgeWatcherLinux.swift` | `OpenBurnBarDaemonLinuxGatewayTests` pass. |
| D2 | Switcher shell: implement `BurnBarCLIShellExecutor` and `ShimInstaller` for Linux. | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/OpenBurnBarSwitcherShellLinux.swift` | CLI tests pass. |
| D3 | Test backfill: replace Linux compile-only paths with deterministic behavior suites; retain placeholders only as platform fallbacks. | `OpenBurnBarCore/Tests/*/Linux*BehaviorTests.swift`, `OpenBurnBarCore/Package.swift`, `scripts/linux-port/linux-swift-test-manifest.json` | Linux manifest declares 9 suites / 92 minimum tests; each selected target executes non-tautological tests and `swift test` passes on the release runner. |

### Phase 2 — Design system foundation

- Implement `DashboardLayout` enum and persistence, `LayoutSwitcher` UI, and 6 layout skeletons.
- Add `GlassCard` / `GlassButton` / `ThemeGlassPalette` / `ProTheme`.
- Add Liquid Glass transparency preference slider and `sidebarThemeGlass`.
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
