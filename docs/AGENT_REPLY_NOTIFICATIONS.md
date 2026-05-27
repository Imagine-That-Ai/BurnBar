# Agent Reply Notifications

OpenBurnBar sends agent-reply notifications from the Cloud plane so every chat
surface gets the same behavior:

- If a reply lands while the user is in another OpenBurnBar surface, the app
  shows an in-app banner or native local notification.
- If iOS/iPadOS or Android is backgrounded, Firebase Cloud Messaging delivers a
  system notification.
- If macOS is running, the Mac app listens to the same Cloud event stream and
  displays a native notification.
- Inline replies are submitted through a signed-in callable and, where the
  runtime is available locally, are immediately forwarded into the existing
  Hermes/Pi/CLI chat send path.

## Cloud Contract

Server-owned event documents live at:

```text
users/{uid}/agent_notification_events/{eventId}
```

Client-owned reply commands live at:

```text
users/{uid}/agent_notification_replies/{replyId}
```

Events are created by Cloud Functions when an assistant message is appended to
either of these sources:

```text
users/{uid}/cli_sessions/{threadId}
users/{uid}/mobile_assistant_chats/{threadId}
```

The event id is deterministic across source, runtime, thread, message id, and
content hash, so duplicate snapshots do not create duplicate notifications.
Cloud fanout reads `users/{uid}/devices`, skips the active matching chat when
the device heartbeat is fresh, sends FCM to registered mobile devices, and marks
stale or invalid tokens. Android receives data-only high-priority messages so
`FirebaseMessagingService` can always build the notification with inline reply
actions, including while the app is backgrounded. Apple platforms receive alert
pushes with the `AGENT_REPLY` category registered at launch.

Firestore rules intentionally make events server-only. Users may read events and
create bounded reply commands only when the command references a real
server-created event and matches that event's thread/runtime/source. Clients may
only advance reply command status; they cannot mutate the target, text, or
ownership fields.

## Client Surfaces

### iOS and iPadOS

`AgentReplyNotificationService` registers the `AGENT_REPLY` notification
category, requests alert/sound permission, persists device state and FCM tokens,
suppresses foreground banners for the active thread, renders the in-app banner,
deep-links to `burnbar://assistants/{runtime}?threadId={threadId}`, and handles
inline replies.

Inline replies call `submitAgentNotificationReply` first for durable audit and
then attempt immediate local delivery through:

- `CLIAgentMobileChatService` for Codex, Claude Code, Droid, Forge, and
  Antigravity
- `HermesService` for Hermes
- `PiService` for Pi

### Android

`AgentReplyNotificationState` writes the stable Android device heartbeat, FCM
token, app lifecycle, and active assistant thread. `MercuryFcmService` handles
data-only `type=agent_reply` messages, suppresses the already-open active chat,
creates the `agent_replies` notification channel, adds a direct-reply action,
and opens the same assistant deep link. `AgentReplyNotificationReceiver`
submits inline replies to the Cloud callable and cancels the notification after
successful dispatch. The Mac host then consumes the queued reply command and
sends it into the same agent thread, so Android notification replies work even
when the Android app is backgrounded.

### macOS

`MacAgentReplyNotificationListener` starts with live services, follows Firebase
Auth state, listens to `agent_notification_events`, suppresses the active
foreground thread locally, writes a Mac device heartbeat, and displays native
notifications with inline reply. Reply actions call the same Cloud callable and
route through `ChatSessionController` so the Mac uses the same backend/thread
send path as an open chat. The same listener also consumes queued
`agent_notification_replies` from phones/tablets, claims them, routes them
silently through `ChatSessionController`, and marks them `sent` or `failed`.

## Apple and Firebase Setup

Apple Developer:

1. Enable Push Notifications on the `com.openburnbar.app` app identifier.
2. Confirm the iOS entitlement includes `aps-environment`.
3. Debug builds use `APS_ENVIRONMENT=development`; Release archives use
   `APS_ENVIRONMENT=production` from `project.yml`.
4. Create or reuse an APNs Auth Key for the team and record Key ID, Team ID, and
   the `.p8` file location.

Firebase Console:

1. Open Project Settings -> Cloud Messaging.
2. Under Apple app configuration for the iOS app, upload the APNs Auth Key.
3. Confirm the bundle id matches `com.openburnbar.app`.
4. Confirm Android has a valid `android/app/google-services.json`; CI injects it
   from `GOOGLE_SERVICES_JSON_BASE64`.
5. Deploy the new functions and rules together:

```bash
npm --prefix functions run build
firebase deploy --only functions:onCliSessionAgentReplyNotification,functions:onMobileAssistantAgentReplyNotification,functions:submitAgentNotificationReply,firestore:rules
```

## Verification

Local checks:

```bash
npm --prefix functions run build
npm --prefix functions run test:agent-notifications
npm --prefix functions run test:firestore-rules
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/DerivedData-openburnbar-notifications -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-openburnbar-notifications-mac-arm64 -skipPackagePluginValidation -skipMacroValidation ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
cd android && ./gradlew :app:compileDebugKotlin --no-daemon
```

Device smoke:

1. Sign in on Mac and at least one mobile device.
2. Open a CLI agent chat on mobile, then background the app.
3. Send an assistant reply into the mirrored Mac thread.
4. Verify the mobile system notification appears with Reply and Open actions.
5. Reply inline and confirm the reply is written to
   `agent_notification_replies` and sent into the chat when the runtime is
   available.
6. Repeat with the mobile app foregrounded in a different tab and with the
   target chat already open; only the non-active surface should notify.
