# P-06 Gateway Credential Boundary Proof

P-06 proves that the signed, installed Linux desktop keeps the daemon gateway
bearer in the native Tauri process. It is separate from P-05, which proves how
credentials are stored at rest.

## What the live session proves

`run-p06-gateway-boundary-session.mjs` refuses fixture and unsigned inputs. It
requires the installed manifest, detached Ed25519 signature, release public key,
desktop binary, and production renderer assets to be root-owned and immutable.
The manifest must match the selected candidate commit, package version,
architecture, format, and caller-supplied SHA-256.

Against a live installed desktop it then proves:

- the native binary contains the bounded probe, stream, and cancellation proxy,
  loopback-only endpoint rejection, request/response limits, and abort path;
- the signed renderer assets contain no gateway credential API, direct
  `fetch(...)`, or exact daemon bearer bytes;
- the renderer CSP permits only the Tauri IPC transport, not HTTP, HTTPS, WS, or
  WSS;
- at least one WebKit renderer owned by the exact desktop process is live; and
- the exact bearer bytes do not occur in the desktop/WebKit process arguments or
  environments.

The bearer is held in a mutable buffer only for comparisons, zeroed before the
report is created, and never written to evidence. The report contains hashes,
counts, and booleans only.

## Produce and capture

Run the producer inside the target graphical session after installing the exact
signed candidate:

```bash
node scripts/linux-port/run-p06-gateway-boundary-session.mjs \
  --token-file "$XDG_RUNTIME_DIR/openburnbar/daemon-socket-auth-token" \
  --output-root "$P06_INPUT_ROOT" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256"

node scripts/linux-port/capture-p06-gateway-boundary-proof.mjs \
  --input-root "$P06_INPUT_ROOT" \
  --session-report "$P06_INPUT_ROOT/p06-gateway-boundary-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
```

The capture emits
`feature-artifacts/gateway-credential-boundary-installed.json` and a
`feature-proof-registration.json` using role
`feature.gateway-credential-boundary-installed`.

## Fail-closed boundaries

The validator rejects changed source hashes, extra or missing fields, stale
candidate identity, unsigned/local package claims, unsupported environments,
missing WebKit processes, direct renderer networking, a bearer-returning Tauri
command, non-loopback native routing, incomplete limits/cancellation, and any
credential-shaped material in the evidence document.

Run the focused suite with:

```bash
node --test scripts/linux-port/p06-gateway-credential-boundary-proof.test.mjs
```

## Remaining integration

The producer, capture, independent validator, and mutation suite do not by
themselves register P-06 with the global certification closure. The shared
registry, evidence materializer, release workflow, ownership preflight, and all
seven signed environment receipts must still be wired by the integration owner.
Until those changes and receipts exist, P-06 remains unregistered and cannot be
counted ready by strict parity certification.
