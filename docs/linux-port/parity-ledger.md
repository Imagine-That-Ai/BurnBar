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

As of this mission slice, the ledger intentionally blocks Linux public release
promotion. The release lane must not relabel synthetic or fake-pass product
evidence as ready. Blocked rows include packaged shell real-daemon proof,
Computer Use portal and panic-halt proof, media interop/timing proof, Avahi
parser correctness, provider parser corpus/macOS oracle, and package release
promotion.

Release readiness means the strict command exits 0 from a clean release commit
and every Tier A/B row is `ready`.
