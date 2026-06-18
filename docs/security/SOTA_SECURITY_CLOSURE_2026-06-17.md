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
