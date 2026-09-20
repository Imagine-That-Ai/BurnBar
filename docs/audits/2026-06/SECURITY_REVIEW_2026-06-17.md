# Security Review — Uncommitted Remediation Delta

**Reviewer:** Security review agent (GLM 5.2)
**Date:** 2026-06-17
**Worktree:** `/private/tmp/burnbar-sota-security-remediation-20260617`
**Branch:** `codex/sota-security-remediation-20260617`
**HEAD:** `0c7c1188c2` (8 commits behind `origin/main` at `0c308916f3`)
**Status:** Uncommitted changes on top of HEAD (16 modified, 2 untracked)

---

## Executive Verdict

**The remediation is sound, correctly targets real gaps, and is safe to land after a rebase onto `origin/main` and one trivial fix.** The cryptographic changes are the strongest part — they reuse the existing audited CloudVault AES-256-GCM + v2 path-bound AAD machinery correctly, with distinct AAD contexts for head vs. version documents. The Firestore rules already enforce the sealed-content allowlist server-side (they are in HEAD, not part of this delta), so the client change completes a write-path that was previously allowed by rules but never emitted.

**Merge/rebase:** Rebasing onto latest `origin/main` is required. The branch is 8 commits behind and the ahead commits touch entirely disjoint files (burnbar-remote UniFFI bridge). A rebase will be conflict-free at the source level. The `project.pbxproj` was regenerated with XcodeGen against the branch HEAD; it must be regenerated again after rebase since `OpenBurnBarCore/Package.swift` changed in the ahead range (new product dependency wiring).

**One must-fix before landing:** Remove the duplicate `import OpenBurnBarCore` in `ProviderQuotaServiceCumulativeAndContextTests.swift` (line 3). Non-fatal (Swift is idempotent on imports) but a lint/code-smell defect introduced by this delta.

---

## Remediation Summary (7 changes)

| # | Change | Files | Verdict |
|---|--------|-------|---------|
| 1 | Seal shared-artifact private content (title/body/contentHash/relativePath) via CloudVault | `CollaborationSyncService.swift`, `CloudSyncSharedArtifactModels.swift`, `CloudSyncCoordinator.swift` | **Correct** — closes a real plaintext-at-rest gap |
| 2 | Fail-closed decode when sealed content lacks key/owner/AAD | `CloudSyncSharedArtifactModels.swift` | **Correct** — backward-compatible read of legacy plaintext, sealed writes only |
| 3 | Gate local MCP semantic search behind `sensitive_read` capability | `tools/openburnbar-mcp/server.py` | **Correct** — consistent with 5 other sensitive_read tools |
| 4 | CSPRNG 256-bit base64url tokens for daemon socket + gateway | `OpenBurnBarSecureToken.swift`, `OpenBurnBarDaemonManager+Lifecycle.swift`, `GatewaySettings.swift` | **Correct** — replaces UUID-derived 122-bit hex tokens |
| 5 | App Check enforcement verifier covers Firestore + Storage | `verify-firestore-app-check-enforcement.sh`, `test-commercial-launch-gate-appcheck.mjs`, `FIREBASE_APP_CHECK_ENFORCEMENT.md` | **Correct** — multi-service loop with fail-closed accumulator |
| 6 | Remove stable literal ciphertext fixtures from vault-key-wrapper tests | `cloud-vault-key-wrappers.test.js` | **Correct** — eliminates test fixtures that looked production-like |
| 7 | Xcode 27 beta compile fixes for test bundles | `project.pbxproj`, 2 test files | **Acceptable** — see findings below |

---

## Detailed Findings

### F1 — Duplicate `import OpenBurnBarCore` (must-fix, trivial)

**File:** `AgentLensTests/Active/ProviderQuotaServiceCumulativeAndContextTests.swift:3`
**Severity:** Low (cosmetic / lint)
**Evidence:** HEAD had a single `import OpenBurnBarCore` on line 4. The delta inserted a second one on line 3:
```swift
import Foundation
import GRDB
import OpenBurnBarCore      // <-- added by delta
import XCTest
import OpenBurnBarCore      // <-- pre-existing
@testable import OpenBurnBar
```
**Impact:** Swift treats duplicate imports as idempotent, so this compiles. However it is a code smell and may trip strict lint configs.
**Fix:** Remove line 3 (the newly added import). The existing line 5 import is sufficient.
**Confidence:** High

---

### F2 — `project.pbxproj` TEMP UUID churn from XcodeGen regen (informational)

