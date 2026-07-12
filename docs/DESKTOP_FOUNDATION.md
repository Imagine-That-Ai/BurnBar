# OpenBurnBar Desktop Foundation

**Status:** Shared desktop substrate plan v1.0 · **Date:** 2026-07-03  
**Companion plans:** [`WINDOWS_PORT_MASTER_PLAN.md`](WINDOWS_PORT_MASTER_PLAN.md) · [`WINDOWS_PORT_MISSION_BRIEF.md`](WINDOWS_PORT_MISSION_BRIEF.md) · [`LINUX_PORT_MASTER_PLAN.md`](LINUX_PORT_MASTER_PLAN.md)  
**Scope:** the shared engine, IPC, data, security, design, release, and validation foundation for all local-peer desktop ports.  
**Non-goal:** this is not a Linux or Windows implementation plan by itself. Platform deltas live in the platform master plans.

> OpenBurnBar's desktop ports are local peers, not cloud-only companions. The shared foundation exists so macOS, Windows, and Linux do not grow three engines, three IPC dialects, three schema systems, three visual identities, or three incompatible parity harnesses.

---

## 0. How to read this document

- **§1** states the product stance and why a shared foundation is mandatory.
- **§2** records the bound architecture decisions.
- **§3** defines the engine, Core split, and data-store ownership model.
- **§4** freezes the shared IPC contract and codegen strategy.
- **§5–§8** cover security, cloud, crypto, media, and design-system invariants.
- **§9–§11** define release plumbing, CI, parity evidence, and factory execution.
- **§12–§14** list ratchets, known caveats, and explicit do-not-build boundaries.

Use this as the contract every desktop-port PR must preserve. If a platform plan needs to diverge, it must do so explicitly in its own Tier-C substitution or risk row.

---

## 1. Canonical stance

OpenBurnBar is **daemon-first** and **local-first**.

Current committed architecture already states the canonical authorities:

| Authority | Current owner | Port implication |
|---|---|---|
| Usage, conversations, retrieval, shared-artifact projections | macOS app local SQLite (`AgentLens/Services/DataStore`) | Desktop peers must preserve local authority and byte-compatible data contracts. |
| Provider routing, controller state, connector/browser config, run/runtime state | local daemon-owned files (`OpenBurnBarDaemon`) | Desktop peers must run a local control plane, not a cloud-only dashboard. |
| Firestore | optional replication/collaboration plane | Non-Apple desktops need a lower-trust or custom-attestation posture before cloud parity claims. |
| iCloud session mirror | disabled/raw path not canonical | Linux/Windows do not emulate iCloud; they use the portable sealed/Firestore paths when available. |

Evidence in the repo:

- `docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md` defines local SQLite and daemon-owned files as canonical and Firestore/iCloud as non-canonical replication planes.
- `docs/DIRECTION.md` says retrieval stays the spine, the daemon/editor loop strengthens into the working control plane, and collaboration must not give up local authority.
- `OpenBurnBarDaemon` already exposes a local Unix-socket control plane with bearer-token auth, method capability scoping, peer checks, local services, and an optional loopback HTTP gateway.
- `tools/schema-sync/` already owns a TypeSpec-to-TS/Swift/Kotlin schema pipeline and a drift gate. Use it; do not create a parallel IDL.

Desktop foundation principle: **one shared product truth, platform-native skins around it**.

### 1.1 Shared parity vocabulary

All desktop peer plans use the same tiers:

| Tier | Foundation meaning |
|---|---|
| **Tier A** | Exact parity: byte- or behavior-identical outputs such as database schema, IPC transcripts, parser output, crypto KATs, prompt-wrapper vectors, and entitlement math. |
| **Tier B** | Functional parity through a platform-native equivalent such as tray APIs, secret stores, PTYs, capture/input APIs, notifications, and package managers. |
| **Tier C** | Explicit substitution where no safe platform analog exists. The platform plan must name the substitute, evidence, and any v1.1 promotion criterion. |

No platform plan may replace a Tier A promise with Tier B convenience, or hide a Tier C substitution as “not applicable.”

---

## 2. Bound architecture decisions

