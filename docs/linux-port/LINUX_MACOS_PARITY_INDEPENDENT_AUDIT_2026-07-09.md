# Linux/macOS Parity Independent Audit

| Audit field | Value |
|---|---|
| Date | Baseline audit: 2026-07-09; remediation evidence through 2026-07-23 UTC |
| Gold standard | OpenBurnBar for macOS |
| Linux target | `apps/linux-desktop` plus the shared OpenBurnBar daemon |
| Baseline checkout | `windows/liquid-glass-kernel-reskin` at `18836ae40a` |
| Current status | **Proof infrastructure: 40/40 owners**, committed at `df1852fae2`; the exhaustive registry/preflight suite passes **44/44**. **Implemented product behavior: approximately 80%** by the audit's source-level classification. **Strict certification: 0/40 requirements and 0/7 environments.** Ownership means every requirement has a fail-closed producer/materializer/validator path; it does not mean the behavior exists completely or has passed on a signed installed candidate. |
| Latest source delta | `336ee0eca2` adds a daemon-owned, durable all-time usage projection and explicit recount over the canonical ledger; `736fcae8a9` makes the renderer reject inconsistent or out-of-range aggregates. `e4e4c15bdb` adds Copilot session-state/log parsing, rotation-safe event deduplication, bounded token accumulation, durable cumulative checkpoints, restart-safe delta recording, and Linux daemon scheduling; `dd78a83bef` expands the Linux default registry to all 18 previously implemented core parser identities, and `5a37e88f8e` adds the remaining nine local-log lifts (Aider, Cursor SQLite, OpenCode SQLite, Pi Agent, OpenClaw, Ollama, Junie, and Z.ai/MiniMax model filters) with exact-vs-estimated provenance tests. `e7531159b3` adds active-entitlement Stripe Billing Portal routing with production callable framing, App Check, bounded requests, and strict native URL validation. `b45f6378e9` plus `45926a4fac` add the injected P-16 daemon RPC/runtime, encrypted local-first replica engine, and atomic authoritative conflict reconciliation with fail-closed acknowledgements and consent-aware pending state; `6d71bc8aff` adds the daemon-owned Firebase callable gateway, transactional idempotency/merge handlers, strict endpoint allowlisting, and production runtime composition (`7a8391acb5`). `e9923ca4c4` starts and stops a cancellation-safe daemon background sync loop, `dd95895ee9` falls through approved native secret stores when one is locked/unavailable without weakening trust refusal, and `c8b9a9ec4d` adds the portal-backed PipeWire-to-Opus Mercury audio adapter with fail-closed native linking and lifecycle tests. `2df8b03a5a` hardens the Linux Iroh directory client with an explicit HTTPS host allowlist, and `8776a196f6` adds daemon-owned Cloud Sync and metadata-consent controls to Linux Settings with fail-closed readback/error states. `24e1bae875` and `cb118e647f` add a bounded, live-route-gated Iroh remote-read RPC boundary and daemon-composed ECIES credential escrow; plaintext credentials never cross the renderer or persist in the escrow bridge. `d814f85f49` adds the authenticated Mercury call-invite seal contract, fail-closed call acceptance, and portal-backed outbound Opus capture with independent sequencing and teardown tests. `3bda513f65` adds daemon-owned trusted-device list/approve/revoke contracts with bounded redacted validation and unavailable-by-default composition; `bcf0b1a7bf` adds native inbound sealed Opus playback through GStreamer `opusdec`/`autoaudiosink`, bounded packet ingress, capability probing, and route teardown; `ffcae66d4b` wires the trusted-device contract through Linux Settings and Tauri and exposes playback capability state without fabricating devices; `cc9ad63f7a` adds the bounded native Firebase callable adapter with companion-owned credentials and nonce/action-proof injection; `b90945e411` validates the manager session before asking the companion to mint proof; `17d909ab5a` classifies malformed manager credentials as rejected rather than device-ID errors. Focused checks are green: Hermes wire protocol 18/18, Linux Settings/decoder/bridge tests 112/112, Tauri Rust 135/135, Swift trusted-device adapter parse, a clean macOS daemon build, production frontend bundle, and Linux-target Swift parsing. A focused physical-iPad settings test passed 1/1 on the attached device at this head. These are meaningful advances within partial rows. Remaining gaps are companion/Iroh credential/proof injection, live Linux GStreamer/PipeWire output proof, and live signed/device/environment proof. |
| Latest continuation delta | `e3765be861` makes Linux Mercury inbound-download destination selection atomic with `O_EXCL`, preventing concurrent transfers from reserving the same user-visible filename; the Linux media regression exercises 32 concurrent reservations and verifies unique existing paths. `b13b191f82` preserves data-backed PDF/image `input_file` parts when an OpenAI Responses request falls back to Chat Completions, and fails closed for unresolved file IDs or remote URLs instead of silently dropping the input; focused conversion regression coverage was added. `26dd3cbc30` preserves model-authorized PDF attachments through the Anthropic compatibility route by mapping the shared macOS/Linux data-URL shape to Anthropic `document` blocks and mapping those blocks back to the OpenAI-compatible PDF shape; the package compiled and the focused gateway test was added, while local XCTest execution remains blocked by the missing SQLCipher runtime loader. `fc30202f6b` aligns daemon chat attachment policy with the Tauri model-authorized PNG/JPEG/WebP path; focused Swift/Rust/frontend tests pass 4/4, 4/4, and 3/3. `b96ea13e24` records a fresh physical-iPad Settings/navigation selector at 1/1 on the current source head. The UTM guest's stale root-level crash-looping systemd unit was disabled while the packaged per-user daemon stayed active and the CLI health probe returned `ok=true`. These are bounded source/environment receipts; signed current-candidate binding, Firebase/App Check trust-cycle execution, remaining provider/binary breadth, and the remaining environment matrix are still open. Earlier source deltas remain: `96e021053b` raises the shared activity snapshot migration window from the legacy 80 conversations to a bounded 10,000-session window and adds a 10k-session/100-project regression; `92d87249ea` and `6a87c4ccc4` make P-39 producer evidence attest real runtime metadata; `2298e68f49` plus `058ff3c049` derive Linux parser registration from the generated catalog; `a6f3ec2b0f` centralizes macOS quota adapter coverage; and `b46f16c6ed` fences stale chat capability before send. These commits reduce source-level gaps but do not create live signed or cross-environment receipts. |
| Current continuation delta | `98e8ac02d1`, `29af365384`, and `e6b5539847` add macOS-aligned Linux swarm preferences: provider selection, brand-shape exclusion, auto-cycle, settled-shape sparkles, motion speed, and opt-in click cycling. The catalog now carries all 33 macOS provider IDs; baked point tables remain deterministic, while missing tables use bundled logo rasterization and a readable monogram fallback. `427e86f63f` preserves deterministic macOS provider/model color roles through quota cards, provider cards, overview spend curves, and provider fallbacks. `ea07f5cb99` expands the native tray with Summary, Providers, Mercury, and Quick Switch entries and pins every new entry to a registered shell route. `90124fef88` adds bounded GNOME/KDE/XFCE native wallpaper application and `71c07448e4` wires it through the typed bridge and Appearance settings with status/error readback. `f4b113e6ac` extends the adapter to trusted Sway and Hyprland IPC and `53c45ff60c` adds the macOS Constellation Style preset to persisted Linux Appearance settings and the real swarm engine; the renderer decoder now accepts those native backends. `56ee050bf3` adds real Wayland `CreateSession`/`BindShortcuts` registration and `Activated` event dispatch through the typed portal capability path; `1acf69a9a2` binds every event to the exact active session object path before dispatch. `e194567e74`, `f4b113e6ac`, and `f3c2e4e8ca` retain bounded trusted portal probing. `1f6f2e9383` fails closed on malformed or expired onboarding cloud-auth operations, while `404e425a2e` requires exact provider/label/enabled-slot credential readback before onboarding can report success. The current wallpaper implementation now captures a validated local GNOME/XFCE/Hyprpaper path before the first palette change, persists it owner-only, and exposes a typed accessible restore action; queryless KDE/Sway restoration remains explicitly unavailable. The current frontend gate is green at 107/107 files and 1002/1002 tests, with typecheck, lint, Vite build, and the production bundle verifier passing; the host Rust gate is green at 153/153 tests. These are source/build advances only; live portal consent/event receipts, prior-wallpaper compositor receipts, installed device/compositor receipts, signed current-head artifacts, and the strict 0/40 + 0/7 ledger remain open. |
| Latest continuation delta | `77db7deb8d` adds owner-only prior-wallpaper capture/restore with fail-closed local-path validation and an accessible Appearance action; `a676e48e8b` makes runtime text-expansion capability follow authenticated daemon status; `d70aacf81e` and `c908a2fc6a` reconcile the visible parity ledger and audit rows with the signed IBus implementation. Focused package/engine tests pass 31/31, native-shell source tests pass 15/15, frontend typecheck/lint pass, and the preceding full gates remain green at 106/106 frontend files, 992/992 frontend tests, and 152/152 host Rust tests. These remain source/package proofs only: Fcitx addon and sync, live keyring/IME secure-field receipts, signed candidate execution, compositor/portal/device receipts, and the strict **0/40 product + 0/7 environment** ledger remain open. |
| Latest safety hardening | `9c58df421d` requires explicit signed-feed verification and fresh metadata before Linux install, rollback, or download guidance is enabled; missing metadata now fails closed and leaves restart guidance available. `0c243ec95a` adds an honest Fcitx5 source-only capability contract across Tauri/AUR payloads and release validation, preserving no-global-capture and secure-field-denial invariants without claiming a native addon. Focused checks pass update UI 37/37, Fcitx contract 3/3, release validation, typecheck, and lint. Live signed feed/package execution, native Fcitx5, and the strict **0/40 product + 0/7 environment** ledger remain open. |
| Latest source hardening | `df2b1c8b57` keeps Support diagnostics honest by distinguishing explicit dialog cancellation from closed daemon sockets, timeouts, and permission failures; `b8fa7d5b17` requires exact daemon readback before a preferred quota account switch or clear-to-auto can refresh visible provider/quota state; `52a77d9ab1` gives the deck section switcher a real keyboard contract (focus entry, roving Arrow/Home/End, Enter/Space activation, Escape/outside-click handling, and trigger-focus restoration), with audit receipt `6f7489d768`. The stale pet surface fixtures were aligned to the canonical X11 companion contract at `c7bf394e04`. `379284d336` replaces manual absolute-path entry for Linux local and cloud account exports with typed, scoped native save dialogs, null cancellation, extension/path/symlink validation, and defensive bridge decoding. `151636ccbc` replaces manual recovery-bundle path entry with typed native `.obb` save/open dialogs and fail-closed cancellation/path validation; `c75b17ea07` does the same for encrypted database `.snapshot` save/restore flows while preserving distinct daemon contracts; `1504372a2d` extends the recovery picker contract to the Database workspace with cancellation announcements and trigger-focus restoration; `dd09dbf737` fences onboarding cloud-auth start/cancel responses across daemon bridge and fixture swaps; `81e471e511` replaces Mercury's manually typed outgoing file path with a native regular-file chooser and long-path-safe presentation. Focused picker coverage is 95/95, the full frontend gate is **107/107 files and 1011/1011 tests**, the host Rust gate is **156/156 tests**, and typecheck, lint, Rust format, Vite build, and production-bundle verification pass. These are source/build proofs only; live compositor, keyring/IME, signed-package/feed, device, and seven-environment receipts remain open and the strict ledger stays **0/40 + 0/7**. |
| Latest SmartHub hardening | `ca0f1605e1` clears the previous SmartHub device result as soon as a replacement typed probe starts, so stale reachability/control facts cannot remain visible during a pending native operation. The pending-state regression suite passes 10/10; live device, Avahi, and signed-environment receipts remain open. |
| Latest SmartHub control completion | `89bfaab3c3` exposes the already-supported `pixel_clock_control` native contract in the Linux SmartHub selector and adds regression coverage for the user-visible option. Focused SmartHub/decoder/bridge coverage passes 36/36; real Pixel Clock discovery/control and signed-environment receipts remain open. |
| Latest pet interaction completion | `51612362fd` adds a native companion close/re-summon action and a keyboard-accessible Wave/Open chat toolbar inside the companion child, while preserving the contained fallback and explicit click-through contract. Focused pet/bridge/window coverage passes 74/74; native compositor, attachment-drop, avatar, and live desktop receipts remain open. |
| Latest text-expansion sync surface | `9c5cc7abf2` exposes the existing daemon-owned encrypted cloud-replica status, explicit `text_expansion` consent policy, and bounded manual sync run through canonical Tauri/RPC contracts. `2026-07-23` hardening adds a daemon-owned global-consent provider to `LinuxCloudSyncRuntime`: status, policy mutation, manual sync, and the periodic loop now fail closed before identity, vault-key, or gateway access when the global cloud switch is off or unreadable. Settings now shows key-lock/backoff/pending/conflict posture and keeps snippet sync separately opt-in; credentials, vault keys, cursors, and payloads remain daemon-only. Full frontend coverage is 107/107 files and 1016/1016 tests; host Rust coverage is 156/156 plus 132 Linux gateway tests (one Linux-only test skipped). Native keyring/IME runtime, conflict receipts, signed candidate, and seven-environment proof remain open. |
| Latest database first-run hardening | `da9d6a5188` makes Linux provision a 256-bit database key in the approved native Secret Service/KWallet backend for a new or legacy plaintext profile before the daemon opens the shared database, then verifies persisted readback and migrates atomically through the packaged SQLCipher codec. `071fc7672e` preserves explicit injected keys for migration/test callers without forcing a Secret Service lookup. Encrypted profiles with an unavailable key remain fail-closed and are never assigned a replacement. Focused macOS daemon tests remain green (12 tests, 2 codec-gated skips); Linux-only injected-secret coverage is included for the ARM64 gate. The current pre-change VM still shows the expected locked database state until the new candidate is installed. |
| Latest packaging hardening | `59d49c7d59` makes an explicit staged `OPENBURNBAR_SWIFT_LIB_DIR` authoritative, `804ced4523` adds a read-only `OPENBURNBAR_LINUX_REUSE_STAGED_PAYLOAD=1` validation path for Swift-less hosts, and `aa188d24fa` makes Cargo invalidate generated Tauri context when hashed frontend assets rotate; `ded781e94d` adds route-level render recovery; `8cafd2d7e0`, `da42c16a78`, and `872074af3a` add provider-catalog, daemon-subscription, and SmartHub shell-loss reliability guards; `e6c32ec2b2` repairs stale provider selection after catalog refresh; `465431d0fc` hardens startup forwarding; `7ac2e021c9` makes Browser Computer Use capability checks fail closed; `c0a725447d` adds a trusted embedded autostart fallback; `447abb0564` fences stale Mercury capability responses; `9e868e60a7` refreshes tray state periodically; `3e7ede75e3` bounds expired browser authorization polling; `ebab7da744` fences stale concurrent version/feed responses; `534d7aae65` completes overflow-menu keyboard/focus behavior; `519f0456a7` adds a packaged-shell reconnect action for degraded daemon health; `811d84172a` queues native notification actions until renderer bootstrap completes; `66b280162f` fixes the Linux-only AppHandle ownership path caught by the ARM64 build; `b2c8579835` fences stale/overlapping diagnostics exports across bridge replacement; `90fac18c86` scopes the test-only notification queue helper so release builds stay warning-clean for that path; `7c5b68d750` matches macOS loopback-only CORS/preflight behavior for buffered and streamed gateway responses; `106b15855b` retains the last good mission snapshot during transient refresh failure; `e4f14c4387` avoids duplicate SmartHub health/control probes; `9f1bd7ca8c` wires Mission Inspect logs; `5e1a2dd962` routes Import sessions to Activity; `2ad3b2752d` brackets IPv6 device endpoints; `10c26c9a5d` makes Appearance radios keyboard-navigable; `2b64049552` fences stale Computer Use authority/approval responses; `3258104c1a` retains Activity snapshots across refresh failures; `f9bf08c600` fails closed from a broken X11 pet child; `e114bca710` retains stale signed-update facts while blocking package mutation; `36514bee98`/`72afa18f7e` force and validate native GStreamer Mercury packaging; `af31748ece` stabilizes the SmartHub bounded-output guard/test fixture; `41a9381e9e` exposes recovery-bundle controls in Data & Privacy; `7cdeb0ab85` adds daemon-backed project history; `1eae2dcc7e` preserves quota provenance and canonical provider aliases; `c0853c29af` splits heavy routes into lazy chunks; and `90c5bd34ca` keeps Support error wiring synchronous. Source-only checks are green at 873/873 frontend tests, 129/129 host Tauri Rust tests, and 130/130 media-enabled Rust tests on Ubuntu ARM64; the current shell receipt is non-certifying because the daemon/CLI remain staged. |
| Latest VM proof | The exact `5571e65f85` Ubuntu 24.04 GNOME/X11 ARM64 DEB is 152,137,340 bytes with SHA-256 `5c3218d60fc188df6102c683628e9b0dcae77d80167b724dcad4fdb8df01483`. The clean guest build preserves all 12,456 tracked source blobs; all 163 regular package files match their installed bytes; desktop, daemon, CLI, iroh, linkage, daemon service, and CLI health checks pass; and no stale `/usr/local` product process is present. Live QA exposed and fixed a startup race where `main.tsx` and `App.tsx` could drain the same initial deep link. After `5571e65f85`, three of three true cold starts with `openburnbar://providers?provider=codex` selected Codex and passed AT-SPI at 189 nodes / 108 named / 91 actionable with zero failures. Receipt: [`evidence/parity-audit-2026-07-10/linux-arm64-current-5571e65f85-exact-native-2026-07-20.json`](evidence/parity-audit-2026-07-10/linux-arm64-current-5571e65f85-exact-native-2026-07-20.json). Screenshot: [`evidence/parity-audit-2026-07-10/linux-arm64-current-5571e65f85-provider-deep-link.png`](evidence/parity-audit-2026-07-10/linux-arm64-current-5571e65f85-provider-deep-link.png). The receipt remains explicitly non-certifying because the installed manifest is the unsigned `{}` placeholder, production cloud identifiers are absent, and the remaining environment/device matrix is open. |
| Historical remediation evidence | Earlier installed candidates (`5b70a3d320`, `1b80f2ca08`, and the `50d40b9acb` kernel capability slice) remain preserved under `evidence/mission-002-reanchor/` and explain the staged-payload, first-paint, WebKit, Settings, and accessibility fixes. The WebKitGTK probe still reports `webgl2=false`, `webgl1=true`; the current package visibly uses the Canvas2D fallback with an explicit `WebGL2 unavailable` label. Historical focused physical-iPad receipts remain bound to their recorded source commits. Signed provenance, the hosted architecture/compositor matrix, cross-device proof, and the strict product/environment receipts remain open. |

## Exact-head Linux gate checkpoint — 2026-07-23

The corrected Linux PR Gate run `30036735995` passed at head
`cd4caaf4d2226f226efc59548cd77abb93319233`. Its macOS matched-performance
reference and Linux fast package/parity job both passed, including the complete
Linux parity-ledger and release-integrity suites, Linux desktop typecheck/unit
tests/build, Linux Swift package tests, the native Swift/Rust behavior manifest,
and IPC drift validation. This head includes the Linux first-run SQLCipher key
provisioning fix (`da9d6a5188`), explicit-key migration bypass
(`071fc7672e`), the AUR Fcitx capability fixture correction (`2869b88a24`),
and the refreshed native test manifest (`cd4caaf4d2`). These are source and
hosted-CI proofs only: the installed UTM guest remains stopped and is still the
pre-change package, while signed current-candidate execution, production
credentials, and the strict **0/40 product + 0/7 environment** ledger remain
open.

## Current integration branch checkpoint — 2026-07-23

The parity integration branch is now at `f26af7e1cf`. This head contains a
CI-only SwiftLint correction in `BurnBarLinuxOnboardingServiceTests.swift`:
the two boolean assertions reported by the hosted SwiftPM gate now use the
specific `XCTAssertEqual` matcher. Local SwiftLint passes for that file, and
the change is pushed to both GitHub and GitLab in PR #1930. The fresh hosted
checks have reported no failures while the remaining native, mobile, and
security jobs continue to run.

The host-only onboarding test compiled its product and test bundle but could
not launch the XCTest bundle because the local Xcode runner could not resolve
the existing `SQLCipher.framework` `@rpath` dependency. This is recorded as a
test-environment limitation, not a passing behavior receipt. UTM/QEMU is
intentionally stopped; no new installed Linux or desktop-environment evidence
was collected, and the strict **0/40 product + 0/7 environment** ledger is
unchanged.

## Latest verification checkpoint — 2026-07-22

The integration branch's hosted Linux gate is green at commit
`4fb5bffe6f558797f5a029dab6ad061624ee7165`. All 29 job steps passed, including
the full Linux Swift/Rust behavior manifest, desktop typecheck/unit/build,
release and package contract checks, matched macOS/Linux performance comparison,
and the IPC drift gate. The final native behavior suite includes the complete
daemon manifest rather than the reduced list that had been accidentally staged
during the earlier timeout repair.

The Linux freedesktop notification bridge now bounds the `/usr/bin/notify-send`
process, terminates a stalled invocation, and preserves a typed timeout instead
of blocking the daemon actor indefinitely. The native test manifest includes a
regression case for the stalled-process path. This closes a reliability gap in
source and tests; it is not installed-environment certification.

