# BurnBar

## What this codebase does

OpenBurnBar is a daemon-first, local-first product for tracking AI-agent usage, spend, quota, and runtime state across macOS, iOS/iPadOS, Android, a local daemon, a Cursor/VS Code extension, Firebase Functions, Firestore sync, and hosted Hermes/Pi relay services. Local SQLite/GRDB and daemon-owned files are canonical; Firestore, iCloud, hosted quota sync, provider routing, connector integrations, and realtime relays are opt-in cloud or network planes.

## Auth shape

- Firebase callable functions must use `enforceAuthAndAppCheck(request, uid)` or equivalent `assertAuth` + `assertAppCheck` + ownership checks before touching `users/{uid}` data, provider accounts, quota, pairings, or deletion flows.
- Firestore owner isolation is in `firestore.rules` via `ownsUserNamespace`, `ownerWritableNonSecret`, and stricter escrow helpers; server-only collections include `provider_account_secret_refs`, `_rate_limits`, rollup counters/jobs, entitlement bindings, pairings, audit events, and session caches.
- Hosted relay WebSocket upgrades authenticate with `authenticateRequest`, requiring Firebase ID token, optional App Check allowed-app validation, hosted entitlement verification, and `x-openburnbar-relay-role` of `host` or `client`.
- Local daemon RPC uses `socketAuthToken` on each `IncomingRequestEnvelope`, filesystem-protected UNIX sockets, per-peer rate limiting, and enumerated `BurnBarRPCMethod` dispatch.
- Local secret access flows through `KeychainStore`, `BurnBarKeychainSecretStore`, `BurnBarConnectorKeychainSecretStore`, and `withKeychainUserInteractionDisabled`; provider secrets should not be stored in SQLite, Firestore client-writable documents, logs, or daemon config JSON.

## Threat model

Highest-impact failures are credential exposure, cross-user Firestore reads/writes, hosted quota/relay entitlement bypass, and remote access to local daemon/router surfaces. Next tier is malicious same-user local processes abusing daemon RPC, connector credentials, provider routing, or Keychain reads. Privacy-sensitive data includes prompts/session logs, project names, provider/model names, chat content, quota snapshots, and synced artifact metadata; cloud backup settings must remain explicit and opt-in.

## Project-specific patterns to flag

- Any new Firebase `onCall` handler in `functions/src/` that reads or writes user/provider/quota/Hermes/Pi/account-deletion data without `enforceAuthAndAppCheck`, provider allowlist validation, UID ownership, and bounded input helpers.
- Any Firestore rule that lets clients write secrets, server-owned state, audit logs, usage rollups/counters, entitlement docs, pairings, provider device links, or relay/session cache docs.
- Any hosted relay path in `services/hermes-realtime-relay/src/` that bypasses `authenticateRequest`, `RedisRelayQuotaStore`, `parseFrame`, `assertFrameForUid`, `assertRoleCanSend`, runtime namespacing, frame byte caps, or entitlement checks.
- Any daemon or app code that stores provider credentials, connector tokens, auth cookies, database keys, gateway bearer tokens, or recovery material outside Keychain/Secret Manager/ciphertext escrow.
- Any local gateway, tunnel, connector, browser plane, or smart-display endpoint that can bind beyond loopback or perform external actions without explicit enablement, bearer-token protection when required, and rate/size limits.

## Known false-positives

- `services/hermes-realtime-relay/src/server.ts` exposes `/healthz` and `/readyz` without Firebase auth by design; WebSocket upgrade `/v1/hermes/ws` is the protected surface.
- Local emulator/dev flags such as `ENFORCE_APP_CHECK=false`, `VERIFY_REVOKED_ID_TOKENS=false`, and fake provider output env vars are test/dev controls; production scripts and configs should keep App Check and credential protections enabled.
- `firestore.rules` allows owner writes to selected sync collections, but `ownerWritableNonSecret` and specific validators intentionally reject plaintext-looking secret fields.
- Local CLI, daemon, and extension surfaces intentionally read session logs from user-owned home-directory locations; this is core product behavior and should be judged against local-only scope, socket auth, and workspace trust gates.
- Tests, templates, quarantined suites, Firebase config templates, and generated build artifacts may contain sample identifiers, fake tokens, or uncompiled historical patterns; confirm reachability before treating them as production findings.
