# 06 — Cloud Authorization / Firestore-Storage Rules / Multi-Tenant Isolation

Domain: cloud-authz-rules-isolation (Phase 9 + IDOR/BOLA). Source of truth = current code at HEAD (2026-06-13).
Mapped to OWASP API Security Top 10 (2023) + ASVS 5.0.

## Components & files reviewed
- `firestore.rules` (4254 lines) — Firestore security rules (targeted reads only).
- `storage.rules` (30 lines) — Cloud Storage rules.
- `functions/src/auth.ts` — `assertAuth`/`assertOwnership`/`assertAppCheck`/`enforceAuthAndAppCheck`.
- `functions/src/config.ts` — `enforceAppCheck` default + production fail-closed.
- `functions/src/guards.ts` — type-guard parsers (no authz logic; input validation only).
- `functions/src/callables/encryptedSearch.ts` — session-blob signed-URL upload/download.
- `functions/src/callables/dataExport.ts` — export signed-URL minting.
- `functions/src/callables/shared.ts` — `assertUserStoragePath` path-scope guard.
- `functions/src/accountDeletion.ts` — storage prefix cleanup (`users/<uid>/`, `avatars/<uid>`).
- `functions/src/routerRundown.ts`, `functions/src/health.ts`, `functions/src/callables/{stripe,cliLink,knowledgeSync}.ts`, `functions/src/appstore/notifications.ts` — HTTP `onRequest` posture.
- `firestore-rules-tests/rr12-relay-and-root.test.js` — regression coverage for vault-wrapper delete + root-doc allowlist.

## Controls present
- Per-namespace ownership predicate — `firestore.rules:52` `ownsUserNamespace(userId)` (`request.auth.uid == userId`) — strong — used by every `users/{userId}/**` collection read/write.
- Root user-profile write allowlist — `firestore.rules:77-113` `validRootUserProfileWrite` + `:1151` — strong — `keys().hasOnly([...])` + per-field type/size caps; `uid` pinned to path; secret-field denylist via `hasNoPlaintextSecretFields`. (Closes legacy T-CL-6/RR-6.)
- Plaintext-secret field denylist — `firestore.rules:56-69` `hasNoPlaintextSecretFields` — moderate — bans apiKey/token/refreshToken/accessToken/idToken/cookie/password/secret/secretVersionName/authorization/bearer/credential (exact top-level names only).
- Sealed-envelope structural validator — `firestore.rules:462-500` `validCloudSealedText` — strong — forces AES-256-GCM, base64-only, bounded nonce/ciphertext/tag, AAD required at schemaVersion>=2.
- Entitlements are read-own / server-write-only — `firestore.rules:3364-3367` (`allow write: if false`), `:3373-3375` events, `:3382-3383` bindings `read,write:false` — strong — billing state cannot be self-minted by clients.
- Cloud-vault key wrappers: owner read, server-gated create requiring BOTH source+target trusted escrow devices, delete denied — `firestore.rules:2209-2255` (`allow delete: if false` `:2254`; trust gets `:2250-2253`) — strong. (Closes legacy RR-12 — see test `rr12-...:141`.)
- Cloud-vault state: owner read, single-doc (`stateId=="current"`) allowlisted write, vaultKeyID continuity check, delete denied — `firestore.rules:2169-2206` — strong.
- Escrow trust elevation is server-only — `firestore.rules:3448-3451` (create rejects `trustState=="trusted"`), `:3453-3514` (update freezes trustState + every identity/fingerprint field byte-identical) — strong — prevents client self-approval / trusted-doc reuse.
- Server-only provider secret refs — `firestore.rules:1086-1088` `provider_account_secret_refs` `read,write:false` — strong.
- Server-only root index / nonce / rate-limit collections — `firestore.rules:4226-4248` (`google_play_token_claims`, `high_risk_action_nonces`, `public_rate_limits`, `cli_link_sessions`, `hermes_gateway_*`) all `read,write:false` — strong.
- Credential-transfer create-only with format/TTL bounds; get/list/update/delete denied — `firestore.rules:1092-1133` (`allow get:false` `:1129`, `list:false` `:1132`) — strong — consumption is server-transaction-only.
- App Check helper, default ON, prod fail-closed — `functions/src/config.ts:68` (`enforceAppCheck` defaults true), `:78-84` (throws on prod start if disabled) — strong; assert in `auth.ts:53-61`.
- Centralized callable ownership guard — `functions/src/auth.ts:22-31` `assertOwnership` + `:69-73` `enforceAuthAndAppCheck` — strong — 97 onCall handlers wire `enforceAppCheck: getConfig().enforceAppCheck`.
- Signed-URL path-scope guard — `functions/src/callables/shared.ts:514-541` `assertUserStoragePath` (`parts[1] !== uid` rejects) — strong — blocks IDOR on download-URL minting.
- Signed URLs are v4, short-TTL, uid-scoped server-side paths — `encryptedSearch.ts:87-94` (10-min write, path `users/${uid}/...`), `:135-141` (10-min read after existence check), `dataExport.ts:240` (`SIGNED_URL_TTL_MS = 15min`), `:601` prefix `users/${uid}/${prefix}/` — strong.
- Storage owner-only session logs + size/contentType caps — `storage.rules:5-14` — strong.
- Default-deny on unmatched paths — Firestore/Storage deny-by-default + explicit `match /{allPaths=**} { allow read, write: if false }` (`storage.rules:26-28`) — strong.

