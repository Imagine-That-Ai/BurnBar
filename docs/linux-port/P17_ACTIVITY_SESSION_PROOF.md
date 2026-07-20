# P-17 installed Activity and session-log proof

P-17 proves that a signed, installed Linux candidate can display, search, inspect,
export, and resume persisted Activity sessions with the same durable data contract
used by the macOS app. The proof is fail-closed and bound to one release candidate,
Git commit, supported Linux environment, and installed-package attestation.

## What the proof covers

- Complete Activity history returned through the installed CLI and daemon socket.
- Exact provider-qualified source resolution for lexical search.
- Persisted session-body loading in the installed desktop UI.
- Daemon-validated, non-launching native Codex resume argument readback.
- Explicit rejection of missing and ambiguous session identifiers.
- Loaded-index JSON, Markdown, and complete-history JSON exports.
- Last-successful-body retention with an accessible error state during daemon loss.
- Search, history, replay, and body durability after daemon and desktop restarts.
- AT-SPI names/actions and three distinct nonblank live-state screenshots.
- Signed installed-manifest verification and content-addressed evidence closure.

The runner does not launch Codex or claim that a resumed provider process completed.
It verifies the production daemon's native resume resolution in `print` mode, including
the real session-file readback, without weakening installed launcher trust or `PATH`.

## Preconditions

Run inside the target Linux desktop session using an installed candidate. The session
must provide X11, D-Bus, AT-SPI, `python3`, `xdotool`, and `scrot`. No installed
OpenBurnBar desktop process may already be running. The runner temporarily stops the
user `openburnbar-daemon.service`, restores it afterward, and uses isolated owner-only
support, home, download, and evidence directories.

After validating that the isolated home and download roots are empty and owner-only,
the runner writes that exact download root to the isolated profile's
`.config/user-dirs.dirs`. WebKit therefore hands native Activity exports to the same
directory the proof monitors; the runner rejects paths that cannot be encoded safely.

The installed candidate must include:

- `/usr/bin/openburnbar-cli`
- `/usr/bin/openburnbar-linux-desktop`
- `/usr/libexec/openburnbar-daemon-launch`
- the signed installed manifest and detached signature

## Capture order

Create one private working root in the Linux guest. Do not reuse it across captures.

```bash
umask 077
ROOT="$HOME/p17-activity-$(date +%s)"
mkdir -m 700 "$ROOT" "$ROOT/raw" "$ROOT/support" "$ROOT/home" "$ROOT/downloads"
printf '%064x\n' 1 >"$ROOT/support/daemon-token"
chmod 600 "$ROOT/support/daemon-token"
```

Set the candidate binding from the signed release closure, then run the native probe:

```bash
node scripts/linux-port/run-p17-native-activity-probes.mjs \
  --raw-output-dir "$ROOT/raw" \
  --support-dir "$ROOT/support" \
  --home-dir "$ROOT/home" \
  --download-dir "$ROOT/downloads" \
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
INPUT_ROOT="docs/linux-port/evidence/product-parity-inputs/P-17/$ENVIRONMENT_ID"
mkdir -p "$INPUT_ROOT"
node scripts/linux-port/materialize-p17-activity-session.mjs \
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
node scripts/linux-port/capture-p17-activity-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p17-installed-activity-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture emits `feature-artifacts/p17-installed-activity-proof.json` and a
single-role `feature-proof-registration.json`. Registration in the shared product
workflow is a separate integration step.

## Acceptance criteria

The product validator must accept exactly one `feature.activity-installed` proof.
Changing any bound artifact bytes, source identity, body, search hit, resume command,
error status, export schema, retained failure, restart PID, screenshot, signature,
environment root, or collection time must make validation fail.

Run the focused regression suite before using live evidence:

```bash
node --test \
  scripts/linux-port/p17-native-activity-probes.test.mjs \
  scripts/linux-port/p17-activity-proof.test.mjs

swift test --package-path OpenBurnBarDaemon \
  --scratch-path .tmp/p17-swift-build \
  --filter BurnBarCLITests
```
