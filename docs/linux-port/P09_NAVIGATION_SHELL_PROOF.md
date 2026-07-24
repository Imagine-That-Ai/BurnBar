# P-09 navigation and shell product proof

P-09 certifies the installed Linux shell, not its React route table. The exact
signed candidate must activate every product route through AT-SPI, paint the
selected route, survive typed provider/model deep links, and preserve native
window state. Source tests, a screenshot board, Xvfb/XFCE captures, and direct
store mutation are rejected.

## Acceptance contract

Each of the seven support environments supplies one
`openburnbar-linux-p09-installed-session-v1` report with:

- the target HEAD, candidate run ID and digest, installed package version,
  installed-manifest SHA-256, and successful signature verification;
- the exact real desktop, display server, compositor, and architecture for the
  requested support environment;
- all 19 canonical routes in order, each activated using
  `atspi-command-palette-actions`;
- a per-route AT-SPI tree, PNG screenshot, window geometry record, and
  `packaged-ui-route-after-paint:<route>` performance sample;
- provider and provider-plus-model `openburnbar://` second-launch evidence with
  strict native acceptance, single-instance forwarding, reload/history restore,
  back/forward restore, focus restore, AT-SPI, and screenshots;
- secondary-window open/close focus restoration, bounded geometry, persisted
  relaunch state, and multi-monitor restoration.

The capture must finish within 30 minutes and be collected within 15 minutes.
Every route AT-SPI tree and structured window record repeats the native probe
producer, capture timestamp, app PID, window ID, desktop, display server, and
installed-manifest SHA-256. Those values must match the route transcript and
the window must be visible, focused, and at least 320 by 200 pixels. Deep-link
AT-SPI trees repeat the identity from their final focus-restored event.
Every referenced file is a regular non-symlink file below the environment's
P-09 evidence root. The collector reopens it and checks path, byte count, and
SHA-256. Missing, repeated, stale, mutated, synthetic, or source-only evidence
fails closed.

## Collection

The workflow must first invoke `run-p09-native-navigation-probes.mjs` against
the installed candidate. That native runner writes the raw AT-SPI, screenshot,
structured window, perf, deep-link event, and native-window event artifacts.
The executable materializer
verifies the live installed candidate and derives the session report from those
files; it does not accept a hand-authored session summary:

```bash
node scripts/linux-port/materialize-p09-navigation-shell-session.mjs \
  --output-root "$ROOT" \
  --shell-evidence-dir "$LIVE_SHELL_EVIDENCE" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$INSTALLED_MANIFEST_SHA256" \
  --manifest-signature-sha256 "$INSTALLED_MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Then produce the feature proof:

```bash
node scripts/linux-port/capture-p09-navigation-shell-proof.mjs \
  --input-root "$ROOT" \
  --session-report "$ROOT/p09-installed-navigation-shell-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$INSTALLED_MANIFEST_SHA256" \
  --manifest-signature-sha256 "$INSTALLED_MANIFEST_SIGNATURE_SHA256"
```

The materializer copies and reopens the installed manifest and signature,
verifies Ed25519 against the repository-pinned release key, validates the strict
manifest inventory identity, and binds those bytes to the selected release
closure. The collector writes
`feature-artifacts/navigation-shell-installed.json` and registers
`feature.navigation-shell-installed`. The independent P-09 validator reopens
the source session and every raw artifact; the proof JSON cannot pass by
embedding a summary.

## QA verification

1. Exercise all 19 routes using installed AT-SPI actions and confirm the route
   name appears in the matching tree and post-paint sample.
2. Launch provider and model links into an already-running instance; reload,
   go back/forward, close the secondary window, and confirm selection and focus.
3. Move and resize a secondary window across monitors, relaunch, disconnect a
   monitor, and verify restored geometry remains visible.
4. Replay an AT-SPI or window artifact from another PID, window, desktop,
   display server, manifest, or timestamp and confirm collection fails.
5. Mutate one screenshot CRC, perf row, candidate ID, manifest/signature,
   deep-link destination, environment path, or timestamp and confirm failure.
6. Repeat on every GNOME X11/Wayland, KDE Wayland, and Sway architecture row.

Focused verifier:

```bash
node --test scripts/linux-port/p09-navigation-shell-proof.test.mjs
```
