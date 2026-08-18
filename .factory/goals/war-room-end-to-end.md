# Goal: War Room master plan, W0 through W6, end to end

## Objective

Ship every phase of the 2026-08-17 War Room master plan on `war-room/master-plan`:
multi-machine Hermes orchestration across three faces (Desk, Hermes Room, Command
Board), the Wire (fail-closed Pro/Ultra Mac-to-Mac lane), and the Flame (a router
with a voice).

## Success Criteria

- [x] W0 machine identity + originator (schema, rules, migration v62, publisher)
- [x] W1 the Wire: war frame codec, fleet snapshot exchange, outbound dial, Firestore fallback on deny
- [x] W2 Face B Hermes Room: roster + swap control reading `HermesBodyDirectory`
- [x] W3 Face C Command Board: run grid, STARTED BY column, cost rollups
- [x] W4 the Flame: `DistillRecord`, daemon service, RPC methods + socket coverage entry
- [x] W5 Flame dispatch: `targetBodyID` plumbed through mission dispatch + rules
- [x] W6 rhythm: standing-order persistence (GRDB v63), the scheduler, and a runtime host that fires them
- [x] Every phase carries tests that run without an Xcode build where the code allows it
- [x] A review pass over the whole branch, with its findings fixed at the source

## Constraints

- Repo laws: schema-sync is TypeSpec-first, GRDB changes update `docs/SCHEMA_SQLITE.sql`,
  rules changes carry rules tests, `xcodegen` owns the pbxproj, no new suppressions.
- The Mac app build is nightly, not a door check. Do not gate progress on it.
- A second Droid session (`a9ed65eb`) shares this working tree. Never stage its files
  (`AgentLens/Views/Chat/*`, `Plasma*`, `DESIGN.md`, `Vendor/libsignal`,
  `scripts/ci/prepare-domain-core-native-release-gate.mjs`) and never kill its processes.
- Prefer `OpenBurnBarKernel` for new logic so it validates in seconds.
- The Wire stays fail-closed: entitlement, identity, and consent are checked before any dial.

## Non-goals

- Android or iOS parity for War Room surfaces.
- Reworking the existing iroh transport, `HermesRelayCrypto`, or the mission runtime.
- Landing the other session's Plasma work or unblocking their compile error.

## Progress

- W0 `39aace399a`, docs `4d68d133ce`, Flame router `9f1006443d`,
  standing orders `dd8dc44634`, test module import fix `81241a6c8f`.
- W1 `4f4081d580` (frames), `99eb74317f` (handshake), `0318afc088` (dial over iroh).
- W6 `e46deb05e5` (migration v63 + row model + store + schema doc).
- W4 `09d8c4e719` (distill log, `BurnBarFlameService`, 3 RPC methods, IPC canon).
- W5 `0707f04815` (`targetBodyID` + `FlameDispatchPlanner` + rules).
- W2/W3 `cd218bfa4f` (Hermes Room + Command Board, Kernel models + SwiftUI + settings).
- Review fixes `bee0d1c541` (Wire fail-open delivery, concurrent reader, nondeterministic
  rationale, daemon gateway probe, board honesty, shared components, migration v64).
- W6 runtime `59b1e93698` (`StandingOrderRuntime` + host wired into `OpenBurnBarRuntimeContext`).

Deliberate scope calls, each recorded in the commit that made them:

- `targetBodyID` was **removed** from the unused legacy `CLIAgentMissionRequestDoc`
  TS interface: nothing in `functions/src` consumes that type, and the
  hand-maintained TS surface ratchet exists to stop exactly that growth. The
  field's real contract is `firestore.rules` (with tests) plus the Swift writer.
- The generated `OpenBurnBar.xcodeproj/project.pbxproj` was left untouched. The
  xcodegen spec globs `AgentLens/`, so the new app files land on the next
  regeneration, and the file is already modified by the other session.
- The Command Board reads `token_usage` via a `GROUP BY sessionId` projection
  rather than widening the `TokenUsage` value type, which has hundreds of call
  sites and does not carry the v62 attribution columns.
- **The Wire's app-side auto-dialer was deliberately not shipped.** `WarWireDialer`
  and `WarWireLink` are complete and tested over a real transport, but nothing in
  the app dials peers yet: that host needs the app target to compile, and it is
  blocked by the other session. Shipping unexercised networking that reaches out
  to other machines on its own would be the one thing this branch spent its
  review pass removing — code asserting something nobody checked. Named here
  rather than hidden behind a green checkbox.

## Validation

- [x] `cd OpenBurnBarCore && swift test --filter "WarWire|Flame|StandingOrder|HermesRoom|CommandBoard|DistillRecord|FleetSnapshot|BurnBarOriginator"` — 203 tests, 0 failures
- [x] `cd OpenBurnBarCore && swift test --filter "OpenBurnBarDataStandingOrderMigrationTests|WarWireDialerTests"` — 18, 0 failures
- [x] `cd OpenBurnBarDaemon && swift test --filter "BurnBarFlameServiceTests|BurnBarDaemonSocketRPCCoverageTests"` — 20, 0 failures
- [x] `npm --prefix functions run test:firestore-rules` — 65 pass, 0 fail
- [x] `node --test packages/hermes-wire-protocol` (18 pass) and `node parity.mjs` (PASS)
- [x] `./tools/schema-sync/check-drift.sh` — passed
- [x] `./scripts/ci/check-no-suppressions.sh` — passed
- [x] `node scripts/ci/verify-sqlite-schema-doc.mjs` — 41 tables
- [ ] App XCTest bundle (`HermesBodyWarRoomTests`, `WarWireGrantStoreTests`) — blocked on the
      other session's `PlasmaTerrariumOrbItem`; new app files verified by parse only.

## Resume Prompt

All seven phases are committed, plus a review pass whose findings were fixed at
the source. Three things remain, none of which this session could do:

1. The app XCTest bundle, once session `a9ed65eb` lands `PlasmaTerrariumOrbItem`.
   New app files are parse-verified only.
2. `xcodegen` regeneration of the pbxproj, once the tree is free of that session's WIP.
3. The Wire's app-side dial host (see the scope call above) — the last piece that
   turns a tested transport into a live Mac-to-Mac lane.
