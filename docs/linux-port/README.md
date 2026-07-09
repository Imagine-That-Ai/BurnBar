# OpenBurnBar Linux port

This directory tracks the Linux desktop peer release work. The Linux lane is
implemented as reviewable infrastructure, not a public availability claim.

Current parity status as of 2026-07-09:

- A public signed aarch64 prerelease exists at `linux-v0.1.0`.
- Full macOS parity is not complete. See
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
- [`parity-ledger.md`](parity-ledger.md) - generated human-readable ledger.
- [`parity-ledger-history.json`](parity-ledger-history.json) - archived
  mission evidence that cannot satisfy current product parity.
- [`evidence/mission-002-reanchor/`](evidence/mission-002-reanchor/) - Phase 0
  reanchor baseline for full parity work.
- [`factory-pr-handoff.md`](factory-pr-handoff.md) - review map and known
  blockers for the factory PR loop.
- [`runtime-capabilities.md`](runtime-capabilities.md) - canonical native
  capability probes, fail-closed route gating, change procedure, and QA steps.
- [`ui-parity/`](ui-parity/README.md) - W6/W7 UI parity execution plan:
  foundation reference plus parallel task packets P01–P15.
- [`evidence/`](evidence/) - generated and collected mission evidence.

The release verifier refuses to publish `latest-linux.json` while the package
closure has missing artifacts, missing signatures, missing Sigstore provenance,
dirty commit state, missing package smoke logs, or blocked parity rows.

Fast local checks:

```bash
node scripts/linux-port/validate-linux-release-config.mjs
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
node scripts/linux-port/check-linux-docs.mjs
```
