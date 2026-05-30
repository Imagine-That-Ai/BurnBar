# Computer Use — audit chain dispute runbook

**Plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) § Decision 8 · **WS3:** [`plans/2026-05-30-sota-security-remediation.md`](../../plans/2026-05-30-sota-security-remediation.md) · **Reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md) § 5

When a user claims an action was unauthorized:

1. **Collect the export.** Ask for `cu-<sessionId>.tar.gz` and its `{archive}.sig.json` sidecar, or the raw session directory under `~/Library/Application Support/.../computer-use-audit/<sessionId>/`. The archive should contain `manifest.json`, `chain.jsonl`, `head.json`, **`signed_head.json`** (WS3), and optional `chain.jsonl.ots`.
2. **Run the offline verifier (no daemon, no trust in the Mac):**
   ```bash
   openburnbar-cli audit-verify /path/to/<sessionId> [--max-entry-index N] [--skip-opentimestamps]
   ```
   - Re-derives the parent-hash chain from `manifest.json` + `chain.jsonl`.
   - Pins the terminal head using `signed_head.json` (Ed25519 over `{sessionId, lastEntryIndex, headHashHex, closedAt}`).
   - When `chain.jsonl.ots` is present and `ots` is installed, runs `ots verify chain.jsonl.ots` in the session directory.
   - With `--max-entry-index N` (panic entry index **P**), asserts **no entry index > N** — the completeness proof for “nothing happened after the kill.”
3. **Read back the export signer.** Read `users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}` using the hash from `.sig.json`. Confirm the parent `escrow_devices/{deviceId}` is still `trustState = trusted`, `platform = macOS`, and the signer record is `status = active`.
4. **Cross-reference Firestore.** Read `users/{uid}/computer_use_sessions/{sessionId}` for `auditHeadHashHex` and `users/{uid}/computer_use_actions/*` for per-action audit headers.
5. **Server OpenTimestamps cross-check (optional):** call `validateOpenTimestampsProof` with UID, session ID, `auditHeadHashHex` from `signed_head.json`, `.ots` bytes, and optional `chain.jsonl`. Matches the head recorded server-side before running the configured OTS verifier (`OPENBURNBAR_OTS_VERIFY_URL` or local `ots`).
6. **Diff.** If `fully_verified=true` (and `no_entries_after_index=true` when panic-bound), the exported prefix is intact, signed, and (when anchored) timestamped. Inspect `approvedBy` on entry **P** and earlier rows.
7. **If verification fails:** capture `first_invalid_reason`, whether `head_signature_valid=false`, or `no_entries_after_index=false` — these distinguish tampering, unsigned heads, and post-panic forgery.
8. **If chain validates but the user still disputes:** check `approvedBy` and device-pairing rotation (see `media-rollout-status.md` § pairing rotation).

## Session directory layout (WS3)

| File | Role |
|------|------|
| `manifest.json` | Session-start manifest (chain genesis parent) |
| `chain.jsonl` | Append-only audit entries |
| `head.json` | Live head marker (`index`, `hashHex`) — updated during the session |
| `signed_head.json` | **Terminal signed head** written at session close, panic, or export |
| `chain.jsonl.ots` | OpenTimestamps proof (optional; digest = SHA-256 of `chain.jsonl`) |
| `chain.jsonl.ots.json` | Notarization metadata sidecar |

## What the anchored signed chain proves

- **Integrity:** parent-hash links + optional `signed_head.json` signature.
- **Completeness after panic P:** `signed_head.lastEntryIndex == P` and verifier `--max-entry-index P` with no extra lines in `chain.jsonl`.
- **External time ordering (when `.ots` verifies):** the chain file digest was committed to Bitcoin via OpenTimestamps before the proof was issued.

## What it does not prove

- The human at the keyboard was the legitimate user (pairing / approval surface only).
- Live page state at action time (screenshot hashes are optional and files may be deleted).

## Escalation

Disputes that cannot be resolved at L2 escalate to the security engineering rotation. Tag `cu-audit-dispute` in the ticket and attach verifier output plus the export.
