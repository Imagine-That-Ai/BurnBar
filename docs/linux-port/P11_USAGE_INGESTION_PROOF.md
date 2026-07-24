# P-11 Installed Usage Ingestion Proof

Status: proof contract and collector implemented. A Tier A receipt is emitted
only from a signed installed candidate in one of the seven supported Linux
environments.

## Acceptance contract

P-11 closes only when one bounded live session proves all of the following:

- a canonical provider event enters through `daemon.usage.record`;
- the first request inserts and an identical idempotency-key retry does not;
- input, output, cache creation, cache read, reasoning, USD cost, provider,
  model, confidence, session, project, and Swift reference-date timestamp
  survive without normalization drift;
- `daemon.usage.recent` returns exactly one matching row before and after a
  daemon restart;
- the append-only JSONL ledger contains zero target rows before ingestion and
  exactly one after insert, retry, and restart;
- malformed identifiers, token overflow, non-finite or negative cost,
  negative tokens, and timestamps before 2000 or over 15 seconds in the future are rejected
  by the daemon rather than persisted;
- the installed refresh subscription advances and recovers after restart; and
- the evidence is bound to the selected candidate, environment, package
  version, signed installed manifest, pinned Ed25519 key, and current source
  contracts.

No boolean summary can satisfy this proof. The validator reopens and hashes the
raw RPC transcripts and every JSONL ledger snapshot, parses their contents,
and independently recomputes the assertions above.

## Evidence layout

The live producer places these files in an owner-only scratch directory:

```text
ledger-before.jsonl
ledger-after-insert.jsonl
ledger-after-duplicate.jsonl
ledger-after-restart.jsonl
usage-rpc-transcript.json
usage-malformed-transcript.json
usage-subscription-transcript.json
```

Run that producer against a fresh, isolated daemon support directory first:

```bash
node scripts/linux-port/run-p11-usage-ingestion-session.mjs \
  --raw-output-dir "$P11_RAW_DIR" \
  --ledger-path "$P11_SUPPORT_DIR/usage-events.jsonl" \
  --socket-path "$P11_SOCKET" \
  --token-file "$P11_TOKEN_FILE" \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

The ledger must be an isolated P-11 support ledger. Do not copy a user's normal
usage ledger into certification evidence. The RPC transcript uses newline-
framed, authenticated AF_UNIX requests against the installed daemon. The
subscription transcript is produced by the installed CLI peer and records
start, pre-restart resume, and post-restart recovery sequence numbers.

The malformed transcript contains the raw ledger bytes before rejection,
after rejection, and after a valid retry for every case. The validator requires
exact JSON-RPC `-32602` responses, stable field-level validation messages,
byte-identical ledger state after rejection, and successful insertion with the
same idempotency key afterward. Its matrix covers blank, control-character,
and oversized identifiers; token-sum overflow; non-finite and negative cost;
negative tokens; and an out-of-range timestamp.

`materialize-p11-usage-ingestion-session.mjs` verifies the live installed
candidate, copies every raw file without overwriting an existing capture,
derives the canonical event and capture bounds from the transcripts, hashes
the production source contracts, and validates the completed session before
writing it. It has no fixture or unsigned mode.

```bash
node scripts/linux-port/materialize-p11-usage-ingestion-session.mjs \
  --output-root docs/linux-port/evidence/product-parity-inputs/P-11/$ENVIRONMENT \
  --raw-evidence-dir "$P11_RAW_DIR" \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256" \
  --compositor "$COMPOSITOR"
```

Then emit the feature registration:

```bash
node scripts/linux-port/capture-p11-usage-ingestion-proof.mjs \
  --input-root docs/linux-port/evidence/product-parity-inputs/P-11/$ENVIRONMENT \
  --session-report docs/linux-port/evidence/product-parity-inputs/P-11/$ENVIRONMENT/p11-installed-usage-ingestion-session.json \
  --environment "$ENVIRONMENT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

## Implementation notes

- Canonical event fields come from `BurnBarUsageEvent`; dates use Foundation's
  seconds-since-2001 JSON representation.
- The source contract includes the 33-provider ingestion catalog, daemon
  recorder and RPC path, its focused Swift tests, and the Hermes ledger writer.
- Ledger snapshots are JSONL, newline terminated when nonempty, and confined
  to the environment-specific P-11 evidence root.
- Manifest and signature copies are independently verified against the pinned
  repository public key. A changed signature hash, target commit, package
  architecture, package format, or environment fails closed.
- Collection must occur within 15 minutes of the live session. The session
  itself is limited to 15 minutes.

## QA verification

```bash
node --test scripts/linux-port/p11-usage-ingestion-proof.test.mjs
node --check scripts/linux-port/lib/p11-usage-ingestion-proof.mjs
node --check scripts/linux-port/materialize-p11-usage-ingestion-session.mjs
node --check scripts/linux-port/run-p11-usage-ingestion-session.mjs
node --check scripts/linux-port/capture-p11-usage-ingestion-proof.mjs
node --check scripts/linux-port/product-validators/P-11.mjs
```

Mutation coverage rejects candidate replay, duplicate acceptance, token/cost/
timestamp drift, malformed-input acceptance, duplicate ledger rows, restart
loss, refresh loss, subscription recovery failure, source drift, forged
signatures, stale collection, and changed evidence bytes.
