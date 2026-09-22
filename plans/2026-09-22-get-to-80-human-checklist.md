# Get-to-80: Human Checklist (Streams B + H + packet receipts)

Alberto — 30-45 min in console, in this order. Paste everything back into chat;
Stream G assembles it into `launch-evidence/`. Nothing below requires code.

## B1. Alert channels live? (GCP Console → Monitoring → Alerting → Notification channels)

- [ ] Confirm the email channel from the Aug 1-2 drill still exists and is verified.
- [ ] Paste: channel name/ID + verified status.

## B2. Alert policies live? (Monitoring → Alerting → Policies)

- [ ] Confirm these policies exist and are enabled: "OpenBurnBar Callable error spike",
      "OpenBurnBar Rollup rebuild breaker open", "OpenBurnBar Rollup delta drain capped"
      (names per `launch-evidence/alert-channel-verified.json`; note any renames).
- [ ] Paste: policy names + enabled status (screenshot or `gcloud alpha monitoring policies list` snippet).

## B3. Sentry rules test-fired? (Sentry → Alerts, rules per `docs/ops/SENTRY_ALERT_RULES.md`)

- [ ] Confirm each rule in SENTRY_ALERT_RULES.md exists in the BurnBar project.
- [ ] Test-fire ONE rule (or show its last-fired/dry-run timestamp).
- [ ] Paste: rule names + last-fired evidence.

## B4. Billing budget set? (GCP Console → Billing → Budgets & alerts)

- [ ] Confirm a budget with alert thresholds exists on project `burnbar`.
- [ ] Paste: budget name + threshold percentages.

## H1. App Check enforcement on? (Firebase Console → App Check)

- [ ] Confirm enforcement is ON for the gated services (Functions + Firestore at minimum).
- [ ] Paste: per-service enforcement status (screenshot or list).

## H2. API-key restrictions? (GCP Console → APIs & Services → Credentials)

- [ ] Find the public web key used by `website/src/lib/firebaseClient.ts`.
- [ ] Confirm HTTP-referrer and/or API restrictions are set (not an unrestricted key).
- [ ] Paste: restriction summary (redact the key itself).

## G-receipts. Data-safety evidence (paste CLI output or screenshots)

- [ ] PITR status: `gcloud firestore databases describe --project=burnbar` (point-in-time recovery field).
- [ ] Delete protection: same output (deletion protection field).
- [ ] Paste both outputs (redact anything sensitive).

## Sign-off (one line each, paste as text)

- [ ] Single-region acceptance: "Accepted: us-central1-only for Functions; failover is a
      future project, not a launch gate." (or your own wording)
- [ ] `break_glass` tightening approved if Stream A/F proposes owner-only/dual-approval.

Reference docs: `docs/runbooks/oncall.md`, `docs/ops/SENTRY_ALERT_RULES.md`,
`docs/runbooks/firestore-disaster-recovery.md`, `launch-evidence/alert-channel-verified.json`.
