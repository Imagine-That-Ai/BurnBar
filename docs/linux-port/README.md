# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Current parity status as of 2026-07-19:

- **Current source head:** the integration branch now includes source changes
  through `3e7ede75e3`. It passes 89 frontend files /
  845 tests, TypeScript, production bundle verification, Tauri Rust 128/128,
  package-payload contract checks (2 pass, 2 historical skips), and product
  validators 12/12. `1130524331` recovers a visible 2D backdrop after
  backgrounded WebGL context loss and retries the requested kernel on resume;
  `db8a52f2f2` makes kernel selection keyboard-complete with focus restoration;
  `2a19ac301a` adds the Support performance empty state; `6ce5ec8623` adds
  quota/account routing state; `149cfec503` plus `bd10c71919` harden provider
  refresh and stale-event handling; `ed940164ce` hardens Mercury recovery;
  `aa188d24fa` makes Tauri invalidate embedded assets when hashed chunks rotate;
  `cf9499d437` adds viewer capability retry; `7e7e7efdf7` plus `58e21e5f9c`
  add a typed privacy-export receipt with a metadata-safe fallback;
  `65f4931c36` keeps onboarding provider recovery actionable; and
  `ded781e94d` adds route-level render-error recovery with Retry/Open Support
  actions; `8cafd2d7e0` preserves provider workspace during transient catalog
  recovery; `da42c16a78` guards daemon subscription lifecycle restarts; and
  `872074af3a` cancels SmartHub work when the packaged shell loses its bridge;
  `e6c32ec2b2` repairs stale custom-model provider selection after catalog
  refreshes; and `c6bf8f2881` makes the chat pop-out status assertion await the
  asynchronous window-open result. `465431d0fc` bounds single-instance
  forwarding while the primary listener finishes starting, and `7ac2e021c9`
  makes native Browser Computer Use fail closed unless the runtime explicitly
  advertises the capability. `c0a725447d` falls back to the trusted embedded
  autostart entry for relocatable installs, and `447abb0564` fences stale
  Mercury capability responses after bridge replacement or recheck. `9e868e60a7`
  refreshes tray health, usage, and update state every 30 seconds with
  serialized manual refreshes, while `3e7ede75e3` bounds browser sign-in
  polling at the daemon-provided authorization deadline and makes expiry
  actionable to keyboard and screen-reader users.
  The ARM VM also passed
  the supported Swift-less staged-payload `pretauri:build`/`tauri:build` path via
  `OPENBURNBAR_LINUX_REUSE_STAGED_PAYLOAD=1`. The installed VM DEB is unsigned
  and non-certifying. The latest exact implementation receipt includes the
  post-unlock visible/animated packaged-shell capture and is
  [`evidence/parity-audit-2026-07-10/linux-arm64-current-3e7ede75e3-postinstall-2026-07-19.json`](evidence/parity-audit-2026-07-10/linux-arm64-current-3e7ede75e3-postinstall-2026-07-19.json).
  The preceding `872074af3a` and `ded781e94d` receipts remain historical
  visible-shell evidence.
  The strict ledger remains **0/40 product rows and 0/7 environment receipts**.

