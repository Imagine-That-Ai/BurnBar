# P-14 Installed Chat Proof

Status: standalone Tier A proof owner implemented. A passing receipt requires
one recent session against the signed installed Linux candidate. Source tests,
fixture transcripts, and hand-authored booleans cannot close P-14.

## Acceptance contract

The installed session proves all of these behaviors together:

- the daemon inserts a message once and returns the same durable message for an
  identical message-ID retry;
- thread search isolates the target transcript;
- older-message pagination uses the stable `(timestamp, message ID)` cursor,
  preserves chronological order, and never repeats a message;
- the installed CLI reads the same thread and search result after the daemon is
  restarted;
- the database has a non-plaintext header while daemon reads still establish
  thread/message integrity;
- the installed desktop exposes live-daemon chat, selects and observes the exact
  backend model and thinking level, and completes a real gateway turn;
- a native chooser attaches an owner-only bounded file, whose size and SHA-256
  agree with persisted metadata and both export formats;
- citation navigation loads an older unseen page and opens the cited source;
- daemon-issued tool approvals reach approved, rejected, and cancelled terminal
  states;
- visibility loss/recovery refreshes the preserved thread;
- JSON and Markdown exports contain the complete durable transcript and
  attachment metadata, but no raw attachment bytes or filesystem paths; and
- opening chat twice focuses one pop-out, closing it leaves the primary window
  alive, and thread state remains intact.

Uploaded attachment bytes are deliberately desktop-process-lived. The durable transcript
keeps only bounded, path-free metadata. After a desktop relaunch the user must
re-upload the bytes before sending them again. P-14 rejects evidence that claims
otherwise.

## Live collection

Prepare an isolated owner-only raw directory, an owner-only attachment, and the
actual encrypted application database. Run from the target Linux desktop login
session, not SSH, Xvfb, a fixture shell, or a source build.

```bash
node scripts/linux-port/run-p14-chat-session.mjs \
  --raw-output-dir "$P14_RAW_DIR" \
  --database-path "$OPENBURNBAR_DATABASE" \
  --support-dir "$OPENBURNBAR_SUPPORT_DIR" \
  --attachment "$P14_ATTACHMENT" \
  --socket-path "$OPENBURNBAR_SOCKET" \
  --token-file "$OPENBURNBAR_TOKEN_FILE" \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR" \
  --backend Codex \
  --model "$MODEL_LABEL" \
  --thinking High \
  --download-dir "$XDG_DOWNLOAD_DIR"
```

The runner verifies the installed manifest before touching the UI. It uses the
authenticated Unix socket for deterministic idempotency/pagination checks, the
installed `/usr/bin/openburnbar-cli` for post-restart readback, AT-SPI for named
controls and semantic state, and X11 window-manager observations for the native
chooser and pop-out lifecycle.

The current native chooser/window proof intentionally rejects Wayland. AT-SPI
content alone cannot prove compositor window identity or a trusted native file
chooser there. This is a named evidence limitation, not a silent X11-equivalent
claim; Wayland P-14 remains blocked until a portal/compositor-backed collector is
implemented and independently validated.

## Materialize and capture

Materialization copies raw files without overwriting, derives time bounds from
the daemon and desktop transcripts, hashes current production source contracts,
copies the installed manifest/signature, and immediately revalidates everything.

```bash
node scripts/linux-port/materialize-p14-chat-session.mjs \
  --output-root "docs/linux-port/evidence/product-parity-inputs/P-14/$ENVIRONMENT" \
  --raw-evidence-dir "$P14_RAW_DIR" \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR" \
  --thread-id "$THREAD_ID"

node scripts/linux-port/capture-p14-chat-proof.mjs \
  --input-root "docs/linux-port/evidence/product-parity-inputs/P-14/$ENVIRONMENT" \
  --session-report "docs/linux-port/evidence/product-parity-inputs/P-14/$ENVIRONMENT/p14-installed-chat-session.json" \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The validator reopens and hashes every artifact. It also verifies the Ed25519
installed-manifest signature against the repository-pinned key and binds the
proof to the environment, package version, candidate run, artifact digest, and
current source hashes.

## QA verification

```bash
node --test scripts/linux-port/p14-chat-proof.test.mjs
node --check scripts/linux-port/lib/p14-chat-proof.mjs
node --check scripts/linux-port/run-p14-chat-session.mjs
node --check scripts/linux-port/run-p14-native-chat-probes.mjs
node --check scripts/linux-port/materialize-p14-chat-session.mjs
node --check scripts/linux-port/capture-p14-chat-proof.mjs
node --check scripts/linux-port/product-validators/P-14.mjs
python3 -m py_compile scripts/linux-port/p14-atspi-control.py
```

Mutation coverage rejects duplicate acceptance, cursor instability, exact-model
drift, dishonest attachment restart claims, plaintext database headers, export
path leaks, source drift, forged signatures, changed raw bytes, stale capture,
native UI failure, and Wayland evidence overclaiming.