### D1 — Non-Apple desktop peers run a shared local engine daemon

**Decision:** Windows and Linux run `openburnbar-engined` as an out-of-process local peer engine. The UI shell talks to it through a typed IPC contract. macOS remains the source implementation and may adopt more of the daemon topology incrementally, but non-Apple peers do not embed a bespoke per-platform engine.

**Why:** the macOS app currently mixes UI, DataStore, parser, retrieval, cloud, and OS glue. Porting that as one in-process bundle would fork every platform. A local engine daemon gives the ports a stable contract, isolates privileged/long-running work, and lets UI shells iterate independently.

**Consequences:**

- Engine APIs must be product contracts, not incidental Swift method shapes.
- The daemon is allowed to own background work, session ingestion, cloud sync, search projection, and mission/control-plane state.
- UI shells must survive daemon restart and show honest degraded states.
- IPC conformance becomes a release gate.

### D2 — Split shared Swift into headless model + Apple/UI umbrella

**Decision:** introduce a UI-free engine/model layer (`OpenBurnBarCoreModel` as the plan name) and keep `OpenBurnBarCore` as the Apple/UI umbrella that re-exports the model layer for existing macOS/mobile callers.

**Current caveat:** `OpenBurnBarCore` is a real SwiftPM package with shared contracts and generated Firestore models, but it is not Linux-clean today. A grep of `OpenBurnBarCore/Sources/OpenBurnBarCore` reports 110 files with unguarded `import SwiftUI`, including `SharedModels/AgentProvider.swift` and `SharedModels/ThemePrimitives.swift`. `OpenBurnBarDaemon/Package.swift` also declares macOS-only platform settings and frameworks.

**Target contract:**

- `OpenBurnBarCoreModel/**` imports no SwiftUI/AppKit/UIKit/Firebase.
- `OpenBurnBarCore` remains source-compatible for Apple targets as the UI umbrella.
- `OpenBurnBarComputerUseCore` gets the same policy-vs-platform split: reusable authority/audit/wire policy in model, platform adapters in Mac/Windows/Linux targets.
- The split lands behind ratchets so UI imports cannot creep back into engine targets.

### D3 — TypeSpec owns shared data and IPC schema evolution

**Decision:** extend the existing `tools/schema-sync/` TypeSpec pipeline rather than hand-roll a second engine-protocol generator.

**Current facts:**

- `tools/schema-sync/typespec/*.tsp` is the accepted schema canon for Firestore and generated client models.
- `tools/schema-sync/check-drift.sh` emits TS/Swift/Kotlin, compiles the TypeSpec canon with `@typespec/compiler`, diffs generated outputs, checks hand mirrors, and is wired into Fast Feedback.
- Generated Swift models already ship through `OpenBurnBarFirestoreModels` and production bridge files.

**New foundation target:** add `packages/engine-ipc/` under the same discipline:

```text
tools/schema-sync/typespec/
  domains/*.tsp                 existing Firestore/domain canon
  engine-ipc/*.tsp              new desktop-engine IPC canon
        │ emit
        ├── OpenBurnBarCoreModel/Sources/.../*IPCModels.swift
        ├── packages/engine-ipc/gen/client.ts
        ├── packages/engine-ipc/gen/schema/*.schema.json
        └── crates/burnbar-remote/... serde mirrors where the media path needs Rust
```

No platform plan may define a private JSON shape that bypasses this canon.

### D4 — Platform shells are native where it matters and shared where it compounds

**Decision:** the shared foundation owns tokens, motion semantics, IPC clients, mock/fixture engines, and parity harnesses. Platform plans own shell toolkit choices and OS-native integration.

**Consequences:**

- Linux can choose Tauri 2 + React/TypeScript if G0 confirms performance and OS integration.
- Windows can remain WinUI 3 unless its own G0 evidence chooses a different shell.
- Both can still share IPC clients, mock engine transcripts, design tokens, shell state machines, and parity tests.
- `apps/console` is not a desktop shell source. Reuse components or visual grammar only when they obey desktop accessibility/performance/permission contracts.

### D5 — Media frames stay on the Rust/shell hot path; Swift engine exposes accounting and policy

