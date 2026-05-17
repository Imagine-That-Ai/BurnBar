# Computer Use — audit chain dispute runbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § Decision 8 · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md) § 5

When a user claims an action was unauthorized:

1. **Collect the export.** Ask for `~/Downloads/cu-<sessionId>.tar.gz`. The export ships under their iCloud device-bound signature — verify the signature first.
2. **Validate the chain.** `swift run validate-computer-use-audit-chain <unpacked-dir>` — runs `ComputerUseAuditChain.validate(at:sessionManifestHashHex:expectedHeadHashHex:)` and prints the result.
3. **Cross-reference the server-side rollup.** Read `users/{uid}/computer_use_sessions/{sessionId}` for the manifest hash and `users/{uid}/computer_use_actions/*` for the per-action audit headers (which carry parent-hash + descriptor-hash but never screenshots).
4. **Check OpenTimestamps** (Phase 13 sessions only): `ots verify chain.jsonl.ots`. A confirmed proof is non-repudiable.
5. **Diff.** If chain validates and rolls up matches, the action was authorized. The audit summary, screenshot hash, and approving surface (`mac` / `phone` / `trusted_scope`) are all in the entry.
6. **If chain does NOT validate:** the export was tampered with locally — non-repudiable proof of post-hoc edit. Capture the `firstInvalidEntryIndex` + `firstInvalidReason` and surface it to the user.
7. **If chain validates but the user still disputes:** check `approvedBy`. Was it `phone` while the user was at lunch? Their paired iPhone may have been operated by someone else — pivot to the device-pairing audit (see `media-rollout-status.md` § pairing rotation).

## What the audit chain proves

- **Yes:** every action was committed on the user's Mac, after passing through the capability gate, in temporal order.
- **Yes:** the action descriptor (selector, coords, URL) has not been mutated since commit.
- **Yes:** the approval source for each action.
- **No:** the chain does not prove the human at the keyboard was the legitimate user. Device-pairing rotation is the answer to that question.

## What the audit chain does not prove

- The browser tool's actual page state at the moment of action (the screenshot hash is content-addressed but the screenshot file itself can be deleted from disk without breaking the chain).
- Whether the user *intended* the outcome — only whether they approved the input.

## Escalation

Disputes that cannot be resolved at L2 escalate to the security engineering rotation. Tag `cu-audit-dispute` in the ticket and link the validated chain export.
