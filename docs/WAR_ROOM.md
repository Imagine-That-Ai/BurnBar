# War Room — multi-machine Hermes orchestration

**Plan of record:** [`plans/2026-08-17-war-room-master-plan.md`](../plans/2026-08-17-war-room-master-plan.md) ·
**Names:** [`NAMES.md`](../NAMES.md) · **Schema:** [`tools/schema-sync/typespec/domains/war-room.tsp`](../tools/schema-sync/typespec/domains/war-room.tsp)

A user with more than one Mac should see every machine's Hermes in one place,
route work to any of them, and watch it execute — without leaving the chat deck.
War Room is that system. It ships in phases behind flags; this document is the
reference for what exists today and the contracts the rest is built on.

---

## The identity law

**A Hermes is a name bound to a machine, not to a bot.**

Bots are ephemeral — they come and go with a gateway restart. Machines are
stable. So the unit of identity is the **HermesBody**: the join of the device
doc, the Hermes relay connection, the iroh endpoint, and the hardware.

The body id is the machine's existing `relay-host-<installationUUID>` relay
connection id. **No new identity is minted.** A Mac that can host a relay
connection already has the only name War Room needs.

Everything downstream reads this: the computer-swap control, the per-machine
room, the Command Board's machine grid, and the Wire's grant endpoints.

### Presence is the reader's verdict

The publisher writes `presence.lastHeartbeatAt` and asserts it is online *at
the moment it writes*. It cannot know it went offline — a Mac that sleeps,
loses power, or loses network never gets to say so.

So **readers derive presence from heartbeat age**
(`HermesBodyPublisher.presenceFreshnessSeconds`, 180s = 3× the active
cadence). A stale body reads offline no matter what its last write claimed.

### The fountains never invent hardware

`MacHardwareInventory` probes sysctl (`hw.model`, `machdep.cpu.brand_string`,
`hw.perflevel0/1.physicalcpu`, `hw.memsize`). Anything unreadable stays `nil`,
is omitted from the payload, and renders as an em-dash. There are no synthetic
defaults anywhere in this path.

---

## The three faces

| Face | What it is | Status |
|---|---|---|
| **A — Desk** | The existing chat workspace. The Flame lives here as a router-with-a-voice in the chat deck, not a separate tab. | Existing surface; Flame lands in W4/W5 |
| **B — Hermes Room** | A per-machine view inside the computer-swap control: identity, bots, recent runs, and a "drive this Hermes" entry point. | W2 |
| **C — Command Board** | The fleet dashboard: every machine's Hermes in a grid with STARTED BY attribution, live status, cost rollups, and dispatch. | W3 |

The swap control reads `HermesBodyDirectory` **and nothing else**. One data
source, machines only — never bots.

---

## STARTED BY attribution

`BurnBarOriginator` is the typed answer to "who started this?", stamped where
work begins so the Command Board never guesses.

- **Kinds:** `user_local`, `user_remote`, `flame`, `wand`, `mission`,
  `hermes_bot`, `hermes_cron`, `external`, `unknown`.
- **Confidence:** `exact` for anything BurnBar dispatched itself, `inferred`
  for sessions it can observe but did not start, `unknown` when it cannot tell.
  External rows are never dressed up as `exact`.
- **Two codecs.** A flat `originatorKind` + `originatorRef` pair for surfaces
  that cannot carry a nested map (the `token_usage` columns added in migration
  v62, and `cli_agent_mission_requests` docs), and a full-map `wireDictionary`
  mirroring the `OriginatorRef` canon model for Firestore payloads that can.

`primaryRef` picks the single most specific reference
(`decisionID → missionGroupID → missionID → botName → bodyID`), which is what
the flat form and deep links key on.

---

## The Wire

The encrypted Mac⇄Mac lane. It is an **upgrade, never a dependency**: when the
Wire is unavailable, callers fall back to the existing Firestore relay path and
the single-machine experience is unchanged.

### Fail-closed by construction

`WarWireGate.evaluate` is pure and dependency-free, so the dialing Mac and the
answering Mac reach the **same verdict from the same code**. Checks run
outermost-first, and every unknown lands on a deny:

1. `war_room_kill_switch` engaged → `kill_switch`
2. Tier below Pro → `entitlement`
3. Missing or empty body id → `unidentified`
4. Local == remote → `self_dial`
5. No grant → `no_grant`
6. Grant covers a different pair → `grant_mismatch`
7. Grant not `active` → `grant_revoked`

