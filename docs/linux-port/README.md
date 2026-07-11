# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Install the small documentation tool package with
`npm ci --prefix scripts/linux-port --ignore-scripts` before running
`node scripts/linux-port/check-linux-docs.mjs` or regenerating the browser-ready
parity audit.

Parity audit baseline: 2026-07-09. Remediation evidence was refreshed on
2026-07-10; source-implemented work remains distinct from deployed and
environment-certified parity:

- A public signed aarch64 prerelease exists at `linux-v0.1.0`.
- Full macOS parity is not complete. See
  the browser-ready
  [`LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html`](LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.html)
  or its Markdown source
  [`LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md`](LINUX_MACOS_PARITY_INDEPENDENT_AUDIT_2026-07-09.md)
  for the independent executive summary, parity matrix, implementation plan,
  prioritized roadmap, and QA checklist.
- The Linux App Check challenge/verifier/daemon-client boundary plus the
  fail-closed root broker transport, per-request kernel credential binding,
  signed installed-file manifest, default-disabled activation gate, active-user
  daemon upgrade recovery, native deb/rpm lifecycle, broker-owned AK
  initialization/rotation, PCR-bound `tpm2_quote` collection, sealed
  IMA/measured-boot evidence descriptors, verifier/mint revocation gates, and a
  high-risk owner revocation callable with pre-materialization enrollment/slot
  tombstones and an atomic tamper-evident audit event are implemented in source.
  The real Firebase Web app, remote enrollment
  activation, deployed ingress/verifier/revocation operation, physical TPM/IMA
  vectors, production audit evidence, and installed matrix remain blocked.
  Linux stays `linux_lower_trust`, and this is not production attestation proof.
- For the CMUX-synthesized implementation plan, see
  [`FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`](FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md).
- The 2026-07-05 release notes below are historical context and should not be
  read as the current live GitHub release state.

Historical active-checkout snapshot captured on 2026-07-05:

- V24 foundation and V23 surface validation passed from
  `$WORKSPACE` at
  `1b62ec42bd752cc8a6af578f034bf776c6ec3b97`.
- The checkout later moved to `1af805eb1878cc5af8821ee35cac838c5ac473ee`;
  release closure must rerun the active-checkout validators at that head or
  restore the sealed head before claiming current release readiness.
- The evidence pointer for that snapshot is
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
- [`LINUX_NATIVE_SHELL_AUTHORITY.md`](LINUX_NATIVE_SHELL_AUTHORITY.md) -
  single-instance launch/deep-link handling, live tray facts and actions,
  user-scoped XDG login start, package ownership, and remaining native-shell
  certification.
- [`LINUX_ACCOUNT_AUTH_AUTHORITY.md`](LINUX_ACCOUNT_AUTH_AUTHORITY.md) -
  purpose-bound device authorization, sealed credential delivery, daemon-owned
  Firebase refresh, keyring custody, redacted desktop state, local sign-out,
  browser approval order, and remaining account/cloud parity blockers.
- [`cloud-security-runbook.md`](cloud-security-runbook.md) - lower-trust Linux
  App Check protocol, configuration, supported/unsupported environments,
  rollout/rollback, production blockers, and QA acceptance. The architectural
  decision is [ADR 015](../architecture/015-linux-app-check-attestation.md).
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
on every failure. Those requirement-owned validators are intentionally absent
until their installed-product acceptance packets land, so the complete ledger
remains fail-closed at 0 ready / 40 blocked.

The product workflow accepts only an immutable artifact ID resolved from the
successful canonical Linux release workflow in `Imagine-That-Ai/BurnBar` at the
exact target SHA. The current release artifact does not yet contain the required
product-proof closure, so this producer boundary remains intentionally blocked
until `LNX-PROOF-001` adds exact-candidate assembly and aggregation.

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
node scripts/linux-port/render-linux-parity-audit-html.mjs --check
node scripts/linux-port/validate-linux-release-config.mjs
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
```
