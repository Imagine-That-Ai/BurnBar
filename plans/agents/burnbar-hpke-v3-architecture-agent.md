# BurnBar HPKE v3 Architecture Guard Prompt

Goal: Freeze the HPKE v3 wire contract, compatibility policy, and security
invariants before implementation workers make code changes.

Claude launch: run this workstream through Claude from the tmux `architecture`
window with the literal keyword `ultracode` in the prompt.

Success means:

- Confirm the exact HPKE suite and mode.
- Confirm the field names and binary encodings.
- Confirm whether v3 wraps only content keys or directly seals payloads.
- Confirm sender-authentication source of truth.
- Confirm v2 compatibility and v1/plaintext refusal policy.
- Confirm capability negotiation fields and fallback behavior.
- Produce a short architecture note the orchestrator can enforce during
  integration.

Stop when:

- The architecture note is ready and every implementation stream can follow it
  without choosing protocol details.

Constraints:

- Keep this stream read-only unless the orchestrator explicitly asks for a doc
  update.
- Prefer RFC 9180 terminology.
- Keep the design minimal and compatible with the current gateway shape.

## Frozen Defaults

Use:

```text
Mode: Auth
KEM: DHKEM(P-256, HKDF-SHA256)
KDF: HKDF-SHA256
AEAD: AES-256-GCM
relayKeyVersion: 3
relayEncryption: hpke-auth-p256-hkdfsha256-aes256gcm
info: "OpenBurnBar-HermesRelay-HPKE-v3|" || key_aad
aad: key_aad
```

HPKE wraps only the 32-byte content key. Payload and attachment AES-GCM layers
remain unchanged.

## Handoff Output

Return:

```text
Protocol:
Wire fields:
Encodings:
Capability policy:
Fallback policy:
Security invariants:
Files that must follow this contract:
Open questions:
```

