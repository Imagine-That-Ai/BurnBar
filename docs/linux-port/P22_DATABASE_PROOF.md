# P-22 installed Database proof

P-22 proves that one signed, installed Linux candidate renders and retains a
populated Database workspace backed by the installed daemon. The evidence is
bound to one release candidate, Git commit, package manifest, supported Linux
environment, and live desktop session.

## What the proof covers

- The daemon indexes 14 marker-bound source files and returns enough search
  hits to exercise UI pagination.
- Project watching starts, survives an encrypted snapshot restore, and indexes
  a post-restore source change.
- Search and bounded context-pack responses carry the canonical untrusted
  source-data signal. Context output may not exceed 24,000 bytes.
- Atlas exposes populated rows. The AT-SPI inspector proves metadata while also
  proving that source contents are not fetched or inferred by that view.
- The installed UI renders page one, page two, a context pack, its trust
  warning, indexing controls, encrypted snapshot controls, and ready recovery
  status.
- A daemon and desktop restart retain the populated indexed corpus.
- The daemon reports a SQLCipher-encrypted index and a real native-key recovery
  state of `ready` before recovery operations begin.
- Snapshot and restore responses are bound to the same SHA-256 digest and an
  `ok` integrity result. Snapshot and bundle paths are owner-only.
- A real recovery bundle is exported. Wrong-passphrase and byte-tampered
  imports fail closed; importing the unchanged bundle verifies the candidate
  key against the encrypted database before storage.
- Five UI screenshots are distinct and nonblank.

The evidence package copies the encrypted database snapshot, recovery bundle,
and byte-tampered bundle so validators can independently recompute their hashes
and sizes. These files remain owner-only. Passphrases are never recorded.

## Deliberate safety boundary

The proof does not delete, replace, or disable the user's native keyring entry.
It therefore does not claim that destructive key-loss or a separate-device
transfer was induced during this run. Those environment-specific drills remain
separate operator tests. The runner does prove the non-destructive fail-closed
states available from the installed product: wrong passphrase, tampered bundle,
candidate-key verification, integrity verification, and restart persistence.

If `daemon.database.recovery.status` is not genuinely `ready` with export and
database-integrity verification enabled, the runner stops and reports the real
phase and code. It does not create a substitute key or fabricate keyring proof.

## Preconditions

Run inside the target X11 desktop session with D-Bus and AT-SPI available. No
installed OpenBurnBar desktop process may already be running. The runner stops
the user daemon service temporarily, launches the installed daemon against an
isolated owner-only support directory and home, and restores the service.

The packaged daemon must include SQLCipher support, and the active Linux user
must already have the matching database key in the supported native secret
store. The host must provide `python3`, `xdotool`, `scrot`, and Python `pyatspi`.

## Capture order

Create one private working root inside the Linux guest. Never reuse a previous
capture root.

```bash
umask 077
ROOT="$HOME/p22-database-$(date +%s)"
mkdir -m 700 "$ROOT" "$ROOT/raw" "$ROOT/support" "$ROOT/home"
printf '%064x\n' 1 >"$ROOT/support/daemon-token"
chmod 600 "$ROOT/support/daemon-token"
```

Run the live installed probe with values from the signed release closure:

```bash
node scripts/linux-port/run-p22-native-database-probes.mjs \
  --raw-output-dir "$ROOT/raw" \
  --support-dir "$ROOT/support" \
  --home-dir "$ROOT/home" \
  --socket-path "$ROOT/support/daemon.sock" \
  --token-file "$ROOT/support/daemon-token" \
  --index-database "$ROOT/support/index.sqlite" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Materialize and capture the candidate-bound proof:

```bash
INPUT_ROOT="docs/linux-port/evidence/product-parity-inputs/P-22/$ENVIRONMENT_ID"
mkdir -p "$INPUT_ROOT"
node scripts/linux-port/materialize-p22-database-session.mjs \
  --output-root "$INPUT_ROOT" \
  --raw-evidence-dir "$ROOT/raw" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"

node scripts/linux-port/capture-p22-database-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p22-installed-database-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture emits `feature-artifacts/p22-installed-database-proof.json` and a
single-role `feature-proof-registration.json`. Shared registry and workflow
registration are a separate integration step.

## Acceptance criteria

The product validator accepts exactly one `feature.database-installed` proof.
Changing the candidate binding, RPC order, marker rows, trust signal, context
bound, encrypted/integrity result, recovery readiness, redaction, fail-closed
mutation, persisted row, accessibility observation, screenshot, installed
signature, environment root, or collection time fails validation.

```bash
node --test \
  scripts/linux-port/p22-native-database-probes.test.mjs \
  scripts/linux-port/p22-database-proof.test.mjs

python3 -m py_compile scripts/linux-port/p22-atspi-control.py
```
