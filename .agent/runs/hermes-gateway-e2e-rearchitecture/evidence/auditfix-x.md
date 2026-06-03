All work is complete and verified. `relay_e2ee.py` correctly required no changes (it is namespace-generic and takes AAD as a parameter; the gateway labels live in `adapter.py`).

## CHANGELOG

### `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`

**BLOCKER 1 — AAD alignment (canonical distinct payload-vs-key labels).** Already landed in the working tree and verified against the CONTRACT; I confirmed and kept it:
- Added `_gateway_event_key_aad` (`gatewayEventKey`) and `_gateway_message_key_aad` (`gatewayMessageKey`); removed the Python-only `_gateway_model_switch_aad` (`gatewayModelSwitch`).
- `seal_message` now wraps the symmetric key under `gatewayMessageKey` (payload stays `gatewayMessage`).
- `_open_envelope` takes a separate `key_aad_builder`; `open_event` unwraps under `gatewayEventKey` and opens under `gatewayEvent`.
- `open_model_switch` / `seal_model_switch` use the EVENT AADs (`gatewayEvent` payload + `gatewayEventKey` wrap), matching iOS sealing model_switch via the event sealer with `modelId` inside the event payload; refuse-unsealed-on-E2E preserved.
- Attachments already use the canonical distinct `gatewayAttachmentManifest`/`Body`/`Key` — verified, left as-is.
- Closes: result 2/3/5/6/9 BLOCKER "key-wrap AAD diverges / E2E dead on the wire" and the model_switch double-mismatch.

**HIGH — Replay dedup keying (verified).** `_handle_burnbar_event` keys dedup on `raw["id"] or envelope["eventId"]` — the SAME stable id `_open_envelope`'s AAD binds — and `_event_already_seen` runs before `open_event`/`handle_message`. Closes: result 6 HIGH "replay dedup bypass via stripped top-level id."

**HIGH — TOFU pin-jacking (new fix).**
- `_pin_peer_public_key` gained `allow_new_pin: bool = True`; when a NEW pin would be established from a source that passes `allow_new_pin=False`, it refuses (logs a security warning, returns False) instead of TOFU-seeding. The immutability guard (reject changed key, idempotent same key) is unchanged for all sources.
- `_absorb_relay_state` (fed by the untrusted `/destinations`, `/events`, `/state` live paths) now passes `allow_new_pin=False` and no longer lets `relayCapable`/`e2eEnabled` flip a never-paired agent into E2E.
- `_open_envelope`'s post-open `senderPublicKey` pin also passes `allow_new_pin=False` (the agent's public key is published, so a sealed inbound frame does not authenticate the carried sender key).
- The only NEW-pin path is the authenticated pairing seed: `interactive_setup`/device-grant writes `BURNBAR_RELAY_PEER_PUBLIC_KEY`, read directly into `self._peer_public_key` at `__init__` (before any runtime absorb). Closes: result 1 BLOCKER and result 10 HIGH "agent TOFU pin-jacking from untrusted relay when the persisted pin is absent" + "untrusted server flips a never-E2E agent into E2E."

### `/Users/albertonunez/.hermes/hermes-agent/gateway/crypto/relay_e2ee.py`
No change required and none made. The module is namespace-generic and accepts AAD bytes as parameters; all gateway-flavoured labels live in `adapter.py`. The shared Swift→Python interop vector (`test_relay_e2ee.py`, 33 tests) stays green, confirming the realtime-relay `request`/`key`/`chunk` path is untouched.

### `/Users/albertonunez/.hermes/hermes-agent/tests/gateway/test_burnbar_plugin.py`
- Existing same-language tests already updated to the CANONICAL labels (inbound event opens under `gatewayEvent`/`gatewayEventKey`; outbound message wraps under `gatewayMessageKey`; model_switch via event AADs; the locked-prefix test asserts 7 distinct labels and drops `gatewayModelSwitch`) — verified they now mirror Swift.
- Added 6 tests:
  - `test_sealed_redelivery_dropped_by_envelope_event_id` — a SEALED event with the top-level `id` stripped but `eventId` in the envelope opens once and every redelivery is dropped, keyed on the AAD-bound id (replay dedup).
  - `test_pin_peer_key_refuses_new_pin_from_untrusted_source` — `allow_new_pin=False` refuses a first pin; the pairing path still seeds it.
  - `test_absorb_relay_state_does_not_seed_pin_from_untrusted_destinations` — `/destinations`|`/state` cannot TOFU-seed a key when E2E is on and no pin exists.
  - `test_pin_jacking_refused_then_send_fails_closed` — full scenario: untrusted `/destinations` refused, then send fails closed (never plaintext, never sealed-to-attacker).
  - `test_untrusted_runtime_does_not_flip_unpaired_agent_into_e2e` — untrusted `relayCapable`/`e2eEnabled` cannot promote a never-paired agent or pin a key.
  - `test_absorb_relay_state_confirms_existing_pin_from_runtime` — a runtime re-advertisement of the pinned key is idempotently accepted.

**Tests run (repo `.venv`):** `test_burnbar_plugin.py` 44 passed; `test_relay_e2ee.py` 33 passed; both together 77 passed; `py_compile` clean on all three owned files. The 9 `aiohttp` collection errors elsewhere in `tests/gateway/` are pre-existing/environmental (no `aiohttp` in the venv) and unrelated to the owned files.