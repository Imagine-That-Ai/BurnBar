# BurnBar HPKE v3 Vector Agent Prompt

Goal: Produce the canonical HPKE v3 cross-language vector suite and verifier
that prove BurnBar Swift and Hermes Python agree on relay bytes.

Claude launch: run this workstream through Claude from the tmux `vectors`
window with the literal keyword `ultracode` in the prompt.

Success means:

- The positive vectors are generated outside Python, preferably by Swift.
- Python verifies every positive vector.
- Python rejects every negative vector.
- Vectors cover event, reply/message, model switch, attachment manifest, and
  attachment body-key wrapping.
- Fixture plaintexts use the current strict schema, including routing IDs and
  replay counters.
- Fixture metadata records suite, version, key encodings, generator language,
  and generator command.

Stop when:

- `venv/bin/python -m pytest tests/gateway/test_burnbar_hpke_v3_vectors.py -q`
  passes.
- The fixture can be regenerated from a documented command.
- A reviewer can inspect the JSON and identify every authenticated field.

Constraints:

- Generate production-shaped wire envelopes.
- Use the shared v3 algorithm marker:
  `hpke-auth-p256-hkdfsha256-aes256gcm`.
- Keep binary fields base64 encoded.
- Keep public keys in uncompressed X9.63 form before base64 encoding.

## Fixture Shape

Create or update a fixture similar to:

```json
{
  "schemaVersion": 1,
  "relayKeyVersion": 3,
  "relayEncryption": "hpke-auth-p256-hkdfsha256-aes256gcm",
  "suite": {
    "mode": "auth",
    "kem": "DHKEM_P256_HKDF_SHA256",
    "kdf": "HKDF_SHA256",
    "aead": "AES_256_GCM"
  },
  "generator": {
    "language": "swift",
    "command": "<exact command>"
  },
  "keys": {
    "agentRecipientPublicKeyX963": "<base64>",
    "phoneSenderPublicKeyX963": "<base64>"
  },
  "cases": []
}
```

Each positive case includes:

```json
{
  "name": "event",
  "aad": "<base64>",
  "plaintextContentKey": "<base64>",
  "enc": "<base64>",
  "wrappedKey": "<base64>",
  "payloadPlaintext": "<json string or base64 bytes>",
  "expected": "open"
}
```

Each negative case includes:

```json
{
  "name": "wrong_sender",
  "derivedFrom": "event",
  "mutation": "pinned_sender_public_key",
  "expected": "reject"
}
```

## Required Positive Cases

- `phone_event_text`
- `phone_event_model_switch`
- `agent_reply_text`
- `agent_reply_attachment_manifest`
- `agent_reply_attachment_body_key`

## Required Negative Cases

- `wrong_pinned_sender_key`
- `wrong_recipient_key`
- `wrong_key_aad`
- `mutated_enc`
- `mutated_wrapped_key`
- `version_changed_to_2`
- `version_changed_to_1`
- `missing_enc`
- `missing_relay_encryption`

## Verifier Requirements

The Python verifier should:

- Load fixture JSON.
- Decode base64 fields.
- Open each positive v3 wrap using the pinned sender key from fixture metadata.
- Compare the unwrapped content key byte-for-byte.
- Apply each negative mutation and assert authentication failure or fail-closed
  parser rejection.
- Assert strict-schema event payloads include `destinationId` and
  `replayCounter` or `eventCounter`.

## Handoff Output

Return:

- fixture path
- generator command
- verifier path
- verifier test command and result
- list of positive and negative cases
