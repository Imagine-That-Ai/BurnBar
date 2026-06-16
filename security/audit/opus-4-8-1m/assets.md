# Asset & Data Inventory — Opus 4.8 1M lane

| ID | Asset | At rest | Confidentiality | Controls | Gaps |
|---|---|---|---|---|---|
| ASSET-01 | Provider API keys / connector creds / bearer tokens | macOS Keychain (WhenUnlockedThisDeviceOnly) | Critical | Keychain; never plaintext to cloud; escrow ciphertext only; secret-field denylist | same-user/daemon-compromise inherent |
| ASSET-02 | CloudVault symmetric key | Keychain | Critical | device-only; ECIES-wrapped to escrow devices; not derivable by Firebase | — |
| ASSET-03 | Device escrow / Signal identity private keys | Keychain (WhenUnlockedThisDeviceOnly, non-syncable) | Critical | platform Keychain; public+fingerprint only leave device | — |
| ASSET-04 | DB encryption key | Keychain | Critical | WhenUnlockedThisDeviceOnly; recovery bundle PBKDF2+AES-GCM | DB itself plaintext today (OPUS-F-004) |
| ASSET-05 | Chat/session/mission/snippet content | Firestore (sealed) + local SQLite (plaintext) | High | AES-256-GCM seal before Firestore; session_logs allowlist | local DB plaintext (OPUS-F-004) |
| ASSET-06 | Shared collaboration artifacts (source) | Firestore | High | owner-scoped rules | **plaintext body/title (OPUS-F-001)** |
| ASSET-07 | Entitlements / billing state | Firestore (server-only) | High (integrity) | write-denied; server reconcilers; replay/downgrade guards | — |
| ASSET-08 | Routing/usage metadata, quota | Firestore | Medium | owner-scoped; intentionally cloud-readable (disclosed) | quota client-mirror window (OPUS-F-013) |
| ASSET-09 | Ephemeral push tokens + uid (voip/fcm queues) | Firestore (TTL) | Medium | TTL + account-erase sweep | live TTL state unverified (OPUS-U-001) |
| ASSET-10 | Logs / crash reports | Cloud Logging / Sentry | Medium | scrubber on 127/127 sites; Sentry consent + scrub | accountDeletion uid (OPUS-F-005); macOS scrub untested (OPUS-F-002) |
| ASSET-11 | Release signing keys (Dev ID, notary, Sparkle EdDSA, GPG) | GitHub `release` environment | Critical | environment-gated; ephemeral keychain per run | single-signer; no HSM (residual) |
| ASSET-12 | Backend secrets (provider/KMS) | Secret Manager / KMS | Critical | IAM + KMS envelope; Firestore stores only resource names | GCP_SA_KEY long-lived (ops) |
| ASSET-13 | macOS login password (Remote Unlock) | transient in IPC | Critical | per-uid 0700 dir + client server-peer auth | legacy /var/run lane (OPUS-F-008) |

**Retention/deletion:** account deletion covers PII-bearing collections + storage (OPUS-F-014 forward-risk); ephemeral queues TTL-bounded (OPUS-U-001 live state). **Export:** `scheduledExports.ts`.