The denial vocabulary is a wire contract (`war.denied` carries it), so the
fallback can log a true reason and the Command Board can render one.

### Consent: `war_wire_grants`

`users/{uid}/war_wire_grants/{pairId}` is the mutual-consent record between two
of the account's own Macs.

- `pairId` is the two body ids **sorted lexicographically and joined with
  `__`**, so either machine derives the same document without coordinating.
  `firestore.rules` enforces this server-side (`bodyIdA < bodyIdB` and
  `pairId == bodyIdA + "__" + bodyIdB`) rather than trusting the client.
- The covered pair is **immutable on update** — revoking replaces the state,
  never the endpoints, so a revoked grant cannot be re-pointed at a new machine.
- Revocable from either machine.
- `WarWireGrantStore` reads anything it cannot fully parse as **revoked**.

### Frames

The `war` group in [`packages/hermes-wire-protocol/protocol.json`](../packages/hermes-wire-protocol/protocol.json)
(iroh-only, never relay-accepted):

| Frame | Purpose |
|---|---|
| `war.hello` / `war.hello.ack` | Dial handshake; the dialer claims a grant |
| `war.fleet.snapshot` | A body pushes its fleet-visible state to its peer |
| `war.dispatch` / `war.dispatch.ack` | Route work; carries the sealed payload + `OriginatorRef` |
| `war.stream.chunk` / `war.stream.complete` | Streamed output for a dispatched run |
| `war.denied` | Fail-closed refusal, carrying a `WarWireDenialReason` |

Edit `protocol.json`, run `node codegen.mjs`, update the hand-written Swift and
Kotlin enums, then `node --test`. The parity gate fails CI on any drift across
Swift, Kotlin, TypeScript, and Rust.

---

## The Flame

BurnBar's router-with-a-voice — a **daemon service, not a chat bot**. It reads
the fleet snapshot, distills routing decisions, exposes an RPC surface the chat
deck calls, dispatches over the Wire (or the relay fallback), and records every
decision as a `RoutingDecision` + `DistillRecord` for the Command Board's audit
trail. Lands in W4/W5.

---

## Collections

| Path | Written by | Notes |
|---|---|---|
| `users/{uid}/hermes_bodies/{bodyId}` | The owning Mac only | `bodyId` == `relay-host-<installationUUID>`. `displayName` is written only on create, so a rename from Devices & Sync survives every heartbeat. |
| `users/{uid}/war_wire_grants/{pairId}` | Either machine in the pair | Canonical sorted `pairId`; pair immutable on update. |

Both are in the consolidated owner-read allowlist — the directory's snapshot
listener depends on it, and the rules suite covers the read path explicitly
because a broken read would blank the War Room surfaces while every write still
passed.

---

## Flags and rollback

| Flag | Default | Effect |
|---|---|---|
| `war_room_kill_switch` | **`true` (engaged)** | Disables the Wire and the Flame. Read app-side in `SettingsManager`. |

The default is the secure one: an install that cannot reach Remote Config keeps
the shipped single-machine experience rather than opening the Mac⇄Mac lane.
Like `computer_use_kill_switch` and `media_kill_switch`, it is **not** a
ring-rolled flag — a kill switch is flipped, not staged.

**Rollback:** engage `war_room_kill_switch`. The Wire and Flame stop; body
publication and the Hermes Bodies roster are read-only identity surfaces and
are unaffected. Migration v62 is additive and nullable, so no data is lost.

---

## Where the code lives

| Piece | Path |
|---|---|
| Canon schema | `tools/schema-sync/typespec/domains/war-room.tsp` |
| Originator | `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/BurnBarOriginator.swift` |
| Wire gate | `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WarWireGate.swift` |
| Body publish / read | `AgentLens/Services/WarRoom/HermesBodyPublisher.swift`, `HermesBodyDirectory.swift` |
| Hardware probe | `AgentLens/Services/WarRoom/MacHardwareInventory.swift` |
| Grants | `AgentLens/Services/WarRoom/WarWireGrantStore.swift` |
| Roster UI | `AgentLens/Views/Settings/HermesBodiesDetailView.swift` |
| Rules | `firestore.rules` (`hermesBodyWrite`, `warWireGrantWrite`) |
| Frames | `packages/hermes-wire-protocol/protocol.json` (`war` group) |
