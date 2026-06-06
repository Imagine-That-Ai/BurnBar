# Relay wire vectors

Reproducible known-answer vectors for the BurnBar relay end-to-end-encryption
key wrap (`plugins/platforms/burnbar/relay_e2ee.py`).

- `../fixtures/HermesRelayWireVector.json`: v1 realtime relay
  (anonymous, single-DH).
- `../fixtures/HermesGatewayWireVector.json`: v2 gateway
  (authenticated 2-DH), covering event, agent reply, model switch, and
  attachment frames.

## What these verify

`generate_wire_vectors.py` seals fixed plaintexts under fixed static keys, fixed
ephemerals, and fixed nonces, so every ciphertext byte is a deterministic
function of inputs the file (and the fixtures) make explicit. This **pins the
Python implementation against a fixed, reproducible target**: no silent wire-format
drift, and any maintainer can re-derive every byte with no non-Python toolchain.

It does **not**, by itself, prove the BurnBar iOS (CryptoKit) / Android clients
interoperate; no non-Python implementation is vendored here. Those clients
implement the same wire format (AAD labels, X9.63 key encoding, the v2 2-DH wrap);
cross-language parity is maintained in the client repositories.

## Regenerate / verify

```bash
# verify the committed fixtures reproduce byte-for-byte (also run by the suite,
# see ../test_wire_vectors_reproducible.py)
python -m tests.gateway.vectors.generate_wire_vectors --check

# regenerate after an intentional change to a plaintext / id / key
python -m tests.gateway.vectors.generate_wire_vectors --write
```

`--check` is enforced in CI via `test_wire_vectors_reproducible.py`, so a fixture
can never drift from the generator without a red test.

## How it works

* **Inputs vs outputs.** Each fixture carries human-readable *inputs* (ids,
  plaintexts, static private keys, symmetric keys) verbatim. The generator owns
  only the *crypto-output* fields, listed in the `_*_OUTPUT_FIELDS` tuples and
  enforced by `_assert_output_fields`, so a forgotten or stray output fails loudly.
* **Determinism.** `_deterministic()` patches the two randomness sources in a
  seal/wrap, the 12-byte GCM nonce (`os.urandom`) and the per-wrap ephemeral key
  (`ec.generate_private_key`), with a counter-driven stream. ECDH, HKDF, and
  AES-GCM (with a fixed nonce) are already deterministic, so the emitted bytes are
  stable and independent of the host's RNG. Patches are confined to the generator
  and its test; production code is never touched.
* **Two parties.** In the v2 gateway vector, `event.recipientPrivateKey` is the
  agent and `message.recipientPrivateKey` is the phone; senders are bound per slot
  (phone-to-agent for event/model_switch, agent-to-phone for reply/attachment), mirroring
  the adapter's send paths.

## Adding a slot

1. Add the slot's inputs (ids, plaintext, keys) to the relevant fixture.
2. Extend the builder in `generate_wire_vectors.py` (and `_*_OUTPUT_FIELDS` if the
   slot has a new output shape).
3. `python -m tests.gateway.vectors.generate_wire_vectors --write`, then add an
   `open`/forge test in `../test_relay_e2ee*.py`.
