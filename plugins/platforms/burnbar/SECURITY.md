# BurnBar Gateway Security Notes

This plugin treats BurnBar Cloud as an untrusted relay. The relay may reorder,
drop, duplicate, mutate, or inject gateway documents. It must not be able to read
sealed payload bodies or forge post-pairing v2 events without the sender's static
private key.

Maintainer note: compare the setup safety code. If the user clicks through
without comparing the code shown by Hermes and BurnBar, first-pairing MITM
protection is defeated.

## Protocol Shape

The v2 key wrap is HPKE-AuthEncap-shaped but is not RFC 9180 HPKE framing:

```text
ikm  = ECDH(ephemeral, recipient) || ECDH(senderStatic, recipient)
info = "OpenBurnBar-HermesRelay-KeyWrap-v2|" || aad || enc || recipientPub || senderPub
key  = HKDF-SHA256(ikm, zero-salt, info, 32)
wrap = AES-256-GCM(key, randomNonce, symmetricKey, aad)
```

The bespoke frame exists for Swift/Kotlin/Python byte compatibility with the
existing `HermesRelayCrypto` gateway vectors. If upstream wants standard HPKE,
that should be a new `relayKeyVersion` with new test vectors; v2 must remain
byte-stable.

## Fail-Closed Requirements

- E2E setup requires `uid`, `clientId`, and the phone relay public key from the
  authenticated device grant. Runtime `/events` or `/state` responses can
  confirm these AAD-binding values but cannot establish the first value.
- E2E open requires `relayKeyVersion == 2` and unwraps only with the pinned phone
  sender key. The relay-visible `senderPublicKey` field is advisory.
- Plaintext is refused in BOTH directions whenever it is forbidden on the link:
  once `BURNBAR_RELAY_E2E=1` (paired), and also when this agent holds a relay
  identity but the link is not yet E2E-paired (unless `BURNBAR_ALLOW_PLAINTEXT=1`).
  The inbound open path uses the same `must_seal` predicate as the send path, so a
  relay cannot drive the agent with an injected plaintext event/control by
  advertising an E2E-capable link as "legacy".
- Every inbound sealed E2E event must carry an authenticated
  `replayCounter` or `eventCounter`. The adapter persists a high-water mark plus
  a bounded id ledger and drops old counters before side effects.

## Non-Goals

- Static recipient-key compromise is out of scope. If the recipient static
  private key is stolen, past messages wrapped to that key can be decrypted and
  the attacker can forge as any sender.
- There is no post-compromise forward secrecy for the static leg. Store static
  keys in OS-protected storage and rotate by re-pairing.
- The relay still sees metadata: routing ids, event/message ids, timing, and
  approximate ciphertext sizes. This is relay-content confidentiality, not
  Signal-grade metadata privacy.
- AES-GCM does not provide replay rejection by itself. Replay rejection is an
  adapter ledger and counter policy.

## Vector Coverage

`tests/gateway/fixtures/HermesGatewayWireVector.json` proves Swift-to-Python
byte compatibility for v2 key wrapping and payload opening, including wrong
sender rejection. It is a crypto wire vector, not a complete current adapter
schema vector.

Before merge with a BurnBar client release that emits the strict E2E event
schema, refresh or add a Swift-emitted gateway vector whose event and
`model_switch` plaintext include:

- `destinationId`
- `replayCounter` or `eventCounter`
- the current control payload shape for approvals/model switches

The Python adapter tests enforce that current schema locally; the refreshed
Swift vector should prove cross-language byte compatibility for the same schema.