**Decision:** real-time capture, encode, frame pacing, render, and call HUD frame delivery are owned by platform media/Rust shell components. The Swift engine owns budget/accounting metadata, grants, audit state, session policy, and product state.

**Why:** ADR 008 already defines `crates/burnbar-remote/` as the remote-control/media spine and Linux's intended path as PipeWire DMA-BUF through VAAPI/NVENC/AMF/Vulkan Video into wgpu/Vulkan, with no universal zero-copy guarantee. Routing hot video frames through Swift IPC would add copies and make latency budgets fictional.

---

## 3. Engine and data foundation

### 3.1 Current-state inventory

| Surface | Current repo state | Foundation action |
|---|---|---|
| Daemon socket | `OpenBurnBarDaemon` listens on `openburnbar-daemon.sock`, `0600`, newline-delimited JSON envelope, bearer token, JSON-RPC-compatible error numbers, method capability scoping. | Promote the envelope to generated IPC schema; keep socket lifecycle/auth tests as the model. |
| HTTP gateway | loopback-only by default (`127.0.0.1:8317`), auth required outside explicit DEBUG bypass. | Use for OpenAI-compatible local gateway and diagnostics, not as the primary UI IPC. |
| Shared RPC contracts | `OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift` defines protocol version, method enum, envelopes, errors. | Version into the engine IPC canon; preserve capability mapping totality. |
| DataStore | macOS `DataStoreCoordinator`/`DataStoreActor` over GRDB `DatabasePool` production and `DatabaseQueue` tests. | Extract store-neutral domain services; avoid UI-owned mutation paths on new peers. |
| SQLite schema | `OpenBurnBarDatabase.swift` is the source migrator; `docs/SCHEMA_SQLITE.sql` is the mirror. | Port migrations through the same canonical migrator or a generated parity harness; docs mirror updates remain required. |
| SQLCipher | app hard-fails when encryption is enabled and `PRAGMA cipher_version` is absent; key lives in Keychain. | Replace Keychain with platform `SecretStore`; pin SQLCipher params; cross-open DB both directions. |
| Daemon SQLite | daemon can open shared SQLite directly for indexed search/resume/project memory when `indexDatabasePath` exists. | Treat app/daemon split as current reality; decide whether Linux makes engine the sole DB writer before implementation. |

### 3.2 Target data ownership

The new peer-desktop engine should converge on this model:

```text
Desktop shell
  -> generated IPC client
  -> openburnbar-engined
       -> Data domain services
       -> GRDB/SQLCipher or approved Linux/Windows-compatible SQLite adapter
       -> parser/session ingestion
       -> retrieval/projection/vector substrate
       -> CloudSync gateways
       -> mission/control-plane runtime
       -> local HTTP gateway for editor/CLI compatibility
```

Rules:

1. The engine is the only owner of durable local data mutations on new peer desktops.
2. UI shells may cache presentation state, but must not create a second product database.
3. The engine exposes snapshots, subscriptions, and commands through IPC.
4. Cloud sync is never the source of truth.
5. Store extraction must preserve macOS tests while adding Linux/Windows parity vectors.

### 3.3 Database portability contract

Every desktop peer must prove:

- SQLCipher `cipher_compatibility`, `kdf_iter`, `cipher_page_size`, FTS5 tokenizer, `bm25()`, and `snippet()` behavior are pinned or measured against macOS.
- A macOS-written encrypted DB opens on the peer, migrates, runs representative FTS/search queries, writes a row, and reopens on macOS.
- A peer-written encrypted DB reopens on macOS.
- WAL, busy timeout, migration backup/restore, schema hash, and key lifecycle are tested.
- Secret-store fallback cannot silently downgrade DB keys, Signal identity keys, refresh tokens, or CloudVault keys to plaintext-adjacent storage.

### 3.4 Daemon SQLite caveat

Do not repeat the stale claim that the daemon never uses SQLite directly. `docs/DATABASE_OPERATIONS.md` currently contains that older statement, but the current daemon initializes raw-SQLite indexed-search/resume/project-memory services when `indexDatabasePath` exists. The shared foundation treats that as a known transitional shape, not a contradiction to hide.

