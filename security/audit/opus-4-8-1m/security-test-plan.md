# Security Test Plan — Opus 4.8 1M lane

## Existing security tests (verified present + running)
| Area | Test | CI gate |
|---|---|---|
| BOLA / object authz | 16 `*.bola.test.ts` + `bolaCoverage.test.ts` (tier-2 cross-user, side-effect assertion) | fast-feedback / harness / release (blocking) |
| Firestore rules | `firestore-rules-tests/*` (~141 assertions, cross-user denial, secret-field rejection, AAD binding, operator reads) | security-pr / deploy-firestore (blocking) |
| Privacy invariants | `check-privacy-invariants.mjs` + self-test (I1-I5) | fast-feedback / ops-confidence |
| Logging scrubber | `loggingScrubber.test.ts` (redaction cases + false-positive guard) | functions test:security |
| Push metadata | `voipPushMetadata.test.ts` | privacy gate |
| Billing | `stripeWebhookOrdering.test.ts`, Apple JWS reconcile tests | fast-feedback |
| Crypto conformance | cross-language signal-interop vectors (Swift+Kotlin) | nightly / harness |
| Updater | Ed25519 verify; live-socket peer-token test (`PrivilegedSocketTrust`) | swift test |
| Sentry scrub (iOS) | `MobileSentryScrubberTests` | — |

## Missing / recommended tests (mapped to findings)
| TEST ID | Covers | Type | Location | Priority |
|---|---|---|---|---|
| TEST-01 | OPUS-F-001 shared-artifact plaintext | rules + swift writer | `firestore-rules-tests/shared-artifact-sealed.test.js` | high |
| TEST-02 | OPUS-F-002 macOS crash scrub | unit | `MacSentryScrubberTests.swift` | high |
| TEST-03 | OPUS-F-005 accountDeletion uid leak | unit | `functions/.../accountDeletion.test.ts` | med |
| TEST-04 | OPUS-F-006 thread_id correlator | unit + gate | extend `check-privacy-invariants` | med |
| TEST-05 | OPUS-F-003 path-bound AAD on remaining surfaces | rules | `m007-path-bound-sealed-payload.test.js` (extend) | med |
| TEST-06 | OPUS-F-014 deletion root-collection completeness | unit | functions test | med |
| TEST-07 | OPUS-F-007 SSRF alt-encoding/rebinding | unit | `ssrfGuard.test.ts` | med (pre-feature) |
| TEST-08 | Privileged-input red-team (RUN_PRIVILEGED_SOCKET_REDTEAM) | integration | macOS nightly | high |
| TEST-09 | Adversarial prompt-injection / confused-deputy (Computer Use + MCP) | integration | new suite | med |
| TEST-10 | session-log-backup rules (make blocking) | rules | already exists; flip to blocking | med |

## Safe local checks run this lane
- `node scripts/ci/check-privacy-invariants.mjs` → PASS (14 checks)
- `node scripts/ci/check-privacy-invariants.test.mjs` → PASS (9/9)
- Direct read of `firestore.rules` session_logs + AAD helpers (M-005 confirmed fixed)
- Static grep sweeps for hardcoded secrets / raw logger / weak crypto → clean

(No destructive tests run; no live third-party systems touched.)
