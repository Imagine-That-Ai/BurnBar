# BurnBar HPKE v3 Python Agent Prompt

Goal: Implement RFC 9180 HPKE Auth mode v3 key wrapping in the Hermes BurnBar
gateway while preserving v2 compatibility and the existing fail-closed paired
link behavior.

Claude launch: run this workstream through Claude from the tmux `python`
window with the literal keyword `ultracode` in the prompt.

Success means:

- Add a v3 key-wrap implementation using the suite
  `DHKEM(P-256, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM`.
- Keep HPKE scoped to content-key wrapping; keep payload and attachment
  AES-GCM sealing behavior unchanged.
- Open v3 with the pinned sender public key from pairing state.
- Emit v3 only for peers that advertise v3 capability.
- Preserve v2 receive/send compatibility for v2-only peers.
- Keep v1 and plaintext refused where E2EE is required.
- Add tests for v3 round trip, wrong sender, wrong recipient, wrong AAD,
  mutated `enc`, mutated `wrappedKey`, and downgrade attempts.
- Keep the existing gateway tests green.

Stop when:

- `venv/bin/python -m pytest tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py tests/gateway/test_relay_e2ee_v3.py tests/gateway/test_burnbar_plugin.py -q`
  passes.
- The diff contains the v3 implementation, tests, and docs needed for Python
  review with no unrelated refactor.

Constraints:

- Use existing Python crypto dependencies unless a blocking API gap is proven.
- Treat `senderPublicKey` from the envelope as diagnostic data.
- Bind authentication to the pinned peer sender key.
- Keep inbound replay counters mandatory for sealed paired-link events.
- Keep routing IDs rooted in the authenticated pairing grant.

## Context

Current v2 is authenticated and HPKE-shaped, but it is not RFC 9180 framing.
Nous reviewers will reasonably ask why upstream should accept a bespoke KEM.
This work answers that by adding a standard v3 while keeping v2 byte-stable for
existing clients.

## Required Wire Shape

Use these markers:

```text
relayKeyVersion = 3
relayEncryption = "hpke-auth-p256-hkdfsha256-aes256gcm"
```

Use this HPKE context:

```text
info = b"OpenBurnBar-HermesRelay-HPKE-v3|" + key_aad
aad  = key_aad
pt   = 32-byte content key
```

Use these envelope fields:

```json
{
  "enc": "<base64 HPKE encapsulated key>",
  "wrappedKey": "<base64 HPKE ciphertext>",
  "relayKeyVersion": 3,
  "relayEncryption": "hpke-auth-p256-hkdfsha256-aes256gcm",
  "senderPublicKey": "<base64 X9.63 public key>"
}
```

## Implementation Steps

1. Read `gateway/crypto/relay_e2ee.py`,
   `plugins/platforms/burnbar/adapter.py`, and the gateway tests before
   editing.
2. Add a small HPKE v3 module or v3 section beside the existing relay E2EE
   helpers.
3. Implement RFC 9180 Auth mode exactly for the chosen suite:
   key schedule labels, context construction, P-256 point encoding, HKDF, and
   AES-256-GCM.
4. Add typed v3 wrap/open helpers that return and consume explicit `enc` and
   `wrappedKey` fields.
5. Extend adapter capability selection so paired v3 peers receive v3 envelopes.
6. Extend adapter open logic so `relayKeyVersion == 3` uses v3 and binds the
   pinned sender key.
7. Add tests before broad integration:
   RFC/schedule vector, local v3 round trip, and all forged-input failures.
8. Add adapter tests for v3 send/open, v2 fallback, and downgrade rejection.
9. Update `plugins/platforms/burnbar/SECURITY.md` to describe v3 and keep v2
   compatibility language truthful.
10. Run the targeted pytest command and record the result in the handoff.

## Security Checks

- Verify v3 ciphertext fails with the wrong pinned sender key.
- Verify v3 ciphertext fails with the right wire `senderPublicKey` but wrong
  pinned key.
- Verify v3 ciphertext fails when the relay strips `relayKeyVersion` or changes
  it to `2` or `1`.
- Verify v3 ciphertext fails when `key_aad` routing IDs differ.
- Verify v2 envelopes continue to open for v2 peers and never auto-upgrade or
  auto-downgrade silently.

## Handoff Output

Return:

- files changed
- tests run
- exact v3 suite string
- exact remaining compatibility limits
- any blocker that prevents RFC 9180 conformance
