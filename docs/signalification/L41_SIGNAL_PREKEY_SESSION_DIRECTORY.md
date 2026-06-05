# L41 Signal Identity, Prekey, Session Directory, and Rotation

Status: server/rules contract implemented; no production client producer is wired yet.

This document closes the server-side shape of L41 without touching native/mobile
key storage. It defines where Signal public identity material, signed prekeys,
one-time prekeys, Kyber prekeys, session metadata, and rotation evidence live in
Firestore, and what the rules must reject.

## Current baseline

The first L41 pass added:

- `users/{uid}/signal_identity_public_keys/{identityKeyId}`
- v1 document ID format: `{deviceId}_1`
- `algorithm == "signal-hpke-identity-seal-v1"`
- `keyVersion == escrow_devices/{deviceId}.keyVersion`
- update/delete denied

That was enough to separate Signal identity keys from legacy P-256
`escrow_public_keys`, but it was not enough for a full Signal lifecycle.

## Firestore paths

All broader L41 material stays under the existing top-level collection, so the
data-domain registry remains stable:

```text
users/{uid}/signal_identity_public_keys/{identityKeyId}
users/{uid}/signal_identity_public_keys/{identityKeyId}/signed_prekeys/{signedPreKeyId}
users/{uid}/signal_identity_public_keys/{identityKeyId}/one_time_prekeys/{oneTimePreKeyId}
users/{uid}/signal_identity_public_keys/{identityKeyId}/kyber_prekeys/{kyberPreKeyId}
users/{uid}/signal_identity_public_keys/{identityKeyId}/sessions/{sessionId}
users/{uid}/signal_identity_public_keys/{identityKeyId}/rotation_events/{rotationId}
```

Server-visible data in this directory is public key material and metadata only.
Private identity keys, prekey private keys, Kyber private keys, and serialized
Signal session state remain device-local in Keychain/Keystore or an equivalent
0600 file. Rules reject `privateKey*`, `serializedSession*`, `sessionState*`,
and `ratchetState*` fields.

## Identity key rotation

Firestore rules cannot stringify an integer `keyVersion`, so rotated identity
documents use an explicit string label:

```json
{
  "deviceId": "device-r",
  "identityKeyId": "device-r_2",
  "keyVersion": 2,
  "keyVersionLabel": "2"
}
```

Rules map `keyVersionLabel` to the numeric `keyVersion` for versions 1 through
10 and require:

- `identityKeyId == {deviceId}_{keyVersionLabel}`
- document ID equals `identityKeyId`
- numeric `keyVersion` matches `escrow_devices/{deviceId}.keyVersion`
- the escrow device is `pending` or `trusted`

This gives the first bounded rotation contract without lossy prefix matching.
Expanding beyond version 10 requires an explicit rules migration and emulator
tests.

## Prekey documents

### Signed prekeys

`signed_prekeys/{signedPreKeyId}` stores:

- `signedPreKeyId` and `signedPreKeyNumericId`
- parent identity binding: `identityKeyId`, `deviceId`, `keyVersion`
- `publicKeyB64`
- `signatureB64`
- `algorithm == "signal-pqxdh-signed-prekey-v1"`
- `status in ["active", "retired", "revoked"]`
- timestamps and optional expiry

Create requires `status == "active"`. Update may only change lifecycle fields;
public key, signature, numeric ID, parent binding, algorithm, and `createdAt`
are immutable. Delete is denied.

### One-time prekeys

`one_time_prekeys/{oneTimePreKeyId}` stores:

- `oneTimePreKeyId` and `oneTimePreKeyNumericId`
- parent identity binding
- `publicKeyB64`
- `algorithm == "signal-pqxdh-one-time-prekey-v1"`
- `status in ["available", "claimed", "exhausted", "retired"]`
- `expiresAt > request.time`
- `claimedBySessionId` and `claimedAt` once no longer available

Create requires `status == "available"`. Update may only move an available key
to `claimed`, `exhausted`, or `retired`; immutable fields cannot change. Delete
is denied.

### Kyber prekeys

`kyber_prekeys/{kyberPreKeyId}` mirrors one-time prekeys, with:

- `kyberPreKeyId` and `kyberPreKeyNumericId`
- `publicKeyB64`
- `signatureB64`
- `algorithm == "signal-pqxdh-kyber-prekey-v1"`

Kyber prekeys are mandatory for libsignal `0.94.4` PQXDH session setup, so a
published bundle is not complete without them.

## Session directory

`sessions/{sessionId}` is metadata only. It records that a session exists and
where private state is stored, but never stores the serialized Signal session:

```json
{
  "sessionId": "session-1",
  "identityKeyId": "device-1_1",
  "deviceId": "device-1",
  "keyVersion": 1,
  "peerUid": "user",
  "peerDeviceId": "device-r",
  "peerIdentityKeyId": "device-r_2",
  "mode": "same-user-device",
  "stateStorage": "device-local-only",
  "status": "active"
}
```

Allowed modes are `same-user-device` and `gateway-transport`. Update may only
archive or revoke a session; peer binding and storage semantics are immutable.
Delete is denied.

## Rotation events

`rotation_events/{rotationId}` is append-only evidence for identity/prekey
rotation and re-wrap planning. A valid event records:

- `fromKeyVersion < toKeyVersion`
- `reason in ["scheduled", "suspected_compromise", "device_repair", "revocation_rewrap", "manual"]`
- `status in ["planned", "running", "completed", "failed"]`
- `rewrapRequired`
- optional `rewrapJobId`, `revokedIdentityKeyId`, `completedAt`

Rules allow create only and deny update/delete so rotation history cannot be
rewritten by a client.

## What this intentionally does not do

This change does not generate Signal keys, publish bundles from clients, consume
prekeys from callables, rotate device Keychain/Keystore state, or re-wrap
existing CloudVault data. Those are producer/runtime tasks. The server-side
contract is now ready for them and fails closed until they are wired.

Before activation, the first producer must:

1. Generate identity, signed prekey, one-time prekeys, and Kyber prekeys on
   device.
2. Publish only public material into the paths above.
3. Store all private key and serialized session records locally.
4. Mark one-time/Kyber prekeys claimed only after a session is established.
5. Write `rotation_events` before any key-version transition that requires
   re-wrap.
6. Prove revocation excludes the revoked identity from future wraps and runs the
   re-wrap job for previously wrapped data.

## Verification

Run:

```bash
cd functions
npm run test:firestore-rules
```

The L41 test is named:

```text
L41 Signal prekey/session directory is path-bound, public-only, and rotation-aware
```

It covers rotated identity key labels, signed prekey immutability, one-time and
Kyber prekey lifecycle transitions, private-key/session-state rejection, session
immutability, and append-only rotation events.
