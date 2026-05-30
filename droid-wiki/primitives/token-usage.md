# TokenUsage

The fundamental data model representing one AI session's token consumption event. Every parser produces `TokenUsage` records; every usage chart, rollup, and Firestore sync doc derives from them.

## Canonical location

```
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/TokenUsage.swift
```

The macOS app re-exports it via `typealias TokenUsage = OpenBurnBarCore.TokenUsage` in `AgentLens/Models/AgentProvider.swift`.

## Fields

| Field | Type | Description |
|---|---|---|
| `id` | `UUID` | Stable record identifier |
| `provider` | `AgentProvider` | Which AI provider generated this usage |
| `sessionId` | `String` | Provider session or conversation ID |
| `projectName` | `String` | Workspace / project folder name |
| `model` | `String` | Model identifier string (e.g. `"claude-sonnet-4-5"`) |
| `inputTokens` | `Int` | Prompt tokens |
| `outputTokens` | `Int` | Completion tokens |
| `cacheCreationTokens` | `Int` | Anthropic cache-write tokens (default 0) |
| `cacheReadTokens` | `Int` | Anthropic cache-hit tokens (default 0) |
| `reasoningTokens` | `Int` | Extended thinking tokens (default 0) |
| `totalTokens` | `Int` | Computed: sum of all billed token types |
| `cost` | `Double` | USD cost (exposed also as `costUSD`) |
| `startTime` | `Date` | Session start |
| `endTime` | `Date` | Session end |
| `createdAt` | `Date` | When the record was created locally |
| `usageSource` | `UsageSource` | `providerLog`, `inAppChat`, `cursorBridge`, `billingAPI`, `daemon`, `unknown` |
| `sourceDeviceId` | `String?` | Device ID if synced from another device |
| `sourceDeviceName` | `String?` | Device name for display |
| `isRemote` | `Bool` | Whether the record originated on another device |
| `providerID` | `ProviderID` | Routing-layer provider ID (defaults to `provider.providerID`) |
| `providerAccountID` | `String?` | Specific account within the provider |
| `providerAccountLabel` | `String?` | Display label for the account |
| `provenanceMethod` | `UsageProvenanceMethod` | How usage was obtained |
| `provenanceConfidence` | `UsageProvenanceConfidence` | Confidence level of the values |
| `estimatorVersion` | `String` | Version of the heuristic estimator used (if any) |

## Provenance enums

**`UsageProvenanceMethod`** (ordered by precedence, highest first):
`providerLog` (6), `billingAPI` (5), `connectorBridge` / `daemonBridge` (4), `inAppChat` (3), `cloudSync` (2), `heuristicEstimate` (1), `unknown` (0)

**`UsageProvenanceConfidence`** (ordered by precedence):
`exact` (4), `derivedExact` (3), `highConfidenceEstimate` (2), `lowConfidenceEstimate` (1), `unknown` (0)

## Lifecycle

```
Parser reads log file
  → TokenUsage(provider:, model:, inputTokens:, outputTokens:, ...)
    → UsageAggregator deduplicates and merges
      → UsageStore persists to SQLite (GRDB)
        → UI reads from ConversationStore / DataStore
        → Firestore sync writes UsageEventDoc (optional)
```

## Firestore schema

`UsageEventDoc` in `functions/src/types.ts` mirrors the fields above. Key Firestore path: `users/{uid}/usage/{docId}`.

Rollups aggregate into 5 documents per user at `users/{uid}/usage_rollups/{today,7d,30d,90d,all_time}`. See [Cloud Functions](../systems/cloud-functions.md).

## Android equivalent

`android/app/src/main/java/…/data/models/TokenUsage.kt` — annotated `@IgnoreExtraProperties`, `@PropertyName` for camelCase↔snake_case mismatches. Computed properties (`get()`) live in the class body, not the primary constructor. Timestamps converted from `com.google.firebase.Timestamp` via `seconds * 1000 + nanoseconds / 1_000_000`.
