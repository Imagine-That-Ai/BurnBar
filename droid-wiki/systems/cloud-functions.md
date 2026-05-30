# Cloud Functions

Firebase Cloud Functions (TypeScript, Node.js 18) backing optional cloud features. All callables enforce Firebase App Check. Secrets are fetched from Secret Manager at call time.

**Location:** `functions/src/`  
**Entry point:** `functions/src/index.ts`  
**Schema:** `functions/src/types/` (migrating from `functions/src/types.ts` to TypeSpec emitters in `tools/schema-sync/`)

## Function groups

### Provider accounts
`functions/src/callables/providerAccounts.ts`

`connectProviderAccount`, `connectProviderCredential`, `connectHostedQuotaAccount`, `connectSelfHostedQuotaAccount`, `uploadProviderQuotaSnapshot`, `deleteHostedQuotaCredentials`, `updateProviderAccount`, `deleteProviderAccount`, `deleteUserCloudData`, `deleteProviderCredential`, `refreshProviderAccountQuota`, `refreshProviderQuota`

### Quota and rollups
- **Quota:** `quota.ts` — provider quota refresh and rollup computation
- **Rollups:** `rollups.ts` — produces 5 documents per user: `usage_rollups/today`, `/7d`, `/30d`, `/90d`, `/all_time`

### Budget governance
- **Computer Use budget:** `computerUseBudget.ts` — hourly `evaluateComputerUseBudget`, per-user daily ceilings: $5 (normal) / $2.50 (soft) / $0 (hard). Hard cap at $2,500/month enforced via Remote Config kill-switch.
- **Media budget:** `mediaBudget.ts` — `evaluateMediaBudget`

### VoIP / push
`functions/src/callables/voipPush.ts`, `apnsSender.ts`, `fcmAndroidSender.ts`

`triggerVoIPCall` fan-outs a Mercury incoming call to all user devices:
- iOS: APNs VoIP push (PushKit) via `sendVoIPOutbound`
- Android: high-priority FCM data message with `media_incoming_call` shape via `sendFcmOutbound`

### Agent notifications
`agentNotifications.ts`, `callables/agentNotifications.ts`

`onCliSessionAgentReplyNotification`, `onMobileAssistantAgentReplyNotification`, `submitAgentNotificationReply`

### Hermes connections
`callables/hermes.ts`

`createHermesPairing`, `completeHermesPairing`, `listHermesConnections`, `revokeHermesConnection`, `updateHermesConnectionStatus`

### Pi agent connections
`callables/piAgent.ts`

Mirror of Hermes pairing flow for Pi agent devices.

### Insights
`insightsHostedAnswer.ts` — server-side hosted insight generation

### Monitoring / rollups (scheduled)
| File | Exported function |
|---|---|
| `irohMonitoring.ts` | `rollupIrohTransportDaily` |
| `mediaMonitoring.ts` | `rollupMediaSessionDaily` |
| `mediaQuota.ts` | `recomputeMediaQuotaUsage` |
| `computerUseMonitoring.ts` | `rollupComputerUseDaily` |
| `computerUseQuota.ts` | `recomputeComputerUseQuotaUsage` |
| `computerUseOpenTimestamps.ts` | `validateOpenTimestampsProof` |

### Scheduled
`scheduled.ts` — background jobs (quota refresh cycles, rollup triggers)

## Security

- **App Check:** `guards.ts` wraps every callable with `appCheck()` enforcement
- **Secrets:** Secret Manager — never committed to source
- **Schema drift detection:** `tools/schema-sync/check-drift.sh` compares TypeSpec contracts against TypeScript types and Android/Swift models before schema-changing deploys

## Canonical Firestore schema

`functions/src/types.ts` (legacy, in migration) defines `UsageEventDoc`, `UsageRollupDoc`, `QuotaSnapshotDoc`, `ProviderAccountDoc`. New contracts are being emitted from TypeSpec sources in `tools/schema-sync/`.

See [TokenUsage](../primitives/token-usage.md) for the client-side model.
