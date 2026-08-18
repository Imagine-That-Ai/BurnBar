# War Room Master Plan — 2026-08-17

Multi-machine Hermes orchestration for OpenBurnBar. A user with more than one
Mac should be able to see every machine's Hermes in one place, route work to
any of them, and watch it execute — without leaving the chat deck.

## The three faces

- **Face A — Desk.** The existing chat workspace. The user's primary surface.
  Flame lives here as a router-with-a-voice in the chat deck, not a separate
  tab. When the user types "run the test suite on the Mini", Flame routes the
  work to that machine's Hermes and streams the result back into the same
  conversation.
- **Face B — Hermes Room (per machine).** A per-machine view inside the
  computer-swap control. Each Mac gets a room: its HermesBody identity
  (name, hardware, presence), its active bots, its recent runs, and a
  "drive this Hermes" entry point. The swap control (the machine picker)
  is the single source of truth for which Hermes is active — it reads
  `HermesBodyDirectory` and nothing else.
- **Face C — Command Board.** A fleet-level dashboard: every machine's
  Hermes in a grid, with STARTED BY attribution (originator), live status,
  cost rollups, and the ability to dispatch work to any machine. This is
  the "mission control for your Macs" surface.

## The Wire

The encrypted Mac⇄Mac transport lane. Pro/Ultra entitlement only, fail-closed:
if the Wire is not available, Flame falls back to the existing Firestore
relay path. The Wire uses the iroh transport's existing `connect()` outbound
capability (not accept-only) with per-device pairing keys sealed via HPKE.
No new identity is minted — the Wire rides the existing
`relay-host-<installationUUID>` connection id.

## The Flame

BurnBar's own router-with-a-voice. Not a separate agent — it is a daemon
service that:
1. Reads the fleet snapshot (all HermesBodies + their presence).
2. Distills routing decisions (which machine, which model, which tool set).
3. Exposes an RPC surface so the chat deck can ask "where should this go?"
4. Dispatches work to the chosen machine's Hermes via the Wire or the
   Firestore relay fallback.
5. Records every decision as a `RoutingDecision` + `DistillRecord` for the
   Command Board's audit trail.

## 14 decisions (all closed)

1. **A Hermes is a name bound to a machine, not to a bot.** Bots are
   ephemeral; machines are stable. The `HermesBody` record is the join of
   device + Hermes connection + iroh endpoint + hardware, keyed by the
   existing relay connection id.
2. **The swap control reads `HermesBodyDirectory` and nothing else.** No
   bot-level switching, no ad-hoc machine lists. One data source.
3. **Originator is stamped on every unit of work.** `BurnBarOriginator`
   (typed kind + label + confidence + specific ref) is written into
   missions, runs, usage rows, fleet rows, and Flame decisions. The
   Command Board's STARTED BY column never guesses.
4. **The Wire is Pro/Ultra only, fail-closed.** If the Wire is not
   available, Flame falls back to Firestore relay. No silent degradation.
5. **The Wire rides the existing connection id.** No new identity is
   minted. Per-device pairing keys are sealed via HPKE using the existing
   `HermesRelayCrypto` (v3 auth-p256).
6. **Flame is a daemon service, not a chat bot.** It exposes an RPC
   surface (`BurnBarRPCMethod`); the chat deck calls it. Flame does not
   impersonate a chat participant.
7. **Routing decisions are recorded.** Every Flame decision is a
   `RoutingDecision` + `DistillRecord` in the daemon's JSONL journal,
   queryable by the Command Board.
8. **The Command Board is a read-mostly surface.** It observes the fleet
   and dispatches work; it does not own state. State lives in the daemon
   and Firestore.
9. **`war_room_kill_switch` is fail-closed.** Remote Config, read app-side
   only in `SettingsManager.swift`. When true, the Wire and Flame are
   disabled; the existing single-machine experience is unaffected.
10. **No new suppressions.** All new code follows the no-suppressions gate.
11. **Schema-sync TypeSpec-first.** All new Firestore models go through
    `tools/schema-sync/` (`.tsp` + `generate.mjs` + `manifest.json`).
    Hand-mirrors are registered and parity-gated.
