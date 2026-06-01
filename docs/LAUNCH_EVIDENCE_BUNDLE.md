# Launch Evidence Bundle

`GTMMasterPlan.MD` is not complete until `launch-evidence/LAUNCH_DONE.md`
exists and every referenced artifact proves the live commercial launch. The
machine-checkable manifest is:

```bash
scripts/validate-launch-evidence-bundle.mjs --template \
  > launch-evidence/final-launch-evidence.json
```

Validate the staged evidence as it matures:

```bash
scripts/validate-launch-evidence-bundle.mjs --stage paid-proof launch-evidence/final-launch-evidence.json
scripts/validate-launch-evidence-bundle.mjs --stage public-release launch-evidence/final-launch-evidence.json
scripts/validate-launch-evidence-bundle.mjs --require-done-stamp launch-evidence/final-launch-evidence.json
```

## Required Artifact Set

- `launch-evidence/latest-commercial-launch-gate.json`
- Six live paid proofs: Apple Cloud, Apple Cloud Pro, Stripe Cloud, Stripe
  Cloud Pro, Google Play Cloud, Google Play Cloud Pro
- `launch-evidence/cross-channel-paid-path-matrix.json`
- Canary report with margin, App Check, entitlement failure, projected spend,
  dashboard, COGS, and incident-log evidence
- Public launch report with Remote Config, GitHub release, website deploy,
  launch-channel posts, entitlement gate, and top-up prepay evidence
- Refund/abuse report proving refunds, expirations, chargebacks, suspensions,
  quota throttling, and Remote MCP revocation
- Rollback drill report proving kill-switch patching, Hosting rollback,
  Functions build, Cloud Run revisions, launch gate, ops readiness, and console
  access
- Release IDs for iOS, Stripe, Google Play, and Hosting
- `launch-evidence/LAUNCH_DONE.md` linking the final manifest and all evidence

## Paid Proof Commands

Use the generic paid-tier proof for the new launch tiers:

```bash
npm --prefix functions run prove:paid-tier -- --uid "$UID" --tier cloud --channel apple \
  | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -

npm --prefix functions run prove:paid-tier -- --uid "$UID" --tier cloud-pro --channel stripe \
  | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -

npm --prefix functions run prove:paid-tier -- --uid "$UID" --tier cloud-pro --channel google_play \
  | scripts/capture-commercial-launch-evidence.mjs --kind paid-proof --input -
```

The legacy hosted-quota proof remains only for grandfathered
`com.openburnbar.hostedQuotaSync.cloud.monthly` users.

## Gate Progression

When the app is live in the store, `scripts/commercial-launch-gate.mjs` reports:

- `READY_FOR_LIVE_PAID_PROOF` until the paid-proof manifest passes
- `READY_FOR_CANARY` after live paid proofs and cross-channel matrix pass
- `READY_FOR_PUBLIC_RELEASE` after canary evidence passes
- `LAUNCH_DONE` only after the final manifest and `LAUNCH_DONE.md` validate

If the manifest exists but fails validation, the gate returns `NO_GO`.