Exact-head hosted verification for this change is run `29894925872`, Linux job
`88843437034`; all 29 steps passed, including the native Swift/Rust behavior
suite and IPC drift gate. Machine-readable evidence:
`evidence/mission-002-reanchor/notification-timeout-2026-07-22.json`.

The Linux chat image path is now source-complete for model-authorized PNG,
JPEG, and WebP inputs. `BurnBarChatAttachmentPolicy` accepts and canonicalizes
the same image MIME types that the Tauri gateway stores, capability-checks, and
encodes as bounded data URLs; the shared policy regression covers extension
inference, explicit MIME values, and rejection of unsupported audio. This
removes the prior daemon-side rejection that made the implemented gateway
image path unusable after message persistence. Provider-specific backend
coverage, PDF input semantics, and installed-candidate proof remain open.

The malformed/incomplete HTTP frame test is deterministic now: the Linux raw
request helper half-closes its write side after sending the intentionally short
body, so the gateway returns its typed error immediately instead of waiting for
the receive timeout. The focused Docker Linux reproduction passed in 0.015 s.

A physical iPad navigation smoke also passed one test with zero failures. This
is deliberately recorded as focused evidence only. The strict P16 trust-cycle
receipt was not fabricated because no signed current-candidate binding,
coordination request, or Firebase/App Check configuration was available. The
live UTM Ubuntu 24.04 ARM64 guest built the exact product-source daemon and CLI,
passed both help probes, and returned healthy native AF_UNIX status; those
binaries remain unsigned and do not replace installed-package certification.

Machine-readable receipt:
`evidence/mission-002-reanchor/continuation-2026-07-22.json`.

### Local frontend verification — 2026-07-22

After restoring the locked `apps/linux-desktop` dependency set with
`npm ci --ignore-scripts`, the current branch passed the complete local
frontend gate: Vitest **100/100 files and 958/958 tests**, TypeScript
typecheck, ESLint with zero warnings, Vite production build, and the Linux
production-bundle verifier. The build warnings are limited to existing
Rollup dynamic-import/chunk-size advisories; the bundle verifier reported no
failures. `node_modules/` and `dist/` were removed after verification. This is
source/build evidence only and does not advance the strict **0/40 product** or
**0/7 environment** certification counters.

### Onboarding provider-route verification — 2026-07-22

The required Linux `provider_paths` onboarding probe now performs an
asynchronous daemon-owned configuration read in addition to checking the
writable XDG support directory and bundled catalog. It only verifies the step
when at least one enabled routing provider has either a Linux-local endpoint or
a readable credential; disabled providers and credential-less cloud catalog
rows no longer satisfy first-run setup. The config store exposes this as a
redacted provider-ID projection, so no credential material crosses the
onboarding contract. Focused daemon target compilation passed after the change,
and the focused XCTest bundle compiled; execution on the host remains blocked
by the existing missing `SQLCipher.framework` runtime loader. This closes a
source-level onboarding false-green path but does not advance the strict
**0/40 product** or **0/7 environment** certification counters.

### Public Linux download trust gate — 2026-07-22

The Linux release plan's missing public-download gate is now implemented in
`scripts/ci/verify-public-linux-download-trust.sh` with a focused contract test
and `.github/workflows/public-linux-download-trust.yml`. The verifier parses the
exported `SITE` object (not regex decoys), requires HTTPS/version-bound AppImage,
deb, rpm, and PEM names, downloads each artifact and its detached Ed25519
signature, verifies the signatures with the published key, and validates the
signed `latest-linux.json` feed plus version alignment. The workflow has separate
metadata/code checks and live-public checks, supports pull requests, merge queues,
main pushes, and manual runs, and fails closed when public artifacts or feed trust
are absent. Merge-queue workflow validation now requires this Linux trust check.
This closes the release-gate implementation gap but cannot certify the current
public site until a signed, current Linux release and feed are actually published;
the strict ledger remains **0/40 product** and **0/7 environment**.

### Reduce Transparency shell parity — 2026-07-22

The Linux shell now listens to the desktop `(prefers-reduced-transparency:
reduce)` preference for the full window lifetime. `a11y.ts` applies and removes
the `body.reduced-transparency` class on live preference changes, including the
legacy MediaQueryList listener used by older WebKitGTK versions. The shared
shell CSS disables backdrop filters and maps Liquid Glass surfaces to opaque
skin-aware tokens across lazy-loaded routes; onboarding is covered by the same
fallback rather than relying only on its prior media query. Focused lifecycle
and stylesheet contract tests cover the modern and legacy listener paths. The
General settings pane also persists the continuous `-1…+1` transparency range,
with Frostier/System/Clearer status text, and selects skin-aware Liquid Glass
token presets.

This closes the source-level transparency preference gap in the visual-preference
slice. Installed compositor/WebKit receipts and the remaining per-layout
`sidebarThemeGlass` palette are still required; the strict ledger remains
**0/40 product** and **0/7 environment**.

### Linux Tauri observability bootstrap — 2026-07-22

The Linux Tauri shell now has a held Rust Sentry client guard in
`apps/linux-desktop/src-tauri/src/observability.rs`. It validates
`OPENBURNBAR_SENTRY_DSN` (or the legacy `BURNBAR_SENTRY_DSN`) before calling
the SDK, keeps missing or malformed configuration non-fatal in normal
development, and refuses startup only when strict observability is explicitly
requested. The client uses the `linux-desktop` environment, a version-bound
release name, `send_default_pii=false`, zero trace sampling, and a scrubber
that removes identity, request, message, context, tag, extra, and breadcrumb
payloads while retaining crash/stacktrace signal. The guard is managed by
Tauri for orderly event draining at shutdown. Four focused Rust tests cover DSN
parsing and the privacy boundary.

This closes the Linux shell's source-level Sentry bootstrap gap. A configured
production DSN, captured event, and release-environment receipt remain
external evidence requirements; the strict ledger remains **0/40 product** and
**0/7 environment**.

### Linux per-layout ThemeGlassPalette — 2026-07-23

The Linux shell now mirrors macOS `ThemeGlassPalette.glass(for:)` for all six
dashboard layouts. `dashboardGlassPalette.ts` keeps the mapping total and
typed, while the root `data-dashboard-glass` binding lets CSS resolve the
semantic tint, wash-top, wash-bottom, and rim roles against the active skin.
Top Chrome consumes those roles for its wash, selected-tab rim, icon tint, and
focus glow, so changing layouts changes the glass identity without hard-coded
component colors. The role mapping and CSS token contracts are covered by
focused tests, and the existing reduced-transparency rules still override the
glass surface itself.

This closes the source-level per-layout glass palette gap. Top Chrome and the
sidebar now consume the same roles. Installed visual comparison receipts
across the compositor matrix are still required; the strict ledger remains
**0/40 product** and **0/7 environment**.

### Linux ProTheme membership surfaces — 2026-07-23

Linux membership cards, bands, crests, and foil buttons now consume a shared
ProTheme token vocabulary matching macOS/iOS: obsidian and elevated obsidian
plates, mercury text, aureate foil, ember-pop accents, the dark aurora ribbon,
and the 18/14px Pro corner radii. The existing React components remain the
behavioral surface; this change aligns their visual roles instead of adding a
second component system. The token contract now fails if any required ProTheme
role disappears.

This closes the source-level ProTheme token gap. Installed membership visual
receipts, entitlement-state coverage, and live billing/account evidence remain
required; the strict ledger remains **0/40 product** and **0/7 environment**.

### Linux desktop wallpaper palette — 2026-07-23

Linux Appearance settings now carry the full eleven-case macOS
`DesktopWallpaperBackground` vocabulary. The validated local preference drives
the root dataset and CSS palette beneath both the live kernel canvas and the
Canvas2D/CSS fallback, so WebGL2 absence does not erase the selected mood.
Selection is exposed as a native Linux select control with descriptive copy.

This closes the source-level wallpaper palette gap. Native desktop-wallpaper
installation, live wallpaper panels, and installed compositor receipts remain
open; the strict ledger remains **0/40 product** and **0/7 environment**.

### Linux native desktop wallpaper adapter — 2026-07-23

The Tauri shell now exposes a bounded native wallpaper adapter for GNOME,
KDE/Plasma, and XFCE. `desktop_wallpaper_apply` validates the same eleven
macOS palette identifiers, writes an owner-only SVG atomically under the XDG
data directory, invokes only the detected desktop's native wallpaper command,
and returns an explicit ready/applied/degraded/unsupported status. GNOME's
dark URI is best-effort for older schemas; the light URI remains authoritative.
The status command and focused Rust tests keep command availability, URI
escaping, path safety, and unsupported compositor behavior honest.

The adapter now also covers Sway through trusted `swaymsg` IPC and Hyprland
through trusted `hyprctl` calls to a running `hyprpaper` service. Sway's output
wildcard is passed as an argument (never through a shell); Hyprland preloads
the image before switching it, so a decode failure leaves the current image in
place. Those backends report unavailable when their fixed root-owned
executables are absent.

This closes the source-level native wallpaper installation adapter gap for
those desktop families. The Appearance settings control now calls the typed
status/apply bridge and surfaces applied/degraded/unsupported state. The
remaining gaps are installed compositor receipts, restoration of a user's
prior wallpaper, and live wallpaper panels; the strict ledger remains **0/40
product** and **0/7 environment**.

### Linux prior-wallpaper restoration — 2026-07-23

Commit `77db7deb8d` extends the native wallpaper adapter to capture the current local wallpaper before
the first BurnBar palette change and stores only a bounded owner-only record.
GNOME URI output, XFCE paths, and Hyprpaper JSON are decoded and validated as
absolute regular local files; remote URIs, malformed output, missing files,
and queryless KDE/Sway backends fail closed. Appearance settings exposes a
typed `restoreAvailable` status and an accessible **Restore previous
wallpaper** action. A successful restore removes the snapshot so the next
palette change captures a fresh user wallpaper rather than overwriting the
original baseline.

This closes the source-level prior-wallpaper lifecycle gap for queryable
backends. Live restore receipts on installed GNOME/KDE/XFCE/Sway/Hyprland
sessions, multi-monitor wallpaper panels, and the strict certification ledger
remain open: **0/40 product** and **0/7 environment**.

The post-change frontend gate is **106/106 files and 992/992 tests**; typecheck,
lint, Vite build, and the production bundle verifier also pass. The host Rust
gate is **151/151 tests**.

### Linux Constellation Style appearance mode — 2026-07-23

Linux Appearance now exposes a persisted **Use Constellation style** preset
matching the macOS `useConstellationBackground` behavior. When enabled, the
real `swarmEmber` backdrop forces the macOS cinematic speed (`0.55`), settled
sparkles, provider-only shapes, automatic cycling, and no click-cycle override;
the selected provider glyph catalog remains user-controlled. The preset is
implemented in the shared preference event path, so Canvas2D fallback hosts
receive the same effective kernel settings as WebGL2 hosts.

Focused state and settings coverage plus the complete Linux frontend suite pass.
This closes the source-level Constellation preset gap. Exact macOS raster/logo
equivalence, compositor rendering, reduced-motion visual proof, and installed
visual receipts remain open; the strict ledger remains **0/40 product** and
**0/7 environment**.

### Linux Wayland shortcut registration — 2026-07-23

The native shortcut status performs a bounded, trusted-path `gdbus`
introspection for `org.freedesktop.portal.GlobalShortcuts` on Wayland and
returns typed `portalAvailable`/`portalReason` fields through the renderer
bridge. The shell now uses the `ashpd` portal client for the asynchronous
`CreateSession`/`BindShortcuts` flow, preserves partial binding state, and
dispatches portal `Activated` signals to the same fixed dashboard, pet, and
Computer Use panic handlers used by X11. Preferred accelerators are a fixed
native mapping; renderer input cannot create a portal shortcut.

This closes the source-level Wayland registration/event-delivery gap. Live
portal consent, compositor receipts, partial-registration recovery, and
IME/input matrix evidence remain open; the strict ledger remains **0/40
product** and **0/7 environment**.

### Linux onboarding cloud-auth recovery — 2026-07-23

Onboarding now rejects pending cloud-auth states with missing, malformed, or
expired operation identity/expiry metadata. It stops unbounded polling and
stale cancel controls, explains the fail-closed state, and offers a fresh
daemon-issued sign-in operation.

This closes a source-level reliability gap in onboarding recovery. Live OAuth,
device approval, and production cloud evidence remain open; the strict ledger
remains **0/40 product** and **0/7 environment**.

The provider credential step now also requires exact daemon readback of the
requested provider, label, non-empty slot ID, and `isEnabled=true` before it
refreshes route health or reports storage success. A stale or unrelated slot
therefore remains visibly unverified instead of producing a false-green
onboarding state. Secret Service, provider endpoint, and production OAuth
receipts remain live verification work; the strict ledger is unchanged.

### Linux external text-engine capability readback — 2026-07-23

Commit `a676e48e8b` makes the shell runtime-capability evaluator no longer hard-code system text
expansion as unavailable. When the authenticated daemon is healthy it now
reads `daemon.text_expansion.engine.status` and advertises the system
capability only when the daemon's signed-engine adapter reports
`supportsExternalExpansion=true`; missing registration, missing package
identity, or an unavailable daemon remain explicitly unavailable with the
daemon's bounded reason. This keeps the UI aligned with the already-packaged
IBus engine without ever promoting in-app expansion or an unverified binary.

This closes the source-level capability-readback mismatch. Live signed IBus
execution, secure-field denial, keyring custody, and the strict certification
ledger remain open: **0/40 product** and **0/7 environment**.

### Linux Fcitx5 package capability contract — 2026-07-23

The host does not provide `Fcitx5Core` development headers or a packaged native
OpenBurnBar addon, so this slice does not pretend to enable Fcitx5. Deb, RPM,
AppImage, and AUR payloads now carry an owner-readable
`fcitx5-openburnbar-addon.json` contract that explicitly reports
`source-only-not-packaged`, `runtimeSupport=false`, and `packageSupport=false`.
It records the required native headers and preserves the no-global-capture,
no-clipboard, no-surrounding-text, and secure-field-denial invariants. Release
validation checks every Tauri payload and the AUR recipe, and fails closed if
Fcitx5 is accidentally promoted before an exact signed addon build exists.

This closes the package-capability ambiguity without claiming runtime parity.
Building and signing a real Fcitx5 addon, live secure-field/consent execution,
and the Wayland/X11 receipt matrix remain open; the strict ledger remains
**0/40 product** and **0/7 environment**.

### Linux GlassCard / GlassButton primitives — 2026-07-23

Linux now exposes typed `GlassCard` and `GlassButton` components matching the
macOS interactive/embedded card vocabulary and prominent/regular/cool button
variants. The primary `SurfaceCard` route shell uses `GlassCard`, and the
settings database action uses `GlassButton`; shared CSS keeps the Reduce
Transparency fallback and hover/press behavior centralized.

This closes the source-level glass primitive gap. Installed visual and
accessibility receipts for every consuming surface remain open; the strict
ledger remains **0/40 product** and **0/7 environment**.

### Linux swarm speed and sparkle controls — 2026-07-23

Linux Appearance settings now expose validated macOS-compatible swarm motion
speed and settled-shape sparkles controls. Preferences persist locally and
publish a typed change event; `KernelBackdrop` rebuilds the active
`swarmEmber` kernel with the new options, including when the host has no
WebGL2 and is using the Canvas2D/CSS fallback.

This closes the source-level speed/sparkle subset of swarm customization.

### Linux swarm provider selection and cycle controls — 2026-07-23

Linux Appearance now persists the renderable provider-glyph catalog, exposes
All/None and per-provider checkboxes, and passes the normalized selection into
the `swarmEmber` formation builder. The same control surface also exposes
brand-shape inclusion and automatic cycling. Explicit empty selections are
preserved, stale IDs are rejected, and the provider-only default remains the
existing Linux behavior. Focused state, settings, catalog, and cycle-contract
tests plus the full Linux frontend suite pass.

This closes the source-level provider-selection and brand-shape/auto-cycle
subset. Linux also now supports opt-in click-to-cycle on the backdrop and
resets the automatic cycle timer after a manual advance. The catalog now
contains all 33 macOS provider IDs; missing baked point tables use bundled
logo rasterization and a readable monogram fallback. Constellation mode,
native wallpaper hosting, and installed visual receipts remain open; the strict
ledger remains **0/40 product** and **0/7 environment**.

### Linux provider and model color roles — 2026-07-23

Linux now applies deterministic macOS-aligned provider accents and model-family
colors to provider glyph fallbacks, quota cards, provider cards, and overview
spend curves. Known aliases such as Claude Code, Codex, Gemini CLI, and Grok
resolve to their provider colors; unknown model names use the same stable
palette-hash strategy instead of a single brass fallback.

This closes the source-level color-role subset. Full provider logo/theme asset
coverage and installed visual receipts remain; the strict ledger remains
**0/40 product** and **0/7 environment**.

### Linux full swarm provider catalog — 2026-07-23

The Linux swarm catalog now contains all 33 macOS provider IDs. Providers with
existing baked point tables keep deterministic formation geometry; providers
without baked points load the corresponding bundled Linux logo and rasterize
its alpha mask into points, then fall back to a readable provider monogram if
the asset is unavailable. Selection order, All/None behavior, explicit empty
selection, and stale-ID rejection remain covered by tests.

This closes the source-level catalog breadth and non-silent fallback gap.
Exact brand-shape equivalence for every provider asset, compositor rendering,
and installed visual receipts remain open; the strict ledger remains **0/40
product** and **0/7 environment**.

## Integration closeout — 2026-07-21

### Live UTM session re-open — 2026-07-21 (Grok)

### Exact-head Linux daemon product build — 2026-07-21 (Grok)

On the same UTM guest, `swift build -c release --product OpenBurnBarDaemon`
with Swift 6.1 succeeded after compile fixes in
`LinuxCloudAuthHTTPClient` / `LinuxIrohRemoteReadCredentialEscrow`
(head `f985370c83`). Binary SHA-256:

`23fa7b723efa2df56244fcb4204ef6c9caf4142ea73da1af44082459d973cc2e`

Evidence: [`evidence/parity-audit-2026-07-10/utm-exact-head-daemon-build-2026-07-21/`](evidence/parity-audit-2026-07-10/utm-exact-head-daemon-build-2026-07-21/).
This is engineering proof that the current head builds on Linux aarch64; it is
not a signed installed-candidate receipt and does not move the 0/40 or 0/7
strict counters by itself.



The Ubuntu 24.04 aarch64 UTM guest (`OpenBurnBar Linux`, `192.168.64.5`) is
reachable again over SSH with the guest agent active. Captured live receipts:

- Receipt directory: [`evidence/parity-audit-2026-07-10/utm-live-session-2026-07-21/`](evidence/parity-audit-2026-07-10/utm-live-session-2026-07-21/)
- Installed package `open-burn-bar 0.1.1 arm64` with daemon health `ok=true` (protocol 1)
- Desktop process running under GNOME X11 (`openburnbar-linux-desktop --background`; X window present)
- Secret Service (gnome-keyring) store/lookup OK
- PipeWire 1.0.5 + GStreamer `opusdec` / `autoaudiosink` / `pipewiresrc` present
- AT-SPI bus active

CI unblock at `6e65ce5508`: Xcode membership for Linux quota/media/escrow daemon
sources, gitleaks fixture key, and P-39 differential workflow ownership canon
aligned so the 40/40 preflight fixture authenticates again.

**Still not strict certification:** the installed package is not an exact-head
signed candidate, and this is only the `ubuntu-24.04-gnome-x11-aarch64` row.
Strict counters remain **0/40 product** and **0/7 environments** until signed
multi-environment receipts exist.



The latest implementation wave closes two previously named source gaps without
claiming they are live-certified. P-16 now has a daemon-only remote-read
boundary that validates the exact session/route tuple, requires a fresh
trusted-device authorization bound to the request ID, caps responses at 512 KiB,
and returns only bounded payload data. Its credential-escrow companion validates
the target public-key fingerprint/version, reads through the daemon credential
source, encrypts with Cloud Vault ECIES and metadata AAD, and never persists or
returns plaintext. The production convenience initializer composes the escrow
source with the existing Linux cloud credential authority. This is an
implementation contract, not proof that the corresponding production callable,
trusted-device approval, or cross-device transport is deployed.

Commit `3bda513f65` adds daemon-owned trusted-device list, approve, and revoke
contracts with bounded redacted records and an unavailable-by-default manager.
Commit `ffcae66d4b` wires those methods through the Tauri bridge and Linux
Settings without fixture devices. Commit `cc9ad63f7a` adds the bounded native
HTTP adapter for the deployed callable names; companion-owned credentials and
fresh nonce/action-proof injection are still required before mutations can
operate on a real account.

P-08 now requires every accepted Linux call invite to carry an openable
request-bound media seal before any PipeWire capture starts. Accepted calls
start the existing portal-backed Opus adapter, emit independently sequenced
`media.audio.out` frames sealed with MediaFrameAEAD, and stop capture on end,
route loss, seal failure, or capture failure. The canonical Swift/Kotlin relay
models and capability RPC advertise the seal/audio/video requirements. Linux
inbound frames now pass through the daemon-owned GStreamer Opus playback sink
(`opusdec` -> `autoaudiosink`) with bounded ingress and fail-closed cooldown on
missing output or rejected packets (`bcf0b1a7bf`). Frames remain available on
the shell media channel for compatibility, but the daemon owns native playback.
No cross-device call or live desktop-audio receipt has been certified.

The strict ledger remains **0/40 product requirements** and **0/7
environments**. Linux-only XCTest execution for these new files still requires
the Linux guest; the Mac host cannot substitute for that runtime proof.

