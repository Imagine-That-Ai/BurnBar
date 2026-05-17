# Computer Use — quota dispute runbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § E.2 · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md)

## "I never ran that action"

1. The user gives you a session ID (visible in Settings → Computer Use → Recent sessions).
2. Ask the user to export the audit chain: Settings → Computer Use → "Export audit log" → save as `~/Downloads/cu-<sessionId>.tar.gz`.
3. Open the export — it contains `manifest.json`, `chain.jsonl`, `head.json`, and `screenshots/`.
4. Run validation: `swift run validate-computer-use-audit-chain <unpacked-dir>` (CLI lives in `OpenBurnBarDaemon`; thin wrapper around `ComputerUseAuditChain.validate(at:sessionManifestHashHex:expectedHeadHashHex:)`).
5. If validation green:
   - Every action in `chain.jsonl` was committed with the user's Mac present and the iroh peer connection live.
   - Cross-reference each `approvedBy` field — `"mac"` means the Mac UI sheet was tapped; `"phone"` means the paired iPhone was tapped; `"trusted_scope"` means the action matched an active allow rule at runtime.
6. If validation red:
   - **Tampered chain.** The user (or someone with file-system access) modified an entry post-hoc. The on-device chain is non-repudiable to the level of SHA-256.
   - Capture the validator's `firstInvalidEntryIndex` + `firstInvalidReason` in the support ticket.

## "I never got that many actions"

1. Cross-check the per-day rollup: `users/{uid}/computer_use_quota_usage/<YYYY-MM-DD>.browserActionsExecuted + systemActionsExecuted`.
2. Compare against `len(chain.jsonl)` for each session that day — the totals must match.
3. If they don't, run `recomputeComputerUseQuotaUsage` for the user + day. The cloud function reads the canonical `users/*/computer_use_actions/*` snapshots and rewrites the daily rollup.

## "Reset my daily counter"

1. We do not reset counters. The right path is: the user's complaint is either (a) a tampered chain, (b) a genuine bug in `evaluateComputerUseBudget` (see budget runbook), or (c) a feature request to raise the cap.
2. For (c), file a `feature_request:computer-use-cap-raise` ticket; the team reviews monthly.

## OpenTimestamps notarization (Phase 13)

For high-stakes disputes the user may opt-in to OpenTimestamps notarization. After Phase 13 ships, the audit chain root hash is submitted to a public Bitcoin timestamping service. To verify externally:

```bash
ots verify chain.jsonl.ots
```

A confirmed OpenTimestamps proof guarantees the chain hash existed at a specific Bitcoin block time. Combined with the SHA-256 parent-hash links, this is non-repudiable.
