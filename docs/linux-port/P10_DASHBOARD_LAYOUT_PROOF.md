# P-10 dashboard layout product proof

P-10 certifies the six dashboard layouts in the installed product with live
daemon content. Unit snapshots and the historical layout-board screenshots are
useful design evidence but cannot certify the requirement.

## Acceptance contract

Each support environment supplies one
`openburnbar-linux-p10-installed-session-v1` report bound to the exact signed
candidate and real requested desktop session. It must contain:

- `classic`, `aurora`, `nebula`, `constellation`, `cockpit`, and `atelier`;
- one desktop-width and one compact-width capture for every layout;
- AT-SPI selection through the installed layout switcher and persistence after
  a full app relaunch;
- a live daemon connection, at least one provider and usage point, and
  `fixtureMode=false` for every capture;
- a PNG screenshot and matching AT-SPI tree for every layout and viewport;
- a screenshot-bound pixel audit with the exact SHA-256 and dimensions, at
  least 20 percent nonblank pixels, and zero clipping, overlap, text overflow,
  or unreadable-text findings;
- installed AT-SPI observation of populated, loading, offline, and error states,
  including busy, status, alert, and live-region semantics.

Every layout and state AT-SPI artifact repeats its native producer, capture
timestamp, app PID, window ID, desktop, display server, and installed-manifest
SHA-256. Layout identity must equal the persisted-layout-readback event after
the relaunch PID transition. State identity must equal its ordered state event.

The collector rejects Xvfb/XFCE, fixtures, Storybook/Playwright boards,
placeholder renderers, unsigned packages, stale sessions, missing viewports,
false persistence, blank or undersized PNGs, changed bytes, and partial state
coverage. All raw evidence remains below the environment's P-10 input root and
is reopened by the independent validator.

## Collection

The workflow must first invoke `run-p10-native-dashboard-probes.mjs` against the
installed candidate. The native session drives the layout switcher via AT-SPI,
resizes the window for desktop and compact captures, relaunches after every
selection, and writes raw screenshots, AT-SPI, native event, daemon, state, and
geometry files.
The executable materializer verifies the installed candidate, decodes each PNG,
computes its nonblank ratio, derives the pixel audits, and writes the session:

```bash
node scripts/linux-port/materialize-p10-dashboard-layout-session.mjs \
  --output-root "$ROOT" \
  --raw-evidence-dir "$LIVE_LAYOUT_EVIDENCE" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$INSTALLED_MANIFEST_SHA256" \
  --manifest-signature-sha256 "$INSTALLED_MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR" \
  --render-backend "$RENDER_BACKEND"
```

Then produce the feature proof:

```bash
node scripts/linux-port/capture-p10-dashboard-layout-proof.mjs \
  --input-root "$ROOT" \
  --session-report "$ROOT/p10-installed-dashboard-layout-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$INSTALLED_MANIFEST_SHA256" \
  --manifest-signature-sha256 "$INSTALLED_MANIFEST_SIGNATURE_SHA256"
```

The materializer also verifies Ed25519 against the repository-pinned release key
and binds the strict installed manifest to the closure version, architecture,
format, HEAD, and manifest/signature hashes. The collector writes
`feature-artifacts/dashboard-layouts-installed.json` and registers
`feature.dashboard-layouts-installed`. The proof references the raw
session by path, size, and SHA-256; it does not duplicate or replace that source.

## QA verification

1. Select every layout using its AT-SPI button, relaunch, and confirm the same
   `aria-pressed` layout and accessible layout name remain selected.
2. Capture desktop and compact widths with live daemon data; verify all 12 PNGs
   are nonblank and pixel audits report no clipping, overlap, overflow, or
   unreadable text.
3. Exercise loading, offline, error, and populated states and confirm AT-SPI
   exposes busy, status, alert, and live-region changes.
4. Repeat with WebGL2 unavailable and confirm the declared non-placeholder
   Canvas2D or static fallback stays readable without changing layout geometry.
5. Mutate a screenshot, audit hash, viewport, persisted selection, live-content
   claim, state list, candidate identity, or capture time and confirm failure.
6. Replay a layout or state AT-SPI artifact from another PID, window, desktop,
   display server, manifest, or timestamp and confirm failure.
7. Repeat across all seven supported desktop/session/architecture rows.

Focused verifier:

```bash
node --test scripts/linux-port/p10-dashboard-layout-proof.test.mjs
```
