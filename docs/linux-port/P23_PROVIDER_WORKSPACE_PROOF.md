# P-23 Provider and Model Workspace Proof

P-23 closes the installed Linux proof gap for the provider and model workspace. The proof is accepted only when the exact release candidate, its active installed daemon, and its installed desktop produce one cryptographically bound evidence set.

## What the probe proves

- The daemon catalog supplies the selected provider and canonical model.
- Two already-configured native credential slots each complete a small real request when selected manually.
- Marking the preferred slot quota-exhausted causes the same model to route through the second slot.
- A custom model, alias, and high-thinking variant survive a daemon restart.
- Provider, model, and forwarded alias deep links restore keyboard focus in the installed desktop's AT-SPI tree.
- Healthy, degraded, exhausted, cooling-down, missing-secret, and unavailable states appear in the accessible UI.
- The exact original daemon configuration is restored and confirmed after a final daemon restart.

The runner makes **three small real provider requests**. They may consume a small amount of provider quota and incur a small provider charge. It never creates credentials, reads credential values, or writes credential values into evidence.

The direct daemon RPC path uses Swift's native Foundation-reference numeric date encoding for every configuration mutation. ISO timestamps are used only for the proof envelope and local event ordering.

## Preconditions

- Run inside the supported Linux desktop environment against the exact installed candidate.
- `openburnbar-daemon.service` must be active for the current user.
- No installed OpenBurnBar desktop process may already be running.
- The daemon must expose one enabled provider with a catalog model and at least two enabled, working native credential slots.
- The daemon token must be a regular owner-only file, and the evidence directory must be empty and owner-only.
- `python3`, `xdotool`, `scrot`, D-Bus, and AT-SPI must be available in the desktop session.

Missing credentials, a single configured account, an unavailable native route, inaccessible UI, or a failed restoration is a hard failure. Do not replace it with fixture evidence or a manual claim.

## Capture sequence

Use the release closure's exact values for all binding arguments:

```bash
node scripts/linux-port/run-p23-native-provider-workspace-probes.mjs \
  --raw-output-dir "$P23_RAW" \
  --socket-path "$OPENBURNBAR_DAEMON_SOCKET" \
  --token-file "$OPENBURNBAR_DAEMON_TOKEN_FILE" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Materialize the signed installed session:

```bash
node scripts/linux-port/materialize-p23-provider-workspace-session.mjs \
  --output-root "$P23_INPUT" \
  --raw-evidence-dir "$P23_RAW" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Capture the derived product proof:

```bash
node scripts/linux-port/capture-p23-provider-workspace-proof.mjs \
  --input-root "$P23_INPUT" \
  --session-report "$P23_INPUT/p23-installed-provider-workspace-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The capture registers `feature.provider-workspace-installed` for `p-23.provider-and-model-workspace`.

## Safety and recovery

The probe snapshots the complete typed daemon configuration before mutation. It changes only provider selection, non-secret credential health/quota metadata, and custom model lifecycle metadata. It detaches its client, restores the original snapshot, restarts the daemon, and requires byte-equivalent JSON readback before writing successful evidence.

The `finally` path retries restoration after any intermediate failure. A restoration failure prints `P-23 CRITICAL` and fails the run. Stop product validation and repair the installed daemon configuration before another attempt.

Raw JSON and screenshots are copied as owner-only files. The validator recursively rejects common credential field names, requires three distinct successful route records, verifies ordered daemon and UI events, checks five distinct nonblank screenshots, and binds every artifact to the signed installed manifest and candidate digest.

## QA verification

1. Confirm all three real requests completed and route logs identify slot A, slot B, then slot B after slot A is exhausted.
2. Restart the daemon and confirm the custom model, alias, variant, preferred account, and failover mode persist.
3. Confirm the custom-model and forwarded-alias rows receive AT-SPI keyboard focus.
4. Confirm screenshots independently show detail, model deep link, restored alias deep link, degraded, and unavailable states.
5. Confirm the final configuration equals the original snapshot and the daemon is active.
6. Run the focused tests:

```bash
node --test \
  scripts/linux-port/p23-native-provider-workspace-probes.test.mjs \
  scripts/linux-port/p23-provider-workspace-proof.test.mjs
```

The tests also verify fail-closed behavior for missing second credentials, leaked credential fields, substituted route accounts, and incomplete configuration restoration.
