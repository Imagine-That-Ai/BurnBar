# P-34 Credential Security Proof

P-34 is the Linux-native counterpart to the macOS Keychain boundary. The
product parity workflow captures one candidate-bound JSON proof for each
supported installed environment:

```text
node scripts/linux-port/capture-p34-credential-security-proof.mjs \
  --input-root docs/linux-port/evidence/product-parity-inputs/P-34/{environment} \
  --environment {environment} \
  --target-head {commit} \
  --candidate-run-id {run} \
  --candidate-artifact-digest sha256:{digest}
```

The capture is deliberately metadata-only. It probes only fixed,
root-owned native command paths (`secret-tool` and `kwallet-query`), the
desktop session bus, and the presence of `CREDENTIALS_DIRECTORY`. It never
reads a keyring item, opens a credential file, puts a value in an argument or
environment variable, or creates a production credential. If a desktop
backend is unavailable, the proof labels the behavior `contract-fixture`
instead of claiming a live keyring result.

Every backend carries the same fail-closed test-double matrix:

| Case | Required outcome |
|---|---|
| Missing | Read is absent, writes are unavailable, and no desktop plaintext fallback is accepted. |
| Locked | Read/write are unavailable, no fallback is used, and recovery is repairable. |
| Rotation | The old fingerprint is rejected, the new value is accepted, and restart is not required. |
| Recovery | Unlocking makes the store available without restarting the daemon. |
| Redaction | Logs, environment, renderer state, support bundles, and diagnostics contain no credential bytes. |

The validator re-hashes the release manifest, runbook, native command
discovery, Linux Secret Service implementation/tests, and credential contract
test from the candidate checkout. It rejects stale source evidence,
candidate/environment substitution, incomplete backend matrices, accepted
rotated values, locked-keyring fallback, and any credential-like material in
the proof. The `fixture` mode is evidence of the contract and safety behavior;
promotion still requires live GNOME/KDE/headless installed-environment
receipts for the declared matrix.

