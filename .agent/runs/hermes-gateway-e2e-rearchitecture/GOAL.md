# Make Hermes Gateway truly end-to-end

Goal ID: `hermes-gateway-e2e-rearchitecture`
Started: 2026-06-03T05:14:34Z
Parent goal: privacy-leak-remediation-2026-06-02
Mode: full
Ledger path: `.agent/runs/hermes-gateway-e2e-rearchitecture/`

## Objective

Retire the open keyless bearer-token gateway adapter and route phone<->agent gateway messaging through the first-party encrypted relay (HermesRelayCrypto) so the server can no longer read gateway message/event text, sender names, or attachment files

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/hermes-gateway-e2e-rearchitecture/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Design basis

Full recon in the parent ledger: `.agent/runs/privacy-leak-remediation-2026-06-02/evidence/recon-gateway-architecture.md` (data flow, the keyless-third-party-adapter constraint, the three options). Crypto contract: parent `evidence/recon-crypto-primitives.md` (§6 relay = `HermesRelayCrypto` `p256-hkdf-sha256-aesgcm`, separate from the vault key).

**Decision (Alberto, 2026-06-03):** make it TRUE E2E — retire/deprecate the open bearer-token adapter (`tools/hermes-platform-burnbar/adapter.py`) and route phone↔agent gateway traffic through the already-E2E first-party relay (`hermes_relay_requests`/`HermesRelayHostService`). NOT honest-label; NOT vault-key-to-adapter.

## Finishing Criteria

- [todo] Decide the product shape: does the gateway keep an external-agent bridge at all (then the agent must become an ECIES relay endpoint publishing a `relayPublicKey`, per `relayRequestWrite`), or is it folded entirely into the first-party phone↔Mac relay? (Ask Alberto.)
- [todo] `hermes_gateway_messages/events/attachments` carry only `payloadCiphertext`/`wrappedKey`/`relayEncryption` (or are removed in favor of relay docs); `serializeHermesGatewayEvent` returns ciphertext; `handleMessageSend`/`enqueueHermesGatewayEvent`/`handleAttachmentInit` reject plaintext `text`/`senderDisplayName`/`fileName`; bump `HERMES_GATEWAY_SCHEMA_VERSION`.
- [todo] Phone client (`HermesSettingsView`/`FunctionsRepository`) seals on write + opens on read; attachment bytes sealed before the signed-URL upload.
- [todo] `firestore.rules` for `hermes_gateway_*` require the ciphertext shape (reject `text`/`fileName`/`senderDisplayName`); add emulator tests.
- [todo] Registry/website/docs flip the gateway from "server-readable bridge (interim)" to genuinely sealed; `connected_devices` `deviceOnly` line becomes fully true; remove the interim honesty caveat added in the parent goal.
- [todo] Migration: existing plaintext gateway docs scrubbed (extend `privacyBackfill` + scrubber) or TTL-expired; the adapter deprecation path is documented for existing users.
- [todo] Validation: gateway functions tests + rules tests + an end-to-end phone↔agent round-trip; re-run the parent privacy scan (which will then assert gateway sealing, not just honest labeling).
- [todo] Keep `implementation-notes.html` current; link bulky proof from `evidence/`.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