---

## 4. IPC foundation

### 4.1 Transport envelope

Current daemon transport is JSON envelope RPC, not strict JSON-RPC 2.0. It uses:

- newline-delimited request/response frames over AF_UNIX stream sockets;
- request `id`, `method`, optional `authToken`, and typed `params`;
- response `id`, `protocolVersion`, `result` or `error`;
- JSON-RPC-compatible error codes (`-32600`, `-32602`, `-32601`, `-32603`) plus product codes (`-32001` unauthorized, etc.);
- bearer-token authorization plus peer checks and capability attenuation;
- max request sizes, timeouts, and socket cleanup tests.

Foundation term: **JSON envelope RPC**. Use “JSON-RPC-style” only when clarifying compatibility, not strict compliance.

Porting rule: extend the existing `BurnBarRPC*` envelopes and `BurnBarUnixDomainSocket`/`BurnBarCLISocketClient` path unless a reviewed contract deliberately replaces them. Do **not** create a second `DaemonEnvelope`, `DaemonTransport`, or NSXPC-style daemon transport. The current Linux gap is platform portability around the existing AF_UNIX implementation: `Darwin` vs `Glibc` imports, macOS-only `sun_len`, `SO_NOSIGPIPE` handling, peer-credential/package trust, and Linux path/service defaults.

### 4.2 IPC domain freeze

The first `engine-ipc` contract must freeze the whole user-visible surface, even if some methods return structured `unimplemented` during early phases.

| Domain | Required modules |
|---|---|
| Core | envelope/framing, handshake, protocol negotiation, errors, capability profile, diagnostics, engine.status, engine.shutdown |
| Settings | appearance, accounts, providers, alerts, notifications, devices/sync, privacy/data, updates, developer diagnostics |
| Data | providers, usage, quota, budgets, projects, session logs, database health, insights, search/Elder Wand, memory/Pensieve, artifacts |
| Interactive | chat stream/delta/tool/done, missions/live board, approvals, auth/session state, account switcher |
| Computer Use | grants, local capability state, audit ledger state, panic halt, policy status, approval state |
| Media | engine-owned media budget/accounting metadata; Rust/shell-owned frame transport schema references |
| Release/Ops | update channel, version/provenance, support bundle, diagnostics export |

### 4.3 Subscription model

Subscriptions are first-class, not long-polling afterthoughts.

Required semantics:

- `subscription.start` returns a subscription id, first snapshot, and monotonic `seq`.
- Every update carries `(subscriptionId, seq, snapshot|patch, sourceClock)`.
- `subscription.resume(subscriptionId, afterSeq)` either replays missed events or returns `needsSnapshot`.
- Shells must tolerate engine restart: reconnect, request snapshots, and render a degraded/reconnecting state.
- Backpressure is explicit: engine may coalesce progress updates but must not drop terminal states.

### 4.4 Mock engine and transcript conformance

Every generated client ships with:

- a deterministic TS mock engine backed by fixture transcripts;
- Swift conformance tests replaying the same transcripts against `openburnbar-engined`;
- canonical JSON normalization for byte-identical transcript comparisons;
- schema drift checks for Swift, TS, and any Rust serde mirrors.

---

## 5. Platform Abstraction Layer foundation

PAL seams freeze only when they have a second real consumer. Stubs and mocks ship early so UI and engine lanes can build in parallel without inventing private shims.

