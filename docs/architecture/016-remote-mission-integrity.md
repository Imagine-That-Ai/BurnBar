# ADR 016 — Remote mission integrity

## Status

Accepted (2026-08-19)

## Context

`users/{uid}/cli_agent_mission_requests` was a client-writable last-writer-wins
document. Any owner token could create unthrottled missions, two Macs could both
authorize then race a claim, a losing Mac `fail()` could clobber the winner, and
`writeSignalAtRestDocument` could overwrite a live mission. Functions had no
policy replica of daemon `grantCeiling`.

## Decision

- The Mac daemon remains the sole attenuation authority
  (`BurnBarRemoteMissionAuthorizationPolicy.evaluate`). The server trusts the
  attested Mac and never re-evaluates daemon policy.
- Create, claim, host status, cancel, and event append are Admin-SDK callables
  (`createCliAgentMission`, `claimCliAgentMission`,
  `updateCliAgentMissionStatus`, `cancelCliAgentMission`,
  `appendCliAgentMissionEvent`) behind nonce + trusted-device proof. Owner
  token is not a host.
- Client `allow create` on the mission collection is false. Host-shaped client
  updates are denied. Cancel is status-preconditioned and keeps the spelling
  `cancelled`.
- Claim is exclusive and happens **before** daemon `evaluate`. A losing Mac
  does not evaluate and does not write `failed`.
- `writeSignalAtRestDocument` refuses `cli_agent_mission_requests`.
- Runtime tokens come from one catalog fixture with generated allowlists. A
  catalog row is not a launch path.
- Device proofs are possession of a trusted device key, not presence.

## Residuals (in scope)

- App Check on these callables is **config-gated** (`enforceAppCheck`). Staging
  can run with it off; production must keep it on.
- Host status writes are Admin-SDK only. A leftover client merge is denied
  (T13/T14). Mac listeners must call `updateCliAgentMissionStatus` and unclaim
  (`releaseClaim`) when evaluate leaves the mission pending.
- File landing compares a **verified blake3** (iroh) to `contentBlake3`. SHA-256
  is never compared to a blake3 hex.
- Mixed `canceled` / `cancelled` spellings remain distinct. Mac host status uses
  `canceled`; phone cancel callable writes `cancelled`.
- A compromised trusted Mac is **in scope**: the server trusts attested Mac
  identity, not the honesty of that Mac's local policy replica.

## Consequences

- Old clients that `setDoc` missions are denied (hard cut).
- Mixed `canceled` / `cancelled` spellings remain distinct.
- grok/kimi use an ACP stdio JSON-RPC client (not argv-only hang). Gemini remote
  missions stay on Antigravity argv.
