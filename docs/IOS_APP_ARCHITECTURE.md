# iOS App Architecture

`OpenBurnBarMobile` is a native SwiftUI iOS 17+ app that becomes useful immediately after sign-in by mirroring the stats your Mac publishes to Firebase. Provider summaries, usage rollups, quota snapshots, devices, and encrypted credential envelopes all flow Mac → Firestore → mobile. Provider credentials never traverse Firestore in plaintext.

## Targets

- `OpenBurnBarMobile` — iOS app (iOS 17.0+)
- `OpenBurnBarMobileTests` — Unit tests

## Top-level routing

```
OpenBurnBarMobileApp
  └─ AuthGateView
       ├─ FirebaseUnavailableScene   (no GoogleService-Info.plist or unconfigured)
       ├─ SignInScene                  (signed out / signing in / firestore unavailable)
       └─ RootTabView                  (signed in)
            ├─ Dashboard
            ├─ Quota
            ├─ Activity
            └─ Account → Devices, Cross-device transfer, Diagnostics
```

`AuthGateView` owns the singleton stores so they survive auth-state transitions.

### SignInScene

`OpenBurnBarMobile/Views/Auth/SignInScene.swift` is the polished first impression: the brand SVG (`Resources/Assets.xcassets/AppLogo.imageset`) renders inside an "ember breathing" halo, an ambient backdrop drifts two warm orbs across the surface gradient, and Apple's `SignInWithAppleButton` sits above a custom Google button that mirrors the HIG. Both buttons surface a per-provider in-flight `ProgressView`; classified errors slide in as an inline banner with `recoveryHint` copy from `CloudErrorClassification`.

The scene honors `accessibilityReduceMotion` and `accessibilityReduceTransparency` (no infinite animations or additive blends under either), supports Dynamic Type up to `.accessibility2`, and exposes `signIn.apple` / `signIn.google` accessibility identifiers for UI tests. `FirebaseUnavailableScene` reuses the same logo + backdrop language for the no-config fallback.

## Layers

```
Views (SwiftUI)
  ↓
Stores (@Observable @MainActor)
  ↓
Gateways (AuthGateway, CloudReader, DeviceTrustGateway, EscrowGateway)
  ↓
Live adapters (LiveAuthGateway, LiveCloudReader, …) → Firebase SDK
  ↓
Firestore / Cloud Functions / Firebase Auth
```

Views never import Firestore types. Stores expose typed state and a `CloudErrorClassification` enum so UI copy can be security-honest about Firebase, Firestore, App Check, permission, network, and account-mismatch failures.

### Stores

| Store | Responsibility |
|---|---|
| `AuthStore` | `signedOut / signingIn / signedIn / firebaseUnavailable / firestoreUnavailable`, sign-in/out actions, classified errors |
| `CloudSyncHealthStore` | `healthy / syncing / degraded / offline / permissionDenied / appCheckBlocked / firebaseUnavailable / unknown`, last published / read time, publisher device |
| `ProviderSummaryStore` | Mac-published provider summaries (read-only mirror of `users/{uid}/provider_connections`) |
| `DashboardStore` | Usage rollups, hero total, period totals, top providers/models, stale flag |
| `QuotaStore` | Quota snapshots, urgency sort, classified errors, stale-all flag |
| `ActivityStore` | Paginated `TokenUsage` events, classified errors |
| `DevicesStore` | Devices list, this-device trust state, bootstrap eligibility, rename/revoke/bootstrap actions |
| `CredentialTransferStore` | Available envelopes, unsupported envelopes, history, import state machine |

### Import state machine

```
idle → downloading → decrypting → storing → validating → validated
                                                       ↘
                                                       failed(reason)
```

`validated` is reached only after provider readback. Failures classify into `grantRevoked`, `wrongDevice`, `missingPrivateKey`, `decryptionFailed`, `providerValidationFailed`, `permissionDenied`, `appCheckBlocked`. `grantRevoked`, `wrongDevice`, and `missingPrivateKey` are non-retryable; the rest are.

## Tabs

1. **Dashboard** — sync health pill, stale-data banner, actionable card stack (pending trust, available imports, revoked transfers, bootstrap), hero total / period cards / chart / top providers / top models. Falls back to a "no Mac data yet" empty state when nothing has been published.
2. **Quota** — urgency-sorted quota cards grouped by provider with source provenance and stale banner.
3. **Activity** — paginated raw usage ledger with session detail. Errors render an inline classified panel.
4. **Account** — profile, cloud sync, this-device card linking to **Devices**, provider summaries (from Mac), cross-device transfer, sync diagnostics, sign-out.

### Devices, Cross-device, and Diagnostics

- **Devices** lists this device + others with trust pills, exposes rename, revoke (trusted), bootstrap (when no other trusted device exists), and the available imports section.
- **Credential transfer** segments imports into Available / Unsupported / History. Available envelopes open the import progress stepper which only shows "Validated" after provider readback.
- **Sync diagnostics** dumps Firebase/Firestore availability, listener health, classified errors, and a manual refresh.

## Shared Models

All models live in `OpenBurnBarCore/SharedModels/` and are `Codable`, `Sendable`, and platform-agnostic:

- `AgentProvider.swift`
- `TokenUsage.swift`
- `ProviderQuotaTypes.swift`
- `UsageRollupTypes.swift`
- `ProviderConnectionTypes.swift`
- `Formatting.swift`
- `ThemePrimitives.swift`
- `EscrowModels.swift` — `EscrowDevice`, `EscrowGrant`, `EscrowSecretEnvelope`, `EscrowAuditEvent`, plus the `DeviceKeypairProtocol` abstraction implemented by `iOSDeviceKeypair` (mobile) and `MacDeviceKeypair` (Mac).
- `CloudSyncModels.swift` — `CloudProfile`, `CloudDevice`, `SyncWatermark`, `SyncStatus`, `RecentUsageSummary`, `ProviderCostSummary`, `ModelCostSummary` — the cloud-shape contracts that flow Mac → Firestore → mobile.

## Why mobile does not require provider re-entry

Mobile reads `users/{uid}/provider_connections`, which the Mac publishes when cloud sync is enabled. Until the Mac publishes, mobile shows an honest "no Mac data has been published yet" empty state. Adding a provider on mobile only configures that mobile install; it does not replace the Mac's local-first authority.

## Encrypted credential transfer

Provider secrets only move between devices through opt-in encrypted escrow. UI surfaces:
- Mobile import flow (`CredentialTransferView` + `ImportProgressView`) — explicit confirm, decrypted on device, stored in iOS Keychain, validated by provider readback.
- Mac export flow (`DevicesAndSyncSettingsView` + `CredentialTransferSheet`) — pick a trusted destination, encrypt locally for that device, upload ciphertext, wait for readback.

Browser/session credentials, providers that do not allow portable credentials, and unrecognized credential kinds are surfaced as **unsupported** with a precise reason.

## Security

- No local token parsing or counting on mobile.
- No plaintext provider secrets in Firestore — UI never displays "Connected" or "Success" before provider readback.
- No automatic device trust based on Firebase sign-in alone — the explicit bootstrap flow gates this.
- Imported credentials are stored in iOS Keychain on the device that decrypted them.
