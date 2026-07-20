# P-08 Mercury media product proof

P-08 is complete only when the exact signed Linux candidate and a paired physical
device finish the same live Mercury session. Source tests, codec probes, simulator
runs, fixture transports, and screenshots without runtime events do not certify the
requirement.

## Acceptance contract

Every supported Linux environment must produce all 17 passed targets below from
both the installed Linux daemon and the physical device app:

| Target | Required outcome |
|---|---|
| `pairing` | Authenticated pairing, exact peer identity, unauthorized peer rejection |
| `presence` | Online, offline, heartbeat, and reconnect observed |
| `file-send` / `file-receive` | Non-empty transfer, identical content hashes, interrupted-transfer resume, terminal cleanup |
| `call-accepted` | Bidirectional audio and video for at least five seconds; no frames after end |
| `call-rejected` / `call-cancelled` | Visible terminal result and no frames after terminal state |
| `screen-share-consent` | Linux portal and device consent, one-shot grant, silent grant rejection |
| `screen-share-render` | Mirroring, sealed frames, at least 30 rendered frames, multi-monitor selection, p95 latency no greater than 250 ms |
| `permission-denied` / `permission-revoked` | Fail closed with a visible reason and no post-terminal frames |
| `packet-loss-recovery` | 5-30% injected loss, bounded queue, recovery within 30 seconds |
| `transport-reconnect` | At least one reconnect, recovery within 30 seconds, no duplicate terminal event |
| `suspend-resume` | Suspend and resume observed, recovery within 60 seconds, stale frame rejection |
| `codec-absence` | Capability unavailable, start rejected, visible reason, no false success |
| `unpair-repair` | Removal on both peers, stale-session rejection, successful re-pair |
| `cleanup` | No active media, capture, portal, temporary, or partial-file residue |

The two observations may report different local frame counts, latency, and timing.
They must independently satisfy every threshold. File byte counts and hashes and
the authenticated peer identity must agree across both sides.

## Required inputs

Place these files directly in the environment's P-08 input root:

- `p08-linux-desktop-observation.json`, emitted by the installed
  `openburnbar-daemon`.
- `p08-physical-device-observation.json`, emitted by the current-head
  `OpenBurnBarMobile` or Android app on physical hardware.

Both reports use `openburnbar-p08-mercury-observation-v1`. They bind the target
HEAD, candidate run ID and digest, shared session UUID, random challenge, current
app build, hardware provenance, canonical ordered events, and a verified SHA-256
event-chain terminal. A simulator, fixture mode, developer override, different
session, different candidate, stale build, missing event, non-overlapping capture,
or changed event chain fails validation.

The Linux live producer additionally verifies:

- the installed manifest and signature are root-owned and immutable;
- the manifest and signature hashes match the selected release subjects;
- the Ed25519 signature is valid;
- the strict installed-manifest schema and candidate identity match;
- package-manager ownership and every file in the signed inventory match live
  disk bytes;
- the desktop/session/architecture matches the requested support environment;
- both observations ended no more than 15 minutes before collection.

## Collection

Set `ROOT` to the environment input directory. The signed release closure supplies
all values after the equals signs:

```bash
node scripts/linux-port/run-p08-mercury-media-session.mjs \
  --output-root "$ROOT" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$INSTALLED_MANIFEST_SHA256" \
  --manifest-signature-sha256 "$INSTALLED_MANIFEST_SIGNATURE_SHA256"

node scripts/linux-port/capture-p08-mercury-media-proof.mjs \
  --input-root "$ROOT" \
  --session-report "$ROOT/p08-installed-mercury-media-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
```

The capture writes `feature-artifacts/mercury-media-installed.json` and registers
the role `feature.mercury-media-installed`. The independent validator reopens the
session and both raw reports by path and digest; embedded summaries alone cannot
pass.

## Promotion and QA

P-08 remains blocked until the shared feature-proof registry, materializer, and
Linux product-parity workflow own this producer and all seven environment receipts
pass. A receipt from one VM and iPad proves only that environment; it does not
replace GNOME X11/Wayland, KDE Wayland, Sway, x86_64/aarch64, or the broader
macOS/iOS/Android peer matrix required by the independent audit.

Focused verifier:

```bash
node --test scripts/linux-port/p08-mercury-media-proof.test.mjs
```
