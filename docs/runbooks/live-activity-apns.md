# Agent Watch Live Activity APNs

**Status:** Cloud Function sender is in the tree. Delivery still depends on the
same APNs auth-key secrets as Mercury VoIP, plus a Live Activity topic that
matches the iOS bundle id. VAL-MOB stays open until a named-device receipt
exists.

## What sends the push

| Trigger | Path | Event |
|---|---|---|
| `onComputerUseSessionLiveActivity` | `users/{uid}/computer_use_sessions/{sessionId}` | Session create → `update`. First `endedAt` / `endReason` → `end` (`Halted` for panic / `user_halt`). |
| `onComputerUseActionLiveActivity` | `users/{uid}/computer_use_actions/{actionId}` | Action header create → `update` (`Approval pending` / `Action done` / `Denied`). |

Both read `users/{uid}/devices/*` and push only when
`liveActivitySessionId` matches and `liveActivityPushToken` is a hex ActivityKit
token. The HTTP/2 send is the existing `pushToAPNs` path
(`apns-push-type: liveactivity`, `pushWithResilience("apns.liveactivity")`).

The payload is a full ActivityKit `content-state` for
`AgentWatchLiveActivityAttributes.ContentState`. It never carries screenshots,
hashes, secrets, or the iroh `approvalId`. Approve / Deny still require device
unlock plus the live iroh request. Halt stays always-allowed on-device.

`registerDevicePushEndpoint` now accepts the same
`liveActivityPushToken` / `liveActivitySessionId` names the client already
merges onto the device doc.

## Honest limits

- **Pending approval is rarely on the server.** Mac cloud metering writes action
  headers after invoke completes. `awaiting_approval` is a valid status and will
  fan out if written; today most pending approvals exist only on iroh. A killed
  app can refresh counts / halt / completed actions from Firestore. Lock-screen
  Approve / Deny stay disabled until iroh delivers `pendingApprovalId`.
- **A killed app still cannot mint a new Live Activity.** This path only
  updates an activity that already requested `pushType: .token` and persisted
  its per-activity token.

## Missing ops / config

Reuse the VoIP APNs auth key. Do not invent a second key type.

| Name | Kind | Required | Notes |
|---|---|---|---|
| `APNS_KEY_ID` | Functions secret | Yes | Same key as `sendVoIPOutbound`. |
| `APNS_TEAM_ID` | Functions secret | Yes | Team `4Y367DF25B`. |
| `APNS_KEY_P8` | Functions secret | Yes | `.p8` body. `firebase functions:secrets:set APNS_KEY_P8 --project burnbar` |
| `APNS_LIVEACTIVITY_TOPIC` | Functions param | Defaulted | Must be `{bundle-id}.push-type.liveactivity`. Default `com.openburnbar.app.push-type.liveactivity` matches OpenBurnBarMobile `PRODUCT_BUNDLE_IDENTIFIER`. |
| `APNS_HOST` | Functions param | Defaulted | Production `https://api.push.apple.com`. Debug / development `aps-environment` needs `https://api.sandbox.push.apple.com`. |

The Live Activity topic is **not** the VoIP topic. Existing
`APNS_VOIP_TOPIC` default `com.openburnbar.mobile.voip` does not match the
current iOS bundle id (`com.openburnbar.app`); do not reuse it here.

Until those three secrets are bound on the new functions, the handler runs and
logs `live_activity_apns_retry` / `must be configured` instead of updating a
lock-screen activity.
