# Privacy, Logging, and Data Governance Review

## A.8.1 Privacy Model

- Local-first: default state is no cloud data.
- Cloud sync opt-in requires explicit user action.
- Sealed payloads protect content; metadata is visible.
- Data deletion callable available.
- Push notifications use FCM tokens; payload minimized.

## A.8.2 PII Handling

### Cloud Functions Logging

`functions/src/logging.ts` implements a PII scrubber:

- Emails → `[email]`
- IPv4/IPv6 → `[ip]`
- Tokens/secrets → `[REDACTED]`
- UIDs → truncated
- Path-shaped UID segments redacted

### Mobile Scrubbers

- `OpenBurnBarMobile/App/MobileSentryScrubber.swift` removes emails, tokens, and UIDs from Sentry events.
- Android equivalent exists.

### Notification Payloads

- `functions/src/agentNotifications.ts` reduced UID exposure per prior audit M-023.
- Need to verify no PII in notification title/body.

## A.8.3 Data Minimization

| Data | Minimized? | Note |
|---|---|---|
| Agent content | Yes (sealed) | Only hashes/ids server-side |
| Cost metadata | Partial | Visible to server for sync/billing |
| Provider IDs | No | Required for aggregation |
| Device IDs | Partial | Hashed where possible |
| Crash context | Partial | Free-form stack/extras could leak |

## A.8.4 Retention and Deletion

- Firestore rules do not enforce TTL; deletion relies on callables.
- `dataDeletion` callable must be tested end-to-end.
- `ops/` telemetry retention unknown (UNKNOWN-008).

## A.8.5 Logging Gaps

1. **Free-form context in Sentry/Crashlytics** can include user content if thrown as error messages.
2. **Local daemon logs** may contain file paths or command snippets; need redaction policy.
3. **Extension logs** in VS Code are uncontrolled; could leak tokens.

## A.8.6 Prior Audit Items (Privacy)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-023 | agentNotifications UID leak | Partial | Verify notification body |
| M-028 | Capability token HID binding | Open | Phone HID actions need stronger binding |
