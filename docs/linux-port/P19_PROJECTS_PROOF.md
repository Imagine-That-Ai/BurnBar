# P-19 installed Projects proof

P-19 proves that a signed, installed Linux candidate uses the daemon controller
registry as the authoritative Projects store. The evidence is bound to one
release candidate, Git commit, installed package manifest, supported Linux
environment, and live desktop session.

## What the proof covers

- `daemon.controller.project.upsert`, `list`, and `get` preserve canonical
  project identity and alias resolution.
- `daemon.controller.project.delete` removes the registry entry while retaining
  a durable deletion tombstone.
- `daemon.controller.project.reassign` resolves a deleted source identity and
  reassigns durable references to a live target. The probe creates a real
  source-project mission, requires a positive migrated-reference count, and
  reads the mission back from the target project before and after restart.
- A daemon restart replays the target, deletion, and reassignment state.
- The deleted source remains absent by slug and alias after restart.
- Reusing a tombstoned slug, stable ID, or alias is rejected after restart.
- The installed Projects UI exposes both initial projects, then only the live
  target and its detail/history surface after restart through AT-SPI.
- Initial and restart screenshots are distinct and nonblank.

The proof does not infer cloud replication or mobile behavior. Those remain
owned by their separate product requirements.

## Preconditions

Run inside the target X11 desktop session with D-Bus and AT-SPI available. No
installed OpenBurnBar desktop process may already be running. The runner stops
the user daemon service temporarily, launches the installed daemon against an
isolated owner-only support directory and home, and restores the service.

The installed candidate must include:

- `/usr/bin/openburnbar-linux-desktop`
- `/usr/libexec/openburnbar-daemon-launch`
- the signed installed manifest and detached signature

The host must provide `python3`, `xdotool`, `scrot`, and Python `pyatspi`.

## Capture order

Create one private working root inside the Linux guest. Never reuse a previous
capture root.

```bash
umask 077
ROOT="$HOME/p19-projects-$(date +%s)"
mkdir -m 700 "$ROOT" "$ROOT/raw" "$ROOT/support" "$ROOT/home"
printf '%064x\n' 1 >"$ROOT/support/daemon-token"
chmod 600 "$ROOT/support/daemon-token"
```

Run the live installed probe with candidate values from the signed release
closure:

```bash
node scripts/linux-port/run-p19-native-projects-probes.mjs \
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
INPUT_ROOT="docs/linux-port/evidence/product-parity-inputs/P-19/$ENVIRONMENT_ID"
mkdir -p "$INPUT_ROOT"
node scripts/linux-port/materialize-p19-projects-session.mjs \
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
node scripts/linux-port/capture-p19-projects-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p19-installed-projects-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture emits `feature-artifacts/p19-installed-projects-proof.json` and a
single-role `feature-proof-registration.json`. Shared registry and workflow
registration are a separate integration step.

## Acceptance criteria

The product validator accepts exactly one `feature.projects-installed` proof.
Changing the candidate binding, project identity, RPC order, deletion result,
tombstone rejection, migrated-reference count, associated mission project,
reassignment target, restart state, UI observation, screenshot, installed
signature, environment root, or collection time fails validation.

```bash
node --test \
  scripts/linux-port/p19-native-projects-probes.test.mjs \
  scripts/linux-port/p19-projects-proof.test.mjs

python3 -m py_compile scripts/linux-port/p19-atspi-control.py
```
