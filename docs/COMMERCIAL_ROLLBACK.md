# Commercial Rollback Runbook

This runbook is the single operator path for rolling back the two-tier
commercial launch: Free Local, BurnBar Cloud, and BurnBar Cloud Pro. It layers
paid-tier controls on top of the general release rollback procedure in
[`RELEASE_ROLLBACK.md`](RELEASE_ROLLBACK.md).

Use this when revenue, entitlement, hosted quota, media relay, Computer Use, or
store distribution behavior is unsafe after launch.

## Rollback Triggers

Page the operator and enter rollback mode when any of these stay true for two
consecutive checks, unless the trigger is marked immediate:

| Trigger | Threshold | First action |
|---|---:|---|
| Cloud Pro gross margin | Less than 50% for 2 hours | Freeze new Cloud Pro promotion and tighten hosted caps |
| Media projected spend | Greater than $600 month-end projection | Let `evaluateMediaBudget` tighten the media envelope |
| Media hard spend | Greater than $1000 month-end projection | Immediate: set `media_kill_switch=true` |
| Computer Use projected spend | Greater than $1500 month-end projection | Let `evaluateComputerUseBudget` tighten the envelope |
| Computer Use hard spend | Greater than $2500 month-end projection | Immediate: set `computer_use_kill_switch=true` |
| App Check denied requests | Greater than 1% of commercial Firebase calls | Pause hosted purchase promotion and inspect clients |
| Entitlement mismatch | Greater than 0.5% of entitlement checks | Disable self-serve upgrade entry points |
| Stripe webhook failure | More than 5 minutes without successful delivery | Disable Stripe checkout links |
| Apple or Play rejection after release | Any live paid surface affected | Hide the affected store product from new purchasers |
| Security incident | Confirmed secret, auth, or billing abuse | Immediate: kill hosted features and follow incident response |

## Immediate Kill Switches

Remote Config is the fastest commercial rollback lever because clients poll it
and the budget functions also enforce it server-side.

```bash
firebase remoteconfig:get --project burnbar > /tmp/openburnbar-rc.json
```

Edit `/tmp/openburnbar-rc.json` so these parameters are present:

```json
{
  "media_kill_switch": "true",
  "computer_use_kill_switch": "true",
  "hosted_quota_daily_refresh_limit": "0",
  "hosted_quota_monthly_refresh_limit": "0"
}
```

Publish the rollback config:

```bash
firebase remoteconfig:set --project burnbar --config /tmp/openburnbar-rc.json
```

Expected behavior:

- Media sessions deny new starts and in-flight sessions terminate within 60 s.
- Computer Use denies new hosted vision actions and active sessions halt within
  60 s.
- Hosted quota refreshes fail closed instead of spending server budget.
- Local-only Free features continue to work.

## Hosting Rollback

Use Firebase Hosting clone when public copy, pricing, legal, or download pages
overclaim availability.

Dry-run inspection:

```bash
firebase hosting:releases:list --project burnbar --site burnbar --limit 5
```

Rollback to the last known-good release:

```bash
firebase hosting:clone \
  burnbar:burnbar:<SOURCE_RELEASE_VERSION> \
  burnbar:burnbar \
  --project burnbar
```

After cloning, verify:

```bash
curl -fsSL https://burnbar.ai/pricing | rg 'BurnBar Cloud|BurnBar Cloud Pro'
curl -fsSL https://burnbar.ai/legal/terms | rg 'BurnBar Cloud|refund|cancel'
```

## Functions Rollback

If the break is in entitlements, webhooks, App Store reconciliation, Google Play
verification, quota refresh, budget evaluation, or COGS monitoring, deploy the
previous known-good Functions artifact or commit.

Dry-run build from current checkout:

```bash
npm --prefix functions run build
```

Rollback deploy from a known-good tag or commit:

```bash
git fetch origin --tags
git switch --detach <KNOWN_GOOD_TAG_OR_SHA>
npm --prefix functions ci
npm --prefix functions run build
firebase deploy --project burnbar --only functions
```

Return to the working branch after deploy:

```bash
git switch -
```

Then run:

```bash
scripts/capture-commercial-launch-evidence.mjs
```

The captured gate must show whether the rollback restored or intentionally
disabled each commercial surface.

## Cloud Run Quota Runner Rollback

If the hosted quota runner is the failing component, move all traffic back to
the previous Cloud Run revision:

