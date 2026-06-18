# SOTA Security Closure - 2026-06-17

This note records the June 2026 security remediation pass. The implementation worktree was fast-forwarded onto the latest observed `origin/main` before final verification:

- Commit: `0c7c1188c26c209fc03e7558572259e890ecbe52`
- Short SHA: `0c7c1188c2`
- Subject: `Merge pull request #533 from Imagine-That-Ai/codex/rollup-cloud-tasks-20260617`
- Commit time: `2026-06-17T15:24:42-05:00`

## Remediated Controls

1. Shared artifact cloud content now seals `title`, `body`, `contentHash`, and `relativePath` into a vault-key-backed private payload. Firestore head and version documents use distinct authenticated-data contexts, and sealed writes delete legacy plaintext fields.
2. Shared artifact reads fail closed when sealed content is present without the required vault key, owner binding, or authenticated-data match.
3. Local MCP semantic conversation search now requires the explicit `sensitive_read` capability.
4. Gateway and daemon socket authentication tokens now use 256-bit OS CSPRNG base64url tokens.
5. Firebase App Check enforcement verification now checks Cloud Firestore and Firebase Storage by default, with the launch-gate probe covering both services.
6. Firestore vault key wrapper tests no longer use stable literal ciphertext fixtures that look reusable or production-like.
7. Current-main Xcode 27 beta test-bundle compile blockers in conversation tombstone and provider quota tests were corrected in the isolated worktree so the focused security regressions compile and run.

## Verification

Passed locally:

- `python3 -m pytest tools/openburnbar-mcp/tests/test_semantic_search.py -q`
- `node scripts/test-commercial-launch-gate-appcheck.mjs`
- `bash scripts/ci/check-no-suppressions.sh`
- `bash -n scripts/ops/verify-firestore-app-check-enforcement.sh`
- `bash -n scripts/ops/verify-production-ops-plane.sh`
- `git diff --check`
- no legacy wrapped-key base64 literals remain in `firestore-rules-tests/cloud-vault-key-wrappers.test.js`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SharedArtifactCloudCodecTests`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/CloudSyncEmulatorIntegrationTests`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SettingsManagerSecretStorageTests/test_generateGatewayAuthToken_producesUniqueURLSafeSecrets`

Live read-only operator check:

- `OPENBURNBAR_FIREBASE_PROJECT=burnbar scripts/ops/verify-firestore-app-check-enforcement.sh`
  - `firestore.googleapis.com`: `ENFORCED` at `2026-06-17T21:06:04Z`
  - `firebasestorage.googleapis.com`: `ENFORCED` at `2026-06-17T21:06:04Z`

Live Firebase App Check service mutation:

- `firebasestorage.googleapis.com` was changed from `<unset>` to `ENFORCED`
  for Firebase project `burnbar` / project number `246956661961`; Firebase
  returned update time `2026-06-17T21:03:36.373647Z`.

`OpenBurnBar.xcodeproj/project.pbxproj` was regenerated with XcodeGen after rebasing onto `origin/main`.

## Claim Guidance

Safe after this pass:

- Shared artifact cloud sync writes sealed private content for newly written artifacts and verifies sealed payload integrity on read.
- Local MCP semantic search requires an explicit sensitive-read session capability.
- Generated gateway and daemon socket bearer secrets are OS-CSPRNG-backed 256-bit tokens.
- Production Firebase App Check is enforced for Cloud Firestore and Firebase
  Storage in the `burnbar` Firebase project, and the live verifier checks both.

Avoid until migration telemetry confirms old records are rewritten:

- "No legacy plaintext shared artifact fields exist in the production dataset."

## Current-Main Pass 2 - 2026-06-18

This follow-up was rebuilt on current `origin/main` instead of merging the stale
`codex/sota-security-remediation-20260617` worktree wholesale:

- Base commit: `c39b8c5d35b42aa5a2674b2b75e6b677899f9fd8`
- Short SHA: `c39b8c5d35`
- Subject: `Fix mobile control stream stale supervisor cleanup`
- Commit time: `2026-06-17T23:51:29-05:00`

Additional remediated controls:

1. Legacy plaintext shared-artifact documents are detected on trusted-device
   pull and re-written through the sealed CloudVault envelope using the local
   vault key. The repair deletes plaintext `title`, `body`, and `contentHash`
   fields from the head document and writes a sealed version document with its
   own authenticated-data context.
2. The backend exposes `scanLegacyPlaintextArtifacts`, an authenticated,
   App-Check-enforced, read-only callable that returns only document paths,
   identifiers, and field-presence flags. It does not return plaintext content
   and scopes scans to the caller's own workspace path.
3. Gateway auth-token generation now throws on CSPRNG failure so callers can
   fail closed instead of crashing or launching an unauthenticated gateway.

Additional verification passed locally:

- `npm exec vitest run src/__tests__/sharedArtifactLegacyScan.test.ts --reporter=verbose`
- `npm run build` from `functions/`
- `bash scripts/ci/check-no-suppressions.sh`
- `git diff --check`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SharedArtifactCloudCodecTests`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/CloudSyncEmulatorIntegrationTests/test_collaborationPull_healsLegacyPlaintextArtifact`
- `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SettingsManagerSecretStorageTests/test_generateGatewayAuthToken_producesUniqueURLSafeSecrets`

Claim guidance update:

- Safe: trusted clients automatically clean up legacy plaintext shared-artifact
  fields when those records are pulled and the local vault key is available.
- Safe: the backend can inventory likely legacy plaintext shared-artifact
  records without returning plaintext content.
- Still avoid: "No legacy plaintext shared artifact fields exist in production"
  until scan results and client-heal telemetry show the corpus is clean.
