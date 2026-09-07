# The agent lane waits for review

`burnbar_remember` used to write a memory that was **approved on arrival**. There was no
human step anywhere on that path, so BurnBar had a second memory authority: one that the
Memory review inbox never saw and that fed the next chat prompt directly. This is the
finding the Po'dex memory-consolidation baseline carries as **BL-1** ("MCP `burnbar_remember`
lands `approved` by contract default — the agent-autonomous lane has no review step"), and
it falsified the product line "nothing is remembered without your say-so".

Under the consolidated model (ADR **R10**: agent writes are quarantined; decision **D-0005**:
every write whose `origin_kind` is not `human` lands `quarantined`) that lane now lands in
review, like every other new memory.

## What the lane actually is

`burnbar_remember` (`tools/openburnbar-mcp/server.py`) commits to the Memory MCP engine's own
store, then mirrors the committed fact into the shared encrypted database through
`_memory_mirror_remember` → `daemon.memory.remember`. That mirror sends `engineMemoryID` and
**no `reviewStatus` at all**. So what an absent `reviewStatus` means on that wire *is* the
review posture of every agent-autonomous write — and it meant `approved`.

The daemon marks a mirrored row `source_kind = "agent"` (`BurnBarProjectCodeMemoryStore.swift`,
the `engineMemoryID` partition), which is the store's own vocabulary for D-0005's
`origin_kind = agent`. No column was added and no migration was needed: both fields already
existed, and only the value the lane chose was wrong.

## The change

**1. The wire default is review, not trust.**

`OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarProjectMemoryContracts.swift`

| | before | after |
|---|---|---|
| decoder (the wire) | `:50` `decodeIfPresent(…, forKey: .reviewStatus) ?? .approved` | `:58` `… ?? .quarantined` |
| memberwise init | `:23` `reviewStatus: MemoryReviewStatus = .approved` | `:31` `reviewStatus: MemoryReviewStatus = .quarantined` |

`daemon.memory.remember` has no human caller — the engine's mirror, the signed CLI courier it
speaks through, and a `burnbar_remember` turn are all agent writes — so a request that omits
the field now gets review. A caller that genuinely carries a human verdict (the review lane
re-mirroring an already-approved row) still says `approved` explicitly and is still believed.
Both defaults moved together so the field has one meaning wherever it is read.

**2. A row quarantined from birth keeps its sync identity.**

`agent_memory_bodies` is the table blind sync seals and uploads from, and until now it was
only ever written for an approved row. With the lane landing quarantined, a mirrored memory
that a member later approves would have had no engine-id mapping to key its sealed cloud
document on, and would have silently stopped syncing. Two edits close that:

- `BurnBarProjectCodeMemoryStore.swift:365` — on the quarantined branch of `remember`, a
  mirrored row records its `engine_memory_id` with an **empty body**. The mapping survives;
  unapproved content still never reaches the sync lane's table.
- `BurnBarProjectCodeMemoryStore+MemoryPersistence.swift:176` — on approval, `setReviewStatus`
  refills that body under the id the row was parked with. `:198` is the other half of the same
  invariant: a row leaving `approved` blanks the body and keeps the id, so the sealed cloud
  copy stays deletable.

Repository knowledge (`source_kind = "code"`, no `engineMemoryID`) is untouched by both edits.

**3. Nothing about approval changed.** The app's `ControlPlaneStore.setMemoryReviewStatus`
still writes the `memory.approve` / `memory.reject` audit row with `actor:"app"`, and the
daemon's `setReviewStatus` still writes `memory.review_status`. The exporter's classifier
depends on those shapes and sees exactly what it saw before.

## Tests

| test | file | proves |
|---|---|---|
| `testAgentLaneRememberLandsInReviewInsteadOfRecall` | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift:2846` | a request built from the JSON the mirror actually sends lands `agent\|quarantined`, is absent from default recall, is present in the review feed, and leaves the engine id but no body in the sync table |
| `testApprovingAnAgentLaneMemoryRepublishesItAndItsSyncBody` | same file `:2918` | approving it republishes it to recall, refills the syncable body under its engine id, and is audited as `memory.review_status` / `review_status:approved` |
| `testAbsentReviewStatusLandsInReviewRatherThanApproved` | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/BurnBarProjectMemoryRememberContractTests.swift:81` | the BL-1 pin: an absent field decodes as `quarantined` |
| `testExplicitApprovedIsStillHonoured` | same file `:94` | the default is fail-closed, not a ceiling |
| `testLegacyPayloadDecodesWithNilBlindSyncField` | same file `:62` | updated: a pre-blind-sync caller now also lands in review |

Both new daemon tests were mutation-checked: with the decoder default put back to `.approved`,
`testAgentLaneRememberLandsInReviewInsteadOfRecall` fails on five assertions; with the approval
refill removed, `testApprovingAnAgentLaneMemoryRepublishesItAndItsSyncBody` fails on the body.

Seventeen existing `BurnBarProjectMemoryRememberRequest` constructions in the daemon store
tests relied on the old default to get a live, recallable row. They now say
`reviewStatus: .approved`, which is the same lesson BL-1 teaches: a write that means approved
should say so.

## What a member sees

Memories an agent asks BurnBar to remember now **wait in the Memory review inbox** instead of
appearing in the next chat. Nothing is lost — the row is in the review feed from the moment it
is written, and approving it puts it into recall exactly as before, including its cloud copy.
Repository knowledge (`index_project`, code facts) is unaffected.

### Release note (BB-D)

> **Agent memories now wait for you.** When a coding agent asks BurnBar to remember something,
> the fact lands in your Memory review inbox instead of going straight into your chats.
> Approve it and it behaves like any other memory — recalled, cited, and synced. Nothing an
> agent writes is used before you say so.

## Known limits (not fixed here)

- **The macOS review inbox does not list `source_kind = "agent"` rows.**
  `MemoryReviewInboxModel` loads exactly two partitions, `[.chat]` and
  `MemorySourceKind.usageKinds`, and `MemoryReviewInboxView`'s source tag still says
  "Engine memories arrive approved, so they never reach this inbox." Today these rows are
  reviewed through `daemon.memory.review_status` (the Linux desktop Memory review surface, the
  `burnbar_memory_review` MCP tool, the p18 probes). Wiring the macOS inbox needs three things:
  `.agent` added to the two bucket loads; an `openBody` fallback from `openChatMemoryBody` to
  the existing `openAgentMemoryBody`; **and a body the app can read** — a quarantined body
  lives in `memory_quarantine_bodies`, which the daemon's bootstrap DDL creates and the app's
  GRDB migrator does not, so that surface needs its own decision before it can show one.
- **The daemon bootstrap DDL still declares `review_status TEXT NOT NULL DEFAULT 'approved'`**
  (`BurnBarProjectCodeMemoryStore+Database.swift`). Every writer sets the column explicitly, so
  it changes no behaviour today, but it is the same fail-open default one layer down.
