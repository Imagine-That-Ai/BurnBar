# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Current parity status as of 2026-07-19:

- The latest parity hardening reaches `82b0fcf11e` (including the WebKit
  startup fallback from `6321897d4e`). The VM now has a freshly rebuilt and
  installed arm64 package with the real `media-gst` shell viewer enabled; its
  non-certifying receipt is
  [`evidence/mission-002-reanchor/vm-e2e/current-82b0fcf11e-media-gst-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-82b0fcf11e-media-gst-arm64/).
  The preceding media-gst receipt remains a historical baseline at
  [`evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-media-gst-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-media-gst-arm64/), and the earlier non-GStreamer UI receipt remains available at
  [`evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-ui-arm64/`](evidence/mission-002-reanchor/vm-e2e/current-fdbc7d718b-ui-arm64/).
  The daemon/media capability receipt remains bound to the `a570c9b087`
  runtime package; the clean parity-ledger
  validation is bound to checkpoint `073c2aba45`. The Release and
  Nightly receipts below are historical engineering evidence for an older
  checkpoint, not a claim that the current docs head has a promoted artifact.
- The latest source hardening adds single-flight native pet-window launch
  (`511c8a1049`), body-click `open` routing for notification servers without
  action buttons (`1397313284`), GStreamer decoder retry without requiring a
  socket reconnect, and Secret Service/KWallet health-before-write onboarding
  checks (`82b0fcf11e`). Focused verification is 28/28 pet UI tests, 4/4 native
  notification Rust tests, 5/5 media Rust tests in both feature modes on the
  VM, and 6/6 Linux onboarding tests on Ubuntu.
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
- The candidate branch now has **83 desktop test files / 770 tests** passing,
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
