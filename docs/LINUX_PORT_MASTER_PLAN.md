# OpenBurnBar — Linux Port Master Plan

**Status:** DRAFT v1.0 (shared desktop foundation + Linux delta plan) · **Author:** Codex synthesis from the accepted Linux-port plan, repo evidence, and sibling Windows plan · **Date:** 2026-07-03  
**Target:** full **peer** parity of the macOS app (`AgentLens/`) on Linux desktop: x86_64 first, aarch64 supported by CI as hardware runners mature.  
**Foundation:** [`DESKTOP_FOUNDATION.md`](DESKTOP_FOUNDATION.md) owns shared engine, IPC, schema, design, release, and validation contracts.  
**Sibling plan:** [`WINDOWS_PORT_MASTER_PLAN.md`](WINDOWS_PORT_MASTER_PLAN.md) remains the Windows delta; Linux reuses the workstream/gate cadence but does not inherit Windows-only choices.

> Linux is not a cloud-only companion. It is a local log-reading peer like macOS: tray, popover, workspaces, local engine, local encrypted database, parser engine, chat, mission control, Computer Use, Mercury media, PetCompanion, membership, release/update, and parity certification.

> The completion bar is the same as the rest of BurnBar: no hidden drops, no “Linux-ish” dashboard, no silent weaker security posture, no UI that looks like a sample app. Where a macOS behavior has no Linux analog, this plan names the equivalent, the evidence, and the declared substitution.

---

## 0. How to read this document

- **§1** summarizes the Linux product shape and the deltas from Windows/macOS.
- **§2** defines complete parity and Linux-native equivalent tiers.
- **§3** records current repo facts and Linux-specific blockers.
- **§4** binds the recommended stack, with Phase-0 abort/fallback criteria.
- **§5** lists the reuse ledger.
- **§6–§8** define workstreams, dependency graph, gates, and phase plan.
- **§9** provides workstream deep dives.
- **§10** is the full subsystem inventory.
- **§11–§13** cover verification, CI/release/distribution, and security.
- **§14–§16** list risks, explicit v1.1 non-goals, and decisions resolved by evidence.

This plan is executable only with [`DESKTOP_FOUNDATION.md`](DESKTOP_FOUNDATION.md). If the two conflict, fix the shared foundation first or record an explicit Linux divergence here.

---

## 1. Executive summary

OpenBurnBar's Linux port is the second non-Apple desktop peer and the first platform where **Wayland, portals, distro fragmentation, and lower-trust cloud identity** are first-order product constraints.

The recommended shape:

- **Engine:** shared Swift headless core running as `openburnbar-engined`, behind generated TypeSpec IPC. The engine owns durable local state on Linux.
- **Shell:** Tauri 2 + React/TypeScript candidate shell using WebKitGTK 4.1, bound by G0 evidence. It wins only if tray, popover, transparent pet, perf, a11y, and packaging gates pass. GTK/libadwaita and Qt/Kirigami remain named fallback candidates.
- **Display/input:** Wayland-first using xdg-desktop-portal, PipeWire, libei where available, AT-SPI2 for accessibility, and explicit X11 fallback using XTEST/XShm. No evdev keylogger shortcut.
- **Data:** local SQLCipher-backed SQLite with byte-compatible schema, FTS5, WAL, and cross-open vectors against macOS.
- **Cloud:** Linux is a lower-trust principal by default. Low-risk sync may use a Linux-specific custom/debug provider; high-risk hosted actions require appId allow-list + hardware/WebAuthn step-up. Local Computer Use remains local.
- **Release:** AppImage + signed update feed primary; deb/rpm and AUR from the same artifact closure; Flatpak is a documented tail because sandbox holes conflict with local log ingestion unless the user grants broad filesystem access.
- **Validation:** parity matrix + evidence ledger. No row is green without a concrete artifact: fixture diff, KAT, UI script, screenshot book, benchmark log, package smoke, or red-team result.

The decisive Linux-specific truth: **the repo has no Linux desktop shell, package metadata, systemd/polkit integration, Linux updater, or Linux App Check posture today.** Those are first-class workstreams, not assumptions.

---

## 2. Complete parity contract

### 2.1 Tiers

| Tier | Meaning | Linux examples | Evidence |
|---|---|---|---|
| **Tier A — exact parity** | Byte/behavior-identical. | SQLite schema/migrations, SQLCipher cross-open, parser token/cost/model output, TypeSpec IPC transcripts, CloudVault/HermesRelay/Signal KATs, prompt-injection wrapping, entitlement math. | Golden fixture diff, KAT logs, schema hash, transcript replay. |
| **Tier B — functional parity via native equivalent** | Same user outcome through Linux-native system APIs. | NSStatusItem → KSNI/AppIndicator/portal tray; Keychain → libsecret/KWallet/Secret Service + trust metadata; ScreenCaptureKit → PipeWire portal; CGEvent/AX → libei/uinput/XTEST + AT-SPI2; LaunchAgent → systemd user service/XDG autostart. | Real DE matrix tests and security/a11y evidence. |
| **Tier C — explicit substitution** | Mac behavior has no safe Linux analog; Linux ships a named substitute or an explicit v1.1 non-goal. | iCloud mirror → Firestore/sealed archive only; StoreKit purchase UI → Stripe web checkout; system-wide text expansion on Wayland → in-app expansion v1, IME-based v1.1; GNOME Wayland pet free-placement → degraded draggable tier. | Signed-off row with substitute criterion; not a blank dash. |

### 2.2 Non-negotiable parity invariants

- Local SQLite + daemon-owned state remain canonical.
- Every provider parser, quota path, session-log view, and cost ticker has a Linux evidence path.
- Aurora/Editorial visual identity travels through tokens and proof books, not taste-matching.
- Computer Use must be safer than “input injection works”: approval, audit, deny-region, replay, and panic-halt semantics are the product.
- Cloud lower-trust posture is explicit; no generic server-minted Linux token may unlock Apple-equivalent high-risk callables.
- Release artifacts are not user-facing until signing, checksums, SBOM, provenance, source-offer, install smoke, and update-feed verification pass.

---

## 3. Current-state architecture snapshot

### 3.1 Verified current facts

