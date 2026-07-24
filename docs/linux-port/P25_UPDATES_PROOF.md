# P-25 Installed Updates Proof

P-25 proves Linux update UX against real signed release infrastructure and native package ownership. The shell verifies and explains updates; `apt`/`dpkg`, `dnf`/`rpm`, `pacman`, or the user-owned AppImage remains the only component allowed to replace files.

## Acceptance boundary

One accepted session must contain:

- a previous authenticated same-architecture package showing a fresh, Ed25519-verified **available** state;
- activation of **Open signed download**, with no shell-side package mutation;
- the exact candidate showing a fresh, verified **current** state after the native package manager updates it;
- a real public-feed outage or rejection showing a fail-closed error state with install/download actions unavailable;
- a passed native update, rollback, candidate-restore, and data-preservation report;
- the restored candidate after daemon restart, with aligned shell/daemon versions and accessible restart guidance;
- four distinct nonblank installed-desktop screenshots and AT-SPI observations.

The proof does not run a fake update server. Release builds ignore `OPENBURNBAR_UPDATE_FEED_URL`, so available/current/error captures must come from the real allowlisted production feed. It does not claim rollback from guidance text: rollback passes only when the package lifecycle report proves a real previous-to-candidate update, candidate-to-previous rollback, data preservation, and candidate restoration.

If a compatible signed previous package, fresh public feed, real outage/rejection, or supported package rollback is unavailable, P-25 remains blocked. Do not substitute fixtures, a locally hosted feed, source tests, or an AppImage backup that was not authenticated.

## Capture phases

Use one empty owner-only raw directory. Run each phase only at the matching real lifecycle point:

```bash
node scripts/linux-port/run-p25-native-update-probes.mjs \
  --raw-output-dir "$P25_RAW" \
  --phase available \
  --expected-version "$PREVIOUS_VERSION" \
  --package-channel "$PACKAGE_CHANNEL" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Repeat with `--phase current`, `error`, and `restart`. Use `$PACKAGE_VERSION` as `--expected-version` for those three phases. The `available` action opens the signed first-party URL; it never installs the artifact. The `restart` phase restarts `openburnbar-daemon.service` before relaunching the installed desktop.

Place the authenticated package lifecycle report at `$P25_RAW/updates-package-lifecycle.json`. It must record the package channel, previous and candidate versions, passed update/rollback/data-preservation steps, and `restoredCandidate: true`.

Materialize and capture:

```bash
node scripts/linux-port/materialize-p25-updates-session.mjs \
  --output-root "$P25_INPUT" --raw-evidence-dir "$P25_RAW" \
  --environment "$ENVIRONMENT_ID" --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" --previous-version "$PREVIOUS_VERSION" \
  --package-channel "$PACKAGE_CHANNEL" --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"

node scripts/linux-port/capture-p25-updates-proof.mjs \
  --input-root "$P25_INPUT" \
  --session-report "$P25_INPUT/p25-installed-updates-session.json" \
  --environment "$ENVIRONMENT_ID" --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The result registers `feature.updates-installed` for `p-25.updates`. The product validator also requires the aggregate release closure, so a UI-only transcript cannot bypass package lifecycle gates.

## QA checks

1. Confirm the previous package shows a fresh verified available release and the signed-download action opens without changing installed files.
2. Confirm the package manager updates to the exact candidate and the candidate reports current.
3. Confirm invalid/unavailable feed UI disables download and install actions while retaining recovery.
4. Confirm rollback restores the previous version, preserves the sentinel, then restores the exact candidate.
5. Restart the daemon and desktop; confirm shell/daemon alignment and update-route persistence.
6. Run focused tests:

```bash
node --test \
  scripts/linux-port/p25-native-update-probes.test.mjs \
  scripts/linux-port/p25-updates-proof.test.mjs
```

Mutation coverage rejects unsafe shell package actions, screenshot replay, blocked rollback, and version substitution.
