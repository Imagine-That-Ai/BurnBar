# BurnBar HPKE v3 Swift Agent Prompt

Goal: Implement Swift-side RFC 9180 HPKE Auth mode v3 relay key wrapping and
emit the canonical Swift-generated v3 wire vectors consumed by Hermes Python.

Claude launch: run this workstream through Claude from the tmux `swift` window
with the literal keyword `ultracode` in the prompt.

Success means:

- Swift uses the same v3 suite, `info`, AAD, X9.63 point encoding, and envelope
  field names as Python.
- Swift opens Python-generated v3 envelopes.
- Python opens Swift-generated v3 envelopes.
- Swift emits vectors for event, reply/message, model switch, attachment
  manifest, and attachment body key.
- The vector suite includes wrong-sender rejection using a pinned sender key.
- Current payload schema fields appear in the fixture plaintexts.

Stop when:

- Swift unit tests pass.
- Python opens every positive Swift vector and rejects every negative Swift
  vector.
- The generated fixture is committed or handed off with the generator command.

Constraints:

- Use `relayKeyVersion = 3` and
  `relayEncryption = "hpke-auth-p256-hkdfsha256-aes256gcm"`.
- Use `info = "OpenBurnBar-HermesRelay-HPKE-v3|" || key_aad`.
- Use HPKE Auth mode, not base mode.
- Bind opens to the pinned sender key.
- Preserve the safety-code and pairing UX semantics.

## Context

The Python PR needs a vector generated outside Python. A Python round trip proves
the implementation is internally consistent; a Swift-emitted fixture proves the
BurnBar phone and Hermes agent agree on bytes.

## Required Fixture Coverage

Emit one fixture file that includes:

- static agent recipient key pair
- static phone sender key pair
- positive event envelope
- positive reply/message envelope
- positive model-switch envelope
- positive attachment manifest envelope
- positive attachment body-key envelope
- negative wrong pinned sender case
- negative wrong AAD case
- negative mutated `enc` case
- negative mutated `wrappedKey` case

Each plaintext that represents an inbound event must include:

- `destinationId`
- `replayCounter` or `eventCounter`
- current control payload shape for model switching or approval flows where
  applicable

## Implementation Steps

1. Read the Python v3 plan and the current Swift relay crypto implementation.
2. Map Swift crypto APIs to the chosen RFC 9180 suite.
3. Implement v3 key wrap as content-key HPKE Auth seal/open.
4. Keep payload and attachment AES-GCM sealing unchanged.
5. Add a vector generator command or test fixture builder that emits stable JSON.
6. Include raw public keys in X9.63 format and base64-encoded binary fields.
7. Run Swift tests.
8. Run the Python vector verifier against the Swift fixture.
9. Record the exact command that regenerates the fixture.

## Handoff Output

Return:

- Swift files changed
- fixture path
- generator command
- Swift test command and result
- Python verifier command and result
- any platform API limitation that affects RFC 9180 byte parity