| Fact | Evidence / implication |
|---|---|
| Product stance is local-first and daemon-first. | `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md` and `docs/DIRECTION.md` make local SQLite and daemon-owned state canonical. |
| Current daemon has a local Unix-socket JSON-envelope RPC control plane. | `OpenBurnBarDaemon` socket server uses `AF_UNIX`, `0600`, bearer token, peer checks, method capability mapping, and JSON-RPC-compatible errors. |
| `OpenBurnBarCore` is shared but not Linux-clean. | 110 unguarded `import SwiftUI` files under `OpenBurnBarCore/Sources/OpenBurnBarCore`; Core split is a prerequisite. |
| DataStore is macOS-app-owned today. | `DataStoreCoordinator`/`DataStoreActor`/`OpenBurnBarDatabase` own GRDB migrations, WAL, SQLCipher config, and focused stores. |
| Daemon may directly attach to SQLite. | Current daemon initializes raw-SQLite indexed search/resume/project-memory stores when configured; stale docs saying otherwise must not guide the port. |
| TypeSpec schema-sync is real and CI-wired. | `tools/schema-sync/check-drift.sh` compiles TypeSpec, emits TS/Swift/Kotlin, checks generated drift and hand mirrors. |
| No Linux desktop product surface exists. | No committed `apps/desktop`, Tauri/GTK/Qt shell, AppImage/deb/rpm/Flatpak metadata, systemd/polkit files, Linux updater, or Linux release workflow. |
| Linux-ish parser hints are incidental. | Some provider paths reference `XDG_DATA_HOME` / `~/.local/share`, but that is not Linux app support. |
| Current release architecture is macOS-only. | DMG/ZIP, Sparkle/appcast, `latest-macos.json`, notarization/stapling, macOS download trust workflow. Linux release must be new. |

### 3.2 Linux-specific blockers

1. **Core split:** engine cannot compile on Linux while SwiftUI/AppKit/Security/WebKit types sit in shared targets.
2. **Data ownership:** Linux needs engine-owned durable local state; current DataStore is app-side and Apple-keychain-bound.
3. **SQLCipher/GRDB:** Linux must build/link SQLCipher 4.16.0+FTS5 and prove GRDB or approved adapter parity.
4. **Cloud trust:** Apple App Check does not port. Linux needs lower-trust custom-provider rules and high-risk step-up design.
5. **Wayland permissions:** capture/input require portal-mediated user consent and compositor support; behavior varies across GNOME, KDE, wlroots/Hyprland, and X11.
6. **Global text expansion:** safe system-wide capture is not a Wayland v1 feature; IME/fcitx/IBus route is a separate product surface.
7. **Tray/popover reality:** KSNI/AppIndicator support is inconsistent; GNOME may need extension/portal fallback messaging.
8. **Visual rendering:** WebKitGTK/Tauri must prove swarm/glass/backdrop perf and a11y; otherwise fall back to GTK/libadwaita or Qt/Kirigami.
9. **Release/update:** Linux packages and update feeds must join release preflight, AGPL/source-offer, SBOM, provenance, and public trust gates.

---

## 4. Stack decision

### 4.1 Options

| Option | Shell | Engine | Reuse | Risk |
|---|---|---|---|---|
| **A. Tauri 2 + React/TS** | WebKitGTK 4.1 shell, Rust command bridge, system tray plugin, CSS tokens | shared Swift `openburnbar-engined` | Highest UI sharing with web/possible Windows Tauri path; strong packaging story; small binary vs Electron | WebKitGTK perf variance, tray/pet window edge cases, a11y depth, transparent click-through, GNOME Wayland behavior |
| **B. GTK4/libadwaita native** | GTK/libadwaita Rust/Swift bridge | shared Swift engine | Best Linux-native integration and a11y | More UI rewrite, less shared shell code, glass/swarm harder |
| **C. Qt/QML/Kirigami** | Qt shell | shared Swift engine | Strong cross-DE behavior, good tray/window control | Larger runtime, licensing/package complexity, visual mismatch risk |
| **D. Electron** | Chromium shell | shared Swift engine | Best web API parity | Heavy idle cost, weaker craft/perf posture, package bloat |
| **E. Avalonia** | .NET cross-platform shell | shared or .NET bridge | Possible Windows/Linux shell convergence | Weaker Linux-native polish, separate .NET runtime, design-system gap |

**Recommendation:** Option A starts Phase 0 because Tauri 2 gives the best shot at one high-craft Linux shell with reusable TS/CSS/design-token code and standard AppImage/deb/rpm/AUR paths. It is not exempt from proof. G0 kills or pivots it if perf, a11y, tray/pet, or packaging evidence fails.

### 4.2 G0 stack-binding evidence

Tauri remains selected only if all are true:

- `webkit2gtk-4.1` renders the seeded swarm + three glass panels + mesh backdrop at **≥55fps on WebKitGTK 2.46+** and **≥30fps on 2.44** on reference hardware.
- Tray click → popover open p95 <150ms on GNOME, KDE, wlroots/Hyprland where tray support exists, and X11.
- Transparent PetCompanion window passes click-through/input-passthrough tier tests or records a DE-specific degraded tier.
- Accessibility tree exposes names, roles, shortcuts, focus order, reduced-motion state, and live regions through AT-SPI2.
- AppImage/deb/rpm/AUR package smoke passes install/launch/daemon socket/update metadata checks.
- Engine IPC mock and real engine both drive the shell through generated clients.

Fallback order: GTK/libadwaita if WebKitGTK/Tauri fails on OS integration/a11y; Qt/Kirigami if GTK fails on tray/window/pet; Electron only with an explicit performance-risk acceptance.

### 4.3 External stack notes

- Tauri v2 Linux bundling supports AppImage/deb/rpm configuration and Debian packages depend on WebKitGTK 4.1 / GTK3; tray packages add AppIndicator dependency.
- Current Wayland remote desktop/control depends on xdg-desktop-portal, PipeWire, and libei/EIS support; compositor/portal backend differences are product constraints, not test flakiness.

---

## 5. Reuse ledger

### 5.1 Reuse as-is or with generated adapters

