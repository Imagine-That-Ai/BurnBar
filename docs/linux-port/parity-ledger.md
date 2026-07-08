# Linux parity ledger

The machine-readable ledger is [`parity-ledger.json`](parity-ledger.json). It is
the release gate source for Linux Tier A/B/C rows. Each row carries status,
evidence, command, platform, source oracle, accepted divergence, owner,
promotion criterion, commit, and environment.

Run the strict promotion check with:

```bash
node scripts/linux-port/validate-parity-ledger.mjs
```

Run the PR structural check with blocked rows preserved:

```bash
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
```

As of 2026-07-05, the ledger points at the V24 foundation and V23 surface seals
from `1b62ec42bd752cc8a6af578f034bf776c6ec3b97`. The checkout later moved to
`1af805eb1878cc5af8821ee35cac838c5ac473ee`, so product rows are blocked for
release promotion until validation is rerun at the release head. Public release
promotion also remains blocked by release packaging, update metadata,
signature/provenance, nightly-matrix artifact, release-dependent docs, and clean
commit evidence.

Release readiness means the strict command exits 0 from a clean release commit
and every Tier A/B row is `ready`.
