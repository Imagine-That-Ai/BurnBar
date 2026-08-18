# Goal: War Room master plan, W0 through W6, end to end

## Objective

Ship every phase of the 2026-08-17 War Room master plan on `war-room/master-plan`:
multi-machine Hermes orchestration across three faces (Desk, Hermes Room, Command
Board), the Wire (fail-closed Pro/Ultra Mac-to-Mac lane), and the Flame (a router
with a voice). W0 and the pure-logic cores of W1/W4/W6 are already committed; this
goal closes the remaining transport, UI, daemon, dispatch, and persistence work.

## Success Criteria

- [x] W0 machine identity + originator (schema, rules, migration v62, publisher)
- [ ] W1 the Wire: war frame codec, fleet snapshot exchange, outbound dial, Firestore fallback on deny
- [ ] W2 Face B Hermes Room: roster + swap control reading `HermesBodyDirectory`
- [ ] W3 Face C Command Board: run grid, STARTED BY column, cost rollups, dispatch
- [ ] W4 the Flame: `DistillRecord`, daemon service, RPC method + socket coverage entry, CLI
- [ ] W5 Flame dispatch: `targetDeviceID` plumbed through mission dispatch + rules
- [ ] W6 rhythm: standing-order persistence (GRDB + Firestore) and a scheduler runtime host
- [ ] Every phase carries tests that run without an Xcode build where the code allows it

## Constraints

- Repo laws: schema-sync is TypeSpec-first, GRDB changes update `docs/SCHEMA_SQLITE.sql`,
  rules changes carry rules tests, `xcodegen` owns the pbxproj, no new suppressions.
- The Mac app build is nightly, not a door check. Do not gate progress on it.
- A second Droid session (`a9ed65eb`) shares this working tree. Never stage its files
  (`AgentLens/Views/Chat/*`, `Plasma*`, `DESIGN.md`, `Vendor/libsignal`,
  `scripts/ci/prepare-domain-core-native-release-gate.mjs`) and never kill its processes.
  Commit a Plasma-free pbxproj generated from a temp spec, then restore the full one locally.
- Prefer `OpenBurnBarKernel` for new logic so it validates in seconds.
- The Wire stays fail-closed: entitlement, identity, and consent are checked before any dial.

## Non-goals

- Android or iOS parity for War Room surfaces.
- Reworking the existing iroh transport, `HermesRelayCrypto`, or the mission runtime.
- Landing the other session's Plasma work or unblocking their compile error.

## Progress

- 2026-08-18: W0 shipped (`39aace399a`), docs (`4d68d133ce`), Flame router (`9f1006443d`),
  standing orders (`dd8dc44634`), test module import fix (`81241a6c8f`).
- 2026-08-18: 89/89 War Room Core tests, 65/65 firestore rules, wire parity PASS,
  no-suppressions PASS.

## Validation

- [ ] `cd OpenBurnBarCore && swift test --filter "WarRoom|Flame|StandingOrder|WarWire|BurnBarOriginator"`
- [ ] `npm --prefix functions run test:firestore-rules`
- [ ] `node --test packages/hermes-wire-protocol` and `node packages/hermes-wire-protocol/parity.mjs`
- [ ] `./tools/schema-sync/check-drift.sh`
- [ ] `./scripts/ci/check-no-suppressions.sh`

## Resume Prompt

Continue this goal from the latest checkpoint. Re-read this file, run `git log --oneline`
on `war-room/master-plan` to see which phases landed, inspect the working tree for the
other session's unstaged files, update the checklist, and proceed until every success
criterion is satisfied.