| Asset | Linux use |
|---|---|
| `tools/schema-sync/` TypeSpec canon | extend for engine IPC and generated Linux shell clients. |
| `packages/data-domains`, `packages/design-tokens`, entitlements packages | generate Linux/TS/Rust adapters; do not fork meanings. |
| `OpenBurnBarCore` wire/domain contracts after Core split | engine model layer. |
| `OpenBurnBarFirestoreModels` generated Swift | Firestore schema mirror for Swift engine. |
| Rust crates (`openburnbar-iroh`, `burnbar-remote`, `project-code-static-parser`) | add linux-gnu `.so`/static artifacts and link/load tests. |
| HermesRelay/RemoteUnlock/Signal KATs | extend to Linux⇄macOS. |
| Liquid Glass / Editorial / Swarm docs and tests | visual parity source and proof fixtures. |
| Release SBOM/provenance/source-offer controls | extend, do not replace. |

### 5.2 Requires extraction before reuse

| Asset | Extraction |
|---|---|
| DataStore / migrations / focused stores | move behind engine-owned service boundary; keep macOS green. |
| CLIBridge / parsers / provider path maps | extract parser fixture builders and Linux `ProviderLogLocation` mappings. |
| CloudSync | split SDK-specific Firestore gateway from REST/gRPC Listen gateway. |
| Prompt injection wrappers / ContextBuilder | make UI-free CoreModel invariant before chat/search fan-out. |
| Settings and account stores | separate product state from SwiftUI/AppKit views. |
| Pretext/markdown rendering | decide WebKitGTK/DOM bridge vs engine-side normalized output. |

### 5.3 New Linux work

| Work | Why new |
|---|---|
| Tauri shell / tray / popover / window manager | no Linux desktop shell exists. |
| systemd-user + XDG autostart + service repair | LaunchAgent/AppKit install logic does not port. |
| libsecret/KWallet/systemd-creds SecretStore | Keychain is Apple-only. |
| PipeWire/portal/libei/uinput/XTEST/AT-SPI2 PAL | Apple CGEvent/AX/ScreenCaptureKit do not port. |
| Linux App Check lower-trust/custom provider | Apple App Attest does not port. |
| AppImage/deb/rpm/AUR/Flatpak packaging | no metadata exists. |
| Linux update feed + public download trust workflow | macOS `latest-macos.json` and appcast are platform-specific. |
| Linux visual/a11y/perf harness | no renderer or snapshot book exists. |

### 5.4 Do not reuse as code

- SwiftUI view code in `AgentLens/` or `OpenBurnBarCore/Views`.
- AppKit window/tray/menu/popover managers.
- Keychain/Security.framework wrappers without a SecretStore seam.
- Firebase Apple SDK clients as the Linux cloud transport.
- macOS updater DMG replacement code.
- CGEvent/AX/System Events Computer Use glue.

---

## 6. Unified workstream model

Linux adopts the shared W-scheme from the accepted plan, with W0 shared foundation explicit.

| WS | Owns | Linux content | Critical path |
|---|---|---|---|
| **W0 Shared foundation** | engine daemon topology, TypeSpec IPC, Core split contract, parity harness schema | full IPC/domain freeze; mock engine; transcript replay | yes |
| **W1 PAL** | paths, SecretStore, process/PTY, transport, tray, watchers, autostart, hotkeys, notifications | XDG, libsecret/KWallet, POSIX PTY, KSNI/AppIndicator, systemd-user, inotify, Avahi, DBus | yes |
| **W2 Native core/crypto/transport** | Swift core split, Rust targets, libsignal, DB engine, crypto | `OpenBurnBarCoreModel`, SQLCipher C target, GRDB/adapter, `.so` builders, PlatformCrypto | yes |
| **W3 Data & sync** | DataStore extraction, Firestore REST+transforms+Listen, CloudVault | engine-owned DB, CloudSyncWatchGateway, lower-trust App Check redesign | partial |
| **W4 Agent engine** | CLIBridge, parsers, quotas, sessions, embeddings | Linux path maps, shell/PATH resolution, ONNX/GGUF/Rust-side local embedder behind existing seam | after W0/W2 |
| **W5 Computer Use + Mercury** | capture/input/audit/media/call path | PipeWire/portal/libei/uinput/XTEST/AT-SPI2, panic halt, VP9/AV1/Opus, Rust media budget substrate | after W0/W1 |
| **W6 UI shell + design system** | Tauri shell, tray/popover, glass, swarm, tokens | `apps/desktop`, `packages/{ui,swarm,backdrop,ipc-client}`, WebKitGTK perf/a11y | blocks W7 |
| **W7 UI surfaces** | all workspaces | dashboard/chat/insights/quota/settings/onboarding/missions/media/smarthub/membership | after W6 |
| **W8 PetCompanion** | glTF runtime and overlay | transparent click-through per DE; GNOME degraded tier documented | no |
| **W9 CI/release/distribution** | package builds, signing, update feed, ratchets | Linux PR gate, AppImage/deb/rpm/AUR/Flatpak, `latest-linux.json`, minisign, SBOM/provenance | enable early |
| **W10 Verification/parity harness** | fixtures, KATs, replay corpus, visual/perf snapshots | macOS⇄Linux fixture diff, DB cross-open, Linux DE matrix, evidence ledger | enable early |

### 6.1 Dependency graph

```text
W0 IPC/Core contract ─► W2 Core split + DB substrate ─► W3 data/sync ─┬─► W4 agent engine
                                                                      └─► W7 UI data consumers
W1 PAL ────────────────────────────────┬─► W5 Computer Use/Mercury
                                       ├─► W6 shell integration
                                       └─► W8 Pet overlay
W6 shell/design system ─────────────────► W7 all workspaces
W9 CI/release ── gates from Phase 0
W10 parity harness ── fixtures from Phase 0, certifies from Phase 1 onward
```

### 6.2 False-parallelism corrections

These serialize fan-out even with many agents:

1. `OpenBurnBarCore/Package.swift` and `OpenBurnBarCore/Sources` split.
2. `project.yml` app source/dependency changes when extracting DataStore/services.
3. DataStore public-access extraction before consumers migrate.
4. TypeSpec IPC freeze before shell/workspace teams invent clients.
5. SecretStore and SQLCipher key lifecycle before cloud/E2EE claims.
6. Visual token emitter before UI surfaces hand-author palette constants.