The last broad source gate is **94 frontend files / 911 tests**, Tauri Rust
**133/133**, and **683 Linux-port Node cases / 678 passed / 5 environment
skips / 0 failures**, plus TypeScript, ESLint, production-bundle,
Cargo-formatting, Swift file-size, and core target-membership checks. The
current proof registry is complete at **40/40 owners** in `df1852fae2`, and the
exhaustive ownership/preflight inventory passes **44/44**. Those results prove
that no requirement lacks a fail-closed evidence path. They do not replace a
signed-candidate run or advance the strict certification counters. The
physical-iPad selected suite at `dd34c005fb` executed **6 tests, 1 expected
skip, 0 failures**; current P-16 device execution remains a separate live gate.

The exact installed ARM64 proof is now the `5571e65f85` DEB: **12,456/12,456**
tracked source blobs and **163/163** installed package files match, daemon and
linkage checks pass, and three of three cold-start provider deep links pass
with a clean screenshot and AT-SPI result. The unsigned `{}` manifest,
unconfigured production cloud auth, incomplete Wayland/package-format
collectors, and incomplete environment/device matrix remain non-certifying.

**Verdict:** **NO-GO for a full-parity claim or stable Linux promotion**

### Source continuation — 2026-07-21

The current source head includes the 10k-session project migration fix and the
current-version differential attestation. The Xcode project now includes the
usage-ingestion, trusted-device, and CloudSync daemon sources that had been
omitted from the native target, plus the missing `OpenBurnBarInsights` test
framework dependency. That removes the prior undefined-symbol failure, but
Xcode 27 now aborts during Swift package graph synchronization with an internal
`NSMutableArray insertObjects:atIndexes` count mismatch before the focused test
can run; this is an IDE/package-graph blocker, not a failure in the migration
logic. The selected P-39/resolver/differential
workflow suite passes 81/81, and the focused 10k-session migration test passes
1/1 on macOS, but a
real same-clean-commit macOS and Linux producer run is still required before
P-39 can become a certified row.

### Provider catalog closeout — 2026-07-21

`2298e68f49` makes `BurnBarLocalUsageIngestionService` derive Linux parser
membership and ordering from the generated `AgentProviderIngestionCatalog`.
A typed factory map covers all 27 local-parser identities, and an absent
factory fails closed instead of silently parsing an API-only or unavailable
provider. The regression test asserts exact catalog membership and order;
provider-catalog parity tests pass 12/12 and Swift syntax parsing passes. The
daemon build now compiles this path after `058ff3c049` corrected the factory to
the existing `CodexParser`; the focused test binary still cannot load its
SQLCipher framework in this macOS SwiftPM layout. API/quota/cloud sources,
installed corpus proof, and signed/environment certification remain open.

### Source hardening closeout — 2026-07-21

`a6f3ec2b0f` adds `ProviderQuotaAdapterRegistry` to the shared quota target and
rewires the macOS refresh actor to consume one canonical 19-provider table.
Seventeen live adapters and explicit unavailable entries for `cursorAgent` and
`openBurnBar` are tested 3/3; no usage-only provider is accidentally resolved.
`5000b5200b` hardens P-39 JSON evidence parsing against duplicate object keys,
including escaped spellings that normalize to the same key; `7bb470cfac` also
requires canonical UTC millisecond timestamps. The full targeted
P-39/differential/workflow gate passes 84/84. `18231a4a40` maps Linux quota
signal tiers to explicit API-backed, local-artifact, cached, or unavailable
provenance; its focused tests pass 4/4 and existing quota snapshot regressions
pass 7/7. `fb3afed33b` and `faa50c0e7a` make notification readback default
missing fields, bound valid ranges, preserve safe defaults, deduplicate hours,
and reject fractional values; settings and decoder coverage is green.
`df0822290b` requires daemon readback confirmation before a preferred-slot
mutation replaces the provider catalog. These are source-level improvements.
Linux quota transport, production cloud/API sources, signed packaging, and
live environment receipts remain open.

`708260e4f4` hardens the P-21 Insights proof validator to require canonical UTC
millisecond timestamps and reject mutated event timestamps; its focused suite
passes 3/3. `b46f16c6ed` closes a chat reliability hole by rechecking the
daemon-owned backend capability immediately before append/stream, so stale or
disabled selections fail closed without bridge calls; focused chat coverage
passes 50/50 with TypeScript typecheck. `09fd63e4e6` makes the Linux quota RPC
expose the
shared 19-provider adapter coverage (17 live, two explicitly unavailable) and
fails closed for missing registry entries; focused coverage passes 4/4. These
changes improve source parity and reliability only. Live populated data,
production API/cloud credentials, signed packaging, cross-device approval, and
the seven environment receipts remain open.

`8ede809724` adds a shared `ProviderQuotaSnapshotValidator` and applies it at
Linux quota snapshot materialization. Provider identity, expected-provider
matching, future timestamps, unavailable-source shape, and non-finite bucket
values now fail closed; focused validator coverage passes 5/5 and existing
quota snapshot regressions remain 7/7. `50d139047b` prevents stale overlapping
Activity list/search responses from overwriting newer rows, loading state, or
errors; Activity coverage passes 22/22. `44a5864b0d` and `7017227ac8` make chat
backend availability depend on daemon catalog routing capability, and fail
closed before append/stream when catalog evidence is missing; focused chat
coverage passes 52/52 for the capability slice and 33/33 for the live-send
regression. These remain source-level improvements; production services,
signed packaging, and live Linux execution are still required.

The connected physical iPad also passed the focused settings selector **1/1**
with `xcodebuild` exit 0 during this continuation. The receipt is
[`ipad-navigation-focused-current-source-wave-2026-07-21.json`](evidence/parity-audit-2026-07-10/ipad-navigation-focused-current-source-wave-2026-07-21.json).
It is intentionally non-certifying because the dependency build began from a
dirty source wave and the test does not exercise Linux enrollment or approval.

The final source verification wave adds `58974b8392`, giving the text-expansion
consent checkbox an explicit accessible name when native storage is degraded;
the previously failing regression now passes. The Linux app suite is green at
**100 test files / 954 tests**, TypeScript typecheck passes, the daemon builds
with an isolated SwiftPM scratch path, and the full P-39/differential/workflow
gate passes **84/84**. These are source and contract gates, not a replacement
for the still-required signed Linux guest, production, cross-device, and
multi-environment receipts.

Commit `530c51c259` removes another source-level gap from P-40: Linux Settings
now exposes a trusted-device/App-Check-gated cloud account export. The daemon
owns nonce-bound authorization, cloud credentials, response validation, and
owner-only file creation; the renderer receives only a bounded path/size/schema
receipt. Older shells and fixture mode remain visibly unavailable. The focused
Settings/bridge slice passes **112/112**, the Tauri Rust suite passes **136/136**,
and the daemon production build passes in an isolated scratch tree. Linux-only
privacy XCTest execution still requires the guest; the macOS host's test bundle
cannot load its SQLCipher framework and is not treated as Linux evidence.

### CI and release-contract closeout — 2026-07-21

The integration branch now also repairs the repository-wide gates that were
red on the preceding head. `d2300d2197` scopes the Ed25519 private-key check
to the unsigned build phase, avoiding a false failure from the separate signer
job, and synchronizes the AUR daemon launcher byte-for-byte with the canonical
launcher. `06274ccc40` regenerates the Functions authorization catalog,
removes the hand-maintained schema-surface overage, replaces the final empty
catch, and fixes Ruff's AT-SPI exception and UTC handling. Local gates are
green: Functions lint/build and 1,378 unit tests (four expected skips),
security 10/10 plus BOLA 84/84, schema drift, empty-catch budget, Ruff, Linux
release validation, and diff hygiene. These are source and CI quality gates;
they do not create signed-candidate, production, or seven-environment
certification receipts.

The current integration head `b27d98a696` also restores the
`BurnBarMissionControlServiceTests` class boundary that had left the project
lifecycle methods outside their XCTest type. A fresh SwiftPM scratch build of
the daemon test target now completes, and the focused mission-control suite
passes **80/80**. The attached physical iPad ran the current-source Settings
selector and passed **1/1**. These checks close the source/test regression only;
the normal PR daemon/Linux workflows have not yet attached to this SHA beyond
the trusted deletion guard, and the signed-candidate/live environment matrix
remains non-certifying.

## Current proof-ownership checkpoint — 2026-07-20

The implementation audit classifies six of the forty product rows as near
parity and thirty-four as partial; none are classified missing or broken. That
is an engineering-completeness view, estimated at roughly **80%**, not a release
certificate.

The fail-closed proof system now has registered candidate-bound ownership for
all forty requirements. Commit `df1852fae2` closes the final ownership gaps for
`P-15`, `P-16`, `P-33`, `P-35`, and `P-36`; the exhaustive registry and
preflight suite passes **44/44**. This is **40/40 proof infrastructure**, not
40/40 product parity. It means every row has an exact candidate-bound producer,
materializer, validator, workflow contract, mutation coverage, and named live
evidence expectations. It does not assert that every macOS behavior is already
implemented on Linux or that any row has passed the signed seven-environment
matrix. P-13 adds a fail-closed
installed onboarding lifecycle with required completion gates, catalog-backed
temporary credential setup and cleanup, privacy persistence, restart readback,
blocked/retry/skip recovery, and four distinct screenshots. P-20 adds a fail-closed
installed mission lifecycle covering approval, result/evidence, pending-question
answering, restart persistence, detail inspection, and two-step cancellation
through concrete daemon and AT-SPI receipts with five distinct screenshots. P-23
adds a fail-closed installed Provider workspace lifecycle covering two real
credential slots, deterministic failover, custom models/aliases/variants,
deep links, health states, restart persistence, exact restoration, AT-SPI, and
distinct screenshots. P-25 adds a fail-closed signed previous-to-candidate
native package lifecycle with exact package-manager receipts, a process-local
network outage, exact proxy restoration, rollback, data preservation, candidate
restoration, restart, and four distinct accessible UI states. None of these rows
claims a live signed-candidate pass until its workflow runs successfully.

P-24 adds fail-closed installed Settings ownership for all 16 searchable tabs,
with exactly four real reversible writes rather than a claim that every tab is
writable. Its candidate-bound proof exercises the installed daemon and AT-SPI,
restart persistence, XDG launch-at-login, degraded and recovery states, and
exact restoration of the prior settings, service, autostart, and privacy state.

P-26 adds candidate-bound native tray/background ownership with package-owned
autostart, live DBusMenu revisions, route actions, daemon disconnect/reconnect,
relaunch, accessibility, and exact service/process restoration. P-30 adds a
candidate-bound installed Pet Companion owner: X11 must prove the global
`Ctrl+Alt+Super+P` summon, native always-on-top child, explicit click-through
enable/restore, and relaunch; Wayland must remain on the contained substitute.
Both modes prove selection/clear, pointer and keyboard repositioning, focused
AT-SPI status, distinct screenshots, live runtime-manifest binding, package
identity, and exact prior-state restoration. These are registered producers,
not claims that the seven live signed-candidate environments have passed.

P-32 adds a candidate-bound installed performance owner. Its macOS and Linux
nightly producers use the same source digest, package version, immutable
candidate run and artifact digest; the Linux collector additionally binds the
packaged desktop session, route samples, comparison, budget verdicts, installed
manifest, and signature. Report freshness, disjoint collection windows,
relabeling, and source drift fail closed. The seven-environment signed-candidate
execution remains open.

P-27 adds a candidate-bound installed notifications and deep-link owner. It
uses the real Tauri/WebDriver surface, activates an actual freedesktop
notification action through AT-SPI, proves a notification reply queued before
renderer bootstrap is consumed after cold start, and rejects wrong-state and
replayed OAuth callbacks. P-28 adds a candidate-bound installed SmartHub owner
using the package-owned CLI, daemon launch path, and desktop process; it proves
live advertise/browse/discover/status/control, bridge loss and recovery,
restart behavior, AT-SPI, screenshots, and exact restoration. P-29 adds a
candidate-bound installed text-expansion owner using the package-owned IBus
engine in actual GTK free-form and password fields. It proves expansion in the
normal field, denial in the secure field, encrypted persistence and keyring
behavior, cancellation/kill/restart handling, AT-SPI, screenshots, and exact
restoration of the prior IBus engine and local state. Their focused proof and
workflow contract tests pass; live signed-candidate execution across all seven
environments remains open.

The five final owners make the remaining work measurable rather than complete:

- **P-15 Account and billing:** installed WebDriver/AT-SPI proof covers account
  state, authentication transitions, billing and recovery affordances, package
  identity, restart, and restoration. Production OAuth, membership, checkout,
  recovery, account deletion, and signed-candidate outcomes remain live gates.
- **P-16 Cloud and devices:** the Linux producer consumes a same-run receipt
  written by a dedicated physical-iPad producer through owner-only shared roots.
  It binds trusted-device list/approve/revoke, nonce and fingerprint identity,
  Linux state, restart, and cleanup. `b45f6378e9` additionally supplies the
  daemon-owned encrypted local replica core and injected status/policy/manual-
  cycle RPC runtime. Production Firebase gateway/process composition, Account
  UI, authorized Iroh remote reads, credential escrow, and a passing current
  signed-candidate iPad/Linux receipt remain open.
- **P-33 Reliability:** installed probes now own crash/restart, daemon loss and
  recovery, offline/online transitions, subscription continuity, stale-response
  fencing, bounded retry, and prior-state restoration. Multi-hour suspend,
  portal/keyring faults, migration recovery, and all-environment soak remain.
- **P-35 Diagnostics and support:** installed proof owns redacted bundle export,
  native destination handling, privacy/permission checks, degraded/reconnect
  states, package/runtime facts, restart, and restoration. Real signed packages
  must still pass on every supported desktop and failure mode.
- **P-36 Visual and interaction polish:** real Tauri WebDriver screenshots and
  AT-SPI receipts are required at exact compact, standard, wide, reduced-motion,
  and overflow states. The owner verifies DPR-1 viewport convergence, theme
  persistence, contrast, clipping/overlap, keyboard focus/menu behavior, restart,
  compositor identity, and restoration. The seven live visual baselines remain
  unexecuted for strict certification.

Strict promotion remains **0/40 product requirements** and **0/7 environment
receipts**. A row becomes strictly ready only after its signed candidate proof
and all required live-environment receipts validate. Source implementation,
registered ownership, installed proof, and strict promotion are therefore four
separate counters and must not be reported as one percentage.

## Post-main exact-native checkpoint — 2026-07-20

The branch now includes current `main` through merge commit `6bf0708eec` and
preserves both the Linux parity work and newer shared application behavior. The
merged source passes 94 frontend files / 910 tests, Tauri Rust 133/133, workflow
verifier tests 28/28, Linux Swift verifier tests 18/18, TypeScript, the
production-bundle verifier, and production Linux daemon and CLI builds.

Two Linux compile regressions found by the clean guest build are repaired:

- `8a17df54d2` introduces an unambiguous explicitly named AES-GCM nonce API for
  Swift 6.1 whole-module builds; `6aaae20226` fully qualifies that platform
  support call from the legacy crypto paths.
- `6aaae20226` makes the app-group container lookup Apple-only and returns an
  honest unavailable result on Linux, keeping the newly shared Insights target
  usable by the daemon.

`22fd7dfad9` completes the latest exact-head native package cycle. In addition
to the decomposed resource packaging introduced at `0eb6efcc1a`, this wave
reconciles post-merge CI contracts, removes 21 Linux force unwraps, and keeps
UI-only Observation conformance out of the Linux daemon dependency closure.
The latter fixes the Swift 6.1 ARM64 release-link failure while preserving the
macOS Observation behavior. Fresh release builds of both daemon and CLI pass.

The 152,116,006-byte ARM64 DEB has SHA-256
`72fb15222374ee5231aa53b498aba984e4b281e5c93fa359c4a4f53c29886522`.
Package-versus-installed hashes match for all native payloads and both resource
bundles; the daemon is active, CLI health is OK, and the native Codex deep link
passes AT-SPI at 189/108/91/33. The receipt and screenshot are linked in the
audit table above. The earlier `0eb6efcc1a` receipt remains historical evidence.

Strict promotion remains **0/40 product rows and 0/7 environment receipts**.
The package manifest is still the unsigned `{}` placeholder. External blockers
include production OAuth/App Check/callables, signed updater
and rollback, real keyring custody, the remaining compositor and architecture
matrix, real SmartHub and pet integration, physical-iPad Computer Use/Mercury
proof, and a same-commit macOS differential.

## Current implementation and installed checkpoint — 2026-07-20

The `bfd0eefea9` wave closes four additional source gaps and one live visual
defect without changing the strict certification boundary:

- `0fd663a3f5` and `5d10b95bc8` add reload-safe provider/model destinations,
  strict native parsing, bounded single-instance forwarding, browser-history
  restoration, and focused provider/model detail.
- `b76b67e8bc` adds a daemon-owned quota failover control with exact canonical
  readback and rollback. `8d9dba71fe` corrects both Quota and Settings to the
  macOS/daemon wire values `provider_family_failover` and
  `same_model_failover`.
- `b74bc6d068` distinguishes verified source IDs from display fallbacks and
  resolves fallback Activity rows only through complete, uniquely matched
  daemon history before replay, resume, export, or resume-from-export.
- `21a13a6792` wires onboarding to the existing native account status/start/
  cancel RPCs, including signed-out, browser authorization, device approval,
  denial, expiry, cancellation, retry, active verification, and unavailable
  states.
- `bfd0eefea9` declares the dark WebKitGTK native-control color scheme after
  installed visual QA exposed light system selects with low-contrast text.

The installed ARM64 package was built only after the relevant tracked source
digest matched between host and guest. A native second launch with
`openburnbar://providers?provider=codex` forwarded to the running app, selected
Codex, and exposed a passing AT-SPI tree with 189 nodes, 108 named nodes, 91
actionable nodes, and 33 focusable nodes. This is strong installed proof for the
new navigation route; populated Activity history, production OAuth, destructive
privacy, signed release lifecycle, other desktops/architectures, and physical
iPad cross-device workflows remain open.

## Prior exact-native installed checkpoint — 2026-07-20

The `b93e656645` package removes the staged-daemon qualification from the current
ARM64 proof. The guest checkout was reconciled to the tracked source set, stale
Swift files were removed, iroh and Mercury were rebuilt, and both Swift products
were compiled and staged fresh. Package, extracted payload, source build, and
installed hashes match for the daemon, CLI, and iroh runtime.

This wave also closes four source-level reliability gaps:

- `594dc668ab` retains the last successful Activity replay body after refresh
  failure and exposes an explicit retry without replacing useful content with
  an error-only state.
- `6b707d24b8` retains the last non-empty Quota catalog through loading and
  transient failure, labels stale provenance, preserves retry/error truth, and
  still treats an explicit empty catalog as authoritative.
- `9250e90092` requires privacy mutations to be confirmed by a canonical daemon
  config readback before Settings reports success; mismatched readback preserves
  prior UI state and fails closed.
- Live installed QA found that data subscriptions serialized absent `run_id` as
  an empty string, which the strict Linux bridge rejected. `b93e656645` omits the
  optional key for non-run topics while retaining validated run identifiers for
  run subscriptions. The focused Linux suite passes 3/3, and the reinstalled UI
  changed from `Connected; data refresh degraded` to `Connected to local peer`.

The exact receipt records **890/890 frontend tests**, TypeScript, production
bundle verification, the package startup/linkage probe, daemon health, a visible
unlocked screenshot, and AT-SPI passes for Overview (44 nodes), Quota (297),
Activity (44), and final Settings (90). It is available at
[`evidence/parity-audit-2026-07-10/linux-arm64-current-b93e656645-exact-native-2026-07-20.json`](evidence/parity-audit-2026-07-10/linux-arm64-current-b93e656645-exact-native-2026-07-20.json).

This advances implementation and removes the current ARM64 staged-native
blocker. It does **not** change the strict promotion ledger from **0/40 product
rows** or **0/7 environment receipts**: signed provenance, production cloud
configuration, the remaining architecture/compositor environments, physical
iPad/cross-device flows, and live external integration proofs remain open.

## Prior Source Checkpoint — 2026-07-20

The current integration branch includes source changes through
`fc0af729e1`; the latest installed package contains the current shell while its
daemon/CLI are reused staged payloads. This is a source and build checkpoint,
not a promotion claim:

- `1130524331` immediately reveals a visible 2D backdrop when a WebGL context
  is lost while the window is backgrounded, then retries the requested kernel
  after hidden-to-visible resume. The focused loss/resume regression is 4/4.
- `db8a52f2f2` makes the kernel listbox keyboard-complete (Arrow/Home/End,
  Enter, Escape), restores focus to its trigger, and keeps fallback labels
  truthful.
- `2a19ac301a` renders an accessible empty state for Support performance data on
  a fresh install instead of an empty table body.
