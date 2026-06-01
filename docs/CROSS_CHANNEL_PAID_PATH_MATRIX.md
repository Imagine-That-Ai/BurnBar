# Cross-Channel Paid-Path Matrix

`GTMMasterPlan.MD` T29 requires a real paid-path smoke matrix before canary:

- Stripe Cloud monthly.
- Stripe Cloud Pro annual.
- Apple Cloud purchase, restore, cancel, and refund.
- Apple Cloud Pro purchase plus top-up.
- Google Play Cloud purchase, restore, cancel, and refund.
- Google Play Cloud Pro purchase plus top-up.
- Legacy Hosted Quota Sync subscriber gets Group A only.
- Expired or canceled entitlement fails closed.

The artifact belongs at:

```bash
launch-evidence/cross-channel-paid-path-matrix.json
```

Validate it before canary:

```bash
scripts/validate-cross-channel-paid-path-matrix.mjs \
  launch-evidence/cross-channel-paid-path-matrix.json
```

Or capture/generate JSON from another tool and pipe it:

```bash
some-paid-path-matrix-command \
  | scripts/validate-cross-channel-paid-path-matrix.mjs -
```

To inspect the required shape:

```bash
scripts/validate-cross-channel-paid-path-matrix.mjs --template
```

The validator requires every T29 row to include live evidence paths, expected
entitlement IDs, product IDs, Group A/Group B gating results, and self-grant
denial evidence. Cloud Pro rows must also prove allowance/top-up state where
applicable.

The final launch evidence manifest also validates this matrix via
`scripts/validate-launch-evidence-bundle.mjs`; see
[`LAUNCH_EVIDENCE_BUNDLE.md`](LAUNCH_EVIDENCE_BUNDLE.md).
