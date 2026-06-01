# Launch Evidence Bundle

`GTMMasterPlan.MD` is not complete until the final evidence bundle validates.
The bundle manifest belongs at:

```bash
launch-evidence/final-launch-evidence.json
```

Generate the required shape:

```bash
scripts/validate-launch-evidence-bundle.mjs --template \
  > launch-evidence/final-launch-evidence.json
```

Validate before writing `LAUNCH_DONE.md`:

```bash
scripts/validate-launch-evidence-bundle.mjs \
  launch-evidence/final-launch-evidence.json
```

Validate the pre-canary stage after paid proofs and T29 matrix:

```bash
scripts/validate-launch-evidence-bundle.mjs \
  --stage paid-proof \
  launch-evidence/final-launch-evidence.json
```

Validate the public-release stage after canary:

```bash
scripts/validate-launch-evidence-bundle.mjs \
  --stage public-release \
  launch-evidence/final-launch-evidence.json
```

Validate the final stamp:

```bash
scripts/validate-launch-evidence-bundle.mjs \
  --require-done-stamp \
  launch-evidence/final-launch-evidence.json
```

The manifest requires:

- Latest commercial launch gate JSON.
- Six real paid proof artifacts: Apple Cloud, Apple Cloud Pro, Stripe Cloud,
  Stripe Cloud Pro, Google Play Cloud, and Google Play Cloud Pro.
- Valid T29 cross-channel matrix at
  `launch-evidence/cross-channel-paid-path-matrix.json`.
- Canary report validated by `scripts/validate-commercial-canary-report.mjs`.
  It must prove no open P0/P1, at least 72 hours or 25 paid users, Cloud gross
  margin >= 80%, Cloud Pro gross margin >= 50%, App Check denied < 1%,
  entitlement failures < 0.5%, and media/Computer Use projections below the
  soft caps.
- Rollback drill evidence validated by
  `scripts/validate-commercial-rollback-drill.mjs`.
- App Store, Stripe, Google Play, and website release IDs, plus public launch
  evidence validated by `scripts/validate-public-launch-report.mjs`.
- At least one dashboard artifact for revenue/margin/ops readback.

`LAUNCH_DONE.md` should only be created after the validator passes without
`--require-done-stamp`. The final `--require-done-stamp` run confirms that the
done stamp links the manifest, paid proofs, matrix, canary, rollback drill, and
launch gate artifacts it claims.

`scripts/commercial-launch-gate.mjs` reads this manifest when present:

- Missing manifest: the live app can reach `READY_FOR_LIVE_PAID_PROOF`.
- `--stage paid-proof` valid: the gate can reach `READY_FOR_CANARY`.
- `--stage public-release` valid: the gate can reach `READY_FOR_PUBLIC_RELEASE`.
- `--require-done-stamp` valid: the final `LAUNCH_DONE.md` references are
  consistent with the evidence bundle.

Canary report helper:

```bash
scripts/validate-commercial-canary-report.mjs --template \
  > launch-evidence/canary-report.json

scripts/validate-commercial-canary-report.mjs \
  launch-evidence/canary-report.json
```

Public launch report helper:

```bash
scripts/validate-public-launch-report.mjs --template \
  > launch-evidence/public-launch-report.json

scripts/validate-public-launch-report.mjs \
  launch-evidence/public-launch-report.json
```

The public launch report proves `public_paid_launch=true`,
`paid_canary_percent=100`, GitHub release publication, website deployment,
pricing/legal HTTP 200 captures, launch-channel posts, top-up prepay
enforcement, entitlement-gate verification, and live monitoring dashboards.