- `6ce5ec8623` adds quota/account routing state; `149cfec503` plus `bd10c71919`
  harden provider refresh and stale-event handling; `ed940164ce` hardens
  Mercury recovery; and `aa188d24fa` invalidates embedded assets when hashed
  chunks rotate. `cf9499d437` adds viewer capability retry, `7e7e7efdf7` plus
  `58e21e5f9c` add a typed privacy-export receipt with a metadata-safe fallback,
  `65f4931c36` keeps onboarding provider recovery actionable, and `ded781e94d`
  adds route-level render-error recovery with Retry/Open Support actions.
  `8cafd2d7e0` preserves the last provider workspace during transient catalog
  errors, `da42c16a78` discards delayed daemon events across subscription
  restarts, and `872074af3a` cancels typed SmartHub work when the shell bridge
  disappears. `e6c32ec2b2` repairs stale custom-model provider selection after
  a catalog refresh. `c6bf8f2881` stabilizes the asynchronous chat pop-out
  status test. `465431d0fc` extends owner-checked single-instance forwarding
  while the primary Unix listener is still starting, and `7ac2e021c9` disables
  native Browser Computer Use unless the runtime capability manifest explicitly
  reports it available; missing or rejected capability probes now leave the
  action controls disabled. `c0a725447d` falls back to the trusted embedded
  autostart desktop entry when the system-wide entry is absent, while preserving
  permission/read failures. `447abb0564` fences delayed Mercury capability
  responses by probe generation across bridge replacement, unmount, and manual
  recheck.
- `9e868e60a7` refreshes tray health, usage, and update labels every 30 seconds
  while serializing manual refreshes. `3e7ede75e3` stops browser authorization
  polling when the daemon-provided deadline expires, announces the degraded
  state accessibly, and keeps device approval non-cancellable per the native
  contract.
- `ebab7da744` fences stale concurrent version/feed responses so an older
  signed-update result cannot overwrite newer shell facts or leave loading
  state stuck.
- `534d7aae65` makes the overflow menu keyboard-complete with Arrow/Home/End,
  Enter/Space, Escape, and trigger-focus restoration; its focused regression
  tests pass 2/2.
- `519f0456a7` adds a packaged-shell-only Support **Reconnect** action when
  daemon health is missing or degraded, with bounded busy/disabled state and
  retry guidance; focused Support coverage is 34/34, including stale-export
  fencing across bridge replacement and overlapping requests.
- `811d84172a` bounds native notification action retention until renderer
  bootstrap, adds the `initial_notification_actions` drain command, and keeps
  cold-start Reply/open intent and composer focus; focused Rust, bridge, and
  App coverage is 1/1, 33/33, and 26/26.
- `66b280162f` clones the Tauri `AppHandle` before the Linux
  `run_on_main_thread` notification callback, closing the ARM64-only compile
  failure found during the first current-head package attempt.
- `b2c8579835` fences stale and overlapping diagnostics exports by request
  generation and bridge identity, clearing export state when the shell context
  changes; focused Support coverage is 34/34.
- `90fac18c86` scopes the notification queue helper to test builds, removing
  the release-only dead-code warning without changing runtime behavior.
- `7c5b68d750` mirrors macOS loopback-only CORS headers, preflight handling,
  and streamed-response headers on the Linux gateway; focused Linux gateway
  tests cover allowed/blocked origins, OPTIONS, IPv6, and SSE headers.
- `106b15855b` retains the last good mission snapshot during transient refresh
  failure; `e4f14c4387` removes duplicate SmartHub health probes;
  `9f1bd7ca8c` wires Mission **Inspect logs** to canonical detail;
  `5e1a2dd962` routes **Import sessions** to Activity; and `2ad3b2752d`
  brackets Avahi-discovered IPv6 device endpoints. Focused mission/shell tests
  are 20/20 and both changed Swift files parse; these three source fixes are
  included in the historical `2ad3b2752d` package receipt. `10c26c9a5d` then
  gives custom Appearance controls true radio semantics with roving tab stops
  and Arrow/Home/End movement; `2b64049552` fences stale Computer Use
  authority and approval-poll responses by request generation; and
  `3258104c1a` keeps the last successful Activity query snapshot visible during
  transient refresh errors while preserving visible-row exports. `f9bf08c600`
  fails closed from an errored X11 pet child to the contained keyboard/pointer-
  safe fallback; `e114bca710` retains stale signed-update facts while disabling
  package mutation until a fresh check succeeds; and `36514bee98`/`72afa18f7e`
  force and validate the native GStreamer Mercury viewer feature for package
  builds.
- Current source wave adds three source-completable parity gaps: provider
  catalog aliases now resolve macOS vendor IDs to canonical Linux parser paths
  and preserve daemon quota provenance; Projects detail now reads recent
  daemon-controller history and exact session associations; and Data & Privacy
  now exposes encrypted recovery-bundle export/import with explicit import
  confirmation. Heavy routes are split into lazy chunks while Support error
  wiring remains synchronous for deterministic startup failure states. Chat
  resume now preserves the last good transcript during failed reloads; Memory
  exposes the daemon audit timeline; Account fences stale identity state and
  reports trusted-device posture without inventing local approval authority.
- Source gates pass: 91 frontend files / 877 tests, TypeScript, production
  bundle verification, Tauri Rust 129/129 on the host and 130/130 with
  `media-gst` on Ubuntu ARM64, package-payload contract checks
  (2 pass, 2 historical skips), and product validators 12/12.
- The ARM64 VM validated the supported Swift-less staged-payload path with
  `OPENBURNBAR_LINUX_REUSE_STAGED_PAYLOAD=1`; the current shell package was
  rebuilt from synced source `90c5bd34ca` with native GStreamer linkage while
  reusing the previously clean verified daemon and CLI payloads, then captured
  separately in
  [`evidence/parity-audit-2026-07-10/linux-arm64-current-90c5bd34ca-ui-staged-daemon-2026-07-20.json`](evidence/parity-audit-2026-07-10/linux-arm64-current-90c5bd34ca-ui-staged-daemon-2026-07-20.json).
  It remains unsigned and non-certifying; AT-SPI and window presence passed,
  while the SPICE screenshot was black.

The strict certification ledger remains **0/40 product rows** and **0/7
environment receipts**. The remaining blockers are signed exact-head artifacts,
the hosted architecture/compositor matrix, production cloud configuration,
physical-iPad enrollment and cross-device Computer Use, two-device Mercury
flows, live SmartHub/IME/keyring/assistive-tech proofs, and same-commit
macOS/Linux differential evidence.

PR #1691 currently has one external CI blocker: the trusted Domain Core
deletion guard reports that the candidate has no legacy-deletion ledger to
anchor validation. The candidate branch predates the current Domain Core
source roots and cannot be made green with a fabricated Linux-only ledger; a
clean mainline/release-head integration is required before merge.

The focused physical-iPad approval run at the current checkout passed **44/44
tests** with xcodebuild exit 0. Its exact receipt is
`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19-v2.json`.
The test process started at `eace4cc200` before the provider source commit was
created, so the receipt is intentionally non-certifying and does not claim
coverage for installed-Linux enrollment, approval/revoke, or cross-device
Computer Use.

## Current Live Checkpoint — 2026-07-19

The historical live checkpoint below records the earlier `1b80f2ca08` kernel
capability slice. The current source checkpoint is `872074af3a`; the kernel
capability slice at
`50d40b9acb` adds a typed kernel
resolution receipt from the shared backdrop engine and exposes the requested
kernel, resolved kernel, substrate, and fallback reason through DOM attributes
and the Linux switcher. The UTM guest's WebKitGTK context probe is
`webgl2=false`, `webgl1=true`; the live dev-surface check selected Aurora and
observed `resolved=constellation`, `reason=webgl2-unavailable`,
`fallback=1`, `substrate=2d`, and the visible switcher label
`Aurora · 2D fallback (WebGL2 unavailable)`. The installed baseline also
exposed a separate first-paint issue for the Linux default: two root-window
captures two seconds apart changed only 256 bytes, so `swarmEmber` was visibly
static while its lazy factory resolved. Commit `1dc1328818` makes that 2D
default eager and adds a regression test that observes `fillRect` during init
and the first frame. Follow-up commits `907187f767` and `0ae08b3baf` make every
lazy 2D proxy paint an opaque palette-backed base immediately and retry after
either asynchronous rejection or a synchronous loader throw. The current source fallback remains animated when the
Canvas2D path is exercised. A fresh current-head release build was launched in
the unlocked UTM guest after restoring the real Vite `dist`; the screenshot
showed the rendered shell, setup card, and the `Aurora - 2D fallback (WebGL2
unavailable)` status. The direct tree launch intentionally has no packaged
daemon, so its setup card reports daemon authority unavailable; that is a
separate packaging/runtime check from backdrop rendering. The prior installed
package receipt remains the historical `5b70a3d320` candidate. The preceding
`ded781e94d` package receipt is also historical: it contains a visible
shell/setup capture, daemon health, and a Canvas2D fallback label. The current
`872074af3a` ARM64 package is installed at `/usr/bin` and reports daemon health
`ok=true`. Initial black captures were caused by the locked GNOME session; after
`loginctl unlock-session 1`, the same package rendered the Overview route and
Fluid Aurora 2D fallback, with two captures two seconds apart differing in
382,024 pixels. This is still bounded visual evidence, not a full visual-parity
claim:
`evidence/parity-audit-2026-07-10/linux-arm64-latest-implementation-2026-07-19-v2.json`.

The connected physical iPad was rechecked against the current checkout using
the bounded approval/navigation selectors: the existing approval-focused
receipt has **44 tests passed, 0 failed, xcodebuild exit 0**, and the current
head navigation slice adds **21 tests passed, 0 failed, xcodebuild exit 0**.
These are focused mobile coverage only; they do not prove Linux enrollment,
cross-device approval, or the full mobile suite. The current-head navigation
receipt is `evidence/parity-audit-2026-07-10/ipad-navigation-focused-current-2026-07-19.json`.

The latest installed candidate is `5b70a3d320`. The Settings live failure found in the
VM was a route-boundary bug, not a daemon failure: packaged `SurfaceRouter`
deferred the entire Settings surface behind an idle queue, so no
`daemon.config.get` request could start. `2f75f3269e` mounts Settings
immediately in packaged mode and `5b70a3d320` makes its first config hydration
eager while retaining deferred paint for other routes. The installed candidate
now reports 105 AT-SPI nodes and 50 actionable controls, no `Loading Settings`
node, a reachable `Launch OpenBurnBar at login` checkbox, and a working Media &
Sharing route. The daemon loaded 21 providers from the live config store.

Source verification is green at **87 frontend files / 807 tests**, focused
Settings/route coverage **45/45**, accessibility coverage **10/10**, Tauri Rust
**125/125**, TypeScript, formatting, and production-bundle verification. The
connected physical iPad focused navigation suite passed with xcodebuild exit 0.
This closes one real
installed Linux reliability gap, but it does not change certification: the
strict ledger remains **0/40 product requirements ready** and **0/7 environment
receipts complete**. The exact live receipt is
`evidence/mission-002-reanchor/vm-e2e/current-5b70a3d320-settings-hydration-arm64/`.

## Execution Status — 2026-07-19

The strict ledger is unchanged at **0/40 product requirements ready** and
**0/7 environment receipts complete**. The latest bounded physical-iPad
receipt, from source checkout `c9c679f43b`, built the arm64 Signal FFI slice and
the source-safe Firestore graph (`grpc-ios` plus `BoringSSL-SwiftPM`) and
executed **44 focused approval cases with 0 failures** on Alberto's paired
iPad. The receipt is
`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19.json`.
The earlier 9-case theme receipt remains useful supplemental coverage. These
are non-certifying focused mobile results; neither proves installed Linux
enrollment, fingerprint confirmation, approve/revoke, or cross-device Computer
Use behavior. The live UTM Ubuntu 24.04 GNOME/X11 aarch64 guest is now running at
`192.168.64.5` and is reachable over the documented SSH key. The exact-head
`b590d5a77d` arm64 package is installed; its daemon is enabled and healthy, the
installed desktop peer is running from `/usr/bin`, and bare CLI health is green.
The exact current receipt is
`evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/live-installed-receipt.json`.
The earlier `a570c9b087` package remains the daemon/media baseline. Its daemon
links the Linux Mercury capture crate and the packaged FTS5
SQLCipher runtime: live RPCs report `available=true`, `codecsKnown=true`,
VP9/AV1/Opus support, an active daemon-to-shell media socket, and available
file-offer capability. The package migration hook, executable-peer
authentication, SQLCipher binding, and WebKit safe-mode selection are covered by
focused tests/source checks. This is a live runtime receipt, not strict
certification: the installed manifest is unsigned, H.264 is not available on
this guest, and two-device transfer/call/screen-share plus the
product/environment receipt matrix remain open. The exact receipt is
`evidence/mission-002-reanchor/vm-e2e/current-a570c9b087/live-receipt.json`.

`a570c9b087` carries the live release/runtime fixes found in the VM: the release
graph builds and stages `libopenburnbar_media.so`, the package post-install hook
registers the user daemon service, and the daemon binds explicitly to the
packaged FTS5-capable `libsqlcipher.so.0` instead of Ubuntu's incompatible
`.so.1`. Linux peer auth hashes the kernel `/proc/<pid>/exe` link without
`O_NOFOLLOW`, which is incompatible with that kernel magic link; the actual
Linux-target test passes 1/1 on Ubuntu. `6321897d4e` adds deterministic WebKit
safe-mode environment selection when no DRM render node exists. The full
`MercuryLinuxMediaTests` class passes **21/21**, the project/code-memory
bootstrap slice passes **3/3**, and the installed package health/media probes
pass on the same guest.
`fdbc7d718b` also makes the Linux media UI distinguish receive-only socket
transport from authenticated daemon call RPCs, preserves valid call actions,
and disables stale file-offer actions; the focused media UI/state lane passes
**33/33** plus TypeScript. The current `media-gst` shell feature is installed
in the UTM guest and links the GStreamer app/base/core/video libraries; the
bounded UI/runtime receipt is
`evidence/mission-002-reanchor/vm-e2e/current-992ef5c580-settings-index-arm64/live-installed-receipt.json`.
The subsequent source slices add single-flight native pet summons
(`511c8a1049`), body-click notification routing (`1397313284`), decoder retry
without socket reconnect, and health-before-write Secret Service/KWallet
onboarding checks (`82b0fcf11e`). They pass 28/28 pet UI tests, 4/4 native
notification Rust tests, 5/5 media Rust tests in both VM feature modes, and
6/6 Linux onboarding tests on Ubuntu. These are engineering improvements, not
cross-device or signed-candidate certification.

Two additional source-only parity hardening slices are now on the candidate
branch. `6f57349c66` keeps Linux settings search selection synchronized with
the matching detail tab, shares one matcher between the sidebar and detail
surface, and renders an explicit no-results state. `5624ad1f6b` makes Linux
Avahi peer discovery honor bounded deadlines and report non-zero helper exits
as typed failures; focused source tests cover timeout, exit status, and a
successful parse. These changes improve behavior and reliability but do not
create installed Linux receipts or change the strict 0/40 and 0/7 ledger.
The current Linux desktop regression run at this candidate head passed **82
files / 749 tests**; the TypeScript check and production bundle verifier also
passed.

Additional source hardening is now on the candidate head: `992ef5c580` adds a
daemon-backed **Index project** action to General Settings Indexing & Search
(focused settings tests **34/34** and the installed arm64 receipt above).
`c095761b07` binds
signed update-feed artifact and signature URLs to first-party release paths
(19 Rust update-feed tests passed); `50a0684e75` rejects symlinked onboarding
state files and support directories before persistence; and `a5522bfc54`
adds bounded, duplicate-identity-checked JSON history import/resume through
the daemon, with **27 focused activity tests** and TypeScript passing. The
history importer preserves normal multi-line Markdown bodies. These changes
remain non-certifying until installed Linux and live production receipts exist.
`d1cb5e517d` also aligns the Linux settings section order with the macOS oracle:
System contains Daemon, Updates, and Data & Privacy, while More contains Text
Expansion, Media & Sharing, Computer Use, and Pets. `a5e74fed57` bounds
SmartHub device-status helper execution with the existing timeout, output cap,
concurrent drain, and process-group termination contract (six focused Rust
tests passed). `0ecdf097a3` adds bounded, deduplicated Insights evidence
citations with accessible selection and opaque-ID chat handoff (the full
desktop suite covers 18 Insights tests). `f35f5392e7` allows a validated
Computer Use portal session close during panic-kill teardown while continuing
to block creation and input; source parsing/build passed, but macOS XCTest
runtime remains blocked by the unavailable SQLCipher framework. The current
Linux desktop regression run at this head passed **82 files / 751 tests**;
TypeScript and the production bundle verifier also passed. None of these
source-only changes creates installed Linux or live cross-device receipts.
The next source wave is also on the candidate branch: `e186d83314` re-resolves
the daemon source identity immediately before activity export resume and fails
closed on stale, duplicate, paged, or unavailable identities; `fba5d8bcc8`
binds P-39 parser evidence to the checked-in corpus and verifies generated and
normalized hashes (29 focused P-39 tests pass); `3d992ce624` preserves metric
readability in forced-colors mode; and `c721ec18f8` removes a focusable
`aria-hidden` shell sentinel. The current desktop regression run is now **82
files / 753 tests**. Segmented Linux evidence-contract suites pass **607
tests**, with **5 explicit fixture skips**; TypeScript and the production
bundle verifier remain required after this source checkpoint. The P-38 proof
fixture now derives its mutation count from the real 24-test workflow suite,
closing stale-count failures without weakening the validator. These are still
source/contract improvements, not installed receipts.

Two additional source slices are now pushed on the candidate branch. `3004da3b72`
adds the macOS-matching Calendar notification default hold-duration control
(15/30/45/60/90 minutes), gated until Calendar is enabled and persisted through
the existing daemon config RPC (focused SettingsSurface **30/30**, TypeScript
passed). `bdd57173e9` hardens support diagnostics export: socket paths and raw
daemon errors are redacted, renderer/capability facts are included, support
directories and atomic bundles have private permissions, and symlinked support
directories fail closed (focused support UI **24/24**, Tauri Rust **115/115**).
`2a80e30921` now recovers the Mercury GStreamer decoder in place after a
transient frame failure, preserving the socket session and re-arming keyframe
gating (default Tauri Rust **119/119** after the membership contract slice).
`8131b51aec` adds a portal-backed native
diagnostics save destination with a second Rust path-validation boundary and
owner-only atomic output (diagnostics **6/6**, support UI **24/24**). The
current desktop regression run is **83 files / 770 tests**, with TypeScript and
the production bundle verifier passing. A prior bounded current-checkout
`MobileThemeTests` receipt passed **9/9**, 0 failures, and xcodebuild exit 0;
the newer focused approval receipt is recorded below. Both remain
non-certifying mobile coverage and do not prove Linux enrollment,
approval/revoke, or cross-device Computer Use.

The current source-only wave also includes `9fb6e88c33`, which canonicalizes
membership RPC names and maps unknown methods to a deterministic capability-
absent state (Tauri Rust **119/119**), and `f9d3b429e5`, which adds persisted
Dashboard Defaults plus truthful daemon-backed Indexing & Search posture and
an explicit unavailable Session Summaries state (focused settings **45/45**,
new controls **3/3**). The full desktop-suite rerun after these two slices is
green at **83 files / 770 tests**. The current focused approval receipt is
**44/44**, 0 failures,
xcodebuild exit 0; it remains non-certifying mobile coverage.

`c94e7b6113` adds the missing daemon-owned Activity history contract. Linux now
requests one bounded indexed snapshot with explicit `historyComplete`, cursor,
identity, tombstone, and body-size checks; the renderer refuses export unless
the completeness proof is true, rather than replaying bounded recent usage as
full history. The focused Activity/bridge suite passed **102 tests**, the
TypeScript check passed, and the Rust RPC test passed. The exact-head package is
now installed and healthy in the UTM guest; its non-certifying live receipt is
`evidence/mission-002-reanchor/vm-e2e/current-c94e7b6113/health.json`.

The latest current-head hardening adds `b0d27caffa`, which treats malformed,
future-version, or unsafe persisted Insights workspace records as invalid and
restores a safe default instead of partially applying renderer state (focused
Insights persistence/renderer coverage **26/26**). `fec153e40b` and `e6bf98601b`
make Activity full-history export and resume require an explicit daemon
`historyComplete === true` marker; the bounded recent-usage session bridge
cannot claim completeness and therefore stays typed-unavailable until that
proof exists (focused Activity history/export/resume coverage **30/30**).
These source-only fixes improve fail-closed behavior but do not change the
strict **0/40** product or **0/7** environment certification state. The latest
full Linux desktop run is **83 files / 787 tests**; TypeScript, production
bundle verification, and Tauri Rust **125/125** also pass. The physical iPad
receipt remains **44/44** and non-certifying. The Ubuntu guest is live at
`192.168.64.5`; the exact `b590d5a77d` package is installed and authenticated
daemon/CLI health is green. The non-certifying live receipt is
`evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/live-installed-receipt.json`.
Signed release provenance, AT-SPI capture, cross-device workflows, and the
remaining environment receipts are still required.

The current source slice is integrated at `b590d5a77d`: Linux Insights has a
macOS-style Compare mode with up to three verified provider/model/widget scopes,
per-column provenance, accessible removal controls, and fail-closed behavior
when evidence is unavailable (`c31c17aa6e`, `ee679e2ed0`, `eb6a5975d4`); General
Settings now exposes a secure Linux-native Launch at login preference backed by
an owner-checked XDG autostart override (`f6d3843937`, hardened in `1bddc6d22a`
and covered for unavailable source state in `5e0fc0e82`). Focused verification
is 28/28 Insights, 4/4 autostart Rust, 39/39 renderer/bridge, 31/31
SettingsSurface, and 32/32 Settings/accessibility tests. The exact-head package
is installed; live checks and limitations are recorded in the receipt above.
`2e609b4061` additionally moves Mercury GStreamer decoder teardown outside the
viewer lock; the focused lifecycle tests pass 6/6 with `media-gst` and 5/5
without it.
`d581da37b7` makes Media & Sharing show the daemon's typed capability state
instead of a stale static blocker, and `47cbf2e2f0` fails onboarding closed when
an ephemeral Secret Service/KWallet probe cannot be cleaned up; Ubuntu
onboarding coverage is 8/8.

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

