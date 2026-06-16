# Asset and Data Inventory

## A.3.1 Assets

| Asset ID | Asset | Owner | Location | Sensitivity | Lifecycle |
|---|---|---|---|---|---|
| ASSET-001 | Agent session content (messages, commands, code, file paths) | User | Local SQLite; sealed Firestore docs | Critical | Created by parser; synced opt-in; deleted by user |
| ASSET-002 | Provider API keys/tokens (Cursor, Anthropic, OpenAI, etc.) | User | macOS keychain (`com.getburnbar.*`) | Critical | Entered by user; never synced in plaintext |
| ASSET-003 | Firebase Auth identity | User/Google | Firebase Auth | Critical | Created at sign-in; linked to account |
| ASSET-004 | Cloud Vault private keys | User | iOS Keychain / Android Keystore / macOS keychain | Critical | Generated per device; never leaves device |
| ASSET-005 | iroh node private key | User | Device keychain / Android shared prefs (cached) | High | Generated per install; see FINDING-014 |
| ASSET-006 | Token/cost summaries | User | Local DB; Firestore `usage/` and `usage_rollups/` | Medium | Derived from logs; metadata visible to server |
| ASSET-007 | Entitlements / subscription status | BurnBar/User | Firestore; Apple/Google | High | Verified server-side; gates paid features |
| ASSET-008 | Device pairing/escrow tokens | User | Firestore `deviceEscrow/`; local keychain | High | Short-lived; used for cross-device trust |
| ASSET-009 | Audit chain hashes | User | Local files; Firestore `auditChains/` | High | Tamper-evident; timestamps optional |
| ASSET-010 | Crash/telemetry logs | BurnBar | Sentry / Crashlytics / Cloud Logging | Low-Medium | Scrubbed; retention TBD |
| ASSET-011 | SBOM / VEX artifacts | BurnBar | GitHub releases; Container Registry | Medium | Generated at release |
| ASSET-012 | CI/CD signing certificates | BurnBar | GitHub secrets; Apple/Google portals | Critical | Managed by ops; injection scripts only |
| ASSET-013 | Source code | BurnBar | GitHub | High | Public repo (presumed); license depends on path |

## A.3.2 Data Flow Table

| Data | Source | Transit | At Rest | Protection |
|---|---|---|---|---|
| Agent session plaintext | Log files | App → Daemon → SQLite | Local SQLite | Currently none (FINDING-001); SQLCipher planned |
| Agent session sealed blob | SQLite parser | App → Firestore | Firestore document | Signal/libsignal sealed envelope |
| Provider tokens | User input / keychain | App ↔ keychain only | macOS keychain | Keychain encryption; never leaves device |
| Firebase ID token | Firebase Auth SDK | HTTPS/TLS | Memory only | TLS + App Check (console) |
| iroh pairing secret | iroh / Cloud Functions | QUIC + encrypted handshake | Device keychain | libsignal/iroh crypto |
| Audit chain entries | Daemon | Local file + optional Firestore | SQLite / files | SHA-256 chain; optional OTS |
| Usage metadata | Derived | HTTPS to Firestore | Firestore | Owner-scoped rules |
| Search index tokens | Encrypted indexing | HTTPS to Functions | Firestore/sealed index | Per-user encrypted index |
| MCP tool results | Hosted MCP | HTTPS to client | Memory | Token-bound audience |

## A.3.3 Retention

| Data | Default Retention | Deletion Path |
|---|---|---|
| Local SQLite | Until app/user deletes | App settings → delete local data |
| Firestore user docs | Until account deletion | `dataDeletion` callable |
| Firebase Storage blobs | Until account deletion | Same callable + storage rules |
| Crash/telemetry | Configured in Sentry/Crashlytics | Sentry retention settings |
| `ops/` telemetry | Unknown (see UNKNOWN-008) | Unknown |

## A.3.4 Sensitive Metadata

Even though content is sealed, the following are visible to BurnBar/Firebase:

- Provider ID and source ID (e.g., `claude`, `cursor`, `codex`)
- Cost and token totals
- Timestamps and device IDs
- Opaque content hashes
- Presence of Computer Use sessions
- Push notification routing tokens

This is a design choice, not a bug, but it should be clearly communicated to users.