Everything else fans out only after those contracts exist.

---

## 7. Adversarial gates

### 7.1 Protocol

Every gate follows: builder dossier → independent critic lenses → quorum synthesis → `GO` / `FIX` / `PIVOT`.

Critic lenses:

- correctness / fixture parity;
- parity-gap / silent omission;
- false parallelism / hidden shared-file seam;
- security / trust downgrade;
- Linux idiom / compositor, distro, package, portal reality;
- performance / idle and interaction budgets;
- accessibility / keyboard, AT-SPI2, contrast, reduced motion.

### 7.2 Gate ledger

| Gate | After | Exit criteria |
|---|---|---|
| **G0** | Phase 0 | Tauri vs fallback shell bound by perf/a11y/tray/pet evidence; `OpenBurnBarCoreModel` spike compiles on Swift 6 Linux with no UI imports; SQLCipher+FTS5 cross-open spike proves feasibility; Rust `.so` artifacts load; libei/portal matrix captured; Linux App Check posture chosen; no production Core mutation beyond approved spike scaffolding. |
| **G1** | Phase 1 | W0 IPC full freeze + generated Swift/TS mock; Core split merged with macOS tests green; PAL API frozen for paths/secrets/process/socket/tray; engine opens copied mac SQLCipher DB read-write; Linux CI blocks a deliberately red PR; parser fixtures extracted. |
| **G2** | Phase 2 | Multi-provider corpus parses byte-identical to macOS golden; quota works for at least one provider per mechanism; one E2EE/cloud domain round-trips via REST/Listen strategy; membership checkout mints/restores entitlement; prompt-injection wrapper vector passes. |
| **G3** | Phase 3 | Every UI surface renders real fixture data; tray→popover and all windows pass interaction scripts; Aurora/Editorial/glass/swarm proof book green across DE matrix; keyboard-only and AT-SPI2 snapshots green; reduced-motion/transparency states verified. |
| **G4** | Phase 4 | Computer Use capture→plan→input→verify loop works with approval; four panic-halt paths stop action <100ms where OS permits; empty AT-SPI/accessibility tree fails closed; pet tier matrix certified; Mercury call/file/screen-share connects to paired device. |
| **G5** | Phase 5 | Signed AppImage installs and self-updates with minisign verification; deb/rpm/AUR/Flatpak outputs smoke-tested; full parity matrix + evidence ledger green; security red-team clean; launch-evidence bundle complete. |

`FIX` loops inside the phase. `PIVOT` escalates with evidence and a recommended route.

---

## 8. Phase plan

### Phase 0 — De-risk and bind · G0

Parallel spikes:

- **0-a CoreModel compile:** isolate UI-free engine/model subset, Swift 6 Linux compile in Docker, hard-zero UI imports.
- **0-b Shell proof:** Tauri 2/WebKitGTK tray/popover/perf/a11y/pet window prototype; fallback GTK/Qt notes if any target misses.
- **0-c Native artifacts:** build/load `openburnbar-iroh`, `burnbar-remote`, and libsignal Linux artifacts.
- **0-d SQLCipher parity:** build SQLCipher 4.16.0+FTS5, open real copied mac DB, run FTS row-set parity, write/reopen both directions.
- **0-e Linux cloud trust:** prove low-risk Linux principal + high-risk callable rejection; choose WebAuthn/hardware step-up path.
- **0-f Wayland/X11 probe:** GNOME, KDE, wlroots/Hyprland, X11: portal ScreenCast, RemoteDesktop/libei, AT-SPI2, tray, global hotkey.
- **0-g Release smoke skeleton:** AppImage/deb/rpm metadata draft, install smoke in clean Ubuntu VM/container, `latest-linux.json` schema draft.

### Phase 1 — Foundation · G1

- W0 IPC full freeze and mock engine.
- Core split and platform import ratchets.
- PAL stubs and first real adapters for paths, SecretStore, PTY/process, socket trust, tray.
- DataStore extraction begins solo; engine opens copied SQLCipher DB.
- Linux CI PR gate and parity fixture corpus land.
- Shell skeleton runs engine health + one provider tile.

### Phase 2 — Engine parity · G2

- Parsers/path maps/session ingestion.
- Quota adapters and provider accounts.
- Firestore REST unary + transforms; Listen/WS/gRPC watch gateway for latency-sensitive listeners.
- CloudVault/E2EE KATs.
- Linux membership Stripe checkout and restore.
- Local embeddings provider behind existing retrieval seam.

### Phase 3 — UI parity · G3

- Tauri shell production chrome.
- All dashboard/settings/session/chat/insights/memory/quota/missions/onboarding/workspace surfaces.
- Visual proof book and a11y passes.
- Empty/loading/error/degraded states.
- Real CLI session end-to-end: spawn→stream→DB→dashboard live cost ticker.

### Phase 4 — Advanced/high-risk · G4

- Computer Use local loop.
- Mercury media screen-share/file/call path.
- PetCompanion overlay and behavior graph.
- Text expansion v1 in-app substitution.
- PixelClock/SmartHub/Cast/Home Assistant Linux adapters.
- Security red-team hardening for input, portals, secrets, package trust.

### Phase 5 — Distribution/certification · G5

- Signed AppImage + update feed.
- deb/rpm/AUR and Flatpak tail package.
- SBOM/provenance/source-offer/legal preflight.
- Public Linux download trust workflow.
- Full parity ledger and launch evidence.

---

## 9. Workstream deep dives

### 9.1 W0 — Shared foundation

Deliverables:

- Extend existing `BurnBarRPC*` envelopes, method enum, capability registry, and newline-framed socket transcript tests; add TypeSpec or schema-sync generation only as a canon for that existing surface, not as a parallel `DaemonEnvelope` transport.
- `OpenBurnBarCoreModel` target or equivalent UI-free engine module.
- TS mock engine with deterministic fixture data.
- Swift engine transcript replay harness against `BurnBarDaemonServer` / `BurnBarCLISocketClient` framing.
- Capability map for every IPC method.
- Contract docs for subscription resume and daemon restart semantics.

Acceptance:

- `./tools/schema-sync/check-drift.sh` extended or sibling drift gate passes.
- Hard-zero UI imports in engine target.
- Every method has schema, owner, capability, subscription/error behavior, and a transcript proving the generated/typed shape matches the current `BurnBarRPC*` wire envelope.

### 9.2 W1 — Linux PAL

Adapters:

- XDG paths: config/data/cache/state/logs and provider log locations.
- SecretStore: libsecret/Secret Service primary, KWallet compatibility, systemd-creds/headless passphrase option, refused plaintext fallback.
- Process/PTTY: POSIX PTY, resize, clean terminate, process-tree cleanup, shell discovery.
- Socket trust: AF_UNIX, `SO_PEERCRED`, uid/pid/exe path, package/hash pin, `0600` socket dir, bearer token, capability map.
- Tray: KSNI/AppIndicator, GNOME degraded messaging, portal fallback if usable.
- Watchers: inotify/fanotify plus polling fallback with bounded CPU.
- Autostart: systemd user service primary, XDG autostart fallback.
- Hotkeys/notifications: portal/DBus notify, compositor-aware global shortcuts.
- mDNS: Avahi/DNS-SD.

Acceptance:

- PAL fixture matrix by DE/distro.
- Every seam has a fake, a real adapter, and degraded-state copy.

### 9.3 W2 — Core, crypto, transport

Deliverables:

- Core split.
- SQLCipher C target or vetted package, pinned 4.16.0-compatible parameters.
- GRDB-on-Linux or approved adapter decision.
- `PlatformCrypto` + `AttestedKeyStore` seam.
- libsignal Linux artifact and search path.
- iroh/burnbar-remote `.so` builders.
- FoundationNetworking import shim for portable network files.
- NIO WebSocket client behind realtime relay seam where `URLSessionWebSocketTask` is unavailable.

Acceptance:

- Swift 6 Linux build in Docker.
- KATs and cross-open DB vector.
- No CommonCrypto/Security/SecureEnclave imports in Linux engine target.

### 9.4 W3 — Data and sync

Deliverables:

- Engine-owned DataStore service.
- Firestore REST gateway with fieldTransforms for server timestamp/increment/delete.
- `CloudSyncWatchGateway` using gRPC Listen or WS bridge for latency-sensitive listeners.
- Lower-trust Linux App Check principal and callable allow-list enforcement.
- CloudVault round-trip Linux⇄macOS.
- Session log encrypted cloud client parity.

Acceptance:

- fake gateway vs REST vs emulator corpus green.
- Linux token rejected by high-risk callable without step-up.
- Low-risk sync succeeds under explicit Linux trust class.

### 9.5 W4 — Agent engine

Deliverables:

- Linux path table for Claude Code, Codex, Factory/Droid, Grok, Kimi, Goose, Hermes, OpenCode, Forge, Warp, Windsurf, Augment, Antigravity/Z.ai, Cline, and future providers.
- Parser fixture extraction from inline tests into portable corpus.
- CLIBridge POSIX process/PTY runner.
- Quota adapters and provider account linking.
- Local embedding provider behind `BurnBarCodeEmbeddingProvider`/retrieval seam; fake/deterministic embeddings excluded from ranking.

Acceptance:

- multi-provider Linux session corpus byte-identical to macOS golden after path/timestamp normalization.
- live CLI run updates DB and dashboard cost ticker.

### 9.6 W5 — Computer Use and Mercury

Deliverables:

- Screen capture: xdg-desktop-portal ScreenCast + PipeWire; X11 XShm fallback.
- Accessibility: AT-SPI2 tree reader; empty/missing permission fail-closed.
- Input: libei/EIS via RemoteDesktop portal where available; uinput helper with polkit/systemd hardening; XTEST fallback for X11.
- Panic halt: global hotkey, shell panic button, phone panic, Remote Config kill switch, engine watchdog.
- Media: PipeWire/GStreamer/Rust capture; VP9/AV1/Opus default; H.264 user-installed only.
- Audit: content-addressed entries and platform input adapter logs.

Acceptance:

- action loop and panic-halt timing evidence per DE.
- no setuid helper; polkit/uinput helper path pinned and package/hash verified.
- Mercury call connects to paired device with latency/cpu budget logs.

### 9.7 W6 — UI shell and design system

Deliverables:

- `apps/desktop` Tauri app.
- generated IPC client package.
- design-token adapter for Aurora, Editorial, Liquid Glass substitutions, provider glyphs, reduced motion/transparency.
- tray/popover/window manager.
- seeded visual proof harness.
- perf HUD for popover open, idle CPU, swarm FPS.

Acceptance:

- shell mock-engine test suite passes without real engine.
- real-engine smoke passes health, provider tile, settings, update state.
- visual proof book green across DE matrix.

### 9.8 W7 — UI surfaces

Surfaces:

- dashboard overview/provider/model/projects/missions;
- chat/Hermes and tool cards;
- insights/editorial observatory;
- quota/budget/accounting;
- session logs and search/Elder Wand;
- settings, accounts, providers, updates, privacy/data, devices/sync, switcher;
- onboarding;
- Mercury media surfaces;
- SmartHub/Cast/Home Assistant/PixelClock settings;
- membership and Stripe web checkout.

Acceptance:

- each surface has populated/loading/empty/error/degraded scripted tests.
- keyboard-only traversal reaches all controls.
- AT-SPI2 names/roles snapshots checked.

### 9.9 W8 — PetCompanion

Deliverables:

- glTF runtime in shell.
- transparent overlay window tier matrix.
- click-through/input-passthrough tests.
- behavior graph events from chat/mission/cost states.
- GNOME Wayland degraded tier: draggable contained pet window if always-on-top/free-placement is blocked.

Acceptance:

- per-DE tier table with screenshots and input tests.
- no pet overlay captures input outside allowed regions.

### 9.10 W9 — CI, release, distribution

Deliverables:

- `linux-pr-gate.yml` or focused Linux Desktop CI.
- `linux-nightly-e2e.yml` with nested Wayland (`weston`/`cage`) + Xvfb.
- `.so` builders for Rust artifacts.
- AppImage/deb/rpm/AUR/Flatpak package scripts.
- `latest-linux.json` schema + minisign key management.
- SBOM/provenance/source archive integration.
- public Linux download trust workflow.
- version-consistency and release-preflight updates.