| Seam | Shared contract | Platform adapters |
|---|---|---|
| Paths | support/cache/log/session root, provider log locations, XDG/known-folder mapping | macOS `Application Support`, Linux XDG, Windows Known Folders |
| SecretStore | `get/set/delete`, key class, accessibility/trust level, lower-trust flag | Keychain, libsecret/KWallet/Secret Service, TPM/systemd-creds/passphrase fallback, CNG/DPAPI+Hello |
| Process/PTY | spawn, stream, resize, signal/terminate, environment scrub, path encoding | `Process`/PTY, POSIX PTY, ConPTY |
| IPC peer trust | socket/pipe identity, token, capability, executable/package verification | code signature/audit token, SO_PEERCRED+path/signature/hash, named-pipe DACL+signed handshake |
| Notifications | local notification, action button, permission state | UserNotifications, DBus portal/notify, WinRT Toast |
| Tray/shell | status item/tray, popover/flyout, click behavior, global shortcuts | NSStatusItem, KSNI/AppIndicator/portals, Shell_NotifyIcon |
| Watchers | file watcher, provider log discovery, debounce/coalesce | FSEvents, inotify/fanotify, ReadDirectoryChangesW |
| Autostart/service | login item/LaunchAgent, systemd-user/xdg autostart, Windows Service/StartupTask | platform-specific install/repair flows |
| Capture/input | screen capture, accessibility tree, input injection, deny regions, panic halt | ScreenCaptureKit/AX/CGEvent, PipeWire/portal/libei/uinput/XTEST/AT-SPI2, WGC/UIA/SendInput/driver |
| mDNS/local discovery | peer advertisement, service discovery, conflict handling | Network/Bonjour, Avahi, DNS-SD/Bonjour SDK |

No platform adapter may silently weaken the shared contract. If the OS cannot provide an equivalent, the platform plan records a Tier-C substitution or v1.1 non-goal.

---

## 6. Security and trust foundation

### 6.1 Invariants that must survive every desktop port

1. Local data remains locally authoritative.
2. High-risk cloud callables require explicit trust signals and must fail closed.
3. Computer Use approval remains the ground truth; no silent autopilot.
4. Capability tokens, audit chains, kill switches, and deny regions are platform contracts, not macOS implementation details.
5. Prompt-injection wrappers and untrusted-content delimiters are exact parity surfaces.
6. Secret storage must not silently degrade for DB keys, Signal identity keys, CloudVault keys, refresh tokens, or capability roots.
7. IPC method capability mapping is total: every method maps to exactly one capability group, and unclassified methods fail closed.
8. Release artifacts carry provenance, SBOM, checksums/signatures, and public trust checks before user-facing distribution.

### 6.2 Non-Apple cloud trust posture

The Apple App Check/App Attest posture does not automatically port.

Foundation policy:

- A non-Apple desktop app id is a distinct principal.
- Low-risk read/sync surfaces may use an explicitly lower-trust debug/custom-provider token only if backend rules/callables know that trust class.
- Hosted Computer Use, grant issuance, escrow elevation, Remote MCP grants, and other high-risk callables must use an appId allow-list and per-action step-up proof. Linux and Windows do not get attestation-equivalent power by minting generic server tokens.
- Local Computer Use does not require cloud attestation; it requires local OS permission, local approval, local audit, and kill-switch enforcement.

### 6.3 IPC peer trust

macOS peer code-sign validation cannot be copied verbatim.

Desktop foundation requires each peer platform to prove an equivalent defense stack:

- socket/pipe permissions scoped to the current user;
- bearer token or mutually authenticated local session;
- executable path or package identity pin;
- package/maintainer signature or hash verification where available;
- method capability attenuation;
- audit log for rejected high-risk methods;
- tests for stale socket/pipe cleanup, wrong token rejection, degraded peer identity, and unclassified method rejection.

### 6.4 Secret-store trust levels

All secret-store implementations expose a trust level:

| Trust level | Allowed for DB key | Allowed for refresh token | Allowed for Signal/CloudVault identity | User-facing state |
|---|---:|---:|---:|---|
| Hardware/OS protected, user-session bound | yes | yes | yes | normal |
| OS secret service without hardware attestation | yes, with lower-trust flag | yes, with lower-trust flag | yes, with lower-trust flag | show lower-trust security copy |
| Passphrase-derived headless KEK | yes, explicit setup | yes, explicit setup | yes, explicit setup | headless mode copy |
| Plain encrypted file with key beside data | no | no | no | refused by default |

---

## 7. Crypto and E2EE foundation

The CryptoKit-to-swift-crypto shim covers only the common surface. The desktop foundation needs `PlatformCrypto` seams for every Apple-only dependency.

Required seams:

| Seam | Darwin implementation | Linux/Windows target |
|---|---|---|
| Common CryptoKit primitives | CryptoKit / swift-crypto | swift-crypto |
| Secure/attested signing key | Secure Enclave where available | TPM 2.0 / CNG / software fallback marked lower-trust |
| Keychain-backed key pinning | Security.framework Keychain | SecretStore + package/executable pinning + trust-level metadata |
| Random bytes | SecRandomCopyBytes/CryptoKit | OS RNG via swift-crypto/BoringSSL/OpenSSL-backed adapter |
| HPKE/Auth-mode vectors | existing HermesRelay/RemoteUnlock KATs | byte-identical KATs on each peer |
| Signal/libsignal store | Apple Keychain + vendored libsignal | libsecret/TPM + Linux/Windows libsignal build artifacts |

Validation is byte-level. “Compiles” is not enough.

---

## 8. Design-system foundation

The desktop ports must look like OpenBurnBar, not like generic GTK/WinUI/Tauri samples.

### 8.1 Token sources

| Token family | Source of truth | Port rule |
|---|---|---|
| Aurora palette, gradients, semantic colors | `AgentLens/Theme/DesignSystem.swift` + shared primitives | Generate/adapt; do not hand-pick approximations. |
| Editorial/Paper skin | `docs/EDITORIAL_SKIN.md`, `apps/console/styles/globals.css`, `DesignSystemTokens.*Editorial` | Preserve light-locked paper model, coral accent, hairlines, and provider dot crest. |
| Liquid Glass vocabulary | `docs/LIQUID_GLASS_PARITY.md` | Use adapter vocabulary and document substitutions. |
| Swarm/provider glyphs | `SwarmCanvasView`, provider logo assets, `SwarmLogoShapeTests` | Every provider glyph participates; reduced-motion path required. |
| Data & Privacy/Pensieve tokens | `packages/design-tokens/` | Use generated outputs; extend emitters for desktop shells. |

### 8.2 Visual invariants

1. Aurora remains the default identity.
2. Editorial is a skin axis, not a fourth OS appearance mode.
3. Glass communicates depth and state; it never stacks glass inside glass.
4. Motion is alive but optional: reduced-motion and low-power modes must remain beautiful, not broken.
5. Provider identity colors and glyphs are fixed under every skin.
6. Accessibility is part of fidelity: keyboard traversal, screen reader names, contrast, focus rings, reduced transparency, reduced motion.

### 8.3 Rendering proof

Each platform shell must ship a visual proof book:

- seeded clock and seeded swarm RNG;
- Aurora and Editorial snapshots;
- light/dark/system appearance where applicable;
- reduced motion and reduced transparency states;
- provider glyph roster snapshot/checksum;
- tray/popover/flyout and every top-level workspace;
- error/empty/loading states;
- side-by-side acceptable-drift notes against macOS/web references.

---

## 9. Release and distribution foundation

Current release architecture is macOS-first: DMG/ZIP, Sparkle-compatible appcast, `latest-macos.json`, checksums, SBOM, Sigstore provenance, and release metadata.

Desktop foundation extends that model without cloning Apple assumptions.

| Artifact | macOS | Linux target | Windows target |
|---|---|---|---|
| Install package | DMG/ZIP, MAS archive | AppImage primary, deb/rpm, AUR, Flatpak tail | MSIX/zip, winget/Chocolatey |
| Latest feed | `latest-macos.json` | `latest-linux.json` | `latest-windows.json` |
| Feed trust | Ed25519/Sparkle signature + SHA | minisign/Ed25519 + SHA + package signatures | Ed25519 feed + Authenticode/MSIX signatures |
| SBOM/provenance | SPDX + Sigstore bundles | SPDX + Sigstore/cosign + package closure | SPDX + Sigstore + signing-chain evidence |
| Smoke | launch app + authenticated daemon health | install, launch, service/socket, update metadata verify | install, launch, service/pipe, update metadata verify |
| Public trust workflow | `public-macos-download-trust.yml` | new Linux download trust workflow | Windows download trust workflow |

Rules:

- Version source stays `project.yml` unless governance changes it.
- `scripts/verify-version-consistency.sh` must include Linux package metadata before public Linux artifacts ship.
- `scripts/ci/check_burnbar_release_preflight.py` must treat Linux packages as release artifacts when they become public.
- Website download metadata is added only after artifact trust gates exist.
- AGPL source-offer, SBOM, VEX, checksum, provenance, and legal preflight requirements apply equally to Linux/Windows binaries.