- **Latest live VM candidate:** the exact `3e7ede75e3` ARM64 DEB is installed in
  the Ubuntu 24.04.4 GNOME/X11 UTM guest. Its non-certifying receipt is
  [`evidence/parity-audit-2026-07-10/linux-arm64-current-3e7ede75e3-postinstall-2026-07-19.json`](evidence/parity-audit-2026-07-10/linux-arm64-current-3e7ede75e3-postinstall-2026-07-19.json).
  Daemon/CLI health is green and the desktop window exists at `/usr/bin`. A
  clean launch in the unlocked GNOME session rendered the first-run
  Secret Service / SQLCipher setup card and Fluid Aurora 2D fallback. Two
  captures two seconds apart differ in 776,489 pixels. The guest reports
  `webgl2=false` and `webgl1=true`; the visible switcher labels the fallback
  `2D fallback (WebGL2 unavailable)`. A stale autostart/locked-era blank
  process was discarded as launch-context evidence, not a package failure.
  This package is unsigned and is not a public release. The previous exact
  `5b70a3d320` package remains the
  historical installed baseline in
  [`evidence/mission-002-reanchor/vm-e2e/current-5b70a3d320-settings-hydration-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-5b70a3d320-settings-hydration-arm64/).
  The packaging history includes `59d49c7d59`, which made an explicit staged
  Swift runtime authoritative; the latest package includes that path and the
  subsequent asset-watcher hardening. The focused iPad
  navigation receipt is
  [`evidence/parity-audit-2026-07-10/ipad-navigation-focused-current-2026-07-19.json`](evidence/parity-audit-2026-07-10/ipad-navigation-focused-current-2026-07-19.json).
  The Settings route now mounts and hydrates deterministically: AT-SPI reports
  105 nodes and 50 actionable controls with no `Loading Settings` node; the
  General startup checkbox and Media & Sharing route are reachable.
  The package is unsigned and this receipt is non-certifying.
- Current source gates are **89 frontend files / 845 tests**, focused provider
  recovery **11/11**, daemon subscription lifecycle **8/8**, SmartHub **9/9**,
  Settings/route **51/51**, Support **29/29**, media **38/38**, Tauri Rust
  **128/128**, TypeScript, formatting, and production-bundle verification. The strict ledger remains
  **0/40 product rows and 0/7 environment receipts**; this is a certification
  gate, not a source-progress percentage.
- PR #1691's only current CI failure is the trusted Domain Core deletion guard:
  it requires the candidate's legacy-deletion ledger and Domain Core source
  roots, which this Linux integration branch does not contain. The guard fails
  before Linux checks; adding a fabricated ledger would be unsafe. A clean
  mainline/release-head integration is required before that PR can merge.
- The current focused physical-iPad approval receipt is
  [`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19-v2.json`](evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19-v2.json):
  44/44 tests passed on the paired device. It is model/UI coverage only and
  does not certify installed-Linux enrollment, approval/revoke, or cross-device
  Computer Use.
- The immediate Settings fix is split into two reviewable commits:
  `2f75f3269e` bypasses the packaged route idle gate for Settings, and
  `5b70a3d320` makes its first config hydration eager while preserving deferred
  first paint for other routes.

- A historical parity hardening and installed candidate reached `b590d5a77d` (including the WebKit
  startup fallback from `6321897d4e`). The running Ubuntu 24.04.4 GNOME/X11
  UTM guest now has an exact-head arm64 package rebuilt from that commit and
  installed; its non-certifying receipt is
  [`evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-b590d5a77-media-settings-onboarding-arm64/).
  The receipt records daemon/desktop health, GStreamer, Secret Service, IBus,
  autostart packaging, and the current source-test gates. The package is
  unsigned and does not certify the seven-environment or cross-device matrix.
  The earlier `5e0fc0e82` receipt remains a historical exact-head baseline at
  [`evidence/mission-002-reanchor/vm-e2e/current-5e0fc0e82-insights-autostart-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-5e0fc0e82-insights-autostart-arm64/).
  The preceding media-gst shell receipt remains historical at
  [`evidence/mission-002-reanchor/vm-e2e/current-82b0fcf11e-media-gst-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-82b0fcf11e-media-gst-arm64/).
  The preceding media-gst receipt remains a historical baseline at
  [`evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-media-gst-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-media-gst-arm64/), and the earlier non-GStreamer UI receipt remains available at
  [`evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-ui-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-ui-arm64/).
  The daemon/media capability receipt remains bound to the `a570c9b087`
  runtime package; the clean parity-ledger
  validation is bound to checkpoint `073c2aba45`. The Release and
  Nightly receipts below are historical engineering evidence for an older
  checkpoint, not a claim that the current docs head has a promoted artifact.