Acceptance:

- release artifact smoke in clean Ubuntu image/VM.
- live feed verification job re-downloads and verifies AppImage.
- package closure legal scan green.

### 9.11 W10 — Verification and parity harness

Deliverables:

- portable parser fixture corpus.
- DB cross-open vector.
- IPC transcript suite.
- Signal/HermesRelay/RemoteUnlock KAT Linux⇄macOS.
- UI visual/a11y/perf proof book.
- Computer Use red-team harness.
- parity evidence ledger and `budgets/linux-parity.json` grow-only counters.

Acceptance:

- every `Tier A/B/C` row has an artifact.
- ledger is machine-readable and blocks G5 if any v1 row is missing evidence.

---

## 10. Full subsystem inventory

| Subsystem | macOS source | Linux approach | Tier | WS |
|---|---|---|---|---|
| Menu bar/tray | NSStatusItem + NSPopover | KSNI/AppIndicator + Tauri popover/flyout; GNOME degraded copy if tray absent | B | W1/W6 |
| Dashboard overview | AgentLens dashboard | Tauri workspace via generated IPC snapshots | B | W7 |
| Provider/model drilldowns | AgentLens dashboard + stores | engine data snapshots + shell charts | A/B | W7 |
| Usage rollups/cost ticker | DataStore + usage services | engine-owned DB + subscription updates | A | W3/W7 |
| Quota/provider accounts | ProviderQuota services | same adapters with Linux network/auth/path seams | A/B | W4/W7 |
| Session logs | local parsers + DB | Linux path maps, parser corpus, DB parity | A | W4/W7 |
| Search/Elder Wand | local retrieval/vector substrate | engine retrieval with Linux local embedder | A/B | W4/W7 |
| Chat/Hermes | ChatSessionController + gateway | engine chat stream + shell UI; prompt wrapper contract | A/B | W7 |
| Tool cards/thinking UI | SwiftUI views | tokenized Tauri components | B | W7 |
| Insights/editorial | AgentLens insights | generated IPC data + tokenized surfaces | B | W7 |
| Projects/Missions | daemon mission control | daemon/engine APIs + shell board | A/B | W7 |
| Memory/Pensieve | sealed knowledge + vector substrate | same sealed path; no new memory store | A | W3/W4/W7 |
| Account switcher | macOS stores/UI | engine account state + shell settings | B | W7 |
| Settings | SwiftUI settings | shell settings backed by generated IPC | B | W7 |
| Onboarding | macOS onboarding | Linux-specific permissions/paths/cloud/tray onboarding | B | W7 |
| Auth | Firebase Auth + Apple/Google flows | system-browser PKCE loopback, Firebase REST signInWithIdp/custom-token, passkeys via console | B/C | W3/W7 |
| Membership/Pro | StoreKit UI + Stripe backend | Stripe web checkout + entitlement restore; no StoreKit | C | W3/W7 |
| Cloud sync | Firebase SDK + CloudSyncGateway | REST unary/transforms + Listen/WS watch gateway, lower-trust App Check | B/C | W3 |
| CloudVault/E2EE | CryptoKit/Security/libsignal | PlatformCrypto + Linux libsignal + KATs | A/B | W2/W3 |
| Local DB | GRDB/SQLCipher/Keychain | SQLCipher/FTS5 + libsecret/TPM/passphrase SecretStore | A/B | W2/W3 |
| Daemon/engine IPC | Existing AF_UNIX newline-framed `BurnBarRPC*` JSON envelope | keep same transport/schema, fix Darwin/Glibc portability, `sun_len`, SIGPIPE, SO_PEERCRED/path/signature/hash pin + typed/generated IPC canon | A/B | W0/W1 |
| Local HTTP gateway | daemon loopback | same loopback gateway with Linux service config | A | W1/W4 |
| CLI bridge | Process/PTY | POSIX PTY runner + shell/PATH resolver | B | W1/W4 |
| Parser providers | 17+ parsers | same corpus + Linux log-path mappings | A/B | W4 |
| Quota adapters | provider-specific services | same adapters, FoundationNetworking/NIO where needed | A/B | W4 |
| Semantic embeddings | Apple NLEmbedding local path | ONNX/GGUF/Rust local provider behind existing seam | B | W4 |
| Telemetry/analytics | Sentry Cocoa/Amplitude SDKs | sentry-rust/Tauri bridge + Amplitude HTTP v2 | B | W6/W9 |
| Updates | direct DMG updater + appcast/latest-macos | AppImage updater + `latest-linux.json` minisign; package-manager channels don't self-replace | B/C | W9 |
| Release trust | notarization/Sparkle/SBOM/Sigstore | package signatures/minisign/SBOM/Sigstore/source-offer | B | W9 |
| Computer Use capture | ScreenCaptureKit | PipeWire portal; X11 fallback | B | W5 |
| Computer Use input | CGEvent/AX | libei/uinput/XTEST + AT-SPI2; consent gates | B/C | W5 |
| Panic halt | hotkey/phone/workspace/RC | global shortcut where available + shell/phone/RC/watchdog paths | A/B | W5 |
| Audit chain | content-addressed JSONL | same chain + platform adapter entries | A | W5 |
| Mercury file transfer | iroh | same iroh transport and file contract | A | W5 |
| Mercury screen share/call | ScreenCaptureKit/AVFoundation | PipeWire/GStreamer/VP9/AV1/Opus, Rust media path | B | W5 |
| PetCompanion | transparent NSWindow + SceneKit/glTF | three.js/glTF overlay; per-DE tier matrix | B/C | W8 |
| Text expansion | macOS global hooks | v1 in-app expansion; system-wide via IBus/fcitx v1.1 | C | W7/W5 |
| PixelClock | CoreWLAN + `/dev/cu.*` | NetworkManager DBus + libudev `/dev/ttyUSB*`/serial; v1 includes mDNS control, firmware flash gated by hardware proof | B/C | W7 |
| SmartHub/Cast/Home Assistant | macOS services | Avahi/DBus/network HTTP adapters | B | W7/W9 |
| Extension shell | VS Code extension | same extension; Linux desktop monitors daemon health | A | W4/W7 |
| Website/download metadata | macOS-only download fields | add Linux metadata only after trust gates | B | W9 |
| Accessibility | SwiftUI/AppKit | AT-SPI2 snapshots + keyboard traversal | B | W6/W7 |
| Visual identity | SwiftUI tokens/swarm/glass | generated CSS/TS token adapter + proof book | B | W6/W10 |

