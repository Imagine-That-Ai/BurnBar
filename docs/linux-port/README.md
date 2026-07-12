# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Current parity status as of 2026-07-09:

- A public signed aarch64 prerelease exists at `linux-v0.1.0`.
- Full macOS parity is not complete. See
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
- [`accessibility-validation.md`](accessibility-validation.md) - axe route
  matrix, installed-app AT-SPI/Orca harness, evidence contract, and remaining
  manual GNOME/KDE certification.
- [`performance-reliability-validation.md`](performance-reliability-validation.md) -
  repeated packaged-shell percentiles, matched production-linked macOS/Linux
  workloads, resource soak, supervisor behavior, and fail-closed QA contract.
- [`LINUX_EVENT_SUBSCRIPTION_AUTHORITY.md`](LINUX_EVENT_SUBSCRIPTION_AUTHORITY.md) -
  daemon start/resume/stop cursors, desktop cadence and cancellation, recovery
  behavior, honest degraded-pull status, and remaining installed certification.
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
architecture reach, P-37 Linux matrix coverage, and P-38 release automation. P-02 captures a
candidate-bound inventory of all 40 requirements, policies, support
environments, substantive validator modules, registered capture roles, and
materializer ownership. It remains blocked while any lane is incomplete; today
34 substantive lanes are absent. The other 34 modules remain intentionally absent until their
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
