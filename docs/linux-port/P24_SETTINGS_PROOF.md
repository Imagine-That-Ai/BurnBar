# P-24 Installed Settings Proof

P-24 proves the Linux Settings surface from an exact signed installed candidate. It does not accept browser previews, fixture mode, source-only screenshots, or a staged desktop binary.

## Coverage

The session must cover the canonical 16-tab inventory in order:

`Home`, `General`, `Updates`, `Engine Room`, `Account`, `Cloud`, `Agents`, `Model Proxy`, `Alerts`, `Notifications`, `Devices & Sync`, `Text Expansion`, `Media & Sharing`, `Data & Privacy`, `Computer Use`, and `Pets`.

Each tab is reached from the supported native `openburnbar://settings` deep link, found through the accessible Settings search field, activated through AT-SPI, focused, and captured in a distinct nonblank PNG. Linux does not currently expose separate external URLs for individual Settings tabs; the proof does not invent unsupported routes.

Navigation coverage is deliberately separate from write coverage. The proof records an explicit ownership row for every tab. It performs exactly four reversible writes owned by P-24: `telemetryEnabled`, `privacyOptIn`, and `cloudSyncEnabled` through the canonical `daemon.config.update` RPC, plus General's native `launch_at_login_set` control. Each receipt contains the original value, requested value, authoritative readback, post-restart value, and exact restored value.

The other 14 tabs are read-only or delegated for write certification. Updates belongs to P-25; account to P-15; cloud and device sync to P-16; agents to P-20; model proxy to P-23; alerts and notifications to P-27; text expansion to P-29; media to P-08; Computer Use to P-19; Pets to P-30; and Engine Room reliability to P-33. P-24 does not invent `settings.<tab>.update` RPC methods or treat successful navigation as write proof.

## Native Integrations

The native receipt covers:

- XDG launch-at-login at `~/.config/autostart/openburnbar.desktop`, including toggle, restart persistence, ownership metadata, and restoration.
- A daemon-unavailable Settings state followed by recovery, both exposed through AT-SPI with distinct screenshots.

All mutations run as a restoration-first transaction. A capture failure triggers reverse-order restoration; a restoration failure is reported as critical and cannot be hidden by the original error.

## Artifacts

The raw runner emits `settings-native-transcript.json`, 16 tab screenshots, and degraded/recovered screenshots. Materialization copies those files plus the installed manifest and signature into the candidate-bound P-24 evidence root. Capture then emits:

- `p24-installed-settings-session.json`
- `feature-artifacts/p24-installed-settings-proof.json`
- `feature-proof-registration.json`

The validator binds all evidence to requirement, environment, target HEAD, candidate run and artifact digest, package version/architecture/format, installed-manifest hash, and installed-manifest signature hash. It rejects symlinks, out-of-root artifacts, stale capture times, duplicate paths, replayed screenshot pixels, and proof/session substitution.

## Live Prerequisites

The installed workflow adapter is
`scripts/linux-port/run-p24-installed-settings-workflow.mjs`. The existing
`run-p24-native-settings-probes.mjs` command delegates to that adapter when
invoked directly. It requires the signed installed desktop and daemon launcher,
an owner-only isolated home/support directory and daemon token, a live D-Bus
desktop session, AT-SPI, `xdotool`, and `scrot`.

```bash
node scripts/linux-port/run-p24-native-settings-probes.mjs \
  --raw-output-dir "$P24_ROOT/raw" \
  --support-dir "$P24_ROOT/support" \
  --home-dir "$P24_ROOT/home" \
  --socket-path "$P24_ROOT/support/daemon.sock" \
  --token-file "$P24_ROOT/support/daemon-socket-auth-token" \
  --index-database "$P24_ROOT/support/index.sqlite" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

The adapter stops and later restores the normal user daemon, starts the
installed daemon with isolated paths, drives the installed desktop through
AT-SPI, performs authenticated AF_UNIX RPC, and restores autostart, the three
Settings config values, desktop processes, and daemon service state on both
success and failure. The executable adapter does not claim that the live
environment matrix has passed; each environment still needs a candidate-bound
session and signed registration receipt.

Focused checks:

```bash
node --test \
  scripts/linux-port/p24-installed-settings-workflow.test.mjs \
  scripts/linux-port/p24-native-settings-probes.test.mjs \
  scripts/linux-port/p24-settings-proof.test.mjs
```
