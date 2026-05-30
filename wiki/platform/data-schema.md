# Canonical SQLite, GRDB Rules, and Model Alignment

This document details the data layer architecture of the **OpenBurnBar** ecosystem, outlining local SQLite storage design, GRDB rules, the TypeSpec-driven schema synchronization chain, and provider-specific telemetry schemas.

---

## 1. Database Architecture & GRDB Stance

OpenBurnBar maintains a local-first architecture. On-device **SQLite** is the absolute canonical storage authority for all telemetry, session histories, and local retrieval vector indexes. 

The application utilizes **GRDB.swift** to manage the database connection, write transactional migrations, and stream reactive queries to the UI:

* **Concurrency Model:** OpenBurnBar uses SQLite's Write-Ahead Logging (WAL) mode. This enables concurrent read operations from the UI threads while background worker queues (such as log parsers and the vector projection pipeline) perform serialized writes.
* **Transactional Gating:** Every telemetry update is written inside isolated SQLite transactions to prevent corrupt states.
* **No Database Sync Conflicts:** Cloud systems (like Firestore) act only as opt-in replication targets. If a sync conflict occurs, **local SQLite state is the absolute authority**, and cloud modifications are discarded or overwritten.
* **Local Encryption (SQLCipher):** Toggling database encryption key-secures the database at rest via SQLCipher. Key material is stored exclusively in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) and can only be recovered via a user-exported passphrase-protected recovery bundle.

---

## 2. TypeSpec-Driven Schema Canon

To prevent schema drift across TypeScript, Swift, and Kotlin targets, OpenBurnBar implements a centralized **TypeSpec** canon chain:

```text
tools/schema-sync/typespec/*.tsp
        │ emit
        ├── functions/src/types.ts (+ generated sections)
        ├── OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/*.swift
        └── android/.../generated/*Models.kt
        │
        └── CI Check: ./tools/schema-sync/check-drift.sh
```

### Schema Governance Rules
1. **Source of Truth:** All cross-platform network payloads and Firestore document schemas are defined inside TypeSpec files (`.tsp`) under `tools/schema-sync/typespec/`.
2. **Never Edit Generated Files Hand-written modifications** to `types.ts`, `*Models.swift`, or `*Models.kt` are strictly prohibited. Extensions to Swift models are handled via hand-written computed property extensions in separate files.
3. **Drift Control Gating:** Any pull request that alters Firestore models or API payloads without matching TypeSpec definitions is automatically rejected by the CI gate (`check-drift.sh`).

---

## 3. Canonical Sync Interfaces

Below is the mapping between TypeScript (`functions/src/types.ts`) schemas, local platform data models, and Firestore targets:

| TypeSpec Module / TS Interface | Android Kotlin Model | Swift Model Target | Firestore Collection |
|:---|:---|:---|:---|
| `UsageEventDoc` | `TokenUsage` | `TokenUsage` | `users/{uid}/usage/{doc}` |
| `UsageRollupDoc` | `UsageRollups` | `UsageRollup` | `users/{uid}/usage_rollups/{today,7d,30d,90d,all_time}` |
| `QuotaSnapshotDoc` | `ProviderQuotaSnapshot` | `ProviderQuotaSnapshot` | `users/{uid}/quota_snapshots/{provider}_{sourceId}` |
| `ProviderAccountDoc` | `ProviderAccount` | `ProviderAccount` | `users/{uid}/provider_accounts/{accountId}` |

---

## 4. Provider telemetry & disk geometries

OpenBurnBar's log parsing engines monitor, parse, and normalize disk artifacts and API responses across five primary providers:

### 1. Claude Code (Anthropic)
* **Log Location:** `~/.claude/projects/<project-name>/*.jsonl`
* **Parsing Strategy:** Real-time JSONL scanning. Input, output, and cache tokens are extracted on every prompt turn.
* **JSONL Entry Geometry:**
```json
{
  "cwd": "/path/to/project",
  "sessionId": "session_abc123",
  "timestamp": "2026-05-30T12:00:00.000Z",
  "message": {
    "usage": {
      "input_tokens": 1500,
      "output_tokens": 450,
      "cache_creation_input_tokens": 200,
      "cache_read_input_tokens": 600
    },
    "model": "claude-3-5-sonnet-20241022",
    "id": "msg_xyz"
  },
  "costUSD": 0.0051
}
```

### 2. Codex CLI (OpenAI)
* **Log Location:** `~/.codex/sessions/*.jsonl`
* **Parsing Strategy:** Delta-subtraction calculation. Codex records cumulative token counters, so OpenBurnBar must subtract the previous entry's totals from the new entry to determine individual turn usage.
* **JSONL Entry Geometry:**
```json
{
  "type": "token_count",
  "payload": {
    "input_tokens": 5600,
    "cached_input_tokens": 1200,
    "output_tokens": 850,
    "reasoning_output_tokens": 150,
    "total_tokens": 6450,
    "info": { "model": "gpt-4o" }
  },
  "timestamp": "2026-05-30T12:05:00.000Z"
}
```
*Note: Reasoning output tokens are pre-aggregated inside `output_tokens` and must not be double-counted.*

### 3. Factory (Droid)
* **Ingestion Strategy:** Server-side poll over Web API using secure WorkOS session cookies or bearer tokens.
* **Response Geometry:**
```json
{
  "usage": {
    "startDate": 1715299200,
    "endDate": 1715385600,
    "standard": {
      "userTokens": 12500,
      "totalAllowance": 100000,
      "usedRatio": 0.125
    },
    "premium": {
      "userTokens": 450,
      "totalAllowance": 1000,
      "usedRatio": 0.45
    }
  }
}
```

### 4. Cursor
* **Auth Token Storage:** Extracted from Cursor state database `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
* **Ingestion Strategy:** Polling the `/api/usage-summary` JSON endpoint.
* **Response Geometry:**
```json
{
  "membershipType": "pro",
  "billingCycleEnd": "2026-06-06T00:00:00.000Z",
  "individualUsage": {
    "plan": {
      "used": 420,
      "limit": 500,
      "remaining": 580
    }
  }
}
```

### 5. Warp AI
* **Ingestion Strategy:** GraphQL v2 POST requests to `/graphql/v2?op=GetRequestLimitInfo`.
* **Request Context:** Requires the User-Agent header `Warp/1.0` to bypass edge rate limiters.
* **Response Geometry:**
```json
{
  "data": {
    "user": {
      "user": {
        "requestLimitInfo": {
          "isUnlimited": false,
          "requestLimit": 1500,
          "requestsUsedSinceLastRefresh": 120
        }
      }
    }
  }
}
```
