# Security Test Plan

This plan maps directly to the threat register. Existing tests should be run and extended; missing tests are listed explicitly.

## Authorization Model

| Object | Owner | Access rule | Evidence | Required tests |
| --- | --- | --- | --- | --- |
| Firestore user namespace | uid | `request.auth.uid == userId` except server-only paths | `firestore.rules` | cross-user read/write deny |
| Gateway client/message/session/token | uid + client/server | server-only writes; Gateway callable owner checks | `firestore.rules`, `hermesGateway.ts` | client SDK deny; callable IDOR |
| Storage session logs | uid/path | owner read/write for session logs; signed URL preferred | `storage.rules`, `encryptedSearch.ts` | path traversal/signed URL scope |
| Gateway attachments | uid/client/message path | intended signed URL/server owner checks | `hermesGateway.ts`, `storage.rules` | fix and test download auth |
| Provider credentials | uid/provider account | callable ownership; Secret Manager refs | `secrets.ts` | cross-user provider access deny |
| Hosted MCP grant | uid/client/scopes | bearer token, scopes, entitlement | `services/hosted-mcp/src/*` | token scope/resource swap |
| Daemon run/tool | local run/controller | controller attachment and pending call ownership | `OpenBurnBarRunService.swift` | stale/wrong controller denial |
| Computer-use session | local session/capability | capability gate, approval | `ComputerUseRunCoordinator.swift` | unauthorized action denial |

## Endpoint Authorization Matrix

| Endpoint/surface | Auth | Authorization | Critical tests |
| --- | --- | --- | --- |
| Firebase callables | Firebase Auth, App Check | `assertOwnership` or object owner checks | missing auth, missing App Check, cross-user id |
| Gateway HTTP `/device/start` | device code/secret input | rate limit, relay key required, pending state | code replay, missing key, rate abuse |
| Gateway HTTP `/device/poll` | code + secret hash | pairing state and expiry | expired/reused/wrong secret |
| Gateway HTTP `/messages` | bearer + PoP | active client, relayCapable, scope | forged PoP, replay nonce, plaintext field |
| Gateway attachment init/finalize | bearer + PoP | client/message/object owner | cross-user path, hash mismatch, expired URL |
| Hosted MCP `/mcp` | bearer token | scopes, entitlement, active client | query-token rejection, scope escalation |
| Hosted MCP token refresh | refresh token hash | grant active, client active, entitlement | replay old refresh, revoked client |
| Daemon RPC | local peer auth | controller/run/tool state | unsigned peer, stale call, oversized request |
| Local MCP | local process/trust | currently privileged | untrusted agent denial once design chosen |

## Automated Tests

| Test | Threat IDs | Status |
| --- | --- | --- |
| Firestore rules cross-user deny for every user collection | BB-T006 | present partial; extend |
| Callable BOLA/IDOR generated test suite | BB-T006 | missing |
| Storage Gateway attachment read/write rules and signed URL scope | BB-T007, BB-T025 | missing |
| Pairing code replay/expiry/MITM key substitution | BB-T004 | partial; extend |
| Gateway message tamper every field | BB-T002 | partial; extend |
| Stored old-envelope replay | BB-T003 | missing |
| PoP nonce reuse/timestamp/body hash/query binding | BB-T003, BB-T015 | present partial |
| Nonce uniqueness and RNG failure | BB-T018 | missing RNG failure |
| Malformed ciphertext/envelope downgrade | BB-T002, BB-T020 | partial; extend |
| Device revocation future access and local purge | BB-T005 | partial; extend |
| High-impact approval required for shell/patch/browser/mac input | BB-T009, BB-T010 | present partial |
| YOLO grant duration/warning/audit | BB-T010 | missing/partial |
| Prompt injection regression corpus | BB-T009, BB-T013 | present partial; extend |
| Tool policy enforcement and schema fuzzing | BB-T013 | partial |
| Memory poisoning/quarantine/delete | BB-T012 | missing/partial |
| Malicious tool output handling | BB-T013 | missing |
| Unsafe output rendering/webview CSP/postMessage | BB-T023 | missing |
| Log/Sentry/Crashlytics redaction corpus | BB-T017 | partial server; missing native/mobile |
| API rate limits per uid/IP/device | BB-T030 | partial |
| Malicious attachment parser corpus | BB-T008 | missing |
| Local daemon IPC signed/unsigned build behavior | BB-T026 | partial |
| Hosted MCP token theft/scope/resource swap | BB-T015 | partial |
| Supply-chain action pinning policy | BB-T021 | missing |

Suggested existing commands to run before audit:

```sh
npm --prefix functions run test:firestore-rules
npm --prefix functions run test:security
npm --prefix services/hosted-mcp test
npm --prefix tools/openburnbar-mcp-remote test
swift test --package-path OpenBurnBarCore
swift test --package-path OpenBurnBarDaemon
```

## Manual Security Tests

| Manual test | Threat IDs |
| --- | --- |
| Pairing ceremony UX review with phishing/MITM prompts | BB-T004 |
| Device spoofing and revoked-device behavior on real devices | BB-T005 |
| Relay compromise simulation with drop/replay/reorder/tamper | BB-T001, BB-T002, BB-T003, BB-T027 |
| Malicious attachment corpus on iOS/Android/macOS | BB-T008 |
| Malicious webpage/document/email indirect prompt injection | BB-T009, BB-T013 |
| Agent tool misuse with shell/browser/mac input | BB-T010, BB-T028 |
| Local privilege escalation/daemon IPC abuse | BB-T026 |
| Mobile deep link/push notification abuse | BB-T024 |
| Crash/log privacy capture during prompt/tool/attachment errors | BB-T017 |
| Admin access abuse tabletop and IAM dry run | BB-T016 |
| CI/CD compromised action tabletop | BB-T021, BB-T022 |

## Cure53 Test Scope

In scope:

- `OpenBurnBarCore` crypto/protocol code.
- `OpenBurnBarDaemon` daemon IPC, tool dispatch, computer-use approval/audit.
- `AgentLens` CLI bridge, provider egress, browser/computer-use UI surfaces.
- `OpenBurnBarMobile` and Android mobile Gateway pairing/attachments/key storage.
- `functions/src` Firebase Functions, Gateway, App Check, high-risk nonces, provider secrets, encrypted search, remote MCP, panic/export/delete.
- `firestore.rules` and `storage.rules`.
- `services/hosted-mcp` and `tools/openburnbar-mcp*`.
- `.github/workflows`, release/deploy/provenance scripts.

Out of scope unless explicitly added:

- Formal cryptographic proof.
- Live production penetration without written authorization.
- Third-party provider internals.
- User endpoint malware beyond defined residual-risk analysis.

Credentials needed:

- Test Firebase project with App Check test tokens.
- Test accounts with multiple users/devices.
- Test Gateway clients and revocation state.
- Test provider API keys with low quota.
- Test GCP IAM read-only evidence access.
- Local macOS/iOS/Android test devices.

High-risk areas for auditors:

1. Local agent and MCP privilege boundaries.
2. Gateway pairing, PoP, replay, sealed envelopes, and attachment download.
3. Cross-user authorization across callables/rules/hosted MCP.
4. Prompt injection to high-impact tool execution.
5. Cloud IAM/KMS/Secret Manager provider credential access.
6. Supply-chain release integrity and vendored agent provenance.