---

## 10. Shared validation foundation

### 10.1 Evidence floor

| Area | Evidence required |
|---|---|
| IPC | TypeSpec compile, generated client/server driftcheck, transcript replay against Swift engine and TS mock, capability-totality tests. |
| DB | SQLCipher cross-open both directions, schema hash, migration to latest, FTS row-set parity, WAL/busy-timeout behavior, key lifecycle tests. |
| Parsers | provider JSONL corpus watch→parse→DB on macOS and peer; canonical token/cost/model output byte-identical. |
| Prompt safety | prompt-injection wrapper contract vector, delimiter-defanging, truncation reseal, no untrusted content in trusted persona blocks. |
| Cloud | fake gateway vs REST vs emulator parity; App Check/lower-trust rejection tests for high-risk callables. |
| E2EE | HermesRelay/RemoteUnlock/Signal KATs across macOS and peer. |
| UI | automated surface scripts, visual proof book, a11y tree snapshots, keyboard-only traversal, reduced motion/transparency states. |
| Computer Use | capture→plan→input→verify loop, approval state, audit chain, deny regions, replay rejection, panic halt timing, fail-closed empty accessibility tree. |
| Media | real capture/encode/network/decode/render stage timings; codec fallback; bandwidth/cost caps; artifacted benchmark logs. |
| Release | install/update smoke, feed signature verification, SBOM/provenance validation, package uninstall/rollback. |

### 10.2 Gate protocol

Every phase gate uses the same adversarial loop:

1. Builders submit an exit dossier with claims and artifacts.
2. Independent critics attack along correctness, parity-gap, false-parallelism, security, platform-idiom, performance, and accessibility lenses.
3. Critics default to refute-on-uncertainty.
4. Synthesis returns `GO`, `FIX`, or `PIVOT`.
5. `GO` requires evidence, not builder confidence.
6. `FIX` loops within the phase.
7. `PIVOT` escalates with the evidence that invalidated the route.

Shared gate names are fixed so Linux and Windows evidence can be compared:

| Gate | Foundation meaning |
|---|---|
| **G0** | De-risk and bind: prove engine/core, DB, cloud-trust, shell, native artifacts, and platform API feasibility before production fan-out. |
| **G1** | Foundation: freeze IPC, land Core split, freeze first PAL seams, prove engine-owned DB open path, and install a blocking CI lane. |
| **G2** | Engine parity: prove parser/quota/cloud/E2EE/membership behavior against golden fixtures and contract vectors. |
| **G3** | UI parity: prove all surfaces, visual identity, accessibility, performance, and reduced-state behavior on real shell surfaces. |
| **G4** | Advanced/high-risk: prove Computer Use, media, pet, helper privilege, audit, panic-halt, and red-team invariants. |
| **G5** | Distribution and certification: prove signed packages, update feeds, SBOM/provenance, source-offer compliance, and the full parity evidence ledger. |

### 10.3 Existing tests to mirror

- `OpenBurnBarDaemonServerTests` for real socket lifecycle/auth.
- `BurnBarRPCCapabilityTests` for method capability totality.
- `DatabaseEncryptionServiceTests` for app SQLCipher runtime and encrypted-file behavior.
- `BurnBarDaemonDatabaseCipherTests` for daemon cipher runtime-probed behavior.
- `tools/schema-sync/check-drift.sh` and Fast Feedback schema job for generated schema drift.
- `AppSkinEditorialPaletteTests` and `SwarmLogoShapeTests` for visual token/glyph invariants.

---

## 11. Software-factory execution model

Desktop-port work must use the software-factory PR loop as a safety mechanism, not a quality laundering mechanism.

Rules:

- Smallest coherent reviewable unit wins, unless a larger atomic slice is safer and fully mapped.
- Phase 0 spikes are draft/spike lane until their exit criteria pass.
- Shared files have single owners. `project.yml`, package manifests, TypeSpec canon, design-token emitters, and parity budgets are merge-queue choke points.
- Cross-agent receipts are mandatory on PRs touching the engine IPC contract.
- Every workstream has an integration branch when parallel fan-out would otherwise thrash shared seams.
- No PR claims parity without the evidence artifact named in the relevant contract.