## Claims verified against code
- "users/{uid} root doc lacks allowlist / secret-field check (RR-6 / T-CL-6)" — **NotDefensible (remediated)** — `firestore.rules:1151` now calls `validRootUserProfileWrite` (`:77-113`); tested `rr12-...:163-185`.
- "Owner can delete cloud_vault_key_wrappers → availability attack (RR-12 / T-CL-2)" — **NotDefensible (remediated)** — `firestore.rules:2254` `allow delete: if false`; tested `rr12-...:141-146`.
- "Entitlements / billing state are server-write-only (clients cannot self-grant Pro)" — **Defensible** — `firestore.rules:3366` `allow write: if false`; reads owner-scoped `:3365`.
- "Escrow device trust cannot be elevated from a client (no self-approval)" — **Defensible** — `firestore.rules:3450, 3465`; matches header comment `:25-26`.
- "Cloud sync stores ciphertext only; plaintext credential fields rejected" — **Partial** — structural sealing enforced (`:462-500`) and denylist exists (`:56-69`), BUT denylist is exact-top-level-name only; nested/renamed secret fields and metadata (counts/timestamps/deviceIds) are not ciphertext. Rules cannot prove client never serializes plaintext into non-denylisted keys — relies on client + unit tests (`:28-31`).
- "App Check fails closed in production" — **Defensible** — `config.ts:68,78-84` (throws if prod + disabled); App Check is also a separate console-enforcement toggle for the SDK datapath (`firestore.rules:20-23` comment) — rule-layer `request.auth` alone does not block non-app clients; UNKNOWN whether console enforcement is on (deploy state).
- "Signed URLs are scoped to the caller and short-lived" — **Defensible** — `shared.ts:524` (uid path-segment check), 10–15 min v4 (`encryptedSearch.ts:88,135`; `dataExport.ts:240`).
- "Avatars are cross-tenant readable (accepted risk)" — **Defensible (confirmed weakness)** — `storage.rules:19` `allow read: if request.auth != null` — ANY authenticated user can read ANY `avatars/{userId}/profile.jpg`. Accepted-risk per comment but is a real BOLA-read on profile photos.
- "Shared workspace artifacts stay owner-scoped" — **Partial** — read is owner-scoped via doc field (`firestore.rules:1067-1071`), but `workspaceId`/`teamId` path segments are NOT bound to the caller uid on write (`:1073-1080`), so a user can plant docs under another tenant's `workspaces/workspace-<victim>/...` path (write-pollution; not a cross-read).

