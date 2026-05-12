# Pi Agent Backend Contract

Pi Agent is a sibling runtime to Hermes. It follows the same pairing, relay, model-discovery, and selected-host pattern, but it does not share Firestore collections, relay encryption namespaces, keychain service identifiers, or rate-limit buckets with Hermes.

## Firestore Collections

All user-scoped Pi documents live under `users/{uid}`:

- `pi_agent_connections/{connectionID}`: published Pi hosts. Relay hosts include `relayPublicKey`, `relayKeyVersion`, `relayEncryption`, `instances`, `models`, and optional realtime metadata.
- `pi_agent_pairings/{pairingID}`: short-lived pairing sessions. Pairing codes are stored only as SHA-256 digests and expire through `expireAt`.
- `pi_agent_relay_requests/{requestID}`: encrypted relay requests for selected Pi hosts.
- `pi_agent_relay_requests/{requestID}/chunks/{chunkID}`: encrypted relay response chunks.
- `pi_agent_audit_events/{eventID}`: server-written audit trail for pairing and connection state changes.
- `runtime_connection_preferences/{deviceID}_{runtimeKind}`: per-device runtime selection for `hermes` and `piAgent`.
- `provider_account_device_links/{accountID}_{deviceID}`: provider-account-to-device links. `ProviderAccountDoc.sourceDeviceID` remains compatibility data, but new readers should prefer this collection.

## Cloud Functions

Pi callables:

- `createPiAgentPairing`
- `completePiAgentPairing`
- `listPiAgentConnections`
- `revokePiAgentConnection`
- `updatePiAgentConnectionStatus`

Provider multi-device callables:

- `adoptProviderAccountForDevice`
- `revokeProviderAccountDeviceLink`
- `backfillProviderAccountDeviceLinks`
- `backfillProviderAccountDeviceLinksScheduled`

All Pi connection callables require an authenticated user and hosted quota entitlement. Pairing, completion, revoke, and status update calls use Pi-specific rate-limit buckets.

## Relay Encryption

Pi relay requests require encrypted v2 payloads:

- request fields: `payloadCiphertext`, `wrappedKey`, `relayEncryption`, `relayKeyVersion`
- chunk field: `ciphertext`
- no plaintext `body`, `data`, `text`, or `error` is accepted for Pi relay writes

The Swift crypto namespace is `PiAgentRelayCrypto`, with separate AAD strings from Hermes. A Hermes-encrypted relay payload must not decrypt through the Pi path, and a Pi payload must not decrypt through the Hermes path.

## Host Runtime

macOS publishes Pi hosts through `PiAgentCloudRelayHostService`. The service probes `PiAgentRuntimeAdapter` at `http://127.0.0.1:8765` by default, advertises discovered instances and models, and forwards encrypted relay operations to the selected Pi gateway instance.

## Client Preferences

Clients should store selected runtime state in:

`users/{uid}/runtime_connection_preferences/{deviceID}_{runtimeKind}`

For example, a single device can independently store `iphone-1_hermes` and `iphone-1_piAgent`, keeping separate selected connection, instance, and model IDs.
