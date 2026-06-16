# Privacy, Logging, and Data Governance Review

## I.1 Data Governance Table

| Data Type | Purpose | Collection Point | Storage | Retention | Deletion | Third Parties | Risk |
|-----------|---------|-----------------|---------|-----------|----------|---------------|------|
| Firebase Auth UID | Identity | Firebase Auth | Firebase Auth | Account lifetime | `deleteAuthUser` | None | Low (hashed in logs) |
| Email | Identity | Firebase Auth | Firebase Auth | Account lifetime | Account deletion | None | Medium (scrubbed from logs) |
| Session content | Cost tracking | Local log parsing | SQLCipher (local), CloudVault (E2E encrypted cloud) | User-controlled | Subtree delete + Storage purge | None (E2E) | Critical if vault key compromised |
| Provider API credentials | Hosted quota | User connects account | Keychain (local), Secret Manager (server) | Until disconnect | KMS destroy + Keychain delete | Provider APIs | Critical |
| Push tokens | Notifications | Device registration | Firestore device docs | 15-min TTL (queue) | TTL + account deletion sweep | APNs/FCM (routing only) | Low |
| Search hashes | Cloud search | Session log sync | Firestore | User-controlled | Subtree delete | None (keyed HMAC) | Low (metadata patterns) |
| Usage rollups | Cost display | Cloud Functions triggers | Firestore | User-controlled | Subtree delete | None | Low (aggregate metadata) |
| Audit chain | Agent accountability | Computer Use | Local filesystem | Session lifetime | Session cleanup | None | Low |
| Telemetry | Performance | Local os_log | Local only | In-memory buffer (max 100) | N/A (never sent remotely) | None | None |
| Crash reports | Debugging | Sentry | Sentry | Sentry retention | Sentry retention policy | Sentry (scrubbed) | Low (PII scrubbed) |

## I.2 Sensitive Logging Review

### Cloud Functions (`logging.ts`)
- **All structured logging** routes through `scrubFields`/`scrubValue` before `console.log/error/warn`
- **Sensitive keys:** `accesstoken|apikey|authorization|bearer|cookie|password|privatekey|secret|token` -> redacted
- **UID handling:** Keys `uid`/`userId`/`user_id` truncated to first 8 chars + renamed `user_id_hash`
- **Path redaction:** `redactUidPaths` catches UIDs in path-shaped string values (F-RR09-002)
- **Regex scrubbing:** Emails -> `[email]`, IPv4 -> `[ip]`, API keys (sk-, AIza, ya29., ghp_, xox, eyJ) -> `[REDACTED]`
- **Truncation:** 1024 chars to prevent log injection
- **CI enforcement:** `check-privacy-invariants.mjs` + eslint `no-restricted-imports` block raw `firebase-functions/logger` import
- **Verdict:** Safe

### Sentry (Cloud Functions)
- `sendDefaultPii: false`
- `beforeSend`: `sanitizeSentryEvent` scrubs request data/cookies/env/headers, recursively sanitizes extra/contexts/breadcrumbs
- UID stored as `uid:<first 16 hex of SHA-256(uid)>` (one-way hash)
- DSN never exposed: `sentryStatus()` returns only `{enabled, environment}`
- **Verdict:** Safe

### Sentry (macOS)
- `sendDefaultPii: false`
- `beforeSend`/`beforeBreadcrumb` route through `MacSentryScrubber.scrub()`
- Per-install anonymized ID (random UUID, not `NSFullUserName`)
- DSN from Info.plist or GoogleService-Info.plist
- **Verdict:** Safe

### Sentry (iOS)
- `MobileSentryScrubber.scrub(event)`: sets `event.user = nil`, redacts message/extra/breadcrumbs, drops request
- Regex redaction for emails, bearer tokens, file paths (`/Users/...`, `/private/var/...`)
- **Verdict:** Safe

### Sentry (Android)
- `SentryPrivacyScrubber`: redacts key=value secret pairs, Bearer tokens, sensitive-keyed values
- Unit tested (`SentryPrivacyScrubberTest.kt`)
- **Verdict:** Safe

### Sentry (VS Code Extension)
- `beforeBreadcrumb` strips token/key/secret/auth from URL query params
- `beforeSend` drops noise events
- **Gap (FINDING-011):** Does NOT run recursive payload scrubber over `event.extra`/`contexts` (relies on logger pre-redaction). Defense-in-depth gap.

### Daemon Logger
- OSLog with `privacy: .private` for all formatted output
- `print(` only for CLI help text, not data paths
- **Verdict:** Safe

## I.3 Privacy Threat Model (LINDDUN)

### Linking
- **Push tokens:** APNs/FCM routing tokens are device-scoped, not user-scoped. Ephemeral correlation IDs rotate per push. Stable routing IDs remain visible (FINDING-010, accepted).
- **Search hashes:** Keyed HMAC prevents server-side linking of search patterns across users. Within-user, hashes are deterministic (enables search) but server cannot reverse without vault key.

### Identifying
- **UID in logs:** Truncated to 8 chars + renamed. SHA-256 hashed in Sentry. Path values redacted.
- **Email:** Scrubbed from all log/Sentry paths via regex.

### Non-repudiation
- **Audit chain:** SHA-256-linked + Ed25519-signed terminal head provides agent action accountability. Cannot be repudiated without breaking the chain.

### Detecting
- **Telemetry:** Local os_log only, never sent remotely. Allowlisted feature names + bucketed durations. No PII.

### Data Disclosure
- **CloudVault:** Server sees only ciphertext. Vault key device-held. Path-bound AAD prevents ciphertext relocation.
- **Account deletion:** Comprehensive (Firestore + Storage + Auth + KMS secrets). Storage purge best-effort (FINDING-013).

### Unawareness
- **Consent:** Crash reporting has explicit opt-in consent gate (`MacCrashReportingConsent.isEnabled()`, `MobileCrashReportingConsent`). Default-on but user-settable.
- **Cloud sync:** Explicitly opt-in per feature (session logs, chat threads, conversation mirror all have separate gates).

### Non-compliance
- **GDPR:** Account deletion implemented (Art. 17). Data export implemented (`exportUserData`). Push queue TTLs (Art. 5(1)(e) storage limitation).
- **Gap:** No explicit DPA or sub-processor list visible in repo (operational concern, not code defect).
