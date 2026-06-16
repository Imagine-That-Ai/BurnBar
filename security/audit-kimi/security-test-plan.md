# Security Test Plan

## Existing Tests

| Area | Test Suite | Coverage | Notes |
|---|---|---|---|
| Cloud Functions | `functions/test/` | Unit tests for auth, callables | Good baseline |
| Firestore rules | `firestore.rules` + tests | Rule simulation tests | Need drift CI |
| Crypto | `OpenBurnBarCoreTests/` | Sealing/envelope tests | Add AAD tamper |
| iOS app | `AgentLensTests/Active/` | UI + service tests | Need adversarial tests |
| Android | `android/app/src/test/` | JVM unit tests | Add iroh key test |
| Parser | Parser unit tests | JSON/XML/text parsing | Need size/depth limits |
| Release | CI workflow | Sign/notarize/SBOM | Need two-person/OIDC |

## Missing Tests

| ID | Test | Priority | Related Finding |
|---|---|---|---|
| TEST-001 | Release build `PRAGMA cipher_version` returns non-null | Critical | FINDING-001 |
| TEST-002 | SQLCipher migration from plaintext database | Critical | FINDING-001 |
| TEST-003 | Non-attested Firestore REST read/write is rejected | High | FINDING-005 |
| TEST-004 | Deployed Firestore rules match repo rules | High | FINDING-011 |
| TEST-005 | BOLA/IDOR fuzz across all callable functions | High | FINDING-005 |
| TEST-006 | Prompt injection corpus through `ContextBuilder` | High | FINDING-004 |
| TEST-007 | RAG snippet provenance and tamper detection | High | FINDING-004 |
| TEST-008 | Computer Use all 13 tool kinds under adversarial input | High | FINDING-003 |
| TEST-009 | Computer Use kill-switch halts session in <1s | High | FINDING-003 |
| TEST-010 | Daemon RPC method authorization matrix | Medium | FINDING-007 |
| TEST-011 | Local MCP user-gate before snippet return | Medium | FINDING-008 |
| TEST-012 | Cursor tunnel token entropy and TTL | Medium | FINDING-009 |
| TEST-013 | Callable rate-limiting enforcement | Medium | FINDING-012 |
| TEST-014 | End-to-end account deletion (Firestore + Storage + local) | Medium | FINDING-013 |
| TEST-015 | Android iroh key in Keystore, not shared prefs | Medium | FINDING-014 |
| TEST-016 | AAD tamper for every envelope variant | Medium | FINDING-015 |
| TEST-017 | session_logs schema + size validation | Medium | FINDING-016 |
| TEST-018 | Parser max-size and max-depth rejection | Medium | FINDING-017 |
| TEST-019 | dataExport fields match privacy policy | Low | FINDING-018 |
| TEST-020 | Notification payload PII scan | Low | FINDING-019 |
| TEST-021 | HID capability token binding | Medium | FINDING-020 |
| TEST-022 | Sentry before-send with synthetic sensitive data | Low | FINDING-021 |
| TEST-023 | Daemon auth token rotation on update | Low | FINDING-022 |

## Suggested CI Additions

1. Run `gitleaks` + `detect-secrets` on every PR (already likely present; verify).
2. Add `firestore.rules` drift check against production.
3. Add App Check enforcement probe in staging.
4. Add prompt-injection corpus to fast-feedback.
5. Add parser zip-bomb tests to unit suite.
6. Add release-build SQLCipher verification step.
