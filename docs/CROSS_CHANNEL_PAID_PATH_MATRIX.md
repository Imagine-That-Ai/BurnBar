# Cross-Channel Paid Path Matrix

`launch-evidence/cross-channel-paid-path-matrix.json` is the T29 proof that
Stripe, Apple, Google Play, legacy subscribers, cancellation, refund, and
fail-closed paths all behave the same way.

The final bundle validator requires this shape:

```json
{
  "schemaVersion": 1,
  "security": {
    "clientSelfGrantDenied": true
  },
  "rows": [
    {
      "id": "stripe_cloud_monthly",
      "ok": true,
      "evidence": [
        { "kind": "paid-proof", "path": "paid-proof-stripe_cloud.json" }
      ]
    }
  ]
}
```

## Required Rows

- `stripe_cloud_monthly`: Stripe Cloud monthly purchase writes active
  `burnbar_pro`; Group A works; Group B remains denied.
- `stripe_cloud_pro_annual`: Stripe Cloud Pro annual purchase writes active
  `burnbar_pro_max`; Group A and Group B work; allowance ledger exists.
- `apple_cloud_restore_cancel_refund`: Apple Cloud purchase, restore, cancel,
  and refund reconcile to the correct `burnbar_pro` state.
- `apple_cloud_pro_topup`: Apple Cloud Pro purchase writes `burnbar_pro_max`;
  top-up credit appears in the allowance ledger.
- `google_play_cloud_restore_cancel_refund`: Google Play Cloud purchase,
  restore, cancel, and refund reconcile to the correct `burnbar_pro` state.
- `google_play_cloud_pro_topup`: Google Play Cloud Pro purchase writes
  `burnbar_pro_max`; top-up credit appears in the allowance ledger.
- `legacy_hosted_quota_group_a_only`: legacy $4.99 Hosted Quota Sync keeps
  Group A only and never unlocks Floo or Agent Control.
- `expired_canceled_fail_closed`: expired or canceled entitlement denies Cloud,
  Floo relay, and hosted Agent Control before hosted resources run.

Every row must include at least one evidence object with a stable local path or
URL. Use redacted transaction IDs, UID hashes, purchase token hashes, and
Firestore paths when recording production proof.

Run:

```bash
scripts/validate-launch-evidence-bundle.mjs --stage paid-proof launch-evidence/final-launch-evidence.json
```

The paid-proof stage fails until this matrix and all six live paid proofs pass.