## Threats
- T-AZ-01 — Cross-tenant avatar read (profile-photo BOLA) — STRIDE:Information Disclosure / LINDDUN:Linkability / OWASP API1:BOLA, ASVS V4 — **Low** — Cloud Storage `avatars/{userId}/profile.jpg` — attack: any authenticated uid issues `getDownloadURL`/signed read for arbitrary `userId` — existing mitigation: direct SDK requires auth, comment marks it accepted; downloads usually via signed URL — gap: no per-owner read scope (`storage.rules:19`) — residual: profile images of all users enumerable/correlatable to UIDs.
- T-AZ-02 — Shared-artifact write into another tenant's workspace path — STRIDE:Tampering / OWASP API1:BOLA + API3:BOPLA, ASVS V4 — **Low** — `workspaces/{workspaceId}/teams/{teamId}/artifacts/{id}` — attack: `mallory` writes doc with `ownerUserID=mallory` under `workspace-alice/...` — existing mitigation: read gated on `ownerUserID==auth.uid` so victim cannot read planted doc; no active client writer found (collection vestigial) — gap: `sharedArtifactOwnerWrite` (`firestore.rules:1073-1080`) never binds `workspaceId` to a uid; no rules-test coverage — residual: namespace pollution / quota-grief in another tenant's path; latent if a future read path keys off path not ownerUserID.
- T-AZ-03 — Metadata leakage in "sealed" cloud sync — STRIDE:Information Disclosure / LINDDUN:Detectability — **Medium** — `users/{uid}/{usage,budgetRules,conversations,...}` — attack: server/operator with Firestore access reads non-sealed metadata (counts, timestamps, deviceIds, hashes, projectKeyHash) — existing mitigation: content fields sealed (`:462-500`); plaintext-name fail-closed on create (`:1163-1165`) — gap: sealing covers named fields only; surrounding metadata is cleartext by design — residual: traffic-analysis / activity inference; not an auth bypass.
- T-AZ-04 — Plaintext secret in a non-denylisted field — STRIDE:Information Disclosure / OWASP API3:BOPLA, ASVS V8 — **Medium** — any owner-writable collection using `ownerWritableNonSecret` — attack: client serializes a credential under a key not in the 12-name denylist (e.g. `auth_blob`, nested map) — existing mitigation: `hasNoPlaintextSecretFields` (`:56-69`) + sealed-text validators on known fields + client unit tests — gap: denylist is exact top-level names; rules cannot enforce no-plaintext universally — residual: depends on client correctness; defense-in-depth only.
- T-AZ-05 — Admin-SDK rule-bypass via a callable missing ownership check — STRIDE:Elevation of Privilege / OWASP API5:BFLA, ASVS V4 — **Medium** — all 100 callables / 8 onRequest endpoints — attack: a handler does Admin-SDK Firestore/Storage I/O for a uid it did not authorize (Admin SDK ignores rules) — existing mitigation: `enforceAuthAndAppCheck`/`assertOwnership` (`auth.ts:22-31,69-73`); signed-URL paths via `assertUserStoragePath` (`shared.ts:514`) — gap: enforcement is per-handler convention, not structurally guaranteed; not every one of 100 handlers individually verified here — residual: a single handler that derives uid from request body without `assertOwnership` is a cross-tenant read/write.
- T-AZ-06 — App Check console enforcement not provable from code — STRIDE:Spoofing / OWASP API2:Broken Auth, ASVS V2 — **Medium** — Firestore/Storage SDK datapath — attack: non-app client with a stolen/forged ID token writes directly via SDK if console App Check enforcement is OFF — existing mitigation: callables fail-closed in prod (`config.ts:78-84`); rules require `request.auth` — gap: rules `request.auth` alone does not attest the app; SDK-level App Check is a console toggle (`firestore.rules:20-23`) not in repo — residual: UNKNOWN until deployed enforcement state confirmed.
- T-AZ-07 — Operator custom-claim trust (`burnbarOperator`) breadth — STRIDE:Elevation of Privilege / OWASP API5:BFLA — **Low** — `isOperator()` `firestore.rules:38-40` gates ops/* metrics reads (`:3068-3074, 4211-4222`) — attack: misissued `burnbarOperator` claim reads ops budget/metrics/events across all tenants — existing mitigation: claim is server-minted; only ops aggregate collections gated, not user content — gap: no code in repo proves claim-issuance path / who can mint — residual: scoped to ops telemetry, not user-private data; UNKNOWN issuance custody.
- T-AZ-08 — Unauthenticated public HTTP endpoints — STRIDE:Information Disclosure / OWASP API2 — **Info** — `routerRundown.ts:1125` `latestRouterRundown` (cors:true, no auth), `health.ts:47` `healthLive` (`invoker:"public"`) — attack: anonymous GET — existing mitigation: intentional public pricing/health data, `maxInstances` cap is the only throttle (`routerRundown.ts:5` comment) — gap: no per-IP rate limit — residual: cost/DoS only; no tenant data exposed (verified scope of payload is public landscape data).

## Gaps / missing controls
- Avatars storage read is global-authenticated (`storage.rules:19`) — no per-owner scope; accepted but should be served only via short-lived signed URLs with owner check, or rule keyed to a follow/visibility model.
- Shared workspace-artifact write path does not bind `workspaceId` to a uid (`firestore.rules:1073-1080`); zero rules-test coverage for that collection.
- No structural guarantee that all 100 callables call `assertOwnership` before Admin-SDK I/O — enforcement is per-handler convention (Admin SDK bypasses rules entirely).
- Plaintext-secret denylist is exact-top-level-name only (`firestore.rules:56-69`) — nested/renamed secret keys and metadata are not covered by rules.
- App Check SDK-datapath enforcement is a console setting absent from the repo — cannot be verified statically.
- No global `match /{document=**}` catch-all in firestore.rules (relies on Firestore implicit default-deny; correct but worth an explicit belt-and-suspenders deny).

## Overclaims
- Header/SECURITY framing of cloud sync as "ciphertext only" overstates: per-collection metadata (counts, runtimes, timestamps, deviceIds, projectKeyHash trapdoor) is cleartext by design (`firestore.rules:74` internal package note; sealing scope `:462-500`). Encryption != E2E for metadata.
- Rule-file comment "App Check: request.auth ... not sufficient to block non-app clients. Enforce App Check ... in the Firebase console" (`firestore.rules:20-23`) is honest, but any doc prose asserting App Check is "enforced" must be read as code-side callable enforcement only; the SDK/Firestore datapath enforcement is not provable from the repo (UNKNOWN).
- "Shared artifacts ... owner-scoped" (`firestore.rules:18`) is true for READ but the WRITE path lacks path-uid binding — the comment understates the write-pollution surface.

## Crypto/protocol notes
- Sealed envelopes pinned to AES-256-GCM with required AAD at schemaVersion>=2 (`firestore.rules:462-500`); vault key wrappers pinned to ECIES-P256-AESGCM with base64 charset + 8 KiB cap (`:2244-2247`). Rules validate STRUCTURE/format only — they cannot verify the ciphertext actually decrypts or that the correct key was used (that is client/server responsibility).
- Vault key continuity enforced in rules: a new `cloud_vault_state/current` write must match the existing `vaultKeyID` (`:2204-2205`) and wrappers must `matchesCurrentVaultKey` (`:2231`) — prevents a client unilaterally rotating the active key via rules alone.

## Open questions / UNKNOWN
- Is Firebase **console** App Check enforcement actually ON for Firestore + Storage in production? (Needs deployed config; rule layer cannot prove it.)
- Is Firestore PITR / backup / delete-protection enabled? (Legacy RR-4/T-CL-1 flagged absent 2026-06-11; not determinable from rules — needs deployed GCP state.)
- Who can mint the `burnbarOperator` custom claim, and is it ever set on end-user accounts? (No issuance code located in this domain's scope.)
- Do ALL 100 onCall handlers individually call `assertOwnership`/`assertUserStoragePath` before Admin-SDK reads keyed on a body-supplied uid? (Spot-checked encryptedSearch/dataExport = pass; full 100-handler enumeration is out of scope here — recommend a lint/CI gate.)
- Is the `workspaces/.../artifacts` collection actually written by any shipping client, or fully vestigial? (No active Swift/Kotlin writer found; confirm before deciding remediation priority.)