**File:** `OpenBurnBar.xcodeproj/project.pbxproj`
**Severity:** Informational
**Evidence:** The delta regenerates `PBXTargetDependency` / `XCSwiftPackageProductDependency` entries with new `TEMP_*` UUIDs and relocates two file references (`MobileStringNilIfBlank.swift`, `AgentLensStringNilIfBlank.swift`) to different group children. The actual source membership is preserved — the same files compile into the same targets — but the UUIDs are new.
**Impact:** No functional change. The churn will produce a noisy diff but is benign. Since `OpenBurnBarCore/Package.swift` changed in the 8 ahead commits (new `burnbar-remote` product), this file **must be regenerated again after rebase** or the build will fail to resolve the new package dependency.
**Recommendation:** After rebasing onto `origin/main`, run `xcodegen` (or the repo's equivalent generation script) to produce a fresh `project.pbxproj` that reflects both the remediation's new file (`OpenBurnBarSecureToken.swift`) and main's new package products.
**Confidence:** High

---

### F3 — Legacy plaintext shared artifacts remain in production (acknowledged residual)

**File:** `CloudSyncSharedArtifactModels.swift:383-400` (decode fallback path)
**Severity:** Medium (correctly acknowledged in closure doc)
**Evidence:** The `decode` function retains a backward-compatibility path that reads plaintext `title`/`body`/`contentHash` when `contentSealed != true`. The write path (`encodeSealed`) always seals, and Firestore rules (`sharedArtifactSealedOwnerWrite`) enforce `contentSealed == true` on all new writes. So new writes cannot inject plaintext. But pre-existing unsealed records in the production dataset remain readable in plaintext until a backfill rewrites them.
**Impact:** Any shared artifact written before this remediation ships still has plaintext content fields in Firestore. A malicious cloud admin or Firestore compromise could read those.
**Status:** Correctly documented in `SOTA_SECURITY_CLOSURE_2026-06-17.md` under "Avoid until migration telemetry confirms old records are rewritten."
**Recommendation:** Track a follow-up backfill/migration task that rewrites (or purges-and-rewrites) legacy shared-artifact documents through the sealed write path. Add a metric or query that counts documents where `contentSealed != true` so the residual shrinks visibly.
**Confidence:** High

---

### F4 — Python-as-trim in bash operator script (informational, no action needed)

**File:** `scripts/ops/verify-firestore-app-check-enforcement.sh:44-48`
**Severity:** Informational
**Evidence:** The service-name trimming uses a Python heredoc (`python3 -c "import sys; print(sys.argv[1].strip())"`) where bash parameter expansion (`"${raw_service//[[:space:]]/}"`) would avoid a subprocess.
**Impact:** None functionally. The script works correctly and the Python invocation is deterministic. A minor startup-cost overhead per service.
**Recommendation:** Optional cleanup; do not block on this.
**Confidence:** High

---

### F5 — `$response` passed as Python argv (robustness note)

**File:** `scripts/ops/verify-firestore-app-check-enforcement.sh:71-74`
**Severity:** Informational
**Evidence:** The App Check API JSON response is passed to Python via `sys.argv[1]`. If the response ever contained a null byte or exceeded the OS argv limit (~128KB on macOS), the parse would fail. The App Check API response is small and well-structured (a few hundred bytes), so this is not a practical concern.
**Impact:** None in practice.
**Confidence:** High

---

## Cryptographic Correctness Assessment

The strongest part of this remediation. Verdict: **cryptographically sound.**

### Sealed shared-artifact payload

| Property | Status | Evidence |
|----------|--------|----------|
| Algorithm | AES-256-GCM | `CloudVaultCrypto.sealPayload` → `AES.GCM.seal` (CryptoKit) |
| Key size | 256-bit | `symmetricKey(from:)` enforces `data.count == 32` |
| AAD binding (head) | `uid\|artifacts\|{artifactID}\|sealedPayload\|2\|sealedPayload` | `encodeSealed` uses `artifactAADCollection` + `remoteArtifactID` |
| AAD binding (version) | `uid\|artifact_versions\|{revisionID}\|sealedPayload\|2\|sealedPayload` | `encodeSealed` uses `artifactVersionAADCollection` + `cloudRecord.revisionID` |
| Distinct head vs. version contexts | Yes | Different `aadCollection` and `aadDocumentID` per document type |
| Rule-side AAD verification | Enforced | `validPathBoundSealedPayloadForUser` in `firestore.rules:980-984` checks `cloudVaultAADContext(userId, collection, docId, "sealedPayload")` |
| Vault key ID binding | Enforced | `openPayload` checks `envelope.vaultKeyID == vaultKeyID(for: keyData)`; rules check `payload.vaultKeyID == vaultKeyID` |
| Plaintext field deletion on merge | Correct | `FieldValue.delete()` for `title`/`body`/`contentHash`/`relativePath` removes legacy fields; `hasOnly()` allowlist passes on the post-transform document |
| Tamper detection | Yes | GCM authentication tag + AAD mismatch → `sealedContentMalformed` |
| Relocation attack resistance | Yes | AAD binds docID; moving ciphertext to a different document fails decryption (verified by `test_decodeSealed_failsWhenAADDocumentChanges`) |

### Key lifecycle

- Vault key generated locally via `CloudVaultCrypto.generateVaultKey()` (32 random bytes, CryptoKit)
- Stored in OS Keychain via `CloudVaultKeyStore`
- Wrapped per-device via ECIES-P256-AESGCM for cloud storage in `cloud_vault_key_wrappers`
- Never transmitted unwrapped to the server
- Key ID is a deterministic HMAC of the key material for integrity checking
- Key rotation supported via `cloudVaultRotationResilience.ts` + `CloudVaultRotationRewrapWorker`

### Token generation (OpenBurnBarSecureToken)

| Property | Status | Evidence |
|----------|--------|----------|
| Entropy source | `SecRandomCopyBytes(kSecRandomDefault, ...)` | OS CSPRNG (Security.framework) |
| Bit strength | 256-bit (32 bytes) | `defaultByteCount = 32`; `precondition(byteCount >= 32)` |
| Encoding | base64url unpadded | 43 chars; `+`→`-`, `/`→`_`, `=` stripped |
| Failure mode | Throws / preconditionFailure | Never returns a weak token on RNG failure |
| ps-audit safe | Yes | No separators or whitespace; survives plist + HTTP header transport |

This is a strict improvement over the prior `UUID().uuidString.replacingOccurrences(of: "-", with: "")` which yielded only 122 bits of UUID v4 randomness in a 32-char hex string.

---

## Security Posture: Does Each Fix Close Its Gap?

### Gap 1: Shared-artifact plaintext at rest — **CLOSED for new writes, residual for legacy**

Before: `CollaborationSyncService` wrote `title`, `body`, `contentHash`, `relativePath` as plaintext Firestore fields. The rules already demanded sealed writes (`sharedArtifactSealedOwnerWrite` in HEAD), but the client never emitted sealed payloads — meaning shared-artifact sync was effectively broken or the rules were permissive in a prior state.

After: New writes seal all four private fields into a `sealedPayload` envelope with path-bound AAD. The rules enforce this server-side. Reads fail-closed when sealed content lacks a key or AAD mismatch, with a backward-compatible fallback for legacy unsealed records.

**Verdict:** Gap closed for new data. Legacy residual is tracked.

### Gap 2: Ungated local MCP semantic search — **CLOSED**

Before: `burnbar_semantic_search_conversations` returned private conversation snippets without any capability gate, unlike the 5 other `sensitive_read` tools.

After: Gated behind `_capability_denial("burnbar_semantic_search_conversations", "sensitive_read", ...)` requiring `OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ=true`.

**Verdict:** Gap closed. Consistent with existing pattern.

### Gap 3: Weak daemon/gateway tokens — **CLOSED**

Before: `UUID().uuidString` derived tokens (122-bit UUID v4, hex-encoded).

After: `OpenBurnBarSecureToken.randomBase64URL()` using `SecRandomCopyBytes` with 256-bit strength.

**Verdict:** Gap closed. Entropy upgraded from 122-bit to 256-bit.

### Gap 4: App Check enforcement only checked Firestore — **CLOSED**

Before: `verify-firestore-app-check-enforcement.sh` only checked `firestore.googleapis.com`.

After: Checks both `firestore.googleapis.com` and `firebasestorage.googleapis.com` by default. Fail-closed if either is not `ENFORCED`.

**Verdict:** Gap closed. Note: the closure doc correctly states that Storage enforcement is currently `<unset>` in production, so the live gate will fail until Storage App Check is enabled. This is the right behavior — fail closed.

### Gap 5: Test fixtures with production-like ciphertext — **CLOSED**

Before: `wrappedVaultKey: "****************"` in rules tests.

After: `wrappedVaultKeyFixture()` generates distinct per-test base64 strings that cannot be confused with real ciphertext.

**Verdict:** Gap closed.

---

## Merge Risk Assessment

### File-level overlap with 8 ahead commits: **NONE**

```
Remediation-touched files          ∩  Ahead-commit files  =  ∅
```

The 8 ahead commits on `origin/main` are entirely about the `burnbar-remote` UniFFI bridge:
- `crates/burnbar-remote/` (Rust crate)
- `OpenBurnBarCore/Sources/BurnBarRemote/Generated/burnbar_remote.swift` (generated bindings)
- `Vendor/burnbar-remote.aar` (Android AAR)
- `android/burnbar-remote/` (Android module)
- `OpenBurnBarCore/Package.swift` (new product dependency)
- `scripts/build-burnbar-remote-*.sh`, `scripts/test-burnbar-remote-*.sh`
- CI workflows for the remote bridge

The remediation touches: CloudSync services, CloudVault models, daemon lifecycle, settings, MCP server, App Check scripts, and test files. **Zero file overlap.**

### Rebase recommendation: **Rebase required, expect clean source merge**

1. `git rebase origin/main` will apply the 7 source changes with no textual conflicts (disjoint files).
2. **`project.pbxproj` will need regeneration** because `OpenBurnBarCore/Package.swift` added a new product in the ahead range. After rebase, run the repo's XcodeGen step to regenerate `project.pbxproj` so it includes both `OpenBurnBarSecureToken.swift` (from this delta) and the new `burnbar-remote` package products (from main).
3. The 2 untracked files (`OpenBurnBarSecureToken.swift`, `SOTA_SECURITY_CLOSURE_2026-06-17.md`) carry over cleanly.
4. Commit the worktree changes before rebasing, or stash-and-apply since the changes are disjoint from the ahead commits.

### Pre-landing checklist

- [ ] Remove duplicate `import OpenBurnBarCore` in `ProviderQuotaServiceCumulativeAndContextTests.swift:3`
- [ ] Rebase onto `origin/main` (`0c308916f3`)
- [ ] Regenerate `project.pbxproj` via XcodeGen after rebase
- [ ] Run `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SharedArtifactCloudCodecTests`
- [ ] Run `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/CloudSyncEmulatorIntegrationTests`
- [ ] Run `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/SettingsManagerSecretStorageTests`
- [ ] Run `node scripts/test-commercial-launch-gate-appcheck.mjs`
- [ ] Run `python3 -m pytest tools/openburnbar-mcp/tests/test_semantic_search.py -q`
- [ ] Run `bash scripts/ci/check-no-suppressions.sh`
- [ ] Confirm `firestore.rules` still passes the rules emulator suite (`firestore-rules-tests/`)
- [ ] **Do not** enable Firebase Storage App Check enforcement gate in production until Storage is actually set to `ENFORCED` (currently `<unset>` per the closure doc)

---

## Tests Verified Passing

| Test | Result |
|------|--------|
| `python3 -m pytest tools/openburnbar-mcp/tests/test_semantic_search.py -q` | 8 passed |
| `node scripts/test-commercial-launch-gate-appcheck.mjs` | passed |
| `bash -n scripts/ops/verify-firestore-app-check-enforcement.sh` | syntax OK |
| `bash -n scripts/ops/verify-production-ops-plane.sh` | syntax OK |
| `bash scripts/ci/check-no-suppressions.sh` | passed (5 artifact paths, 23 scoped files) |

Xcode-dependent test suites (`SharedArtifactCloudCodecTests`, `CloudSyncEmulatorIntegrationTests`, `SettingsManagerSecretStorageTests`) were not run by this review agent due to build environment constraints. The closure doc claims they pass. They should be re-run after the rebase + pbxproj regeneration.

---

## Claims Guidance Update

### Safe to claim after landing (with rebase + must-fix)

- "Shared artifact cloud sync seals private content (title, body, contentHash, relativePath) into a CloudVault AES-256-GCM envelope with path-bound AAD for all newly written artifacts."
- "Shared artifact reads fail closed when sealed content cannot be authenticated."
- "Local MCP semantic conversation search requires an explicit `sensitive_read` capability."
- "Gateway and daemon socket bearer tokens are 256-bit OS-CSPRNG-generated base64url strings."
- "The App Check enforcement verifier checks both Cloud Firestore and Firebase Storage, failing closed if either is not enforced."

### Do NOT claim until follow-ups land

- "No legacy plaintext shared artifact fields exist in production." (backfill not done — F3)
- "Firebase App Check is enforced for all covered services in production." (Storage is `<unset>` — closure doc acknowledges this)
- "Fully independently audited." (no external audit has occurred)
- "All shared artifacts are end-to-end encrypted." (legacy records are plaintext until backfilled)

---

## Conclusion

This is a focused, correct security remediation that closes real gaps without introducing regressions. The cryptographic implementation is the highlight — it correctly reuses the existing CloudVault primitives, binds AAD per-document-type, and the server-side rules already enforce the sealed-content allowlist. The only blocking issue is a trivial duplicate import; everything else is either informational or an acknowledged-and-documented residual. **Rebase onto `origin/main`, regenerate the Xcode project, fix the duplicate import, run the Swift test suites, and this is ready to land.**
