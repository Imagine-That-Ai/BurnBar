# P-32 installed performance proof

P-32 proves performance from the existing BurnBar performance harness. It does
not add a second benchmark or weaken the budgets in
`budgets/linux-desktop.perf.json`.

## Proof contract

The proof is accepted only when all of the following are true:

- The Linux package is the exact signed installed release candidate. The live
  verifier checks the installed manifest, Ed25519 signature, package version,
  commit, format, architecture, binaries, operating system, and desktop session.
- The checkout HEAD matches the selected candidate HEAD.
- Both matched probes emit producer-time provenance containing the candidate
  run/digest, target HEAD, package version, source digest, platform/profile,
  measurement window, and a hash of the report payload. The native packaged
  session emits the equivalent identity. Missing or edited provenance fails.
- `run-matched-performance.mjs` used the `nightly` profile on macOS and Linux:
  30 samples after 5 warmups and at least 1,800 seconds of soak per platform.
- Both matched reports use the same normalized architecture (`arm64` and
  `aarch64` are equivalent; `x86_64` and `amd64` are equivalent).
- The four workload IDs, configuration, checksums, percentile order, absolute
  p95/p99 budgets, Linux-to-macOS parity limits, RSS limits, memory growth, and
  CPU limits all pass when independently recomputed from the raw reports.
- The four packaged-shell metrics (`app.start`, `route.navigation`,
  `ipc.health.roundtrip`, and `tray.click.open`) meet their configured p95
  budgets and minimum sample counts. Percentiles are recomputed from the raw
  samples; reported summary values are not trusted.
- Every route sample comes from `packaged-ui-route-after-paint:*`. Pre-paint,
  placeholder, synthetic, or source-only measurements fail closed.
- Every `ipc.health.roundtrip` sample carries a matching receipt in
  `tray-reconnect-receipts.jsonl`: sequential sample indices, a strictly
  advancing DBusMenu revision, a connected daemon, and an elapsed time equal
  to the reported sample. Every receipt cross-links one owner-only structured
  acknowledgement written by the actual `Reconnect daemon` tray handler in
  `tray-reconnect-handler-acks.jsonl`. The acknowledgement carries a unique
  handler event id, the exact `health-<unix-nanos>` request id issued by that
  handler, handler start/completion timestamps inside the click-to-observation
  window, and proof that the direct update of the logical `status` menu item
  succeeded. The runtime rejects a daemon response unless its envelope id
  matches that exact request id and its protocol version is supported. The
  receipt then captures the stable numeric DBusMenu status-item id, the exact
  connected label observed through `GetLayout`, and an observation timestamp
  taken only after both the live menu and daemon log have been read. The
  observed label must equal the handler acknowledgement, and the observation
  timestamp must equal click time plus the reported sample. That request id
  must occur exactly once in
  `tray-reconnect-daemon-health.log`. Missing, duplicate, background-only,
  truncated, or edited evidence fails closed. Periodic health polling cannot
  emit a handler acknowledgement and therefore cannot satisfy a sample.
- The comparison, packaged budget, threshold report, macOS cross-link, raw
  reports, raw samples, and installed candidate receipt cross-link exactly by
  content hash.
- Evidence and outputs are owner-only regular files in canonical, disjoint,
  non-symlinked directories. Materialized evidence remains inside the P-32
  repository evidence root.

## Collection order

Use a clean checkout of the candidate HEAD. Produce macOS and Linux matched
reports with the same normalized architecture. The two long-running probes may
run concurrently.

```bash
export OB_MATCHED_PERF_PROFILE=nightly
export OB_EVIDENCE_OUT="$P32_SOURCE"
export OB_CANDIDATE_RUN_ID="$CANDIDATE_RUN_ID"
export OB_CANDIDATE_ARTIFACT_DIGEST="$CANDIDATE_ARTIFACT_DIGEST"
export OB_PERFORMANCE_TARGET_HEAD="$TARGET_HEAD"

node scripts/linux-port/run-matched-performance.mjs --macos-only --profile nightly \
  --target-head "$TARGET_HEAD" --package-version "$PACKAGE_VERSION" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
node scripts/linux-port/run-matched-performance.mjs --linux-only --profile nightly \
  --target-head "$TARGET_HEAD" --package-version "$PACKAGE_VERSION" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
node scripts/linux-port/run-matched-performance.mjs \
  --compare-only --profile nightly \
  --macos-input "$P32_SOURCE/matched-performance-macos.json" \
  --linux-input "$P32_SOURCE/matched-performance-linux.json" \
  --target-head "$TARGET_HEAD" --package-version "$PACKAGE_VERSION" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"

node scripts/linux-port/run-perf-budget.mjs
```

The native packaged-session producer must run with the three exported
`OB_*` candidate variables above and must already have written these files into
the same source directory before `run-perf-budget.mjs` runs:

- `linux-desktop-session-report.json`
- `runtime-perf-samples.jsonl`
- `tray-reconnect-handler-acks.jsonl`
- `tray-reconnect-daemon-health.log`
- `tray-reconnect-receipts.jsonl`
- `packaged-route-session-transcript.json`

Create fresh owner-only input and output directories. The output directory must
be empty. Then bind the reports to the live installed candidate:

```bash
node scripts/linux-port/run-p32-installed-performance-workflow.mjs \
  --input-dir "$P32_SOURCE" \
  --output-dir "$P32_RAW" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"

node scripts/linux-port/materialize-p32-performance-session.mjs \
  --output-root "$P32_EVIDENCE_ROOT" \
  --raw-evidence-dir "$P32_RAW" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"

node scripts/linux-port/capture-p32-performance-proof.mjs \
  --input-root "$P32_EVIDENCE_ROOT" \
  --session-report "$P32_EVIDENCE_ROOT/p32-installed-performance-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  --manifest-signature-sha256 "$MANIFEST_SIGNATURE_SHA256"
```

`feature-proof-registration.json` registers the single
`feature.performance-installed` artifact. Shared workflow, registry, and
preflight ownership are intentionally separate from this standalone package.

## Verification

```bash
node --test scripts/linux-port/p32-performance-proof.test.mjs
node --test scripts/linux-port/matched-performance-contract.test.mjs \
  scripts/linux-port/perf-budget-contract.test.mjs
```

The focused suite covers full construction and the real P-32 product validator
through a release-closure context. It also rejects shortened soak, architecture
drift, workload checksum drift, forged native summaries, pre-paint sources,
post-capture mutation, reused output directories, symlink traversal, and
evidence roots outside the repository. Producer-time mutation coverage also
rejects changed HEAD/version/candidate/source identities, detached payload
hashes, truncated measurement windows, and stale reports from an earlier run.

## Honest limitation

This package establishes proof ownership and fail-closed validation. It does not
claim that the seven-environment release matrix has run. Each environment still
needs an exact signed candidate execution, and each architecture needs a
same-architecture macOS matched report, before P-32 can be certified for that
row.
