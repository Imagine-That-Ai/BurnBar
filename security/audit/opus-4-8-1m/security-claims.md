# Security Claims Matrix — Opus 4.8 1M lane

Status legend: ✅ Defensible · 🟡 Partially defensible (narrow the wording) · ❌ Not defensible · ❓ Unknown (deployment/runtime).

| ID | Claim | Status | Evidence | Safe wording |
|---|---|---|---|---|
| CLAIM-01 | Session/chat content is end-to-end-style sealed before Firestore | 🟡 | AES-256-GCM seal on 6 named types + session_logs (M-005 fixed); device-held key; `CloudVaultCrypto.swift` | "Chat, session, mission, and snippet content is sealed with AES-256-GCM under a device-held key before upload; the server cannot read it." Exclude shared artifacts + local DB. |
| CLAIM-02 | Firebase never sees plaintext provider credentials | ✅ | escrow ciphertext only; secret-field denylist `firestore.rules:56-69`; `provider_account_secret_refs` server-only; unit-tested | keep |
| CLAIM-03 | Object-level authorization enforced + tested on every endpoint | ✅ | 150-endpoint catalog + bijection completeness test + tier-2 BOLA proofs | keep |
| CLAIM-04 | Server is the sole authority for entitlements | ✅ | Apple JWS pinned roots + binding + replay; Stripe sig+ledger; `entitlements` write-denied; clients read-only | keep |
| CLAIM-05 | Computer Use requires approval; audit chain is tamper-evident | ✅ | in-code approval gate; audit-before-action; 4 kill paths | keep (add "in Manual mode; Trusted mode acts within deterministic operator scope rules") |
| CLAIM-06 | No plaintext secrets committed to the repo | ✅ | gitleaks+detect-secrets+trufflehog CI+pre-commit; 0 hardcoded in functions/src | keep |
| CLAIM-07 | Supply chain: SHA-pinned actions, SBOM, SLSA attestations, signed/notarized releases | ✅ | 271/271 pinned + verifier; cosign attest; notarized; EdDSA update | keep |
| CLAIM-08 | run-09 privacy invariants (no full UIDs in logs, no stable push correlators, bounded retention) | 🟡 | I1-I5 gated+tested | true except OPUS-F-005 (accountDeletion uid) + OPUS-F-006 (thread_id) — fix or footnote |
| CLAIM-09 | Local database is encrypted at rest | ❌ | SQLCipher not vendored; plaintext fallback (`DataStoreCoordinator.swift:216-261`) | do NOT claim; say "protected by macOS file permissions; at-rest DB encryption is in progress" |
| CLAIM-10 | Shared collaboration artifacts are sealed like chat | ❌ | plaintext `body`/`title` to Firestore (OPUS-F-001) | do NOT claim; either seal or state artifacts are cloud-readable |
| CLAIM-11 | "Signal Protocol" / libsignal encryption is live | ❌ | linked but inert (registry `cloudvault-aesgcm-v2`, RemoteConfig off) | say "AES-256-GCM (CryptoKit)"; libsignal at-rest is staged, not active |
| CLAIM-12 | iroh first-contact is end-to-end authenticated | 🟡 | key-change pinning present; safety-number compare default-off (M-018) | "key-change pinning protects established peers; first-contact safety-number compare is opt-in" |
| CLAIM-13 | Firestore TTLs bound retention of ephemeral PII | ❓ | field-stamp + deploy-readback gate present; live policy state unverified (OPUS-U-001) | confirm live policies before claiming bounded retention |
| CLAIM-14 | App Check enforced (attestation required) | ❓ | code default + startup fail-closed for callables; console enforcement for direct Firestore unverified (OPUS-U-002) | "callables enforce App Check; Firestore console enforcement: confirm" |

## Non-claims to state explicitly
- Does not protect plaintext on a fully-compromised same-user endpoint (unsandboxed local-first model).
- Does not provide local-DB at-rest encryption today.
- Does not seal shared collaboration artifacts.
- Gateway is not user-blind for model-routing metadata (by design).
- No independent external audit has occurred — do not say "audited" or "independently verified."
