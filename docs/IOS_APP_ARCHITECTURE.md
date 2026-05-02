# iOS App Architecture

`OpenBurnBarMobile` is a native SwiftUI iOS 17+ app that provides read-only access to usage, quota, and provider connection management backed by Firebase.

## Targets

- `OpenBurnBarMobile` — iOS app (iOS 17.0+)
- `OpenBurnBarMobileTests` — Unit tests

## Layers

```
Views (SwiftUI)
  ↓
Stores (@Observable @MainActor)
  ↓
Repositories (Firestore, Functions, Auth)
  ↓
Firebase SDK
  ↓
Firestore / Cloud Functions
```

## Tabs

1. **Dashboard** — Hero total, period cards, daily usage chart, top providers/models.
2. **Quota** — Urgency-sorted quota cards grouped by provider with source provenance.
3. **Activity** — Paginated raw usage ledger with session detail.
4. **Account** — Auth profile, sync health, provider connections, actions.

## Shared Models

All models live in `OpenBurnBarCore/SharedModels/` and are `Codable`, `Sendable`, and platform-agnostic:

- `AgentProvider.swift`
- `TokenUsage.swift`
- `ProviderQuotaTypes.swift`
- `UsageRollupTypes.swift`
- `ProviderConnectionTypes.swift`
- `Formatting.swift`
- `ThemePrimitives.swift`

## Security

- No local token parsing or counting.
- Credentials sent only to authenticated Cloud Functions.
- No secrets stored locally in plaintext.