```bash
gcloud run revisions list \
  --project burnbar \
  --region us-central1 \
  --service openburnbar-quota-runner

gcloud run services update-traffic openburnbar-quota-runner \
  --project burnbar \
  --region us-central1 \
  --to-revisions <PREVIOUS_REVISION>=100
```

Verify:

```bash
gcloud run services describe openburnbar-quota-runner \
  --project burnbar \
  --region us-central1 \
  --format='value(status.traffic)'
```

## Stripe Controls

For Stripe checkout or entitlement failures:

1. Disable new public checkout entry points in the website or Remote Config.
2. Leave existing subscriptions intact unless legal or support instructs
   otherwise.
3. In Stripe Dashboard, archive the bad Price only after a replacement Price is
   live and mapped by Functions config.
4. Re-deliver failed webhook events after Functions are restored.
5. Verify a paid proof through the capture helper:

```bash
OPENBURNBAR_PROOF_UID="FIREBASE_UID" \
npm --prefix functions run prove:paid-tier -- \
  --project burnbar \
  --tier cloud \
  --channel stripe \
  --external-subscription-id "STRIPE_SUBSCRIPTION_ID" \
  | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -
```

For Cloud Pro Stripe rollback recovery, change `--tier cloud` to
`--tier cloud-pro` and add `--require-allowance`. If the incident involved a
top-up, also add the matching `--require-top-up agent_control_actions_100` or
`--require-top-up floo_relay_50gb`.

## Apple And Google Play Controls

For store-product or reconciliation failures:

- Apple: remove the affected subscription or IAP from sale for new purchasers in
  App Store Connect. Keep the app version in manual release until paid proof is
  clean.
- Google Play: deactivate the affected base plan or offer for new purchasers in
  Play Console.
- Do not delete product IDs. The reconciler and gate depend on stable IDs for
  grandfathering and refund/cancel handling.
- Verify server notifications after any store-side change:

```bash
scripts/capture-commercial-launch-evidence.mjs
```

## macOS Release Rollback

For direct-download macOS artifacts, follow
[`RELEASE_ROLLBACK.md`](RELEASE_ROLLBACK.md). In commercial rollback mode the
fast path is:

```bash
gh release edit <BAD_TAG> --draft
scripts/tag-release.sh <HOTFIX_VERSION>
scripts/update-homebrew.sh <HOTFIX_VERSION>
```

Verify checksums, notarization, and the live download page before clearing the
incident.

## Drill Checklist

Run this drill quarterly and before public launch. Record the command output in
`launch-evidence/` or the incident ticket.

1. List recent Hosting releases and identify the previous release.
2. Export Remote Config and prepare a kill-switch patch without publishing it.
3. Build Functions from the current branch.
4. List Cloud Run revisions for `openburnbar-quota-runner`.
5. Confirm the Stripe, Apple, and Google Play rollback owner has console access.
6. Run `scripts/capture-commercial-launch-evidence.mjs`.
7. Run `bash scripts/ci/verify-ops-readiness.sh` and `node scripts/commercial-launch-gate.mjs` (expect `opsAlerts.ok`).

The drill passes when an on-call operator can execute each command, identify the
safe rollback target, and explain which customer-facing surfaces remain live.

Write the structured drill artifact at:

```bash
launch-evidence/rollback-drill.json
```

Generate the required shape:

```bash
scripts/validate-commercial-rollback-drill.mjs --template \
  > launch-evidence/rollback-drill.json
```

Validate it before adding the final launch evidence bundle:

```bash
scripts/validate-commercial-rollback-drill.mjs \
  launch-evidence/rollback-drill.json
```

The validator requires every commercial rollback trigger, the Remote Config
kill-switch patch, Hosting release listing, Functions build, Cloud Run revision
listing, commercial launch gate output, ops-readiness output, and Stripe/Apple/
Google Play owner-access evidence. Because this is a dry-run artifact,
`remoteConfigPublished` must stay `false`; attach command output paths instead
of publishing the rollback patch during the drill.

## Exit Criteria

Leave rollback mode only after:

- `media_kill_switch=false` and `computer_use_kill_switch=false` are safe to
  publish.
- Entitlement mismatch is below 0.5% for 1 hour.
- Stripe, Apple, and Google Play paid-path smoke tests pass.
- `scripts/commercial-launch-gate.mjs` no longer reports a commercial rollback
  blocker.
- The incident ticket links the final gate JSON, paid proof, and any customer
  comms.