---

## 12. Ratchets and budget counters

Add these as soon as the first peer-desktop production PR lands:

| Ratchet | Direction | Failure condition |
|---|---|---|
| `desktop_engine_ui_imports` | hard zero | `SwiftUI`, `AppKit`, `UIKit`, `Firebase` in engine/model targets. |
| `desktop_ipc_untyped_methods` | hard zero | IPC method without TypeSpec schema and capability classification. |
| `desktop_schema_drift` | hard zero | generated TS/Swift/Kotlin/JSON schema drift. |
| `desktop_parser_fixture_count` | grow-only | portable parser corpus shrinks. |
| `desktop_parity_rows_green` | grow-only | completed parity rows regress without decision record. |
| `desktop_visual_snapshots` | grow-only | proof book loses certified surfaces. |
| `desktop_sqlcipher_cross_open` | hard required | cross-open vector absent or failing for public builds. |
| `desktop_release_trust` | hard required | public artifact without feed/signature/SBOM/provenance. |
| `desktop_secret_plaintext_fallback` | hard zero | DB/identity/refresh keys stored in disallowed fallback. |

---

## 13. Known caveats and corrections

| Caveat | Foundation handling |
|---|---|
| `OpenBurnBarCore` is not UI-free today. | Core split is a prerequisite, not cleanup. |
| Daemon IPC is JSON-envelope RPC, not strict JSON-RPC 2.0. | Docs and codegen name the actual envelope. |
| Daemon can directly open SQLite despite stale docs saying otherwise. | Foundation records transitional shared-DB reality and forces ownership decision per platform. |
| TypeSpec adoption is real but partial. | New schemas start in TypeSpec; legacy hand models remain during migration. |
| SQLCipher daemon behavior is runtime-probed in tests. | Port docs avoid unconditional daemon encryption claims until the package/runtime mismatch is resolved. |
| Linux/Windows App Check is not solved by Apple posture. | Platform plans must define lower-trust/custom-attestation before cloud parity. |
| Media zero-copy is hardware/compositor-dependent. | Validation measures true copy class; docs never promise universal zero-copy. |
| UI shell convergence is useful but not guaranteed. | Engine/IPC/parity convergence is mandatory; shell convergence is decided by evidence. |

---

## 14. Do not build

Do not build:

- a second engine protocol beside TypeSpec/generator-backed IPC;
- a Linux-only or Windows-only parser model;
- a cloud-only desktop companion and call it peer parity;
- plaintext or silent lower-trust secret fallbacks;
- a UI token fork that cannot round-trip to Aurora/Editorial sources;
- a release artifact outside SBOM/provenance/source-offer controls;
- a Computer Use path that bypasses approval/audit/kill-switch semantics;
- a one-shot mega-PR that mixes Core split, DB extraction, cloud attestation, shell UI, release packaging, and parity certification.

---

## 15. References

- [`OPENBURNBAR_RELEASE_ARCHITECTURE.md`](OPENBURNBAR_RELEASE_ARCHITECTURE.md)
- [`DIRECTION.md`](DIRECTION.md)
- [`architecture/004-schema-canon.md`](architecture/004-schema-canon.md)
- [`architecture/008-remote-control-engine.md`](architecture/008-remote-control-engine.md)
- [`LIQUID_GLASS_PARITY.md`](LIQUID_GLASS_PARITY.md)
- [`EDITORIAL_SKIN.md`](EDITORIAL_SKIN.md)
- [`RELEASE_MACOS.md`](RELEASE_MACOS.md)
- [`SOFTWARE_FACTORY_PR_LOOP.md`](SOFTWARE_FACTORY_PR_LOOP.md)
- [`WINDOWS_PORT_MASTER_PLAN.md`](WINDOWS_PORT_MASTER_PLAN.md)
- [`LINUX_PORT_MASTER_PLAN.md`](LINUX_PORT_MASTER_PLAN.md)