---

## 11. Verification and certification strategy

### 11.1 Flagship parity gates

1. **Golden fixture parity:** provider JSONL corpus ingested on macOS and Linux; canonical DB extracts diff byte-identical after normalized timestamps/paths.
2. **SQLCipher cross-open:** mac-written DB opens/writes/reopens on Linux; Linux-written DB opens/writes/reopens on macOS.
3. **IPC conformance:** TypeSpec-generated transcripts replay against Swift engine and TS mock; canonical JSON byte-identical.
4. **Crypto KATs:** HermesRelay, RemoteUnlock, Signal/libsignal, CloudVault Linux⇄macOS vectors.
5. **Prompt safety:** malicious transcript/memory/tool strings remain wrapped as untrusted content in final prompts.
6. **Cloud trust:** Linux lower-trust token rejected by high-risk callable; low-risk sync succeeds; step-up proof accepted only for named actions.
7. **UI proof:** Playwright/Tauri-driver scripts + screenshot book + AT-SPI2 tree snapshots + console/network error review.
8. **Computer Use red-team:** no input without consent/grant/focus/permission/inactive kill switch; empty AT-SPI fails closed; panic halt timing captured.
9. **Release trust:** install/update/package smoke, feed signature verification, SBOM/provenance/source archive validation.

### 11.2 Linux environment matrix

| Environment | Purpose |
|---|---|
| Ubuntu 24.04 GNOME Wayland | primary support floor, portals, libei/AT-SPI2, AppImage/deb |
| Fedora latest GNOME Wayland | newer portal/libei stack and distro defaults |
| KDE Plasma Wayland | tray, portal, KWin behavior, package-manager expectations |
| wlroots/Hyprland or Sway | portal fragmentation and libei/wlr fallback reality |
| X11/Xvfb | legacy fallback, XTEST/XShm behavior, CI automation |
| aarch64 Ubuntu runner | build parity and package metadata, initially smoke-level |

### 11.3 Performance budgets

| Interaction | Budget |
|---|---|
| tray click → popover usable | p95 <150ms |
| engine health IPC round-trip | p95 <25ms local |
| live cost ticker update after parser event | p95 <250ms after DB commit |
| idle shell CPU | <1% on reference laptop after warmup |
| swarm/glass/backdrop | ≥55fps WebKitGTK 2.46+, ≥30fps 2.44 fallback |
| Computer Use panic halt | <100ms from local panic where OS event path permits; otherwise fastest OS-confirmed bound documented |
| media LAN 1080p60 | ADR 008 target P50 <16ms, P95 <28ms, P99 <50ms motion-to-photon on favorable hardware |

---

## 12. CI, release, and distribution lane

### 12.1 Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `linux-pr-gate.yml` | PR / merge queue | Swift engine Linux build, Tauri shell tests, IPC drift, parser fixture subset, package metadata lint. |
| `linux-nightly-e2e.yml` | nightly/manual | GNOME/KDE/wlroots/X11 real-surface tests, visual proof book, Computer Use loopback. |
| `build-iroh-linux-so.yml` | tags/manual/PR affecting crates | Linux `.so` artifacts for iroh and burnbar-remote. |
| `linux-distribution.yml` | tags/manual | AppImage/deb/rpm/AUR/Flatpak builds, signatures, SBOM, provenance. |
| `public-linux-download-trust.yml` | release/site changes/schedule | re-download public artifacts, verify signatures/feed/checksums/install smoke. |

### 12.2 Package policy

- **AppImage:** primary direct-download artifact; self-update through `latest-linux.json` + minisign/Ed25519; no sandbox surprises.
- **deb/rpm:** native package-manager installs; updates through package channel, not self-replacement, unless user opts into direct channel.
- **AUR:** source/PKGBUILD channel; generated from release metadata.
- **Flatpak:** tail channel. Must document filesystem, portal, and local-agent limitations. No full-parity claim unless broad log access, daemon socket, SecretStore, and portal permissions are proven.
- **Snap:** not in v1 unless a concrete confinement story beats Flatpak; otherwise avoid parallel package work.

### 12.3 Release artifact checklist

Each public Linux release contains:

- signed AppImage;
- deb and rpm packages;
- AUR metadata or generated PKGBUILD;
- Flatpak manifest if tail channel is enabled;
- `latest-linux.json`;
- checksums;
- minisign signature;
- SPDX SBOM;
- Sigstore/cosign provenance;
- corresponding source archive;
- release metadata with commit, version, runner, package closure, update feed;
- install/update smoke logs;
- parity-evidence bundle id.

---

## 13. Security model

### 13.1 Linux trust stack

| Surface | Required defense |
|---|---|
| Engine socket | user-scoped dir, `0600`, `SO_PEERCRED`, bearer token, method capabilities, path/hash/package verification. |
| Secret storage | libsecret/KWallet/Secret Service primary; headless passphrase/systemd-creds explicit; plaintext-adjacent fallback refused for high-value keys. |
| uinput/helper | systemd service + polkit action, no setuid, executable/package hash pin, least-privilege device access, audit every high-impact action. |
| Portal capture/input | user-visible consent, scoped monitor/window/session, fail-closed on missing grant, no silent retry loops. |
| Cloud high-risk | appId allow-list excluding generic Linux low-trust id; per-action WebAuthn/hardware step-up; Remote Config kill switches. |
| Release | package signatures, feed signatures, SBOM/provenance, no untrusted `.so` sideload path, update rollback docs. |
| Prompt content | exact untrusted wrapper contract, delimiter defanging, truncation reseal, tests. |

### 13.2 Lower-trust copy

Linux security UI must be honest:

- show when SecretStore is lower-trust than hardware-backed storage;
- show when a DE/compositor allows only a degraded Computer Use path;
- show when hosted high-risk cloud actions require step-up;
- explain why Flatpak may not be full parity;
- never imply portal consent is permanent if the compositor revokes it per session.

---

