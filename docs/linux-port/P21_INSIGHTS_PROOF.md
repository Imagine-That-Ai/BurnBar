# P-21 installed Insights proof

P-21 proves that a signed, installed Linux candidate renders a populated
Insights workspace from the authoritative daemon usage ledger. The evidence is
bound to one release candidate, Git commit, installed package manifest,
supported Linux environment, and live desktop session.

## What the proof covers

- Three distinct usage rows are written through `daemon.usage.record`; no
  fixture file or renderer-generated receipt is accepted.
- `daemon.usage.insights` returns the seeded provider, model, session, and
  project identities with a populated local-rules brief.
- The response carries `daemon.usage.ledger` provenance, an executive summary,
  findings, citations, and finding-to-citation evidence links.
- The installed UI exposes the canvas library, widgets, inspector, verified
  provenance, fresh qualitative analysis, citations, and bounded audit dialog
  through AT-SPI.
- Model mix selection and Compact density persist across desktop and daemon
  restart.
- Compare renders exactly three provider scopes with per-column provenance.
- A citation opens its bounded follow-up in Chat.
- Refresh produces a distinct daemon request identity; response timestamps
  cannot move backwards or into the future.
- Losing the daemon after a valid load preserves the last successful snapshot
  and exposes the degraded banner instead of clearing or relabeling data.
- Initial, Compare, restart, and source-loss screenshots are distinct and
  nonblank.

This proof does not claim macOS visual pixel identity, cloud-shared evidence,
or certification for Linux environments not named by the session envelope.

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
ROOT="$HOME/p21-insights-$(date +%s)"
mkdir -m 700 "$ROOT" "$ROOT/raw" "$ROOT/support" "$ROOT/home"
printf '%064x\n' 1 >"$ROOT/support/daemon-token"
chmod 600 "$ROOT/support/daemon-token"
```

Run the live installed probe with candidate values from the signed release
closure:

```bash
node scripts/linux-port/run-p21-native-insights-probes.mjs \
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
INPUT_ROOT="docs/linux-port/evidence/product-parity-inputs/P-21/$ENVIRONMENT_ID"
mkdir -p "$INPUT_ROOT"
node scripts/linux-port/materialize-p21-insights-session.mjs \
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
node scripts/linux-port/capture-p21-insights-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p21-installed-insights-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture emits `feature-artifacts/p21-installed-insights-proof.json` and a
single-role `feature-proof-registration.json`. Shared registry and workflow
registration are a separate integration step.

## Acceptance criteria

The product validator accepts exactly one `feature.insights-installed` proof.
Changing the candidate binding, seeded usage identity, RPC order, request
identity, source ID, timestamp, qualitative content, citation links, three-way
Compare result, persisted selection/density, Chat handoff, source-loss state,
screenshot, installed signature, environment root, or collection time fails
validation.

```bash
node --test \
  scripts/linux-port/p21-native-insights-probes.test.mjs \
  scripts/linux-port/p21-insights-proof.test.mjs

python3 -m py_compile scripts/linux-port/p21-atspi-control.py
```
