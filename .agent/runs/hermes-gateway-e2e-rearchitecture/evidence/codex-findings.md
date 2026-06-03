# Codex adversarial review — gateway E2E (2026-06-03)
Two passes: (1) Challenge on fork crypto+adapter (relay_e2ee.py + adapter.py); (2) Review on BurnBar server+iOS. Both converged on a key-pinning MITM gap. Primitives sound (fresh nonces, curve validation, strong AAD); holes are protocol-layer.

## P1 (must fix — defeats/downgrades E2E)
1. KEY PINNING (adapter absorbs peer key from unauthenticated senderPublicKey + _absorb_relay_state from /events,/state,/destinations; server handleRuntimeStatus overwrites agentRelayPublicKey for any bearer holder) -> relay MITM. Fix: pin at pairing (TOFU), reject post-pairing key change. adapter.py:561/647/654/658 ; callables/hermesGateway.ts:724 ; hermesGateway.ts:760.
2. ADAPTER FAIL-OPEN: crypto/key load failure -> _relay_identity None -> must_seal false -> plaintext. Fix: fail-closed when E2E on. adapter.py:612/623/453/353/544.
3. STANDALONE BYPASS: _standalone_send seals nothing -> plaintext on paired links. adapter.py:1110/1127/1134.
4. KEY PERSISTENCE BROKEN: load_or_create persists only if persist= passed; adapter never passes it -> key rotates per restart. relay_e2ee.py:287/307/311 ; adapter.py:1229.
5. SERIALIZE ECHO: serializeHermesGatewayEvent returns text/senderDisplayName/threadId even when relayEnvelope present -> sealed-doc invariant broken for backfilled/admin docs. hermesGateway.ts:677.
6. NO REPLAY CACHE: relay can redeliver a valid sealed event. adapter.py:549/783.

## P2 (hardening)
7. ATTACHMENT AAD: manifest + body share AAD -> ciphertext swap. adapter.py:502/511. (CONTRACT specified distinct labels.)
8. SANITIZE READ: sanitizeGatewayRelayEnvelope accepts any strings/version on read. hermesGateway.ts:492.
9. KEY-VERSION: accepts 1..100 vs only v1 exists. callables/hermesGateway.ts:207.
10. MODEL_SWITCH cleartext on E2E links -> injectable control event. adapter.py:743/746.

## Confirmed GOOD
Fresh os.urandom(12) nonces; P-256 from_encoded_point validates curve; new server writes reject plaintext (gatewayPlaintextWriteAllowed hard-false); iOS open path FAILS CLOSED (no plaintext fallback for isSealed); iOS AAD binds uid+clientId+eventId/messageId.

DECISION (Alberto): Fix ALL P1+P2. Key rotation deferred (pin-only now).