- Earlier source hardening added a macOS-style, evidence-bounded Insights
  comparison workspace (`c31c17aa6e`, `ee679e2ed0`, `eb6a5975d4`) and a secure
  Linux-native **Launch at login** preference (`f6d3843937`, hardened in
  `1bddc6d22a`) alongside the
  fixture-safe daemon-backed **Index project** action in General Settings
  (`992ef5c580`), single-flight native pet-window launch
  (`511c8a1049`), body-click `open` routing for notification servers without
  action buttons (`1397313284`), GStreamer decoder retry without requiring a
  socket reconnect, and Secret Service/KWallet health-before-write onboarding
  checks (`82b0fcf11e`). Focused verification is 28/28 Insights, 4/4 autostart Rust,
  39/39 bridge/renderer, 32/32 settings/accessibility, 28/28 pet UI, 4/4 native
  notification Rust tests, 5/5 media Rust tests in both feature modes on the
  VM, and 6/6 Linux onboarding tests on Ubuntu. The installed arm64 package
  carries the settings action; focused settings verification is **34/34**. The
  earlier `992ef5c580` install remains historical and the current exact-head
  install is recorded in
  [`evidence/mission-002-reanchor/vm-e2e/current-5e0fc0e82-insights-autostart-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-5e0fc0e82-insights-autostart-arm64/).
- `2e609b4061` hardens Mercury viewer lifecycle teardown by detaching the
  decoder under the viewer lock and stopping GStreamer outside the lock. The
  VM media tests pass **6/6** with `media-gst` and **5/5** without it; this is a
  source/runtime reliability improvement, not cross-device media proof.
- `d581da37b7` exposes daemon-backed Mercury capability state in Media & Sharing
  settings, and `47cbf2e2f0` makes onboarding fail closed if an ephemeral
  Secret Service/KWallet probe cannot be cleaned up. The current VM receipt
  includes those slices; onboarding focused coverage is **8/8**.
- The physical-device runner now accepts either the CoreDevice identifier from
  `devicectl` or the hardware UDID required by Xcode, with deterministic
  missing/ambiguous-device failures (`5cff4281ec`).

- Current-head Release Candidate `29664085758` produced signed x86_64/aarch64
  candidate `0.1.1` and passed package, daemon, desktop, tray, accessibility,
  route, lifecycle-contract, and attestation checks at `1dced585af`. The
  immutable evidence artifact is `8435577756` (digest
  `sha256:cb4eeed2f2263707bbf5d563200d02367065067b5c6e4ff6deed651f47299807`).
  A compatible previous same-architecture package was not supplied, so real
  update/rollback/data-preservation promotion remains blocked. The compact
  receipt is under
  [`evidence/mission-005-exact-head-release-1dced585af/`](evidence/mission-005-exact-head-release-1dced585af/).
- Current-head Nightly `29660228199` passed macOS and Linux matched workloads,
  the Ubuntu GNOME/X11 packaged shell gate, and the explicit blocked-row
  contracts for GNOME Wayland, Fedora/KDE Wayland, and Arch/wlroots. The X11
  artifact is `8435091387`; compact extracts live under
  [`evidence/mission-004-exact-head-1dced585af/`](evidence/mission-004-exact-head-1dced585af/).
- Full macOS parity is not complete: the strict ledger remains 0/40 product
  rows and 0/7 environment receipts. The Nightly pass is engineering evidence,
  not a promotion claim; production, lifecycle, installed integration, and
  registered product evidence remain open.
- The candidate branch now has **83 desktop test files / 787 tests** passing,
  plus current-checkout P-39 corpus binding, daemon-authoritative activity
  export resume, forced-colors metric fallbacks, and a focusable-hidden-node
  accessibility fix. The latest source slices also add the persisted Calendar
  notification hold-duration selector (`3004da3b72`), redacted/symlink-safe
  diagnostics exports (`bdd57173e9`), Mercury decoder recovery
  (`2a80e30921`), and a portal-backed native diagnostics save destination
  (`8131b51aec`). Tauri Rust is **119/119**, focused diagnostics UI is **24/24**,
  TypeScript and the production bundle verifier pass. These source results do
  not promote the ledger.
- `9fb6e88c33` canonicalizes membership RPC names and degrades unknown methods
  truthfully (Tauri Rust **119/119**). `f9d3b429e5` adds persisted Dashboard
  Defaults and truthful Indexing & Search posture, with Session Summaries
  explicitly unavailable until a Linux RPC exists (focused settings **45/45**,
  new controls **3/3**). The full desktop suite is green at **83 files / 770
  tests**, with TypeScript and production bundle verification passing.
- `b0d27caffa` hardens persisted Insights workspace state by rejecting malformed,
  future-version, or unsafe records and restoring safe defaults (focused
  Insights persistence/renderer tests **26/26**). `fec153e40b` plus
  `e6bf98601b` require explicit daemon `historyComplete === true` proof before
  Activity full-history export or resume; the bounded recent-usage bridge stays
  unavailable instead of claiming complete history (focused Activity
  history/export/resume tests **30/30**). These source results do not promote
  the strict ledger.
- `13caa70a1e` adds DEB/RPM post-install and Arch post-transaction migration
  hooks that move unmanaged stale `/usr/local/bin/openburnbar-cli` binaries to
  versioned backups, so PATH cannot shadow the packaged CLI. Migration tests and
  package-wiring checks pass without deleting user data.
- `c94e7b6113` adds the daemon-owned `daemon.usage.history` RPC and requires an
  explicit completeness proof before Linux exports full Activity history. The
  focused Activity/bridge suite passes **102 tests**. The exact-head arm64 DEB
  was the preceding installed baseline; its non-certifying receipt is
  [`evidence/mission-002-reanchor/vm-e2e/current-c94e7b6113/`](evidence/mission-002-reanchor/vm-e2e/current-c94e7b6113/).
- `a570c9b087` is the current live Linux slice. The exact arm64 DEB is installed
  in the Ubuntu 24.04 GNOME/X11 UTM guest, the package-owned user daemon is
  `enabled/active`, bare CLI health is green, and the packaged desktop is
  running from `/usr/bin`. The release graph builds the daemon-owned
  `openburnbar-media` crate; the daemon binds the packaged FTS5-capable
  `libsqlcipher.so.0`; and the live media capability probe reports capture
  available with known VP9/AV1/Opus codecs, an active daemon-to-shell media
  socket, and file-transfer capability. The Linux peer-auth test passes 1/1,
  `MercuryLinuxMediaTests` passes 21/21, and the project/code-memory bootstrap
  slice passes 3/3 on the VM. The Linux media UI also gates receive-only
  transport separately from daemon call RPCs (`fdbc7d718b`, focused lane 33/33),
  and the installed shell is linked against the GStreamer app/base/core/video
  libraries through the `media-gst` feature.
  This remains a non-certifying runtime receipt:
  two-device iPad/Linux media, Computer Use, signed provenance, and the strict
  0/40 product plus 0/7 environment ledger remain open. See
  [`evidence/mission-002-reanchor/vm-e2e/current-a570c9b087/live-receipt.json`](evidence/mission-002-reanchor/vm-e2e/current-a570c9b087/live-receipt.json).
- Fresh local recheck: the wired iPad is paired, booted, has Developer Mode
  enabled, and a current-checkout focused approval receipt passed **44/44**
  tests with xcodebuild exit 0 (see
  [`evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19.json`](evidence/parity-audit-2026-07-10/ipad-approval-focused-current-2026-07-19.json)).
  This does not prove installed Linux enrollment, approval/revoke, or
  cross-device Computer Use. The OpenBurnBar Linux UTM guest is now running
  and reachable; authenticated daemon health and bare installed CLI health pass
  through the package-owned Swift runtime launcher and canonical token file for
  the exact `a570c9b087` package. The full release-mobile approval suite remains
  unverified.
  The product-parity workflow is not present on `main`, and GitHub currently
  has zero self-hosted runners for its required Linux environment labels.
- For the detailed audit and implementation plan, see
  the browser-ready
  [`LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html`](LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html)
  or its Markdown source
  [`LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md`](LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md)
  for the independent executive summary, parity matrix, implementation plan,
  prioritized roadmap, and QA checklist.
- For the CMUX-synthesized implementation plan, see
  [`FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`](FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md).
- The 2026-07-05 release notes below are historical context and should not be
  read as the current live GitHub release state.

Current active-checkout status as of 2026-07-05:

- V24 foundation and V23 surface validation passed from
  `$WORKSPACE` at
  `1b62ec42bd752cc8a6af578f034bf776c6ec3b97`.
- The checkout later moved to `1af805eb1878cc5af8821ee35cac838c5ac473ee`;
  release closure must rerun the active-checkout validators at that head or
  restore the sealed head before claiming current release readiness.
- The current evidence pointer is
  [`evidence/mission-001-release/active-checkout-v23-v24-evidence.json`](evidence/mission-001-release/active-checkout-v23-v24-evidence.json).
- Public Linux release promotion is still blocked by release-package, update,
  signing/provenance, nightly-matrix artifact, and clean-release-commit evidence.

Primary files:

- [`P16_ACCOUNT_CLOUD_DEVICES.md`](P16_ACCOUNT_CLOUD_DEVICES.md) - Linux
  daemon-auth account posture, enrollment verification, and the explicit
  trusted-device mutation boundary.
- [`release-runbook.md`](release-runbook.md) - package, update, signature,
  provenance, source-offer, and promotion process.
- [`parity-ledger.json`](parity-ledger.json) - machine-readable Tier A/B/C
  product status ledger. **Semantics:** `productParityClaim` is false until all
  40 product requirements and the seven-environment support matrix have
  current-HEAD attestations.
- [`product-parity-requirements.json`](product-parity-requirements.json) -
  canonical `P-01` through `P-40` inventory and minimum support matrix.
- [`product-parity-evidence-policies.json`](product-parity-evidence-policies.json) -
  canonical per-requirement check, environment, installed-subject, registered-
  producer, and artifact-root policy consumed by
  `scripts/linux-port/attest-product-requirement.mjs`.
- [`product-feature-proof-registry.json`](product-feature-proof-registry.json) -
  exact environment feature-artifact roles and size/media contracts snapshotted
  into each immutable candidate. See
  [`PRODUCT_FEATURE_PROOF_CONTRACT.md`](PRODUCT_FEATURE_PROOF_CONTRACT.md) for
  capture, finalization, materialization, and validator invariants.
- [`parity-ledger.md`](parity-ledger.md) - generated human-readable ledger.
- [`parity-ledger-history.json`](parity-ledger-history.json) - archived
  mission evidence that cannot satisfy current product parity.

- [`evidence/mission-002-reanchor/`](evidence/mission-002-reanchor/) - Phase 0
  reanchor baseline for full parity work.
- [`factory-pr-handoff.md`](factory-pr-handoff.md) - review map and known
  blockers for the factory PR loop.
- [`runtime-capabilities.md`](runtime-capabilities.md) - canonical native
  capability probes, including the fail-closed packaged Browser Computer Use
  bridge and external runtime boundary, route gating, change procedure, and QA
  steps.
- [`P07_COMPUTER_USE_BROWSER_PANEL.md`](P07_COMPUTER_USE_BROWSER_PANEL.md) -
  typed Browser Computer Use actions, Swift/Rust/Tauri wire-shape boundary,
  system-mode unavailability, and focused QA contract.
- [`accessibility-validation.md`](accessibility-validation.md) - axe route
  matrix, installed-app AT-SPI/Orca harness, evidence contract, and remaining
  manual GNOME/KDE certification. P-31 additionally requires exact 200 percent
  reflow, forced-colors/high-contrast/no-color, reduced-motion, and keyboard plus
  Linux screen-reader evidence on every support-matrix row.
- [`performance-reliability-validation.md`](performance-reliability-validation.md) -
  repeated packaged-shell percentiles, matched production-linked macOS/Linux
  workloads, resource soak, supervisor behavior, and fail-closed QA contract.
- [`P22_DATABASE_CODE_INSPECTION.md`](P22_DATABASE_CODE_INSPECTION.md) - bounded
  daemon-owned code search/context-pack behavior in the Database route, with
  trust warnings and fail-closed packaging behavior.
- [`LINUX_EVENT_SUBSCRIPTION_AUTHORITY.md`](LINUX_EVENT_SUBSCRIPTION_AUTHORITY.md) -
  daemon start/resume/stop cursors, desktop cadence and cancellation, recovery
  behavior, honest degraded-pull status, and remaining installed certification.
- [`LINUX_CHAT_THREAD_AUTHORITY.md`](LINUX_CHAT_THREAD_AUTHORITY.md) - canonical
  encrypted thread history, exact-thread typed RPCs, idempotent send ordering,
  strict renderer decoding, failure behavior, and remaining chat parity work.
- [`ui-parity/`](ui-parity/README.md) - W6/W7 UI parity execution plan:
  foundation reference plus parallel task packets P01–P15.
- [`evidence/`](evidence/) - generated and collected mission evidence.
- [`evidence/parity-audit-2026-07-10/aarch64-installed-session-summary.json`](evidence/parity-audit-2026-07-10/aarch64-installed-session-summary.json) -
  compact retained results and source hashes from the current installed aarch64
  audit sample; it is evidence for this report, not a release-promotion row.

Each ledger command discovers exactly one canonical receipt per required
check/environment pair below
`evidence/validator-receipts/<requirement>/<check>/<environment>.json`. Receipt
schema 2 binds current HEAD, the release closure, signed installed-file manifest,
candidate package artifact, exact package-manager ownership and installed-file
inventory, pre/post capability manifests captured from the installed desktop
binary, the logind-anchored live environment, and the registered validator
command/source tree. Trust files must be root-owned, the Ed25519 signature must
verify, and every file hash, size, mode, owner, and symlink target must match.
Installation and session identity are rechecked after validation; both runtime
snapshots are retained and the final snapshot is authoritative.
The adjacent `.sigstore.jsonl` bundle must verify with `gh attestation verify`
against `Imagine-That-Ai/BurnBar` and the pinned
`.github/workflows/linux-product-parity.yml` signer. A hand-authored `passed`
JSON file is never promotion evidence.

`run-product-requirement-validator.mjs` dispatches only to a deterministic
`scripts/linux-port/product-validators/P-XX.mjs` module and deletes stale output
on every failure. Its required candidate run and artifact-digest inputs come
from the trusted GitHub evidence resolver; closure-provided provenance cannot
replace them. Current release closures must directly match the invoked
requirement, environment, and selected package, and registered materialized
feature subjects are byte-validated and required in the validator result.
Requirement-specific validators exist for P-01 release
integrity, P-02 parity-certification preflight, P-03 installed runtime, P-04
architecture reach, P-31 accessibility, P-34 credential security, P-37 Linux
matrix coverage, P-38 release automation, and P-40 data and privacy. P-02 captures a
candidate-bound inventory of all 40 requirements, policies, support
environments, substantive validator modules, registered capture roles, and
materializer ownership. It remains blocked while any lane is incomplete; today
31 substantive lanes are absent. The other 31 modules remain intentionally absent until their
installed-product acceptance packets land. Source availability is not a parity
claim: every row remains blocked until all seven signed live receipts exist.

The product workflow accepts only an immutable artifact ID resolved from the
successful canonical Linux Release Candidate workflow in
`Imagine-That-Ai/BurnBar` at the exact target SHA.
`finalize-product-proof-closure.mjs` emits the required exact-candidate
aggregate only after release attestation and final verification.
It requires signed installed manifests for deb and rpm on both architectures,
every release sidecar, package/feed signatures, Sigstore bundles, and lifecycle
proof, and the validated feature-proof registry. Native package shards supply
signed installed-manifest records; aggregate
assembly validates, copies, and preserves those records before product-proof
finalization. `prepare-product-requirement-input.mjs` copies only hash-bound
subjects from a passed aggregate and a candidate-bound `collected` feature
closure into the selected requirement/environment root. Collection alone never
produces a passed parity receipt.

Release is split into three fail-closed workflows. Linux Release Candidate
builds, signs, verifies, and uploads an immutable candidate but never evaluates
parity or publishes. Linux Product Parity consumes that exact successful
candidate to produce one signed requirement/environment receipt. Linux Release
Promotion resolves exactly 280 successful first-attempt receipt artifacts at
the candidate HEAD, regenerates all 40 row attestations, runs strict ledger
validation, binds the candidate and all rows into `promotion-closure.json`, and
only then stages a draft GitHub release, publishes and verifies the signed R2
feed, and makes the GitHub release public. Missing, stale, cross-candidate,
cross-workflow, cross-repository, or cross-HEAD artifacts stop promotion.
Repeated successful certification for the same candidate is deterministic: the
newest immutable artifact ID is selected and its producer is revalidated.

The release verifier refuses to publish `latest-linux.json` while the package
closure has missing artifacts, missing signatures, missing Sigstore provenance,
dirty commit state, missing package smoke logs, or blocked parity rows.

Computer Use input and panic:

- Linux daemon-owned `system` Computer Use sessions are enabled only on Linux.
  macOS daemon sessions remain browser-only because app-owned CGEvent/AX
  dispatch stays in AgentLens.
- Linux input dispatch uses approved native adapters: AT-SPI2 for Wayland
  accessibility actions when a session bus is available, and X11/XTEST via
  `xdotool` as a degraded X11 fallback. Missing adapter prerequisites fail
  closed instead of silently substituting a fixture or keylogger path.
- Panic halt is exposed through daemon RPC, the packaged shell's global
  emergency shortcut registration (`Ctrl+Alt+Super+.` with
  `Ctrl+Alt+Shift+.` fallback), the focused-window webview fallback for the
  same chords, and the bindable CLI command
  `openburnbar-cli computer-use panic-halt --session-id '*' --source hotkey`.
  The wildcard form halts every daemon-owned Computer Use session and trips the
  privileged-input kill flag before teardown. On Linux, the default flag lives
  at `$XDG_RUNTIME_DIR/openburnbar/privileged-input-kill` so it works under the
  packaged user service's `RuntimeDirectory=openburnbar` confinement; the
  `OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH` override remains available for
  tests and deployment-specific wiring. Desktop environments that reject global
  shortcut registration remain evidence-gated; unavailable global hooks must be
  recorded as blocked rows for that DE.

Fast local checks:

```bash
node scripts/linux-port/validate-linux-release-config.mjs
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
```

The Linux toolchain image also runs five explicit Swift suites with a
fail-closed xUnit floor of 51 executed tests. The active SwiftPM test graph must
exactly match that inventory; placeholder targets, missing output, skipped tests
below the floor, an omitted target, or a zero-test pass fails both the Linux PR
gate and nightly matrix:

```bash
docker build -t openburnbar-linux-toolchain:mission-001 tools/linux-toolchain
docker run --rm -v "$PWD:/workspace" -w /workspace \
  openburnbar-linux-toolchain:mission-001 \
  bash scripts/linux-port/run-linux-swift-tests.sh
```

The runnable suite inventory lives in
[`../../scripts/linux-port/linux-swift-test-manifest.json`](../../scripts/linux-port/linux-swift-test-manifest.json).
