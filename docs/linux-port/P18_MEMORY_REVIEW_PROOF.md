# P-18 installed memory-review proof

P-18 proves that a signed, installed Linux candidate uses the daemon as the
authoritative memory-review store. The proof is bound to one release candidate,
Git commit, installed package manifest, supported Linux environment, and live
desktop session.

## What the proof covers

- New candidates are quarantined and excluded from normal recall.
- The review feed exposes the exact quarantined body with approve and reject
  controls.
- Approval makes the exact body available to normal recall.
- Rejection remains durable and excluded from normal recall.
- Forget removes the body while retaining a metadata-only audit tombstone.
- Approved, rejected, and forgotten transitions are idempotent daemon-owned
  state, not renderer-local overrides.
- Review decisions and body deletion survive daemon and desktop restart.
- The memory audit trail is ordered, hash-linked, and covers remember, approve,
  reject, and forget.
- The installed UI exposes pending, approved, rejected, forgotten, action, and
  audit states through AT-SPI, with distinct nonblank initial and restart
  screenshots.

This proof closes the local P-18 product contract. Cross-device encrypted cloud
replication remains part of P-16 account/cloud certification and must not be
inferred from this local installed session.

## Preconditions

Run inside the target X11 desktop session with D-Bus and AT-SPI available. No
installed OpenBurnBar desktop process may already be running. The runner stops
the user daemon service temporarily, launches the installed daemon against an
isolated owner-only project-memory database, and restores the service afterward.

The installed candidate must include:

- `/usr/bin/openburnbar-linux-desktop`
- `/usr/libexec/openburnbar-daemon-launch`
- the signed installed manifest and detached signature

The host must provide `python3`, `xdotool`, `scrot`, and the Python `pyatspi`
module.

## Capture order

Create one private working root inside the Linux guest. Never reuse a previous
capture root.

```bash
umask 077
ROOT="$HOME/p18-memory-$(date +%s)"
mkdir -m 700 "$ROOT" "$ROOT/raw" "$ROOT/support" "$ROOT/home"
printf '%064x\n' 1 >"$ROOT/support/daemon-token"
chmod 600 "$ROOT/support/daemon-token"
```

Run the live installed probe with candidate values from the signed release
closure:

```bash
node scripts/linux-port/run-p18-native-memory-probes.mjs \
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

Materialize the raw evidence under the candidate-bound environment root:

```bash
INPUT_ROOT="docs/linux-port/evidence/product-parity-inputs/P-18/$ENVIRONMENT_ID"
mkdir -p "$INPUT_ROOT"
node scripts/linux-port/materialize-p18-memory-review-session.mjs \
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
```

Capture the derived proof only after materialization succeeds:

```bash
node scripts/linux-port/capture-p18-memory-review-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p18-installed-memory-review-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture emits
`feature-artifacts/p18-installed-memory-review-proof.json` and a single-role
`feature-proof-registration.json`. Adding that role to the shared certification
registry and workflow is a separate integration step.

## Acceptance criteria

The product validator accepts exactly one `feature.memory-review-installed`
proof. Changing any candidate binding, memory identity or body, transition,
recall result, tombstone, audit hash/link, UI observation, process identity,
screenshot, installed signature, environment root, or collection time must make
validation fail.

Run the focused regression suite before collecting live evidence:

```bash
node --test \
  scripts/linux-port/p18-native-memory-probes.test.mjs \
  scripts/linux-port/p18-memory-review-proof.test.mjs

python3 -m py_compile scripts/linux-port/p18-atspi-control.py
```
