# Computer Use — audit chain dispute runbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § Decision 8 · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md) § 5

When a user claims an action was unauthorized:

1. **Collect the export.** Ask for `~/Downloads/cu-<sessionId>.tar.gz` and its `{archive}.sig.json` sidecar. The current implementation signs with an OpenBurnBar trusted-device Ed25519 export key stored in the local Keychain (`WhenUnlockedThisDeviceOnly`). The sidecar must include `signerKind = openburnbar_trusted_device`, `trustRoot = openburnbar-trusted-device-keychain-v1`, `publicKeyBase64`, and `publicKeySHA256Hex`; verification fails if the public-key hash no longer matches.
2. **Validate the chain.** `swift run validate-computer-use-audit-chain <unpacked-dir>` — runs `ComputerUseAuditChain.validate(at:sessionManifestHashHex:expectedHeadHashHex:)` and prints the result.
3. **Read back the signer.** Read `users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}` using the hash from the sidecar. Confirm the parent `escrow_devices/{deviceId}` is still `trustState = trusted`, `platform = macOS`, and the signer record is `status = active`. `ComputerUseAuditExportWriter.verify(..., signatureTrust: .trustedDeviceReadback(record))` rejects revoked or mismatched readback records.
4. **Cross-reference the server-side rollup.** Read `users/{uid}/computer_use_sessions/{sessionId}` for the manifest hash and `users/{uid}/computer_use_actions/*` for the per-action audit headers (which carry parent-hash + descriptor-hash but never screenshots).
5. **Check OpenTimestamps** (Phase 13 sessions only): call `validateOpenTimestampsProof` with the signed-in user's UID, session ID, audit head hash, `.ots` proof bytes, and optional `chain.jsonl` bytes. The function first checks the submitted head against `users/{uid}/computer_use_sessions/{sessionId}.auditHeadHashHex`, then runs `ots verify chain.jsonl.ots` if the runtime has the OpenTimestamps CLI installed. If it returns `ots_verifier_unavailable`, run `ots verify chain.jsonl.ots` from a support workstation that has the official verifier.
6. **Diff.** If chain validates, signer readback is active, and rollup matches, the action was authorized. The audit summary, screenshot hash, and approving surface (`mac` / `phone` / `trusted_scope`) are all in the entry.
7. **If chain does NOT validate:** the export was tampered with locally — non-repudiable proof of post-hoc edit. Capture the `firstInvalidEntryIndex` + `firstInvalidReason` and surface it to the user.
8. **If chain validates but the user still disputes:** check `approvedBy`. Was it `phone` while the user was at lunch? Their paired iPhone may have been operated by someone else — pivot to the device-pairing audit (see `media-rollout-status.md` § pairing rotation).

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