12. **GRDB + SCHEMA_SQLITE sync.** Every migration is registered in both
    app and Core; `docs/SCHEMA_SQLITE.sql` is updated alongside.
13. **Firestore rules are generated + tested.** Entitlement functions come
    from `packages/entitlements/src/catalog.ts`; rules tests cover every
    new match block.
14. **Fountains never invent hardware.** `MacHardwareInventory` returns nil
    for anything unreadable; the UI renders em-dashes. No synthetic
    values.

## Phases

### W0 — Names on doors (current)

The identity substrate. Every Mac publishes a `HermesBody` record. The
originator type is stamped into every unit of work. The Devices & Sync
surface gets a "Hermes Bodies" section. The schema domain is TypeSpec-first.

**Deliverables:**
- `war-room.tsp` schema domain (7 models) + generated TS/Swift/Kotlin
- `BurnBarOriginator` Swift hand-mirror (flat + full-map codec)
- `MacHardwareInventory` sysctl probe
- Migration v62 (`originatorKind`/`originatorRef` on `token_usage`)
- `HermesBodyPublisher` (60s/300s heartbeat cadence)
- `HermesBodyDirectory` (live snapshot listener)
- Startup wiring (publisher starts alongside relay host)
- Devices & Sync → Hermes Bodies detail view
- `firestore.rules` `hermes_bodies` match block + originator fields
- NAMES.md entries
- Tests (originator codec, payload vs rules, presence/fromFirestore, rules)

### W1 — The Wire

Encrypted Mac⇄Mac transport. `war.*` frame group in protocol.json + Swift
mirror. Per-device pairing keys sealed via HPKE. Mac outbound dial via
`IrohRelayTransport.connect()`. Wire grants (`war_wire_grants` collection)
+ rules + entitlement fail-closed. `war_room_kill_switch` Remote Config.
Fleet snapshot relay (daemon RPC that returns all HermesBodies + presence).

### W2 — Face B + swap

Per-machine Hermes Room inside the computer-swap control. The swap
control reads `HermesBodyDirectory` exclusively. Each room shows the
body's identity, active bots, recent runs, and a "drive this Hermes"
entry point. `matchedGeometryEffect` for the swap animation.

### W3 — Face C Command Board

Fleet-level dashboard. Grid of all HermesBodies with STARTED BY
attribution, live status, cost rollups. Dispatch work to any machine.
Read-mostly surface — state lives in the daemon and Firestore.

### W4 — Flame advisor

Daemon service: `FlameRouter` reads the fleet snapshot, distills routing
decisions, exposes RPC (`BurnBarRPCMethod.flameRoute`), records
`RoutingDecision` + `DistillRecord` in the JSONL journal. CLI surface
for debugging (`droid flame --inspect`).

### W5 — Flame dispatch

Chat deck integration: Flame routes work to `targetDeviceID` via the Wire
or Firestore relay fallback. Streams results back into the same
conversation. The `targetDeviceID` field on mission docs and run journals.

### W6 — Rhythm

Standing orders: `StandingOrder` model + scheduler. "Every night at 2am,
run the full test suite on the Mini and post the result to #ci."
Adaptive telemetry: the Flame learns from routing decision outcomes and
adjusts its distillation weights over time.

## Validation matrix

| Check | Command |
|-------|---------|
| Schema drift | `./tools/schema-sync/check-drift.sh` |
| XcodeGen drift | `python3 scripts/ci/verify-xcodegen-pbxproj-drift.py` |
| Daemon build | `cd OpenBurnBarCore && swift build` |
| Daemon tests | `cd OpenBurnBarCore && swift test` |
| Firestore rules | `npm --prefix functions run test:firestore-rules` |
| App fast checks | `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/<Class>` |
| No suppressions | `bash scripts/ci/check-no-suppressions.sh` |

## Rollback

Every phase is behind a feature flag. `war_room_kill_switch` (Remote
Config, fail-closed true) disables the Wire and Flame. The existing
single-machine experience is unaffected by any War Room phase. Each
phase commits independently; a bad phase is reverted without touching
the others.