### Fresh local device and infrastructure recheck — 2026-07-19

- **Physical iPad:** after the wired reconnection, `xcrun devicectl` sees
  Alberto's paired, booted iPad with Developer Mode enabled and a mounted
  developer image. The physical XCTest readiness preflight passes when the
  hardware UDID (`<IOS_USB_UDID>`) is used. The bounded current-
  checkout `MobileThemeTests` run passed **9/9**, with xcodebuild exit 0; the
  non-certifying receipt is
  `evidence/parity-audit-2026-07-10/ipad-mobile-theme-2026-07-19.json`.
  Parser/store/mutation approval tests and cross-device execution remain open.
- **UTM:** the current `utmctl list` reports the OpenBurnBar Linux guest as
  stopped. No VM was modified during this recheck; installed Linux proof and
  the historical stale `/usr/local` launcher diagnosis remain open repair gates.
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
- **Physical iPad:** Alberto's iPad (`<IOS_USB_UDID>`) was used for
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
  (**98/98** combined). `2a80e30921` restarts the decoder in place after a
  transient decode error and preserves the live socket session when recovery
  succeeds. `a570c9b087` makes the release graph build and stage the daemon's
  `openburnbar-media` Rust crate alongside the shell's `--features media-gst`
  build and binds the packaged FTS5 SQLCipher runtime. The installed VM
  capability probe now reports `available=true`, `codecsKnown=true`, VP9/AV1/Opus
  support, an active daemon-to-shell media socket, and file-transfer capability.
  The two-device file/call/screen-share, PipeWire portal, H.264, and lifecycle
  receipts remain open.
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
| P27 notifications | PR #1651 + `07153ac3d5`, merge-clean + `811d84172a` | Bounded native `notify-send` adapter with typed failures plus typed freedesktop `open`/`reply` actions; Reply preserves intent, opens chat, and focuses the composer without pretending to provide macOS inline notification text input. Native actions are retained until renderer bootstrap and drained once. Actionable host receipts and lifecycle proof remain open. |
| P35 diagnostics | PR #1653, checks in progress + `519f0456a7` | Metadata-only diagnostics preview/export, redaction and `0600` enforcement, plus a packaged-shell-only bounded Reconnect action for degraded daemon health; installed support workflow remains open. |
| P23 provider/model workspace | PR #1655 + integration `e0451afa5e` + provider mutation lane | Canonical daemon catalog/config mapping, strict model provenance, health and failover state, provider/model workspace, config-derived chat backend availability gates, and daemon-backed custom-model add/remove with fixture-safe local behavior; credential custody, live routing, and installed lifecycle remain separate. |
| P16 account/enrollment posture | PR #1658 updated + integration `01784940c5` | Daemon-owned account status, sign-out, rejected-identity recovery, and context-aware generation/bridge fences now decode transitional phases fail-closed; stale responses cannot overwrite a newer identity or busy state. Device ID/fingerprint copy actions and trusted-iPad guidance are present. Trusted-device list/approve/revoke remains a native mobile/Firebase boundary, and cloud backup remains unavailable. |
| P12 quota account switching | PR #1659, stacked on P23 + `be375903f0` | Redacted credential-slot selection through canonical config get/update now includes a preferred provider account selector, explicit daemon auto-routing reset, fixture coverage, and fail-closed read-only behavior when `config.update` is unavailable; does not provide cloud account or trusted-device management. |
| P13 onboarding first-data probe | PR #1667 updated + `238ee56975` | Provider setup now loads the daemon catalog and submits a credential once through native Secret Service storage, clears the web-view field, and keeps completion daemon-authoritative. `238ee56975` validates every daemon snapshot before renderer/cache mutation, preserves the last valid state on malformed or forged responses, and adds `aria-busy` coverage (**27/27** focused onboarding/App tests); OAuth-only auth, portal consent, and desktop integration remain open. |
| P14 chat approval/citation boundary | PR #1662 + integration PR #1691 | Gateway tool cards now carry daemon-issued approval IDs and support approve/reject/cancel with terminal-state and single-flight handling. Bounded citations normalize safely, focus/open the originating thread when available, and fail closed for unavailable sources; daemon-authoritative full-history export/resume and the browser/Tauri pop-out boundary are implemented, while installed reconnect/export/resume proof and remaining backends remain open. |
| P17 activity/session depth | PR #1661 + PR #1685 + integration PR #1691 + `c1f6e69514` + `7ae2412143` + `fec153e40b` + `e6bf98601b` | Canonical daemon-backed search/detail/resume with indexed transcript excerpts and bounded persisted body replay are integrated. Native resume uses the existing `run.resume` contract with provider-safe handoff fallback; the full-history export scaffold re-reads bounded usage rows and verified replay bodies while preserving source/provider/session/project identity, but now requires an explicit daemon `historyComplete === true` marker. The current bounded recent-usage bridge cannot provide that proof, so export and resume stay typed-unavailable rather than claiming full history (focused Activity history/export/resume coverage **30/30**). Replay/resume also require a verified daemon `sourceID` and never fall back to a usage-row identifier. Installed source-resolution and resume-from-export evidence remain open. |
| P21 insights workspace | PR #1669 + integration `5ddd81245d` + `b3002ab3f9` + `825e081bda` + `c31c17aa6e` + `ee679e2ed0` + `eb6a5975d4` | Provenance-labeled brief now sits above a selectable three-pane canvas/library/inspector workspace with trend, provider, model, and cache widgets, account-scoped persisted selection/density, validated evidence IDs, bounded audit disclosure, refresh, a daemon-owned `daemon.usage.insights` qualitative/citation response using local rules and bounded usage rows, a chat follow-up composer, and a macOS-style Compare mode capped at three verified provider/model/widget scopes with per-column provenance and source-loss fail-closed behavior. The exact-head arm64 package is installed and recorded in `evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/`; live daemon qualitative parity and signed/cross-device certification remain open. |
| P24 settings inventory | PR #1665, merge-clean + `992ef5c580` + `f6d3843937` + `1bddc6d22a` + `5e0fc0e82` + `d581da37b7` + `47cbf2e2f0` | Restores Model Proxy, Computer Use, and Pets destinations for a 16-tab searchable inventory with honest capability routing. General Settings now includes daemon-backed Index project, secure Linux-native Launch at login persistence and unavailable-source guard, typed live Media & Sharing capability status, and fail-closed onboarding probe cleanup. The exact-head package is installed in the non-certifying VM receipt above, while deeper writes and signed/live proof remain open. |
| P28 SmartHub | PR #1668 + integration PR #1691 | Typed root-owned CLI allowlist now validates request IDs, bounds JSON depth/items/strings/output, drains stdout concurrently, enforces an 8-second timeout, and supports cancellation/degraded renderer states; live device/Avahi outcomes remain separate. |
| P29 text expansion | PR #1663 + integration PR #1691 + `6c76df084f` + `1ddc8bc33a` + `274f67fba0` + `9598c0b9e8` + `d2dbbe8df8` | Daemon-owned AES-GCM sealed snapshots use native Secret Service/KWallet key custody, consent RPC, owner-only permissions, corruption/tamper fail-closed behavior, and in-app-only Composer expansion without renderer localStorage/global capture. Live renderer controls remain disabled with explicit degraded copy until daemon storage hydration succeeds, including missing-storage and error paths. `274f67fba0` adds a bounded, explicitly opted-in, signed IBus/Fcitx engine manifest/registration gate; `9598c0b9e8` adds typed engine status/start/stop RPC and a Tauri bridge; `d2dbbe8df8` adds trigger-only JSONL expansion requests with strict response bounds, secure/excluded/uninspectable denial before write, cancellation/timeout/kill-switch teardown, and no keyboard/clipboard/surrounding-text payloads. It still does not claim Linux keyring/IME runtime receipts, sync, or installed secure-field proof. |
| P18 memory authority | PR #1671, merge-clean | Live memory inboxes now remain daemon-authoritative; stale renderer status cannot resurrect or hide live items; first-class quarantine and cross-device review remain open. |
| P19 projects depth | PR #1670 + PR #1688 + `9598c0b9e8`, source stack green | Canonical project list/get/upsert plus typed delete/reassign lifecycle, fail-closed slug/id/alias validation and collision handling, durable reference migration across reviews/questions/followups/missions/simulators/nested takeover history, deleted-slug tombstones, checkpoint/journal-tail replay protection against resurrection after a crash, detail/register/edit UI, confirmation, and visible error recovery; installed proof remains open. |
| P20 missions depth | PR #1677 + `bd9d6a5173`, source checks green | Canonical mission get/cancel, typed packet/result/evidence/burn/takeover/PR snapshot mapping, freshness, expandable detail, and a daemon-owned `daemon.mission.health` RPC with typed health/history, stable event IDs, active/failed counts, and UI rendering are integrated; live mission integrations and installed proof remain open. |
| P25 updates | PR #1673 + integration `4a2138897c` | Signed-feed freshness, exact package-channel/architecture selection, shell/daemon compatibility, and fail-closed package/download guidance now disable generic AppImage and downgrade fallbacks when no verified artifact exists; valid public feed and installed rollback remain open. |
| P30 pet companion | PR #1674 + integration `9a527310f9` + `ea82fe5140` + `5c3caab2e` + `2b85f1431` | Native runtime-manifest probe replaces optimistic environment detection; contained fallback now supports accessible summon/focus/status and selection/clear controls with explicit action state. `ea82fe5140` adds a real Tauri companion child window on X11 with explicit focus and click-through toggles; `5c3caab2e` adds the typed X11-only `Ctrl+Alt+Super+P` summon event and `2b85f1431` exposes its accessibility metadata. Wayland and unknown sessions remain degraded and the native overlay still needs compositor-installed proof. |
| P40 data/privacy | PR #1672, `4cdc505537`, `9598c0b9e8`, `7c8a214ce6`, `825e081bda`, `cba9266277`, `379284d336` | Daemon-backed telemetry/privacy/cloud-sync writes with pending/error states, plus a daemon-owned, allowlisted local-store inventory and preview/execute deletion contract wired through typed RPC/Tauri and a confirmation UI for the proxy-route log and encrypted text-expansion store. `7c8a214ce6` adds selected-scope encrypted export with PBKDF2-HMAC-SHA256 100k, AES-GCM authenticated headers, owner-only bounded output, race/path/permission checks, and passphrase clearing. `cba9266277` adds bounded age/size retention rules with fail-closed policy validation and atomic trimming limited to the same allowlist. `379284d336` adds typed native save destinations for local and cloud exports with cancellation and path validation. Account erasure, full transcript/account export depth, recovery-key workflows, and backend erasure receipts remain open. |
| P11 usage catalog | PR #1676, checks green | All 33 canonical provider identities and Swift discovery paths/patterns are contract-tested against the exact 27 ParserRegistry entries; four API-backed and two unavailable sources are labeled explicitly in Settings/onboarding; normalized corpus and runtime/install evidence remain open. |
| P14 exact chat threads | PR #1684 + integration PR #1691 + `0d8ee32526` + `618c7286b9` + `5fdcccabfa` | Canonical encrypted thread list/get/search, idempotent append, older-message pagination, strict Tauri decoding, durable send ordering, daemon-authoritative full-history JSON/Markdown export with bounded cursor/duplicate/size checks, exact model/thinking selection, daemon-owned bounded attachment refs, validated path-free attachment metadata in exports, citations, approval actions, and validated daemon re-read resume are integrated. Composer uploads bounded text documents through the daemon and persists path-free metadata; `26dd3cbc30` preserves capability-authorized PDF data URLs across the Anthropic compatibility bridge instead of dropping them. Reconnect/visibility handling, functional options, and browser/Tauri pop-out boundaries are explicit. Uploaded bytes remain process-lived and require re-upload after daemon restart; remaining backends and installed reconnect evidence remain open. |
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

### Source continuation — 2026-07-21 follow-up

Three concrete source gaps were closed without changing the strict release
verdict. `2bb7bbfe56` hardens the packaged Linux IBus engine: a missing daemon
socket, missing CLI, or two-second lookup timeout now returns no replacement
and keeps the IBus worker alive. Its Python self-test and focused Node contract
suite pass 9/9. `6087fe6660` preserves typed notification actions on a primary
cold launch instead of dropping them before renderer bootstrap; the focused
single-instance suite passes 11/11 and the full Tauri library suite passes
137/137. `160c271057` replaces the hard-coded KWallet
`test_command_fixture` setup state with real available/blocked reporting based
on `kwallet-query` and the session bus, and updates the secure fallback test;
the focused Linux security suite passes 33/33.

These changes improve P-27 notifications, P-29 text expansion reliability, and
P-05 keyring onboarding. They do not provide the still-required signed
installed IBus/keyring receipts, production account approval, or the seven
environment matrix. Source behavior remains approximately **80%** by the
audit's classification; strict certification remains **0/40 requirements**
and **0/7 environments**.

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

The audit is **NO-GO** for a full-parity claim or stable Linux promotion. The
project has completed the machinery needed to prove every requirement, but it
has not completed the signed-candidate executions that turn that machinery into
release evidence.

| Counter | Current result | What it means |
|---|---:|---|
| Proof ownership | **40/40** | Every requirement has fail-closed candidate-bound evidence ownership at `df1852fae2` |
| Exhaustive ownership/preflight | **44/44 passed** | Registry, validator, workflow, and ownership wiring are internally complete |
| Source implementation | **~80%** | Audit estimate of implemented Linux behavior relative to macOS; gaps and unproven outcomes remain |
| Strict requirement certification | **0/40** | No requirement has yet satisfied its complete signed-candidate evidence contract |
| Strict environment certification | **0/7** | No required environment has yet supplied its complete current-head receipt set |
| Release verdict | **NO-GO** | Do not claim full parity or promote stable Linux |

These counters are intentionally non-interchangeable. In particular, **40/40
ownership is not 40/40 parity**: it closes missing proof infrastructure, not
missing implementation, live integration, signing, hardware, or environment
execution.

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

