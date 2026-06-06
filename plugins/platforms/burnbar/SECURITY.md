# BurnBar Gateway Security Notes

This plugin treats BurnBar Cloud as an untrusted relay. The relay may reorder,
drop, duplicate, mutate, or inject gateway documents. It must not be able to read
sealed payload bodies or forge post-pairing v2 events without the sender's static
private key under the relay-only threat model; sender or recipient static-key
compromise is outside that scope and covered below.

Safety-code check: compare the setup safety code. If the user clicks through
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

This frame exists for compatibility with BurnBar's existing mobile relay wire
format. This repo verifies the Python side with vendored known-answer
vectors; mobile-client parity is maintained outside this repo. A standard-HPKE
migration should use a new `relayKeyVersion` with new test vectors so v2 stays
byte-stable.

AAD is a UTF-8 `|`-joined protocol label. Runtime builders reject `|` and control
characters in every dynamic part so two logical contexts cannot serialize to the
same byte string. A future format can move to a length-prefixed or canonical
encoding under a new `relayKeyVersion`.

## Fail-Closed Requirements

- E2E setup requires `uid`, `clientId`, and the phone relay public key from the
  authenticated device grant. Runtime `/events` or `/state` responses can
  confirm these AAD-binding values but cannot establish the first value.
- E2E open requires `relayKeyVersion == 2` and unwraps only with the pinned phone
  sender key. The relay-visible `senderPublicKey` field is advisory.
- Plaintext is refused in both directions whenever it is forbidden on the link:
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

`tests/gateway/fixtures/HermesGatewayWireVector.json` is an in-tree known-answer
vector for the v2 key wrap and payload opening (event, agent reply, model_switch,
and attachment slots), including wrong-sender and wrong-recipient rejection. Its
event and `model_switch` plaintexts already carry the strict E2E schema
(authenticated `destinationId` + `replayCounter`), and
`test_gateway_event_vector_passes_production_open_path` runs that slot through the
full production `_handle_burnbar_event` path — not merely the bare crypto open.

Both this and the v1 realtime vector (`HermesRelayWireVector.json`) are regenerated
and byte-verified in-tree by `tests/gateway/vectors/generate_wire_vectors.py`
(`python -m tests.gateway.vectors.generate_wire_vectors --check`, also enforced by
`tests/gateway/test_wire_vectors_reproducible.py`), so a maintainer can re-derive
every ciphertext byte from this repo alone with no non-Python toolchain. The same
wire format is implemented by the BurnBar iOS/Android clients; cross-language parity
is maintained in those client repositories and is not re-proven here.
