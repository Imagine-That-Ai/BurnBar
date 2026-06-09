# BurnBar Source Availability

BurnBar's main shipped product is AGPL-3.0-only because it includes
Signal/libsignal-backed E2EE. Anyone receiving a Signal-enabled BurnBar build,
or interacting with a hosted Signal-enabled BurnBar service over a network, must
be able to obtain the corresponding source for the covered product version.

## What Must Be Available

For each Signal-enabled BurnBar release, publish or retain a source bundle that
includes:

- the exact BurnBar source revision used for the build;
- the vendored `Vendor/libsignal/` source revision and acknowledgments;
- local patches, build scripts, packaging scripts, CI metadata, and generated
  source needed to rebuild the covered work;
- the dependency lockfiles used by Python, Node, Swift, Kotlin/Android, Rust,
  and any hosted gateway services;
- this source-availability notice, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and
  `LICENSES/Nous-hermes-agent-MIT.txt`.

Build caches, private signing keys, production secrets, user data, and unrelated
deployment credentials are not corresponding source and must not be published.

## Release Gate

Before shipping a Signal-enabled BurnBar build:

1. Run the BurnBar product license-posture scan.
2. Verify the libsignal runtime-readiness manifest at
   `third_party/libsignal/runtime-readiness.json`. A release is not ready while
   native/runtime, hosted write-path, or legal gates remain `not_ready`.
3. Retain proof-only native Signal runtime evidence for each shipped native
   runtime. The `swift_runtime` and `kotlin_android_runtime` readiness gates
   must not be marked complete unless
   `python scripts/ci/check_native_signal_runtime_evidence.py <artifact>.json --platform <swift|kotlin_android>`
   validates native build/test, libsignal prekey publication, local-only secret
   state, CloudVault binding, and shared AAD-vector proof without embedding
   plaintext, private keys, or user data. Each native proof command must name
   the expected Swift or Android test command and proof-specific test surface;
   Android evidence must also name the checked-in Gradle wrapper, wrapper
   metadata, settings file, root build file, and `app` build file used to run
   `:app:testDebugUnitTest`. Placeholder commands such as `echo ok` are not
   valid release evidence.
4. For hosted gateway releases, retain aggregate-only Hermes Gateway
   migration-drain evidence. The `hermes_gateway_write_path` readiness gate must
   not be marked complete unless that JSON evidence validates, shows the deployed
   write path is in `OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true` mode, and shows no
   legacy, plaintext, or unreadable gateway records. The same evidence must name
   the deployed commit, the HTTPS source location users can access,
   `docs/legal/SOURCE_AVAILABILITY.md`, the deployed mode readback source, and
   the dependency lockfiles used by the hosted gateway release. Follow
   `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md` for the guarded
   production rollout sequence. Generate the
   aggregate-only evidence with
   `node scripts/ci/write_hermes_gateway_migration_drain_evidence.js --project-id <project> --deployed-commit <sha> --source-location <https-url> --runtime-mode-from-gcloud --output <artifact>.json`
   from an environment with Firestore Admin access, then validate it with
   `python scripts/ci/check_hermes_gateway_migration_drain.py <artifact>.json --repo-root .`.
   If the evidence still contains legacy or unreadable gateway queue records,
   first generate a dry-run aggregate drain plan with
   `node scripts/ci/drain_hermes_gateway_legacy_records.js --project-id <project> --output <artifact>.json`.
   Destructive drain execution requires both
   `--confirm delete-legacy-hermes-gateway-records` and a
   `--runtime-mode-evidence <artifact>.json` file whose Cloud Run readback proves
   the deployed gateway write path is already Signal-required. The drain tool
   emits aggregate counts only and must not print document paths, user IDs, or
   ciphertext.
5. Retain proof-only CloudVault at-rest runtime evidence. The
   `cloudvault_at_rest_runtime` readiness gate must not be marked complete
   unless `python scripts/ci/check_cloudvault_at_rest_runtime.py <artifact>.json`
   validates contract, libsignal at-rest, admin-write, and privacy-backfill
   proof without embedding plaintext, keys, ciphertext, or document identifiers.
   Admin-write proof must include the compiled Functions runtime smoke in
   `scripts/ci/check_functions_cloudvault_runtime.js` and
   `tests/test_signal_envelope_contracts_cjs_exports.py`, not only compiled
   Vitest source-map output. Privacy-backfill proof must run the compiled
   Functions smoke because the checked-in compiled CommonJS Vitest output is not
   itself a valid release proof. Each proof command must name the expected test
   command and artifact path; placeholder commands such as `echo ok` are not
   valid release evidence.
6. Generate or refresh the source bundle/provenance record for the exact build:
   `python scripts/ci/write_burnbar_source_provenance.py --output <release-artifact>.json`.
   Before publishing, run the stricter release preflight:
   `python scripts/ci/write_burnbar_source_provenance.py --release-check`.
   This must fail unless the Git worktree is clean and every runtime-readiness
   gate is complete.
7. Confirm `Vendor/libsignal/` and Signal acknowledgments are included.
8. Confirm product docs do not promise absolute quantum security.
9. Obtain legal review for AGPL and app-store/commercial distribution posture.
   Counsel should use `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md` and the JSON
   template at `docs/legal/agpl-release-review.evidence.template.json` for the
   release record.
   The `legal_release_review` readiness gate must not be marked complete unless
   the review record validates with
   `python scripts/ci/check_agpl_legal_release_review.py <review-artifact>.json --repo-root .`.
   The evidence must identify external counsel, cover app-store, direct-download,
   hosted-gateway, and commercial distribution channels, and list the legal docs,
   license metadata, runtime-readiness manifest, source-provenance script, product
   posture scan, and MIT-upstream boundary scan reviewed for the release.

## Hosted Gateway Gate

If BurnBar operates a hosted gateway that uses the Signal-backed lane, the same
corresponding-source obligation applies to the server-side covered work. The
hosted gateway release record must name the deployed commit, dependency locks,
the source location users can access, and the aggregate migration-drain evidence
used for the write-path readiness gate.

## MIT Upstream Boundary

The Nous/Hermes upstream PR path remains MIT-compatible. Do not include
Signal/libsignal/SPQR implementation code in that PR path. The upstream PR may
include encrypted gateway framework hardening, backend seams, vectors, and
tests, but Signal-backed claims belong only to BurnBar AGPL product builds.