The latest source wave moves two partial rows forward without changing the
overall estimate or verdict. P-11 now projects and explicitly recounts all-time
usage from the daemon's canonical ledger, persists a fingerprint-bound derived
cache, and rejects inconsistent renderer aggregates. P-16 now has a durable
encrypted local replica engine and injected daemon RPC runtime for redacted
status, consent policy, and manual sync cycles. The remaining parser catalog and
production cloud/device composition work is substantial enough that the source
estimate stays at **~80%**; neither change creates signed installed evidence.

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
| P-05 | Credential custody | Keychain-backed provider, connector, auth, and sync secrets | Secret Service, KWallet, and encrypted headless custodians are wired; the installed candidate lifecycle producer, candidate-bound proof, fail-closed validator, mutation tests, and workflow ownership are implemented; all seven signed live keyring/recovery receipts remain required | Partial | Critical |
| P-06 | Gateway credential boundary | Native process owns bearer credentials | Rust owns the bearer and proxies bounded authenticated HTTP/SSE; renderer receives typed data, not the token | Near parity | Critical |
| P-07 | Computer Use | Browser, Agent Watch, Mac System, approval, audit, and three panic paths | Exact run/call/generation authority, signed session/action responses, replay protection, waiting-run selection, shared scope/panic/Playwright/audit routing, and fail-safe restart/terminal behavior are implemented. Controller-route v2 provides dual-signature bootstrap, exact-tuple same-generation transport renewal, and authoritative absence/revocation. The Linux daemon now composes that runtime with daemon-owned PKCE sign-in, secure refresh-token custody, fresh Firebase ID/App Check credentials, per-install Ed25519 App Check enrollment, account-generation invalidation, phase-safe account transition RPCs, and scoped old-account revocation. Pending approval has an explicit bounded reason and quota-safe retry; permanent rejection stops polling. Official AppImages authenticate the final GUI bytes through a signed manifest rather than mutable environment pins. [PR #1681](https://github.com/Imagine-That-Ai/BurnBar/pull/1681) adds typed navigate/screenshot/click/fill requests with exact selected run/call/generation binding and daemon-owned result decoding; `bf0eb36294` adds a consent-scoped RemoteDesktop `Notify*` executor for pointer/key/shortcut/type/scroll/drag with typed libei/uinput-unavailable states and bounded cancellation/timeout/kill-switch teardown. System mode stays hidden when unavailable. A dedicated Linux Firebase web app exists, but the Desktop OAuth client, production callable deployment, release variables, current physical-iPad approval execution, installed browser/panic/audit/restart proof, Agent Watch, and compositor-installed portal receipts remain missing | Partial | Critical |
| P-08 | Mercury media | File transfer, calls, screen share, mirroring, presence, consent | Daemon-owned transport, calls, files, sealed capture, portal consent, HUD, live capability probing, and native inbound Opus playback are implemented. `d814f85f49` adds a canonical request-bound call media seal, fail-closed call acceptance, portal-backed outbound Opus capture, independent audio sequencing, and teardown tests; `bcf0b1a7bf` adds daemon-owned `opusdec`/`autoaudiosink` playback with bounded ingress and route teardown. `81e471e511` adds a typed native regular-file chooser for outgoing Mercury transfers with cancellation, symlink/path validation, and fail-closed old-shell behavior. `dadb756940` adds a signed-installed candidate producer, exact paired Linux/physical-device session binding, 17-target lifecycle contract, event-chain and source-byte validation, feature capture, semantic validator, and 5/5 focused tests. Registry/materializer/workflow ownership, seven environment receipts, and real cross-device/compositor certification remain open | Partial | Critical |
| P-09 | Navigation and shell | Dashboard, insights, deep provider/model routes, multi-window flows | All 19 installed routes activate through AT-SPI. `0fd663a3f5`/`5d10b95bc8` add typed reload-safe provider/model destinations, native validation, single-instance forwarding, history restoration, and focus; the exact ARM64 package passed a live `openburnbar://providers?provider=codex` second-launch route with Codex selected. Secondary-window breadth and multi-monitor restore remain thinner | Near parity | Medium |
| P-10 | Dashboard layouts | Six dense layouts with real live content and persisted state | All six layouts, persistence, loading/error/offline/populated states, tokens, and tests exist; the packaged six-layout visual matrix remains incomplete | Near parity | Medium |
| P-11 | Usage ingestion | 27 parser registrations, API/quota aggregation, recount, projections, cloud mirror | `336ee0eca2` makes the canonical ledger's all-time projection and explicit recount daemon-owned, durable, fingerprint-bound, and rebuildable after stale/tampered cache state; `736fcae8a9` rejects inconsistent totals, invalid ranges, and malformed aggregates at the renderer boundary. `e4e4c15bdb` adds Copilot session-state/log parsing, rotation-safe deduplication, bounded arithmetic, cumulative checkpoint delta ingestion, and a Linux daemon refresh loop; `dd78a83bef` registers the 18 established parser identities with XDG-native editor paths; `5a37e88f8e` adds the remaining nine local-log parser identities with focused exact/estimated provenance tests; `2298e68f49` plus `058ff3c049` derive daemon parser membership and ordering from the generated catalog with a fail-closed factory map; `a6f3ec2b0f` centralizes macOS quota adapter coverage across all 19 declared quota providers; the Linux quota RPC now exposes that canonical adapter coverage and explicit unavailable states; `8ede809724` validates snapshot identity, timestamps, provenance shape, and numeric safety before materialization. Provider/model/source totals and generation flow through typed daemon, Tauri, tray, and UI contracts. Linux quota transport, normalized macOS corpus differential fixtures, cloud mirror integration, and installed signed-candidate evidence remain open | Partial | High |
| P-12 | Quota | Provider quotas, histories, account switching, alerts | Strong read surface with provider credential-slot account switching, explicit auto-routing reset, preferred-slot persistence, and per-slot quota/status labels. `6b707d24b8` retains the last catalog through transient failure. `b76b67e8bc` adds daemon-confirmed failover policy mutation with exact readback/rollback, and `8d9d71fe` pins the macOS canonical modes. `df0822290b` refuses to refresh the provider catalog until a preferred-slot mutation is confirmed by daemon readback; `18231a4a40` preserves Linux quota signal provenance; the Linux RPC now reports 17 live adapter entries and two explicit unavailable providers, and missing registry entries fail closed. The exact ARM64 route passes AT-SPI; populated live switching/drain, thresholds, cloud profiles, and switching-lag telemetry remain open | Partial | Medium |
| P-13 | Onboarding | Provider connection, scan, permissions, chat engine, recovery, completion gates | Daemon-owned state, required-step gates, restart recovery, Secret Service/XDG/privacy readback, catalog-backed credential setup, and first-data readback are implemented. `21a13a6792` adds the real native cloud-auth state machine for start, polling, device approval, cancel, denial, expiry, retry, active verification, fixture, and unavailable outcomes. `dd09dbf737` fences cloud-auth start/cancel responses by request generation and exact bridge/fixture context, so a replaced daemon cannot produce a false current authorizing or cancelled state. Registered installed proof now binds the required gates, temporary credential lifecycle and cleanup, blocked/retry/skip recovery, privacy choices, completion and restart persistence, and four distinct AT-SPI screenshots to the exact candidate. Production OAuth success and full environment execution remain open | Partial | High |
| P-14 | Chat | Persisted threads, search, streaming, models, attachments, citations, approvals, panes/pop-out | Exact encrypted thread list/get/search, idempotent user/assistant persistence, older-message pagination, strict Tauri decoding, durable send ordering, and safe JSON/Markdown export of loaded durable messages are implemented in [PR #1684](https://github.com/Imagine-That-Ai/BurnBar/pull/1684). Model selection/thinking level propagates the exact selected model through the gateway; bounded text and capability-gated PNG/JPEG/WebP/PDF attachments now upload through the daemon and encode provider-native content with enforced model byte limits; `5fdcccabfa` preserves validated attachment ID/name/MIME/size/SHA-256 metadata in JSON/Markdown exports without raw bytes or paths; `702f59146e` canonicalizes extension-derived MIME and `dcca8b74b4` preserves the draft/staged file when native capability is unsupported or unavailable; citations normalize with source/thread validation; tool approvals use daemon-issued IDs with approve/reject/cancel terminal handling; reconnect/visibility and functional options/pop-out boundaries are explicit. `dd705ca1dd` adds strict page/thread/cursor identity checks, bounded load-all traversal, unloaded citation paging, full-history export safety, and validated chat-only pop-out lifecycle. `b46f16c6ed` rechecks backend capability at send time and fails closed before any append or gateway call when daemon configuration has gone stale. `44a5864b0d` and `7017227ac8` require daemon catalog routing capability before a backend is advertised or a live send is attempted. Uploaded bytes are intentionally process-lived and require re-upload after daemon restart. Remaining provider-specific backend coverage and installed proof remain open | Partial | High |
| P-15 | Account and billing | Sign-in/link/sign-out, membership, subscription, recovery | Daemon-owned PKCE, redacted account state, phase-safe switching/sign-out, and cloud-erasure handoff exist. `e7531159b3` adds the canonical portal RPC, production Firebase callable defaults/framing, daemon-owned ID-token/App Check headers, bounded requests, exact OpenBurnBar return URLs, exact Stripe host validation, and active-entitlement routing that never falls back to a second checkout. Registered installed ownership still requires production OAuth, live membership/checkout/portal, recovery, erasure, and signed-candidate evidence | Partial | High |
| P-16 | Cloud and devices | Backup, sync, conflict handling, remote access, trusted device management | Registered ownership coordinates the physical-iPad and Linux probes through owner-only same-run roots. `b45f6378e9` adds the production-code local replica core: SQLCipher/GRDB replica/outbox/cursor/retry state, Cloud Vault AES-256-GCM sealing, stable retry IDs, tombstones, deterministic conflict order, separate backup/remote-read consent, bounded backoff, and an injected daemon status/policy/manual-cycle RPC runtime that keeps UID, keys, tokens, cursors, plaintext, and ciphertext out of the renderer. `45926a4fac` adds atomic compare-and-merge push results, complete acknowledgement validation, authenticated authoritative-winner reconciliation, and consent-aware pending counts. `6d71bc8aff` adds the Firebase gateway and callable handlers with auth/App Check, strict bounded envelopes, idempotent transactional merge, monotonic pull cursors, and exact host/path validation; `7a8391acb5` composes it into daemon startup. `2df8b03a5a` adds explicit Iroh directory host allowlisting, `8776a196f6` exposes daemon-owned cloud-sync and metadata-consent controls in Linux Settings, and `24e1bae875`/`cb118e647f` add daemon-only live-route/trusted-device-gated remote reads plus ECIES credential escrow with metadata AAD and no plaintext persistence. `3bda513f65` adds redacted list/approve/revoke trusted-device RPCs and `ffcae66d4b` wires them through Linux Settings with fail-closed unavailable state. Production callable wiring, approval execution, and live signed two-device proof remain open | Partial | High |
| P-17 | Activity/session logs | Indexed transcript, search, body, replay, resume, export, source resolution | Canonical daemon search/detail/resume, persisted body replay, native resume, and allowlisted JSON/Markdown export are wired. `594dc668ab` preserves the last replay body across failure. `b74bc6d068` marks display fallbacks unverified and resolves them only through complete, unique provider/session/run/project history before replay/resume/export; incomplete, missing, or ambiguous histories fail closed, including resume-from-export readback. `50d139047b` prevents stale overlapping list/search responses from overwriting a newer query's rows, loading state, or errors, with Activity coverage 22/22. The exact ARM64 route passes AT-SPI; populated installed replay/resolution and provider runtime proof remain open | Partial | High |
| P-18 | Memory review | Quarantined candidates, approve/reject, durable state, audit | `752f6e9745` adds a daemon-owned review-status column, quarantine/approved/rejected/forgotten lifecycle, opt-in quarantine feed, metadata tombstones, audit hashes, typed RPC coverage, and renderer fail-closed decisions. Cross-device replication and installed proof remain open | Partial | High |
| P-19 | Projects | Registered projects, exact associations, detail, management | Canonical list/get/upsert and exact identity are wired with register/edit UI; typed delete/reassign lifecycle, tombstones, durable migration, and checkpoint-tail replay protection are source-integrated; installed proof remains open | Partial | Medium |
| P-20 | Missions | Full run/task state, approvals, questions, evidence, history, health | List/create/approve plus canonical get/cancel and typed packet/result/evidence/burn/takeover/PR snapshot detail are wired; `bd9d6a5173` adds authoritative typed health/history over `daemon.mission.health` and renders it in the detail surface. Registered installed proof now binds project upsert, approval, packet/result/evidence/burn/merged-PR linkage, health/history, pending-question answer, daemon restart persistence, detail inspection, and two-step cancellation to exact daemon and AT-SPI receipts with five distinct screenshots. A live signed-candidate execution across the support matrix remains open | Partial | Medium |
| P-21 | Insights | Editorial brief, evidence, citations, follow-ups, comparison, audit | Provenance-labeled brief plus selectable canvas/library/inspector workspace, normalized trend/provider/model/cache widgets, bounded audit disclosure, refresh, chat follow-up handoff, and macOS-style three-scope Compare mode with per-column provenance and source-loss fail-closed behavior are implemented. `e161148b27` preserves the last valid snapshot across bridge/refresh failures, ignores out-of-order responses, and exposes daemon-issued qualitative freshness with invalid/future timestamps failing closed. `708260e4f4` hardens the proof validator to require canonical UTC millisecond timestamps and rejects timestamp mutations in the focused 3/3 suite. The exact-head arm64 package is installed in the non-certifying receipt `linux-arm64-current-2d42a3367c-ui-staged-daemon-2026-07-20.json`; live populated-data proof, qualitative comparison against macOS, signed/cross-device proof, and broader environment certification remain open | Partial | Medium |
| P-22 | Database | Search/inspect indexed sessions, snapshots, watch/recovery, encrypted storage UX | Index/watch foundation plus bounded daemon-owned code search/context-pack inspection are wired in [PR #1680](https://github.com/Imagine-That-Ai/BurnBar/pull/1680), with pagination, trust warnings, and fail-closed capability handling. SQLCipher-gated encrypted snapshots provide owner-only path validation, bounded atomic copy, SHA-256 integrity, rollback, and watcher reopen; `f5d562da82`/`238577c904` add typed recovery status/export/import state, key-loss/device-transfer guidance, partial-capability rendering, passphrase/path validation, and redacted outcomes. `151636ccbc` adds native `.obb` recovery save/open dialogs, `c75b17ea07` adds separate native `.snapshot` save/restore dialogs, and `1504372a2d` extends the `.obb` picker to the Database workspace with cancellation announcements and trigger-focus restoration; all picker paths have strict extension/path/symlink validation and cancellation semantics. `15b7e3c2ee`/`f7c93c7693` add an accessible metadata-only indexed-record inspector with keyboard coverage and bounded path rendering. The final shell passed installed Atlas AT-SPI, but the live daemon exposed no indexed file rows; populated-row inspection and backend recovery on real keyrings remain open | Partial | Medium |
| P-23 | Provider/model workspace | Provider and model deep dives, health, catalog, failover, routing | Daemon-backed provider/model workspace, canonical catalog/config mapping, variants/aliases, health/failover, account routing, and custom-model mutations are integrated. `0fd663a3f5` adds provider/model URL restoration and focus; the current exact package accepted a bounded native Codex destination and passed AT-SPI at 189/108/91/33 nodes/named/actionable/focusable. `b7a4eb42e6` and `a1806729ec` add and harden a registered candidate-bound installed proof for two real credential slots, deterministic failover, model/alias/variant persistence, provider/model/alias deep links, healthy/degraded/unavailable states, exact config restoration, secret redaction, and five distinct screenshots. A live signed two-slot execution across the support matrix remains open | Partial | Medium |
| P-24 | Settings | 16 searchable tabs with deep links and selected writable state | Registered candidate-bound proof covers all 16 searchable Settings tabs without claiming that every tab is writable. It performs exactly four real reversible writes through the installed daemon and desktop, verifies them through AT-SPI and canonical readback, proves restart persistence and XDG launch-at-login, exercises degraded and recovery states, and restores the exact prior settings, service, autostart, and privacy state. `fb3afed33b`/`faa50c0e7a` harden notification readback defaults, range checks, de-duplication, and fractional-value rejection. A live signed-candidate execution across the support matrix remains open | Partial | Medium |
| P-25 | Updates | Automatic checks, channel, install/restart truth | Registered proof ownership now authenticates exact same-architecture previous and candidate packages through signed installed manifests and signed product closures, records exact native package-manager update/rollback/restore commands, proves data preservation, captures available/current/error/restart UI states, induces a controlled process-local feed outage, and verifies exact proxy restoration. A live signed-candidate execution still fails closed without a compatible public previous release and valid promoted feed history. | Partial | High |
| P-26 | Tray and native shell | Rich live menu-bar status, quick switch, chat, quota, update state | Native tray exposes dashboard/chat/usage/updates/settings routes, daemon health, recent usage, signed-update state, refresh/reconnect, and quit actions; `dcca8b74b4` packages the canonical XDG autostart entry and honors tray-first `--background` startup. Registered candidate-bound proof now covers package ownership, live DBusMenu revision/actions, disconnect/reconnect, relaunch, accessibility, and exact restoration. Live signed-candidate compositor/DE execution remains open | Partial | High |
| P-27 | Notifications/deep links | Actionable notifications, OAuth return, global commands, login start | Registered candidate-bound proof invokes the real Tauri/WebDriver surface, activates an actual native notification action through AT-SPI, proves cold-start reply queuing and route/focus delivery, and validates strict deep links plus state-bound single-use PKCE wrong-state/replay rejection. Live signed-candidate execution requires `tauri-driver` and `WebKitWebDriver` in each target environment and remains open | Partial | High |
| P-28 | SmartHub | Discovery, status, allowlisted device actions | Registered candidate-bound proof requires the trusted package-owned CLI, daemon launch path, and desktop process, then proves live advertise/browse/discover/status/control, bridge loss/recovery, daemon and desktop restart, AT-SPI, screenshots, bounded output, provenance, and exact restoration. Live signed-candidate environment and real-device execution remains open | Partial | High |
| P-29 | Text expansion | Global, secure-field-aware expansion, persistence, sync, previews | Registered candidate-bound proof drives the package-owned IBus engine through real GTK free-form and password fields, proving normal expansion, secure-field denial before write, daemon-owned AES-GCM persistence with Secret Service/KWallet custody, cancellation/kill/restart behavior, AT-SPI, screenshots, provenance, and exact prior-engine/state restoration. Live signed-candidate IBus/keyring execution across the support matrix remains open | Partial | High |
| P-30 | Pet companion | Animated ambient overlay, click-through, summon, selection, interactions | Typed runtime-manifest probe, contained draggable fallback, accessible summon/focus/status, and selection/clear controls are honest. `3b652f9b9e` adds bounded pointer/mouse drag and Arrow/Home keyboard repositioning with focus metadata and announcements for the Wayland-safe contained substitute. `5c3caab2e` adds the X11-only `Ctrl+Alt+Super+P` summon route and `2b85f1431` exposes `aria-keyshortcuts`. `3acc18fad2` adds the registered candidate-bound installed proof package: X11 must prove the native child, always-on-top state, global summon, and explicit click-through restoration; Wayland must prove the contained fallback without an overlay claim; both prove selection/clear, pointer/keyboard movement, AT-SPI, relaunch, package identity, distinct screenshots, and exact restoration. The seven-environment signed-candidate execution remains open | Partial | High |
| P-31 | Accessibility | Semantic UI, keyboard flows, assistive announcements, reduced effects | All routes pass axe; global reduced-motion, forced-colors, and prefers-contrast styling plus keyboard/status contracts are implemented in [PR #1683](https://github.com/Imagine-That-Ai/BurnBar/pull/1683), with live reduced-motion preference updates and cleanup in `7cd30e2e71`; `fdd3ff61ad` adds command-palette dialog/combobox/listbox semantics, focus containment/restoration, active-option announcements, and names for icon-only toolbar actions; `534d7aae65` makes the command-deck overflow menu keyboard-complete with Arrow/Home/End, Enter/Space, Escape, and trigger-focus restoration (focused overflow tests 2/2). Nightly `29646670763` passed 19-route X11 AT-SPI/Orca, keyboard, 200% zoom, onboarding, and text-expansion evidence, while broader desktop/high-contrast breadth remains | Near parity | High |
| P-32 | Performance | Startup/recovery/frame/cadence budgets and mature profiling | Nightly `29646670763` passed matched 30-minute macOS/Linux correctness/resource soak and packaged X11 thresholds: `route.navigation` p95 `95.6 ms` across 33 samples versus the `120 ms` budget, app start p95 `333.9 ms`, IPC health p95 `111.65 ms`, and tray-open p95 `123.55 ms`. `376428d56f` adds registered fail-closed candidate-bound installed ownership across the matched macOS/Linux reports, native packaged-session metrics, budget enforcement, exact source digests, package identity, report freshness, and collection-window coherence. The seven-environment signed-candidate execution, comparable hardware, suspend/keyring recovery, and broader matrix profiling remain open | Near parity | High |
| P-33 | Reliability | Backoff, supervisor, recovery, subscriptions, migrations, long-idle stability | Registered installed ownership covers crash/restart, daemon loss/recovery, offline transitions, subscription continuity, stale-response fencing, bounded retry, accessibility, and exact restoration. Native push, long suspend/idle, portal/keyring and migration faults, multi-hour soak, and seven-environment signed certification remain | Partial | High |
| P-34 | Security hardening | Native URL/secret/process boundaries | Generic renderer shell permission and token exposure removed; production fixtures disabled; full installed adversarial matrix remains | Near parity | Critical |
| P-35 | Diagnostics/support | Native export, privacy choices, accurate runtime/package facts | Metadata-only redacted export, native portal save, path revalidation, private atomic output, preview, and bounded packaged-shell reconnect exist. Registered installed ownership now proves bundle contents/redaction, destination and permission behavior, runtime/package facts, degraded/recovery states, restart, accessibility, and restoration. Seven-environment signed execution remains open | Partial | Medium |
| P-36 | Visual/interaction polish | Consistent components, responsive density, animations, native affordances | Registered installed ownership requires exact 720x900, 1180x820, and 1600x900 DPR-1 WebDriver screenshots plus state-bound AT-SPI at compact/light, standard/dark, wide, reduced-motion, and overflow states. It fails on clipping, overlap, weak contrast, dishonest theme/motion, broken keyboard focus/menu behavior, compositor mismatch, restart drift, or incomplete restoration. Live seven-environment baselines and remaining raw diagnostics polish remain open | Partial | Medium |
| P-37 | Linux matrix | N/A; macOS supported versions are exercised | Environment-bound fail-closed harness binds installed/accessibility evidence to exact environment, architecture, session, and desktop identity (`b012a53a6c`); Nightly `29646670763` passed the runnable Ubuntu GNOME/X11 packaged session while recording Arch/wlroots, GNOME Wayland portal, and Fedora/KDE as explicit blocked rows; current-head promotion and architecture/keyring/portal rows remain open | Partial | Critical |
| P-38 | CI/release automation | Test, sign, package, and promotion jobs fail closed | Strict gates, mutation tests, native architecture shards, sessions, and signed aggregate closure are implemented; Release `29646670068` and Nightly `29646670763` passed their current-head gates, including the root-owned evidence wrapper fix; lifecycle, production, and product/environment promotion remain open | Partial | Critical |
| P-39 | Cross-platform differential proof | Same contract/corpus compared at the same product version | A bounded evidence comparator is implemented in [PR #1682](https://github.com/Imagine-That-Ai/BurnBar/pull/1682): it normalizes object order, redacts credential values, rejects duplicate object keys (including escaped-equivalent keys) before comparison, supports explicit volatile paths, emits path-level differences, and fails closed with machine-readable exit codes. A same-commit macOS/Linux artifact run is still required | Partial | High |
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

**Implementation update (2026-07-10; current-head reconciliation 2026-07-23):
partially closed in the implementation branch.** The parity claim is false, the
generated ledger has all 40 audit requirements at 0 ready/40 blocked, and
strict verification cryptographically binds artifacts, signatures, source,
SBOM/VEX, provenance, feed, architecture sessions, and Sigstore inputs. The
current verifier also rejects blocked lifecycle rows during promotion, checks
the signed feed's schema/MIME/allowlisted hosts and exact artifact coverage,
and fails on stale or contradictory closure metadata. Clean aarch64 and
architecture-correct x86_64 shards at `391fe2847d` each produced all four
required artifacts and passed 28 package-smoke steps. Promotion remains
blocked until an installed x86_64 session, native hosted x86_64 run, final
signed aggregate, valid public feed, and prior-version
update/rollback/data-preservation proof all exist.

- **Difference:** macOS release confidence comes from a signed product and a
  delivery path that can be exercised. Linux's four public Ed25519 artifact pairs
  pass, but the mission-002 local closure diverges and all four local pairs fail.
  The remaining Linux gap is live promotion evidence: the verifier cannot turn
  local metadata into proof that the public candidate, hosted feed, previous
  release, and installed environments are the same bytes. The current JSON
  ledger intentionally says parity is false and keeps all 40 rows blocked.
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
- **Implementation notes:** the current verifier already binds artifact hashes,
  public-key fingerprints, detached signatures, provenance, SBOM/VEX, source,
  architecture sessions, feed metadata, and the parity ledger. Keep the
  mission-002 local bundle non-promotable; the remaining implementation is the
  release-operator path that produces a current signed aggregate, verifies the
  hosted feed and previous release, and records installed environment receipts.
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

**Current live update (2026-07-19, source `a570c9b087`):** the exact arm64 DEB
is installed in the Ubuntu 24.04 GNOME/X11 guest with the package-owned user
service enabled and active (`MainPID=49010`, health `ok=true`). The packaged
desktop is running from `/usr/bin`; post-restart journal inspection found no new
peer rejections, and the daemon resolves the packaged FTS5 SQLCipher library.
This closes the previously observed service registration, Linux peer-lookup, and
database-bootstrap failures for this candidate, but it does not close signed
provenance, x86_64, upgrade/rollback, suspend/resume, compositor, or full visual
certification.

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
  daemon probe fails closed. Keep fixture paths disabled in production. Inbound
  Downloads destinations are reserved atomically before the asynchronous blob
  fetch so concurrent offers cannot overwrite one another.
- **QA verification:** Linux-to-macOS/iOS/Android pair/unpair, file send/receive,
  call, screen share, cancel/reject, packet loss, reconnect, suspend, permission
  denial/revocation, codec absence, cleanup, and multi-monitor selection on each
  supported compositor and architecture.

### GAP-007 - Make usage/provider coverage authoritative

**Implementation update (2026-07-21): authoritative projection/recount, local
parser catalog, and fail-closed snapshot validation implemented; external
sources and installed proof remain open.** `336ee0eca2` derives the durable
all-time projection from the canonical daemon ledger, fingerprints it, rebuilds
stale or tampered state, and exposes an explicit recount RPC without changing
the ledger. `736fcae8a9` rejects negative, non-finite, out-of-range, or internally
inconsistent aggregate values before the UI accepts them. This closes the
projection/recount authority gap, not the complete parser/catalog, API/quota,
cloud-mirror, installed, or cross-platform corpus gap.

- **Difference:** macOS registers 27 parsers and combines local logs, APIs,
  quotas, recount, persistence, projections, and cloud mirroring. Linux now has
  the same 27 local parser identities in its daemon default registry, with
  membership and ordering derived from the generated
  `AgentProviderIngestionCatalog` through a fail-closed typed factory map
  (`2298e68f49`). `8ede809724` validates provider identity, expected-provider
  matching, provenance shape, future timestamps, and finite bucket values before
  Linux materialization. The generated
  `contracts/provider-ingestion-catalog.json` plus
  `providerPathRegistry.swiftParity.test.ts` bind parser/path/UI declarations
  to one catalog. API/quota account polling, cloud mirroring, and installed
  cross-platform corpus proof remain incomplete.
- **Why it matters:** missing or mislabeled usage silently breaks the app's core
  value and makes parity counts unreliable.
- **Recommended solution:** keep the shared provider/model/path manifest as the
  source of truth, extend its platform-specific API/quota/account capabilities,
  and reuse identical golden parser/quota fixtures for macOS/Linux runs.
- **Priority:** **High**.
- **Implementation notes:** include feature flags for local scan, API polling,
  quota, chat backend, account switching, model catalog, and secret needs; map
  XDG, symlink, Flatpak, Snap, malformed log, and multi-account cases.
- **QA verification:** generated-catalog parity and all 27 Linux registrations
  are source-tested. Remaining verification is an identical macOS/Linux input
  corpus producing equivalent normalized usage, cost, quota, model/provider
  identity, timestamps, and deduplication; every declared provider still needs
  path, parser, empty, error, and migration fixtures on the installed candidate.

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
remains required. The daemon now also fails closed when the onboarding state
file or support directory is a symlink, including dangling links, preserving
the intended `0700`/`0600` ownership boundary (`50a0684e75`).

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
  explicit optional skips; link failures directly to repair actions. State-path
  symlinks are rejected before read/write so onboarding cannot escape its
  daemon-owned support directory.
- **QA verification:** clean-user journeys on Ubuntu/Fedora; missing daemon,
  locked keyring, no provider, offline auth, portal denial, icon-only tray,
  partial completion, app restart, upgrade migration, screen reader, and keyboard.

### GAP-009 - Finish the chat workspace

**Implementation update (2026-07-23):** the parity ledger is now aligned with
the shipped behavior: Linux renders actionable approve/reject/cancel controls
when a daemon-issued run approval ID is present, and keeps gateway-only tool
calls unavailable when that identity is missing. No renderer-generated approval
IDs or implicit approvals are allowed.

- **Difference:** macOS supports persisted/searchable threads, twelve backends,
  model selection, streaming, attachments, citations, tool approvals, panes,
  desktop grants, resume/export, and pop-out. Linux now has real encrypted
  thread persistence/search/pagination, exact model/thinking-level selection,
  daemon-owned bounded single-use attachment refs, citations, approvals, and
  bounded unloaded-history/export/resume/pop-out behavior. Model-authorized
  PNG/JPEG/WebP image inputs now pass the shared daemon policy and the Tauri
  gateway's native capability path. Remaining backend breadth, provider-native
  PDF semantics, and installed proof remain incomplete. The Responses fallback
  now preserves data-backed `input_file` PDFs/images through the same bounded
  Chat Completions bridge; unresolved file IDs and remote URLs fail closed.
- **Why it matters:** chat is a primary workflow; presenting a file or model
  control without a real transport still creates false confidence and data-loss
  risk. `44a5864b0d` requires a daemon catalog routing capability before a
  backend is advertised, and `7017227ac8` verifies that a missing catalog fails
  closed before any durable append or gateway call.
- **Recommended solution:** extend the implemented attachment ref store into
  provider-native PDF/binary handling where the selected model declares it,
  finish the remaining backend adapters,
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

**Implementation update (2026-07-21): proof ownership complete; behavior and
certification remain open.** P-15 now owns an installed account/billing
WebDriver and AT-SPI lifecycle. P-16 now owns a same-run physical-iPad/Linux
trust-cycle handshake with separate owner-only macOS and Linux coordination
roots, nonce/fingerprint binding, cleanup, restart, and restoration. These
owners make missing or replayed evidence fail closed; they do not supply
production OAuth, billing, backup/sync/conflict behavior, or a passing live
device receipt.

`b45f6378e9` also implements the P-16 daemon's encrypted local-first replica
engine and injected socket runtime: per-domain consent, separate remote-read
consent, AES-256-GCM Cloud Vault envelopes, SQLCipher/GRDB replica/outbox/cursor
state, stable retry IDs, tombstones, deterministic conflict handling, capped
backoff, and redacted status/policy/manual-cycle RPCs. The production Firebase
gateway and process composition, Account UI, Iroh authorization/read path,
credential escrow, and live two-device execution remain required.

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
  UI describes semantics the backend does not provide. `50d139047b` now
  prevents stale overlapping Activity responses from replacing newer rows,
  loading state, or errors, but full-history source resolution and installed
  proof remain incomplete.
- **Recommended solution:** complete session source/full-history/export RPCs and
  cross-device memory audit replication; retain the implemented durable
  quarantine decision path and bounded replay/resume.
- **Priority:** **High**.
- **Implementation notes:** preserve exact source/session/project IDs; support
  local/cloud conflict and missing-body recovery; make review decisions
  idempotent and auditable; never infer transcript content from usage metadata.
  Complete daemon-history JSON exports now retain `sourceID`/`runID`, reject
  duplicate or paged identities, enforce bounded metadata/transcript sizes, and
  resume only the selected source through the live daemon (`a5522bfc54`).
- **QA verification:** exact replay, full-text search, source filters, export,
  resume, large pagination, missing/corrupt body, cloud conflict; pending memory
  create/approve/reject/reload/audit/forget/chat retrieval across devices.

### GAP-012A - Complete Projects

- **Difference:** The Linux source path now matches the macOS project lifecycle:
  registered project objects have exact stable identities, detail/history views,
  create/edit, typed delete, and explicit session reassignment through the
  daemon-owned controller RPCs. The remaining difference is operational proof:
  the current-head signed installed candidate, migration/large-history behavior
  on Linux, and cross-device conflict behavior have not all been certified.
- **Why it matters:** project identity drives search, insights, missions, and chat;
  without installed and migration receipts, a source-level implementation can
  still regress in packaging, persistence, or recovery without detection.
- **Recommended solution:** certify the existing lifecycle on the signed Linux
  candidate, run the 10k-session migration and restart/reload scenarios in the
  Linux guest, and add cloud/local conflict receipts before claiming parity.
- **Priority:** **Medium**.
- **Implementation notes:** retain daemon-owned stable IDs and tombstones; keep
  delete/reassign typed and idempotent; preserve orphan history for reassignment;
  paginate large projects; never use display titles as identity.
- **QA verification:** on the exact signed candidate, create/edit/delete/register/
  reassign/reload; duplicate names, moved repositories, orphan sessions,
  daemon restart, cloud/local conflict, 10k sessions, and migration from legacy
  inferred associations. Bind every receipt to the candidate hash and runtime.

### GAP-012B - Complete Missions

- **Difference:** Linux now has daemon-backed questions, packet/result evidence,
  ordered health history, freshness, cancellation, and an approval/readiness-
  gated Start/Resume action (`bc30c6a796`). The remaining difference is macOS's
  deeper takeover/recovery orchestration plus installed and cross-device proof.
- **Why it matters:** users cannot understand or safely operate a long-running
  mission from Linux when state changes, stalls, or requires intervention.
- **Recommended solution:** retain the daemon-owned dispatch boundary, add typed
  takeover/recovery orchestration when the runtime contract is ready, and certify
  start/resume/cancel/reconnect on the signed installed candidate.
- **Priority:** **Medium**.
- **Implementation notes:** keep ordering and idempotency daemon-owned; separate
  mission state from transient UI state; preserve evidence IDs and audit links.
- **QA verification:** create/start/approve/deny/answer/cancel/resume/retry/recover;
  verify approval and readiness rejection before side effects, packet/history
  ordering, stale/fresh transitions, missing evidence, daemon restart, concurrent
  decisions, and offline/reconnect.

### GAP-012C - Complete Insights

- **Difference:** Linux now has typed source/evidence provenance, bounded
  citations, provider/model comparison, follow-up chat handoff, audit disclosure,
  and freshness states alongside usage charts and qualitative summaries. The
  remaining difference is backend/domain depth: macOS supplies richer editorial
  analysis and production evidence across the full source corpus, while Linux
  still depends on the daemon's current bounded usage response and has not
  completed installed or cross-device proof.
- **Why it matters:** a polished evidence UI is only trustworthy when the
  underlying analysis is complete, fresh, and backed by the same source depth as
  macOS; otherwise users may overread a bounded summary.
- **Recommended solution:** retain the typed insight/evidence model and extend
  daemon-owned analysis over the full source corpus, preserve citation and
  compare provenance, and certify stale/missing-source behavior on the signed
  installed candidate.
- **Priority:** **Medium**.
- **Implementation notes:** preserve source IDs and generated-at freshness; make
  unsupported inference explicit; share calculation and citation fixtures.
- **QA verification:** evidence-linked insight generation, stale data, missing
  source, compare filters, follow-up navigation, audit history, keyboard/screen
  reader, and large-period performance.

### GAP-012D - Complete Database and indexing operations

- **Difference:** Linux has index/watch foundations, bounded daemon-owned code search/context-pack inspection, and a metadata-only record inspector through [PR #1680](https://github.com/Imagine-That-Ai/BurnBar/pull/1680) and the current Database surface. It now also has SQLCipher-gated encrypted snapshot/restore with owner-only path checks, size bounds, integrity hashes, atomic replacement, rollback, and watcher reopen, plus a macOS-compatible v1 passphrase recovery bundle with PBKDF2/AES-GCM and native key-custody hooks. `da9d6a5188` closes the fresh-profile key-provisioning gap by persisting a 256-bit native Secret Service/KWallet key before first database creation or plaintext migration, with persisted readback and no replacement for unreadable ciphertext. It still lacks raw-content inspection, key-loss/device-transfer recovery depth, deep rebuild UX, live candidate-bound keyring proof, and installed proof on the new code.
- **Why it matters:** users can inspect bounded metadata, but cannot yet reveal
  authorized raw record content, diagnose every missing session, or complete
  key-loss/rebuild recovery with the same depth as macOS.
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

- **Difference:** macOS and Linux now both expose 16 searchable settings tabs
  with matching section taxonomy. Linux still has narrower detail depth for
  dashboard defaults, indexing/summaries, and some cloud/device/media/privacy
  mutations; several controls remain capability-gated or read-only until an
  installed daemon provides the corresponding contract.
- **Why it matters:** configuration is scattered, capabilities are hard to
  discover, and users cannot exercise privacy or operational agency.
- **Recommended solution:** generate settings metadata from a shared capability
  schema, provide searchable deep links, add Linux-native detail pages, and back
  all mutable controls with typed daemon configuration plus readback.
- **Priority:** **Medium**.
- **Implementation notes:** unavailable controls must explain the native
  substitute; store UI navigation locally but product policy in the daemon;
  preserve distro/compositor-specific help without forking the schema. The
  current Linux shell shares the settings matcher between sidebar and detail,
  keeps the current tab when it still matches, selects the first matching tab
  for a new query, and reports an explicit no-results state (`6f57349c66`).
  Its section grouping now mirrors the macOS settings taxonomy exactly
  (`d1cb5e517d`), Calendar hold duration is persisted through the notification
  config RPC (`3004da3b72`), and `fb3afed33b`/`faa50c0e7a` make notification
  readback default missing fields, bound snooze/calendar/hour values, preserve
  safe command defaults, de-duplicate hours, and reject fractional values.
  Deeper per-tab daemon writes plus installed proof remain open.
- **QA verification:** search/deep-link every setting, keyboard navigation,
  persistence/restart, policy conflicts, telemetry opt-out at emission source,
  unavailable capability copy, and migration from existing localStorage keys.

### GAP-014 - Build native tray, notifications, deep links, shortcuts, and startup

- **Difference:** macOS provides a rich menu-bar experience with live cost,
  quota, providers, quick switch, chat, freshness, and update state. Linux now
  has a validated startup/deep-link handoff, background tray launch, XDG
  autostart, desktop MIME registration, freedesktop action routing, and
  per-binding shortcut health in [PR #1679](https://github.com/Imagine-That-Ai/BurnBar/pull/1679),
  `5f74018422`, and `a5571694bb`. `811d84172a` also retains native notification
  actions until the renderer is ready, preventing cold-start Reply/open loss;
  complete installed host lifecycle and cross-desktop receipts remain open.
- **Why it matters:** repeated daily workflows, alerts, recovery, auth, and panic
  controls feel incomplete or cannot work outside the main window.
- **Recommended solution:** finish StatusNotifier/AppIndicator host behavior,
  preserve the typed per-binding X11/Wayland/unknown shortcut states, and add
  installed freedesktop lifecycle receipts without treating unsupported
  compositors as available.
- **Priority:** **High**.
- **Implementation notes:** support GNOME's icon-only limitations; use shared
  live view models and freshness semantics; keep the native action queue bounded
  and drain it exactly once before normal event delivery; never depend on the
  tray as the sole panic path; handle multi-monitor placement and tray host loss.
- **QA verification:** icon-only and rich hosts, stale/offline/reconnect state,
  keyboard/screen-reader navigation, notification actions emitted before and
  after renderer bootstrap (including Reply composer focus), OAuth return,
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
feed validator now also requires first-party release paths for both artifact and
detached-signature URLs, not only an allowlisted host (`c095761b07`). The
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

**Implementation update (2026-07-23):** `89bfaab3c3` exposes the native
`pixel_clock_control` operation in the Linux selector, so the UI no longer
omits a capability that the daemon already advertises. Focused SmartHub,
decoder, and bridge coverage is 36/36. Live device outcomes remain open.

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

**Implementation update (2026-07-23):** `9c5cc7abf2` wires the already-tested
daemon-owned encrypted replica engine through canonical Tauri commands and the
typed renderer bridge. The follow-on runtime hardening makes global cloud
consent authoritative at the daemon boundary: status, policy mutation, manual
sync, and the background loop return a disabled/redacted state before resolving
identity, vault keys, or gateway credentials whenever the global switch is off
or unreadable. Settings now exposes a separate, explicit
`text_expansion` domain consent toggle plus daemon-reported locked/backoff,
pending, failure, and manual-run state. The shell never receives credentials,
vault keys, cursors, ciphertext, or snippet payloads. Focused bridge/settings
coverage is included in the full 107/107-file, 1016/1016-test frontend gate;
native keyring/IME, conflict, signed-candidate, and environment receipts remain
open.

- **Difference:** macOS provides global, accessibility-aware expansion with
  persistence and sync. Linux now keeps snippets and consent in daemon-owned
  AES-GCM sealed storage with native Secret Service/KWallet key custody and
  ships an explicitly consented, signed IBus engine with trigger-only daemon
  expansion and secure-field denial. Fcitx native-addon support, sync, and
  installed cross-desktop proof remain open.
- **Why it matters:** durable snippets must not live in renderer storage, and an
  honest in-app substitute must never silently become a global keylogger.
- **Recommended solution:** retain the daemon boundary and explicit consent,
  finish the IBus keyring/secure-field and desktop matrix receipts, then add a
  separately signed Fcitx5 addon only if its native package can preserve the
  same no-global-capture contract; add conflict-aware sync afterward.
- **Priority:** **High**.
- **Implementation notes:** no renderer localStorage or evdev/global capture;
  use the daemon RPC canon, AES-GCM associated data, owner-only permissions,
  native key custody, consent gating, trigger-only JSONL, secure-field hooks,
  and fail-closed missing-key/corruption behavior. Capability-gate Wayland/X11
  behavior and define import/export/sync conflicts and LLM preview privacy.
- **QA verification:** focused tests cover consent gating, Composer expansion,
  RPC wire names, encrypted persistence/restart, permissions, tamper/corruption,
  missing native secret backend, and no-global-capture scans. Remaining QA is
  normal app inputs, GTK/Qt/Electron apps, password/secure fields, excluded
  apps, clipboard restore, IME composition, Unicode, recursion, import/export,
  sync, GNOME/KDE Wayland, and X11.

### GAP-018 - Ship a real compositor-aware pet companion

**Implementation update (2026-07-23):** `51612362fd` adds native-child close and
re-summon behavior plus a keyboard-accessible Wave/Open chat toolbar in the
companion child. Focused pet, bridge, and window coverage is 74/74. Linux still
does not claim macOS-level attachment drops, avatar selection, or compositor
behavior without live proof.

- **Difference:** macOS has an animated desktop companion with mature overlay
  behavior and interaction. Linux now mounts the bundled glTF mesh/animation,
  provides an accessible draggable contained fallback, and gates the native X11
  child behind an exact session/window/source contract. Cross-compositor proof,
  native chat/file interactions, and complete multi-monitor behavior remain open.
- **Why it matters:** without installed compositor receipts, focus, topmost,
  click-through, and restart behavior can still regress; missing interactions
  also leave the companion less useful than macOS.
- **Recommended solution:** certify the existing X11 child and fixed-marker
  summon contract, then add native selection/chat/file interactions and
  multi-monitor behavior where the desktop contract supports them. Keep the
  explicitly labeled contained fallback for Wayland/unknown sessions.
- **Priority:** **High**.
- **Implementation notes:** maintain a compositor capability matrix; use reduced
  motion and GPU budgets; do not claim click-through from environment variables
  alone; isolate crashes from the main app.
- **QA verification:** GNOME/KDE/Sway Wayland and X11 focus, click-through,
  topmost, drag, scaling, animation, reduced motion, multi-monitor, hotkey,
  restart, GPU fallback, and unsupported contained mode.

### GAP-019 - Replace synthetic accessibility evidence with assistive-tech proof

**Implementation update (2026-07-19): source polish is now explicit; certification
remains open.** All 19 routes and important states run through axe; the installed
`.deb` is exercised through AT-SPI actions, Orca process/focus observation,
keyboard-only traversal, and requested 200% zoom. PR #1683 adds shared
`prefers-reduced-motion`, `prefers-contrast: more`, and `forced-colors: active`
tokens/focus/status rules with DOM keyboard/status contracts. The full shell
verifier rejects missing or synthetic accessibility artifacts. GNOME/KDE matrix
breadth, high-contrast visual captures, and physical assistive-tech execution
remain open. `534d7aae65` closes a concrete command-deck gap: the overflow menu
now enters focus on open, supports roving Arrow/Home/End navigation and
Enter/Space activation, and returns focus to its trigger after Escape or an
action; its focused regression suite is 2/2. `52a77d9ab1` applies the same
keyboard contract to the section switcher listbox: opening moves focus into
the selected option, Arrow/Home/End rove through options, Enter/Space
activate, and Escape restores trigger focus.

- **Difference:** macOS has broad semantic labels/actions and targeted tests.
  Linux has useful landmarks, a skip link, ARIA live regions, focus styling, and
  reduced-motion CSS. Before `534d7aae65`, the command-deck overflow menu
  exposed a menu role but left keyboard users on the trigger, lacked predictable
  list navigation, and did not consistently restore focus after actions; broader
  AT-SPI proof still needs the full desktop matrix. The section switcher now
  exposes the equivalent listbox keyboard/focus behavior through
  `52a77d9ab1`.
- **Why it matters:** visual/component tests do not prove keyboard completion,
  screen-reader meaning, focus order, contrast, reflow, or live announcements.
- **Recommended solution:** keep the overflow-menu and section-switcher
  keyboard contracts and regression tests, then run axe on every route and
  important state; add
  Playwright keyboard/zoom/forced-colors/reduced-motion checks; exercise the
  packaged app with Orca and AT-SPI; fix focusable `aria-hidden` elements and any
  focus rules that remove the indicator.
- **Priority:** **High**.
- **Implementation notes:** subscribe to media-query changes, test dynamic
  state, standardize names/roles/states/errors, and record the actual AT-SPI tree
  plus action transcript; include hardware/software rendering and high contrast.
- **QA verification:** zero serious axe violations; overflow menu and section
  switcher open with ArrowDown, cycle with Arrow/Home/End, activate with
  Enter/Space, close with Escape, and restore trigger focus; every other flow
  remains keyboard-complete with visible focus, no trap, 200% zoom/reflow, Orca
  names/roles/states/actions, live regions, GNOME High Contrast, reduced motion,
  and no color-only meaning.

### GAP-020 - Add real reliability, performance, and installed-shell gates

**Implementation update (2026-07-21): foundation and proof ownership
implemented; certification remains open.** P-33 now owns installed
crash/restart, daemon loss/recovery, offline transitions, subscription
continuity, stale-response fencing, bounded retry, accessibility, and exact
restoration evidence. P-32 retains the matched performance owner. Neither owner
has passed the complete signed seven-environment matrix.

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

- **Difference:** macOS uses narrow native service APIs; Linux now has the
  corresponding narrow Tauri command set, CSP, strict URL/argument validation,
  Rust-owned gateway secrets, and a production fixture module that fails closed.
  The remaining difference is operational proof that signed release artifacts
  contain no fixture activation path and that every sensitive mutation remains
  on the typed allowlist.
- **Why it matters:** WebView compromise must not gain process-launch leverage,
  and users/evidence must never mistake fake data for live state.
- **Recommended solution:** retain the narrow command boundary and bind the
  release-bundle scan, fixture-provenance receipts, and mutation tests to every
  signed candidate.
- **Priority:** **Critical** for bearer/shell containment; **High** for fixture
  leakage proof.
- **Implementation notes:** keep external URL validation centralized; preserve
  command-level schema validation and production fail-closed fixtures; record
  live vs fixture provenance in every evidence artifact.
- **QA verification:** arbitrary command, local-file URL, unexpected scheme,
  non-HTTPS host, argument injection, oversized payload, path traversal, and XSS
  probes all fail; release artifacts have no fixture activation path; debug mode
  shows a banner on every route and never contaminates release evidence.

### GAP-022 - Finish diagnostics and visual/interaction polish

**Implementation update (2026-07-21): proof ownership complete; live visual and
support certification remain open.** P-35 owns the installed diagnostics export,
redaction, native destination, degraded/reconnect, restart, accessibility, and
restoration contract. P-36 owns exact-size DPR-1 WebDriver screenshots and
state-bound AT-SPI for compact/light, standard/dark, wide, reduced-motion, and
overflow states, including contrast, clipping/overlap, focus/menu keyboard
behavior, compositor identity, restart, and restoration. These contracts are
not substitutes for executing and reviewing all seven environment baselines.

- **Difference:** macOS provides mature native windows, consistent controls,
  recovery states, and polished data density. Linux has a strong token base but
  retains inline styles, Unicode/emoji control glyphs, raw JSON panels, inaccurate
  save-dialog copy, and no trustworthy current visual regression set. A concrete
  recovery gap is now closed: `519f0456a7` adds a packaged-shell-only Reconnect
  action to degraded Support diagnostics instead of leaving users with retry
  text only.
- **Why it matters:** the product reads as an engineering console in several
  routes and support bundles may not contain the facts needed to recover users.
- **Recommended solution:** use shared components and iconography, complete
  loading/empty/error/recovery states, keep Reconnect bounded and unavailable in
  fixture/browser preview, add native save dialogs and privacy tiers, and capture
  packaged visual regressions at supported sizes and renderers.
- **Priority:** **Medium**.
- **Implementation notes:** diagnostics should include redacted daemon/package/
  renderer/capability/version facts with 0600 permissions; users preview content
  and choose destination; remove raw JSON from normal flows; keep compact-density
  and responsive behavior aligned with macOS outcomes, not SwiftUI pixels.
- **QA verification:** desktop/compact/200% scale screenshots, no clipping or
  overlap, consistent hover/focus/disabled/error states, Support degraded health
  showing Reconnect only in the packaged shell, one refresh call per activation,
  disabled `Reconnecting...` busy state, dark/high-contrast, save/cancel/
  permission behavior, corrupted daemon/package mismatch bundles, and
  token/path/session-content redaction.

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
| P-01 through P-40 proof ownership | **Complete infrastructure** | **40/40** registered owners at `df1852fae2`; exhaustive ownership/preflight **44/44** | Execute each owner against the exact signed candidate and collect all seven environment receipt sets; current strict status remains 0/40 and 0/7 |
| P-11 authoritative usage projection | Implemented in source; breadth and installed proof open | `336ee0eca2`/`736fcae8a9` authoritative projection/recount and strict aggregate decoder; `e4e4c15bdb` Copilot parser plus durable daemon ingestion loop | Lift the remaining parser identities into the Linux runtime, complete API/quota/cloud mirror coverage, normalized macOS/Linux corpus, and signed installed execution |
| P-15 billing portal | Implemented in source; production proof open | `e7531159b3` portal RPC, callable defaults, auth/App Check, URL validation, paid-member routing, Tauri/UI wiring; focused Rust/TS/Swift parse checks green | Production OAuth/App Check/Stripe session and account recovery/erasure proof on the exact signed candidate |
| P-16 encrypted local replica | Core/runtime implemented; production composition open | `b45f6378e9` encrypted SQLCipher/GRDB replica and injected runtime; `45926a4fac` authoritative conflict reconciliation and consent-aware pending state | Firebase gateway and daemon-main composition, Account UI, Iroh remote read authorization, credential escrow, keyring/two-device/live signed proof |
| LNX-GATE-001, LNX-REL-VERIFY-001, LNX-CI-001 | Implemented | Complete blocked inventory, crypto/closure mutations, strict workflow wiring | Exact signed candidate and all required rows green |
| LNX-SEC-001, LNX-IPC-001, LNX-CAP-001 | Implemented | Native secret custodian, native gateway proxy, production fixture boundary, runtime capability manifest | GNOME/KDE/headless environment certification |
| LNX-A11Y-HARNESS-001 | Implemented | All-route axe plus installed AT-SPI/Orca/keyboard/zoom contract and PR #1683 forced-colors/contrast/reduced-motion source tests | Full architecture/desktop/high-contrast matrix |
| LNX-PERF-HARNESS-001 | Implemented | Matched workload tools, p50/p95/p99/resource capture, nightly soak contract | Final candidate results on comparable hardware and environments |
| LNX-RUN-001 | Partially proven | Clean aarch64 package-owned GUI/daemon/version/uninstall session | x86_64, prior-version lifecycle, suspend/resume, compositor breadth |
| LNX-PKG-001 | Implemented in workflow; construction proven | Four-artifact aarch64 and architecture-correct x86_64 shards green with 28/28 smoke checks each; native dual-architecture aggregation is fail closed. Official AppImages now admit the GUI only through a signed canonical manifest bound to the exact final bytes; focused peer-admission verification passed 8 Swift and 28 Node tests | Provision the release signing secret, produce the exact signed aggregate, then complete native hosted x86_64, installed x86_64, rpm/AppImage lifecycle, and channel proof |
| LNX-UPD-001 | Partially implemented | Native signed-feed availability verifier rejects invalid public metadata | Valid feed plus deb/rpm/AppImage update, rollback, and data preservation |
| LNX-CHANNEL-001 through LNX-DIFF-001 | Open/partial | Existing package/channel/product foundations retained; P-39 comparator mechanism is implemented in [PR #1682](https://github.com/Imagine-That-Ai/BurnBar/pull/1682) | Daily-use platform foundation, same-commit macOS/Linux artifact generation, and current differential proof |
| P07/P09/P11/P13/P14/P15/P16/P17/P18/P19/P20/P22/P25/P27/P28/P29/P30/P31/P40 implementation slices | In review | Existing slices plus typed provider/model navigation, verified Activity source resolution, native cloud-auth onboarding, Linux control-color alignment, `336ee0eca2`/`736fcae8a9` authoritative usage projection/decoder, `e4e4c15bdb` Copilot ingestion, `e7531159b3` billing portal, and `b45f6378e9`/`45926a4fac` encrypted cloud replica/conflict runtime are source-integrated. The typed provider destination is installed and AT-SPI proven in the current exact ARM64 receipt | Merge/rebase onto the release head, then prove remaining parser/API breadth, production Firebase/cloud composition, Account UI, Iroh remote reads, credential escrow, remaining backends/binary attachments, populated Activity, production OAuth/portal consent, trusted-device execution, cross-device memory, database recovery, mission health/history, global shortcut breadth, Linux keyring/IBus/Fcitx, native pet adapters, and destructive privacy contracts |
| LNX-CHAT-CITATIONS-APPROVALS-001 | Implemented in source; installed proof blocked | Bounded citation normalization/source focus and daemon-issued approval IDs with approve/reject/cancel single-flight handling; attachment upload/metadata, path-free attachment metadata in JSON/Markdown export, extension-derived MIME preflight, explicit unsupported-PDF rejection before append/upload, reconnect/visibility, functional options, pop-out boundary, daemon-authoritative full-history JSON/Markdown export, strict unloaded-page traversal, validated resume, and config-derived backend availability are now integrated in `0d8ee32526`, `618c7286b9`, `e0451afa5e`, `dd705ca1dd`, `5fdcccabfa`, and `702f59146e`; `26dd3cbc30` adds Anthropic bridge PDF document mapping with a focused gateway regression; focused chat lane: 60/60 tests plus app TypeScript/build pass | Run unloaded-history/reconnect/pop-out/backend catalog flows against an installed Linux daemon; re-upload staged attachments after daemon restart; compare with macOS behavior; complete provider/backend coverage and signed installed proof before claiming those formats |
| LNX-MEMORY-QUARANTINE-001 | Implemented in source; installed proof blocked | `752f6e9745` adds daemon-owned review-status persistence, quarantine/approved/rejected/forgotten transitions, opt-in review feed, metadata tombstones, audit hashes, typed RPC/capability/socket coverage, strict Tauri mapping, and fail-closed renderer decisions; focused memory/bridge tests: 22 + 81 pass, app TypeScript pass | Exercise pending creation, approve/reject/forget/reload, normal-recall exclusion, audit continuity, and cross-device behavior against an installed daemon and real cloud-sync authority |
| LNX-PRIVACY-ROUTE-RETENTION-001 | Implemented in source; installed proof blocked | `4cdc505537` plus `9598c0b9e8` add daemon-backed local-store inventory and exact preview/execute deletion for the allowlisted proxy-route log and encrypted text-expansion store. `7c8a214ce6` and `825e081bda` add selected-scope encrypted export with authenticated PBKDF2/AES-GCM envelope, bounded payloads, owner-only output, race/path/permission checks, typed daemon/Tauri wiring, passphrase clearing, and Settings controls. `8131b51aec` adds the portal-backed native diagnostics save destination with a second Rust path-validation boundary and owner-only atomic output; the control binds a five-minute scoped token to owner/perms/fingerprints, requires exact confirmation, uses idempotent unlink, and explicitly excludes transcripts, credentials, and account data; Settings/bridge and Core/daemon contract tests pass | Exercise inventory, scope selection, preview expiry, confirm/cancel, clear/export success/failure, restart, locked keyring, tamper/permission rejection, native save destination, and ensure unrelated transcript/credential/account data remains intact; retention/account erasure/backend receipts remain separate |
| LNX-QUOTA-ACCOUNT-SWITCHING-001 | Implemented in source; installed read proof | Preferred credential-slot switching and auto-routing reset remain daemon-owned. `b76b67e8bc` adds failover-policy read/mutation with exact readback and rollback; `8d9dba71fe` uses the macOS canonical wire modes only. The current installed route exposes the daemon-confirmed policy and passes AT-SPI | Exercise live switching between ready/exhausted/cooling slots, persisted policy after restart, auto-routing recovery, quota-driven failover, thresholds, and cloud-account/trusted-device boundaries |
| LNX-SMARTHUB-HARDENING-001 | Implemented in source; live device proof blocked | Typed operation allowlist, request ID validation, bounded JSON depth/items/strings/output, concurrent stdout drain, bounded Avahi timeout (4 seconds by default; 0.1-10 seconds from CLI), cancellation registry, degraded renderer state; 15 focused UI/decoder tests and 3 Rust SmartHub tests pass | Provision supported devices and trusted packaged CLI on GNOME/KDE/wlroots hosts; verify Avahi discovery and offline/reconnect outcomes |
| LNX-TEXT-EXPANSION-001 | Implemented in source; Linux keyring/IME proof blocked | Daemon-owned AES-GCM sealed snapshot, native Secret Service/KWallet key custody, owner-only permissions, consent RPC, in-app Composer expansion, no renderer localStorage/evdev/global capture, corruption/tamper/missing-key fail closed; live renderer controls stay disabled until storage hydration succeeds (`1ddc8bc33a`); `274f67fba0` adds signed registration, `9598c0b9e8` adds typed engine status/start/stop RPC with Tauri mapping, and `d2dbbe8df8` adds bounded trigger-only external expansion with response validation, denial-before-write, cancellation/timeout/kill-switch teardown, and no forbidden context payloads; the packaged IBus engine is now reflected by the shell capability readback (`a676e48e8b`); focused persistence/Composer/RPC/lifecycle tests pass | Run on Linux with Secret Service/KWallet, then certify opt-in IBus external execution, decide/package a separately signed Fcitx5 addon if required, prove secure-field exclusions, sync/conflict policy, and the Wayland/X11 matrix |
| LNX-MISSION-HEALTH-001 | Implemented in source; installed proof blocked | `bd9d6a5173` adds typed `daemon.mission.health` Core/daemon/Tauri contracts, authoritative projection-derived health, stable packet/result/burn/takeover history, active/failed counters, and Missions UI rendering; focused Swift parse, bridge, UI, and RPC contract tests pass | Run against an installed daemon through restart/reconnect and failed/active/terminal mission scenarios; capture exact-candidate health/history receipts and close the P-20 row |
| LNX-INSIGHT-001-FOLLOWON | Implemented in source; installed proof blocked | `5ddd81245d` and `b3002ab3f9` add a three-pane canvas/library/inspector, selectable evidence widgets, account-scoped persisted selection/density, validated evidence IDs, bounded audit disclosure, refresh, and chat follow-up handoff above the provenance-labeled brief; `825e081bda` adds the daemon-owned `daemon.usage.insights` response, local-rules analysis, bounded usage rows, source identity, citations, and renderer qualitative brief mapping; focused Insights, bridge, and axe tests pass | Exercise the live daemon response against real ledger rows, compare qualitative output/citations with macOS, verify restart/reconnect behavior, and certify the installed workflow |
| LNX-ACTIVITY-001-FOLLOWON | Implemented in source; installed proof blocked | `c1f6e69514` adds bounded daemon-authoritative Activity export, verified source/provider/session/project identity, replay-body completeness checks, and typed unavailable state instead of partial/full-history fabrication; `7ae2412143` requires a verified `sourceID` for replay/resume and removes usage-row fallback; `fec153e40b` and `e6bf98601b` additionally require explicit daemon `historyComplete === true` proof before full-history export or resume, so the bounded recent-usage bridge cannot overclaim completeness; focused Activity/bridge/history tests **30/30** pass | Exercise installed source resolution, explicit complete-history proof, full-history replay, export, and resume-from-export against real daemon data |
| LNX-NOTIFY-001-FOLLOWON | Implemented in source; installed proof blocked | `5f74018422` normalizes direct and second-instance notification actions, validates bounded payloads, expands route aliases, and gives validated cold-start native routes precedence over onboarding; `a5571694bb` adds independent per-binding shortcut registration with typed X11/Wayland/unknown backend health and fail-closed unsupported states; 92 Rust and focused bridge tests pass | Capture GNOME/KDE/wlroots D-Bus action and shortcut receipts, verify host persistence/accessibility, and exercise panic paths under partial registration |
| LNX-PET-001-FOLLOWON | Implemented in source; native overlay proof blocked | `9a527310f9` adds contained summon/focus/status and selection/clear controls with typed capability states; `ea82fe5140` adds a Tauri X11-only companion child with explicit focus and click-through toggles; `3b652f9b9e` adds bounded pointer/mouse drag and Arrow/Home keyboard repositioning with focus and announcement metadata for the Wayland-safe contained substitute; `5c3caab2e` adds the fixed-marker X11-only `Ctrl+Alt+Super+P` summon event and `2b85f1431` exposes accessibility metadata. `318d3430fd` hardens renderer capability readback to require the canonical X11 session, window contract, and source before enabling overlay or click-through controls; stale or forged available Wayland status now remains contained. Wayland and unknown sessions remain fail-closed | Certify the X11 child and summon shortcut on supported desktops and decide/prove the Wayland-native substitute, including GPU, focus, click-through, keyboard, and reduced-motion behavior |
| LNX-CU-CREDENTIALS-001 | Implemented in source; production deployment blocked | Daemon-owned PKCE loopback sign-in, secure refresh-token custody, Firebase ID refresh, per-install Ed25519 App Check enrollment/challenge/mint, 30-minute production token ceiling, account-generation invalidation, phase-safe sign-out/account-switch RPC teardown, scoped old-account route revoke, cancellable HTTP, and redacted RPC state. Explicit pending approval retries on a capped 15/30/60/120/300-second schedule below the public quota; permanent rejection stops polling. The earlier focused daemon credential/runtime packet passed 35/35 and App Check backend packet passed 34/34; the lifecycle/polling regression cases are now covered by the 2026-07-12 full Linux-native aggregate. A dedicated Linux Firebase web app, Desktop OAuth client, and public release variables exist | Deploy the new Functions callables/policy and prove the flow from an installed signed candidate |
| LNX-CU-BROWSER-001 | Source authority/runtime complete; mobile approval source present; installed proof blocked | Exact run/call/generation authority, controller-route v2, mobile renewal, macOS lifecycle policy, Linux native iroh composition, durable replay, polkit owner gate, root-owned Playwright runtime, daemon credential authority, signed AppImage peer admission, and redacted Tauri/account UI are implemented. `7bcf432bf4` additionally revalidates pinned authority readiness for every inbound controller frame and terminates the runtime before dispatch after revocation/health loss. The active worktree also contains iPad list/approve/revoke UI, canonical device-ID/fingerprint validation, nonce-bound mutation descriptors, stale-load protection, serialized mutations, and focused store/parser tests. The canonical relay challenge is generated consistently for Swift/Kotlin, Android compile/static-analysis and focused tests pass, and earlier generic iOS build-for-testing coverage passes. The assigned physical iPad now has a current-branch install/launch/liveness/console receipt plus a 21/21 current-head navigation receipt; approval execution and installed certification remain separate gates | Run focused parser/store/mutation tests on the connected physical iPad, then use it to approve the exact Linux install and prove real browser actions, grant/approval/deny/panic, audit/tamper, credential expiry, account switch, and restart behavior |
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
| LNX-MEDIA-001 | LNX-CAP-001, LNX-IPC-001, LNX-SEC-001, LNX-AUTH-001, LNX-NATIVE-001, LNX-EVT-001 | Mercury transport, secure pairing, files, calls, share, codecs, consent, notification/lifecycle | `56af093923` adds a truthful shell-local GStreamer viewer capability contract (VP9 decoder, native sink, PipeWire factories), explicit no-feature degradation, release feature wiring, and package/runtime dependency declarations. `2a80e30921` restarts the existing decoder in place after transient frame failures and re-arms keyframe gating without dropping the live socket when recovery succeeds. `a570c9b087` builds/stages the daemon-owned `openburnbar-media` crate, binds the packaged FTS5 SQLCipher runtime, and records the WebKit safe-mode fallback; `fdbc7d718b` keeps receive-only media transport distinct from authenticated daemon call RPCs and gates stale file actions; the live Ubuntu receipt reports capture available with known VP9/AV1/Opus codecs, an active daemon-to-shell media socket, and file-transfer capability. | Run the exact signed candidate through a real two-device iPad/Linux file, call, and screen-share matrix on supported desktops; prove PipeWire portal consent, codec/sink negotiation (including explicit H.264 fallback), lifecycle, restart, teardown, and cross-device receipts |
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
| 0.5 | **Complete proof ownership** | Complete at `df1852fae2` | P-01 through P-40 producers, materializers, validators, workflow contracts, mutation tests | 40/40 owners and 44/44 exhaustive preflight stay green |
| 1 | **Trustworthy engineering baseline** | Complete in code; dual-architecture construction and aarch64 installed proof live | LNX-REL-VERIFY-001, LNX-CI-001, LNX-RUN-001, LNX-A11Y-HARNESS-001, LNX-PERF-HARNESS-001 | Add installed x86_64 and prior-version package sessions without regressing strict gates |
| 2 | **Security foundation** | Complete in code; matrix pending | LNX-SEC-001, LNX-IPC-001, LNX-CAP-001 | GNOME/KDE/headless credential and installed adversarial verification green |
| 3 | **Mainstream install** | Package construction complete; installed/channel proof in progress | LNX-PKG-001, LNX-CHANNEL-001 | Both architectures and every declared package/repository channel install locally |
| 4 | **Daily-use native foundation** | In progress; onboarding, bounded event refresh, authoritative all-time usage projection/recount, all 27 local parser registrations, encrypted local replica, Firebase gateway, daemon composition, background sync lifecycle, and native secret-store fallback are implemented; API/quota parity, account UI, and installed matrix remain pending | LNX-EVT-001, LNX-ONB-001, LNX-AUTH-001, LNX-NATIVE-001, LNX-UPD-001, LNX-CAT-001, LNX-DIFF-001 | Setup, auth, complete parser/data freshness, Firebase-backed sync/remote access, alerts/tray, update lifecycle, and current provider diff green |
| 5 | **Core product workflows** | Pending | LNX-SESS-001, LNX-CHAT-001, LNX-MEM-001, LNX-PROJ-001, LNX-MISSION-001, LNX-INSIGHT-001, LNX-DB-001, LNX-PROVIDER-001, LNX-PRIV-001, LNX-SET-001 | No synthetic state; every primary workspace and privacy workflow completes |
| 6 | **Browser automation parity** | In progress; controller routing, native iroh runtime, authority/replay/restart safety, polkit owner gate, daemon-owned PKCE/Firebase/App Check credentials, phase-safe account lifecycle, bounded approval polling, redacted account UI, signed AppImage peer admission, and physical-iPad approval source are implemented. Earlier generic iOS build-for-testing coverage passes, and the 2026-07-12 Linux-native aggregate passes. Production OAuth/callable configuration, current physical-iPad execution, signed-candidate installation, and real-device evidence remain open | LNX-CU-CREDENTIALS-001, LNX-CU-BROWSER-001 | Provision Desktop OAuth and release variables, deploy Functions, complete physical-iPad tests, build the signed candidate, then prove iPad-backed sign-in, approval, real actions, panic, audit, and restart recovery |
| 7 | **Media and system integration** | In progress; daemon capture/file capabilities and portal-backed Opus audio adapter are source-complete and fail closed when native artifacts are absent; cross-device/call-seal proof is open | LNX-CU-SYSTEM-001, LNX-MEDIA-001 | Supported compositor safety, PipeWire consent, call-seal composition, and two-device media proof |
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
5. Certify Browser Computer Use navigate/type/click/screenshot, approval/deny,
   panic, tamper detection, audit export, daemon crash/restart, and replay
   persistence against a real browser.
6. Run the same candidate through the GNOME X11/Wayland, KDE Wayland, and
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

- [x] Every P-01 through P-40 requirement has one registered fail-closed proof
  owner at `df1852fae2`.
- [x] The exhaustive ownership/preflight inventory passes 44/44.
- [ ] Do not convert either infrastructure result into a parity claim until the
  signed candidate reaches 40/40 strict requirements and 7/7 environments.
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

- [x] The daemon owns the canonical all-time usage projection and explicit
  recount, and the renderer rejects inconsistent or out-of-range aggregates.
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

- [x] The daemon has a durable encrypted local replica/outbox/cursor/tombstone
  core and injected redacted status/policy/manual-cycle RPC runtime.
- [ ] The production Firebase gateway and daemon-main identity/key providers are
  composed without exposing credentials or replica data to the renderer.
- [ ] Account UI exposes the redacted sync lifecycle and consent controls; Iroh
  remote reads enforce peer/grant authorization; credential escrow stays on its
  separate trusted-device protocol.
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
- [x] A bounded current-checkout `MobileThemeTests` receipt executes on the
  connected physical iPad without using an iPhone or simulator as a substitute
  and passes 9/9; see
  `evidence/parity-audit-2026-07-10/ipad-mobile-theme-2026-07-19.json`.
- [ ] The focused parser/store/mutation approval tests execute on the connected
  physical iPad; the approval workflow itself remains open.
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