## 14. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| **R1 Core split is larger than scoped.** | high | high | Phase-0 compile spike, hard-zero UI import ratchet, small extraction PRs. |
| **R2 SQLCipher/GRDB Linux parity fails.** | medium | critical | CSQLCipher target, raw adapter fallback, cross-open spike before fan-out. |
| **R3 Tauri/WebKitGTK misses perf/a11y bar.** | medium | high | pre-registered G0 perf/a11y gate; GTK/Qt fallback. |
| **R4 Wayland portal/libei fragmentation.** | high | high | DE matrix, tiered support table, X11 fallback, explicit degraded states. |
| **R5 GNOME tray/pet limitations.** | high | medium | AppIndicator/extension guidance, contained pet fallback, no false full-parity claim. |
| **R6 App Check lower-trust path under-scoped.** | high | critical | backend allow-list tests and step-up proof in Phase 0/2 gates. |
| **R7 SecretStore fallback regresses at-rest security.** | medium | critical | trust-level API, refusal defaults, tests for high-value keys. |
| **R8 uinput helper expands privilege too far.** | medium | critical | no setuid, polkit/systemd hardening, path/hash pin, red-team gate. |
| **R9 Parser fixture corpus misses Linux path realities.** | medium | high | real Linux CLI sessions in corpus, path remap table, provider owner review. |
| **R10 Visual identity feels generic.** | medium | high | token generator, seeded proof book, design review gate, provider glyph checksum. |
| **R11 Release package sprawl hides compliance gaps.** | medium | high | W9 single owner, package closure SBOM/provenance, public trust workflow. |
| **R12 Flatpak sandbox prevents parity.** | high | medium | tail channel, documented holes, no full-parity claim until proven. |
| **R13 NIO/WebSocket/FoundationNetworking shims fork network behavior.** | medium | medium | protocol tests across URLSession/NIO clients and emulator corpus. |
| **R14 Media zero-copy promises overrun hardware reality.** | high | medium | stage timing instrumentation, copy-class labels, fallback quality tiers. |
| **R15 One mega-PR collapses review.** | medium | high | factory lanes, single-owned shared files, phase gates, reject-lane discipline. |
| **R16 Docs drift from Windows foundation.** | medium | medium | cross-plan review at W0 IPC changes, links to shared foundation, receipts. |
| **R17 Accessibility gets tested too late.** | medium | high | AT-SPI2 snapshots in G0/G3, keyboard scripts from first shell skeleton. |
| **R18 Package/update trust is treated as post-build.** | medium | critical | W9 enabled Phase 0, `latest-linux.json` schema and signing before public artifact. |

---

## 15. Explicit v1.1 non-goals / declared substitutions

These are not hidden drops; they are named substitutions or v1.1 rows.

| Area | v1 Linux behavior | v1.1 / promotion criterion |
|---|---|---|
| System-wide text expansion on Wayland | in-app expansion only; no evdev keylogger | IBus/fcitx IME integration with consent UI, tests, and per-DE support. |
| GNOME Wayland free-floating pet | contained/draggable pet tier if always-on-top/click-through blocked | GNOME-supported overlay path or extension with input-passthrough proof. |
| Flatpak full parity | tail package with documented filesystem/socket/portal limitations | full log access, daemon socket, SecretStore, updater, and Computer Use evidence. |
| Lock-screen / secure-desktop input | not promised | compositor/system-supported secure input path with explicit user consent and red-team pass. |
| iCloud mirror | Firestore/sealed archive paths only | sealed cross-platform archive product decision, not raw iCloud parity. |
| H.264 bundled media | not bundled | user-installed codec path or licensing decision; VP9/AV1/Opus default. |

PixelClock firmware flashing is **not** a v1.1 non-goal by default: v1 includes mDNS control and attempts a Linux firmware lane through NetworkManager DBus + libudev serial, but G4 may downgrade firmware flashing only with hardware evidence and a named parity row.

---

## 16. Decisions resolved by this plan

1. **Product shape:** Linux is a full local peer, not a cloud companion.
2. **Foundation:** shared engine/IPC/schema/design/release/parity contracts live in `DESKTOP_FOUNDATION.md`.
3. **Engine:** shared `openburnbar-engined` is the target; no Linux-only reimplementation unless G0 invalidates Swift core reuse.
4. **Shell candidate:** Tauri 2 starts Phase 0; it must earn the right to ship.
5. **Display/input:** Wayland-first with full X11 fallback; unsafe global keylogging rejected.
6. **Cloud posture:** Linux lower-trust by default; high-risk actions require allow-list + step-up.
7. **Packaging:** AppImage primary; deb/rpm/AUR; Flatpak tail; Snap out unless justified later.
8. **Validation:** parity evidence ledger is the definition of done.

---

## 17. References

- [`DESKTOP_FOUNDATION.md`](DESKTOP_FOUNDATION.md)
- [`WINDOWS_PORT_MASTER_PLAN.md`](WINDOWS_PORT_MASTER_PLAN.md)
- [`WINDOWS_PORT_MISSION_BRIEF.md`](WINDOWS_PORT_MISSION_BRIEF.md)
- [`OPENBURNBAR_RELEASE_ARCHITECTURE.md`](OPENBURNBAR_RELEASE_ARCHITECTURE.md)
- [`DIRECTION.md`](DIRECTION.md)
- [`architecture/008-remote-control-engine.md`](architecture/008-remote-control-engine.md)
- [`FIREBASE_APP_CHECK_ENFORCEMENT.md`](FIREBASE_APP_CHECK_ENFORCEMENT.md)
- [`LIQUID_GLASS_PARITY.md`](LIQUID_GLASS_PARITY.md)
- [`EDITORIAL_SKIN.md`](EDITORIAL_SKIN.md)
- [`SOFTWARE_FACTORY_PR_LOOP.md`](SOFTWARE_FACTORY_PR_LOOP.md)
- Tauri v2 Linux packaging docs: <https://v2.tauri.app/distribute/debian/> and <https://v2.tauri.app/distribute/aur/>
- libei upstream docs/source: <https://gitlab.freedesktop.org/libinput/libei>
- xdg-desktop-portal docs: <https://flatpak.github.io/xdg-desktop-portal/docs/>
