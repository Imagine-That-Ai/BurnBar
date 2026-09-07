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
depends on those shapes and sees exactly what it saw before. (Item 8 hands the verdict to the
daemon *after* that write, so an approval is now audited by both processes exactly once — the
two shapes themselves are untouched.)

**4. The lane is visible where it is reviewed.** `MemoryReviewInboxModel` loaded
exactly two partitions, so a row this branch had just quarantined was invisible on
the only macOS surface that can approve it.

`AgentLens/Views/Memory/MemoryReviewInboxModel.swift`

| | before | after |
|---|---|---|
| served kinds | `:110` `[.chat]` ∪ usage kinds | `:116` `[.chat, .agent]` ∪ usage kinds |
| pending buckets | `:172` chat, `:177` usage | `:189` adds a third load over `[.agent]` |
| approved buckets | `:182` chat, `:187` usage | `:204` adds a third load over `[.agent]` |
| merge | `mergedInPageOrder(_:_:)`, two buckets | variadic over three — same comparator, so a chat-only merge is still the pre-U7 list byte for byte |

**5. A scoped fetch could never have found one.** Adding the bucket load is not
enough on its own, and this is the part the earlier note did not see. The daemon
writes a mirrored row under its **own** per-project `project_id` and holds no
Firebase identity, so `user_id` and `app_id` are NULL until the sync lane claims
them (`claimUnownedAgentMemories`) — while the inbox's scope is
`MemoryScope(appID: "openburnbar")`, whose scoped fetch demands
`project_id = 'chat:openburnbar'` **and** `app_id = ?`. Both predicates miss every
mirrored row, always.

- `ControlPlaneStore+MemorySupport.swift:24` — `MemoryStoragePartition` gains
  `case agent` (`:34`) and `memoryPartitionedSourceKinds` splits it out (`:48` →
  `:65`). The case names a lane, not a `project_id` prefix: a mirrored row always
  carries a real project id, so the `agent:` spelling is unreachable.
- `ControlPlaneStore+MemoryRecall.swift:260` → `:290` — `if let scope {` becomes
  `if let scope, partition != .agent {`. The agent partition is read unscoped,
  which is how `cloudSyncCandidateChatMemories` has always read it, and is honest
  about the lane: one engine store per macOS user, one review surface.

**6. And a body it can read.** A row whose body cannot be shown is not reviewable —
`canApprove` says so, and needed no change; what changed is that a body now loads.

- `ControlPlaneStore+MemoryRecall.swift:155` → `:164` — `openAgentMemoryBody`
  resolves the approved body from `agent_memory_bodies` first and the quarantined
  body from `memory_quarantine_bodies` second. The order is the safety property:
  an approved row's quarantine copy is deleted the moment it is published, so the
  sync lane cannot pick up unapproved content through this reader.
- `MemoryReviewInboxView.swift:301` → `:301`–`:311` — the host's `openBody` chains
  the chat snapshot into that opener. Both readers are keyed on the same memory id,
  so exactly one body resolves and a chat row never takes the second read.
- `MemoryReviewInboxView.swift:493` → `:504` — the row carries a **"Coding agent"**
  source tag beside "Safari ask" and "Agent session". Without it a member cannot
  tell an agent's memory from something they said themselves.
- `DashboardView.swift:1352` → `:1355` — the Memory badge sums the agent lane too
  (`pendingAgentMemoryReviewCount`, `ControlPlaneStore+MemoryRecall.swift:381`).
  The badge's own comment already said why: a lane the inbox lists and the badge
  omits makes the two disagree.

**7. The table already had one home — now it cannot grow a second.** The earlier
note said the app's GRDB migrator does not create `memory_quarantine_bodies`. It
does, and it did before this branch:
`OpenBurnBarDatabase+CommandBoardIndexMigration.swift:25`, migration
`v65_memory_quarantine_bodies`, mirrored in both trees; `bootstrapSchema` itself
says the migrator is the canonical owner and the daemon's copy is a compatibility
bridge. So no migration was owed. What was owed is the guard that keeps the three
statements one table: both writers say `IF NOT EXISTS`, so whichever process opens
a fresh profile second is a no-op — and silently keeps the other's shape if a
column ever drifts. `MemoryQuarantineBodiesSchemaParityTests` is that guard.

**8. Approving in the app now publishes the memory.** The verdict was always the
app's and the publication was always the daemon's, and only the first half ran: an
in-app approval flipped `review_status` and wrote the `memory.approve` audit row,
while moving the body out of `memory_quarantine_bodies`, refilling the syncable
body under the engine id, and re-embedding it for recall are all
`BurnBarProjectCodeMemoryStore.setReviewStatus`. So an app-approved memory sat in
Approved with an empty `body_hash` — the convergence fold cannot dedupe an empty
hash across devices — and the agent's own recall did not serve it until the daemon
happened to touch the row. The ruling (**I-56**) is that the app calls
`daemon.memory.review_status` after its own approval, so the daemon stays the
single publisher.

- `ControlPlaneStore+MemoryWrite.swift:180` — after the audited write, an `.agent`
  verdict is handed to the daemon. Chat and usage rows keep their bodies in the
  app's own snapshot table and have nothing to hand over.
- `ControlPlaneStore+MemoryPublication.swift` — the hand-off. It resolves the
  project path from `pcm_projects.primary_path` (`memoryProjectRecordedRoot`),
  because the daemon resolves a path through its **writing** resolver and a
  guessed one would register a project rather than address one. It never throws
  and never rolls the verdict back: the member's decision is already durable and
  audited, and an unreachable daemon must not undo it.
- `OpenBurnBarDaemonSocketClient.swift:414` — one `daemon.memory.review_status`
  call, the same RPC the Linux desktop's review surface and the
  `burnbar_memory_review` MCP tool use. No new RPC id, no new contract, no new
  capability: `memory_write` is already `.full` for the `.app` peer.
- **How "pending publication" is represented.** Derived, not stored, and needing
  no column: `body_redacted` names where the body LIVES (`Quarantine body ref:` /
  `Project Memory snapshot ref:`) and only the daemon rewrites it, so a row whose
  verdict and whose body reference disagree **is** a verdict the daemon has not
  published (`ControlPlaneStore.isAwaitingDaemonPublication`, and the same rule in
  SQL built from the same two constants). The inbox row shows a **"Pending
  publication"** tag beside "Coding agent"
  (`MemoryReviewInboxView.swift`, `Item.isAwaitingPublication`), and
  `startMemoryProConcierge` drains the backlog once the daemon is healthy on the
  next launch (`retryPendingAgentMemoryPublications`). A published row stops
  matching, so the retry is idempotent and the tag clears itself; a crash between
  the verdict and the call leaves the same state on disk for free. Nothing reports
  a publication that did not happen.
- One daemon-side ordering fix makes it land. Because the app writes its approval
  into the shared `agent_memories` table FIRST, the row already says `approved`
  when the call arrives while its body is still parked in quarantine, and
  `setReviewStatus` answered `memoryNotFound`. `…+MemoryPersistence.swift:158`
  now looks in the status's own home first and falls back to the other, in both
  directions — an app-side reject leaves the body published, symmetrically.

**9. And the storage layer's own default is review (I-57).**
`BurnBarProjectCodeMemoryStore+Database.swift:229` declared
`review_status TEXT NOT NULL DEFAULT 'approved'` — the same fail-open default one
layer below the wire's, while the canonical GRDB migrator has said `quarantined`
since v51. It is `'quarantined'` in both of the bootstrap's statements now.

**No existing row changes.** Every writer in the tree names the column explicitly,
so the default is only ever reached by a writer that does not — and a memory
nobody vouched for belongs in review. Older daemon databases predate the review
lifecycle entirely: the `ensureColumn` that adds the column moves with the
`CREATE TABLE` (the two govern the same future INSERT and must not disagree) and
stamps the rows already in the table `approved` in the same breath, the way the
app's v51 migration does. Those rows are repository knowledge this daemon has
been recalling all along.

## Tests

| test | file | proves |
|---|---|---|
| `testAgentLaneRememberLandsInReviewInsteadOfRecall` | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift:2846` | a request built from the JSON the mirror actually sends lands `agent\|quarantined`, is absent from default recall, is present in the review feed, and leaves the engine id but no body in the sync table |
| `testApprovingAnAgentLaneMemoryRepublishesItAndItsSyncBody` | same file `:2918` | approving it republishes it to recall, refills the syncable body under its engine id, and is audited as `memory.review_status` / `review_status:approved` |
| `testAbsentReviewStatusLandsInReviewRatherThanApproved` | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/BurnBarProjectMemoryRememberContractTests.swift:81` | the BL-1 pin: an absent field decodes as `quarantined` |
| `testExplicitApprovedIsStillHonoured` | same file `:94` | the default is fail-closed, not a ceiling |
| `testLegacyPayloadDecodesWithNilBlindSyncField` | same file `:62` | updated: a pre-blind-sync caller now also lands in review |
| `testAQuarantinedAgentLaneMemoryIsListedWithItsBodyAndIsApprovable` | `AgentLensTests/Active/AgentLaneMemoryReviewInboxTests.swift:252` | a row seeded the way the daemon writes one (from the mirror's JSON, decoded through the shipping contract) is listed by the inbox model, its parked body opens, `canApprove` is true, the chat row beside it is untouched, and the dashboard badge counts the same rows the inbox lists |
| `testTheChatSourceFilterStillExcludesAgentRows` | same file `:299` | the source axis still narrows: the Chat chip shows no agent row, though the badge still counts it |
| `testApprovingAnAgentLaneMemoryFlipsReviewStatusAndAuditsItAsTheApp` | same file `:316` | approval flips `review_status`, writes exactly one `memory.approve` row with `actor:"app"` in the **daemon's** project bucket and the `source_kind:agent` / `review_status:approved` labels, and the reload moves the row to the approved bucket |
| `testTheAppMigratorCreatesTheQuarantineBodiesTableTheDaemonWritesTo` | same file `:488` | an app-first profile has the table and index the inbox reads, with the five columns |
| `testBothMigrationTreesDeclareTheSameQuarantineBodiesDDL` | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/MemoryQuarantineBodiesSchemaParityTests.swift:43` | the two hand-mirrored migration trees declare byte-identical DDL |
| `testTheAppMigrationDDLIsByteEqualToTheDaemonBootstrapDDL` | same file `:59` | the app's `CREATE TABLE` and the daemon's are the same string, character for character (compared after Swift's own multiline dedent, so indentation is not mistaken for drift) |
| `testTheAppIndexDDLMatchesTheDaemonBootstrapIndex` | same file `:82` | the same for the project index, whitespace-normalised — the two files differ only in a line break |
| `testTheAppMigrationIsANoOpOnADaemonBootstrappedStore` | same file `:98` | a real store bootstrapped by the daemon, with a real quarantined body parked in it by `remember`, still has ONE table and ONE index after the app's DDL is run twice — and the body is still readable |
| `testAnAppApprovedAgentLaneMemoryIsPublishedWhenTheAppCallsTheDaemon` | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift:2984` | I-56 end to end against a live in-process store: a row quarantined by the mirror, approved the way the app approves it (the row already says `approved`, the body is still in quarantine, `body_hash` empty, recall empty), then the call the app now makes — `body_hash` non-empty, quarantine copy gone, recalled by the daemon's own recall, and exactly ONE `memory.review_status` audit row |
| `testTheDaemonBootstrapDefaultsReviewStatusToQuarantined` | `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/MemoryReviewStatusDefaultParityTests.swift:73` | both of the daemon's statements declare `DEFAULT 'quarantined'`, and the fail-open text is gone rather than shadowed |
| `testBothMigrationTreesDeclareTheSameReviewStatusDefault` | same file `:95` | both hand-mirrored v51 migrations add the column fail-closed |
| `testARowWrittenWithoutAReviewStatusLandsInReview` | same file `:111` | the property, not the text: a row INSERTed into a real bootstrapped store naming no review status lands `quarantined` |
| `testAnExplicitlyApprovedRowIsUntouchedByTheDefault` | same file `:146` | the migration note, proved: an explicit `approved` is still believed and still recallable |
| `testApprovingAnAgentLaneMemoryHandsThePublicationToTheDaemon` | `AgentLensTests/Active/AgentLaneMemoryReviewInboxTests.swift:370` | one verdict, one hand-off, addressed by the root the daemon recorded |
| `testAnUnreachableDaemonLeavesTheApprovalAwaitingPublication` | same file `:392` | the daemon refuses: the verdict is still durable, the inbox shows no error, the row reads `isAwaitingPublication`, and the backlog holds exactly it |
| `testTheNextLaunchRetriesAPendingPublicationAndThenStops` | same file `:432` | the retry hands the same verdict over again, and a published row leaves the backlog and loses the tag |
| `testApprovingAChatMemoryNeverCallsTheDaemon` | same file `:461` | the lane boundary: a chat approval hands the daemon nothing |

Both new daemon tests were mutation-checked: with the decoder default put back to `.approved`,
`testAgentLaneRememberLandsInReviewInsteadOfRecall` fails on five assertions; with the approval
refill removed, `testApprovingAnAgentLaneMemoryRepublishesItAndItsSyncBody` fails on the body.

Seventeen existing `BurnBarProjectMemoryRememberRequest` constructions in the daemon store
tests relied on the old default to get a live, recallable row. They now say
`reviewStatus: .approved`, which is the same lesson BL-1 teaches: a write that means approved
should say so.

Both I-56/I-57 tests were mutation-checked too. Skipping the RPC call — the app
approves and never asks the daemon — fails
`testAnAppApprovedAgentLaneMemoryIsPublishedWhenTheAppCallsTheDaemon` on five
assertions, and reverting the daemon's body-resolution fallback fails it with
`memoryNotFound`, which is exactly what the app's ordering used to hit. Reverting
the DDL default to `'approved'` fails all four `MemoryReviewStatusDefaultParityTests`,
the behavioural insert included.

The four parity tests were mutation-checked against the app migration, one mutation at a time:
adding a column fails the two source-equality tests; dropping `IF NOT EXISTS` fails those two
**and** the no-op test; changing the index's column fails the index test. They read the source
files live, so a mutation needs no rebuild — and they fail rather than skip when the repository
is unreachable.

**What was actually run, and what was not.** `swift test --package-path OpenBurnBarDaemon
--disable-automatic-resolution`, one filter at a time: `--filter AgentLane` →
`Executed 3 tests, with 0 failures`; `--filter QuarantineBodies` → `Executed 4 tests, with 0
failures`; `--filter ReviewStatus` → `Executed 4 tests, with 0 failures`; and the whole
`BurnBarProjectCodeMemoryStoreTests` suite → `Executed 98 tests, with 2 tests skipped and 0
failures`. The `AgentLensTests` suites are app-hosted XCTest and need `xcodebuild`, which this
lane does not run; they are written for the nightly Mac app job — but note that
`AgentLensTests/Active/AgentLaneMemoryReviewInboxTests.swift` is **not registered in
`OpenBurnBar.xcodeproj`** (the `Active` group lists its children explicitly), so nothing
compiles it today and adding it is a separate decision this lane did not take on a suite it
cannot build. The new app-target SOURCE file **is** registered — an unregistered source file
would simply fail the app build; every app-target file changed or added in this pass parses
clean (`swiftc -parse`, eight files). The earlier pass's app sources were proved further by
type-check: `MemoryReviewInboxModel.swift` type-checks clean against the real
`OpenBurnBarKernel` module (with the real `MemoryReviewGateScan.swift` and a six-line
`AppLogger` stub, and proved able to fail on a planted type error), and the partition logic
extracted verbatim from `ControlPlaneStore+MemorySupport.swift` compiles and passes sixteen
behavioural assertions against the real `MemorySourceKind`. A full-target `swiftc -typecheck`
is not reachable on this Mac: the AgentLens target imports Firebase, GoogleSignIn and Sentry
from remote SPM packages that only Xcode resolves, and resolution fails machine-wide today
(self-signed certificate on `github.com`).

## What a member sees

Memories an agent asks BurnBar to remember now **wait in the Memory review inbox** instead of
appearing in the next chat — and they wait **in the inbox on this Mac**, not only on the Linux
desktop's review surface. The row appears in Pending with its text shown, tagged **"Coding
agent"** so it is not mistaken for something the member said, and the Memory badge counts it.
Approve and it behaves like any other memory — the app asks the daemon to publish it in the
same breath, so it is recalled, cited and synced with a real content hash, and if the daemon
happens to be down the card says **"Pending publication"** and the next launch finishes the
job. Reject or forget and it leaves. Nothing is lost —
the row is in the review feed from the moment it is written, and approving it puts it into
recall exactly as before, including its cloud copy. Repository knowledge (`index_project`, code
facts) is unaffected, and the chat and usage lanes load exactly as they did.

### Release note (BB-D)

> **Agent memories now wait for you.** When a coding agent asks BurnBar to remember something,
> the fact lands in your Memory review inbox instead of going straight into your chats. You'll
> find it in Memory → Pending, tagged "Coding agent", with its text in front of you: approve it
> and it behaves like any other memory — recalled, cited, and synced across your devices from
> the moment you approve it — or reject it and it is never used. Nothing an agent writes is
> used before you say so.

## Closed here

**The macOS review inbox does not list `source_kind = "agent"` rows** — the first limit this
note carried — is closed by items 4 to 7. It needed one thing more than the note predicted: the
bucket load and the `openBody` fallback were both necessary and neither was sufficient, because
a *scoped* fetch cannot match a daemon-written row at all. And it needed one thing less: the
app's migrator has created `memory_quarantine_bodies` since `v65`, so the "own decision" the
note asked for was already made — what it lacked was a test that keeps the three DDL statements
one table.

**The two limits this note carried out of that pass are closed as well.** **I-56** — an in-app
approval flipped the row without publishing the body — is closed by item 8: the app calls
`daemon.memory.review_status` after its own approval, so the daemon stays the single publisher,
and "approved but not yet published" is a visible, self-clearing state rather than a silent
gap. It needed one thing the ruling did not predict: because the app writes its verdict into the
shared table first, the daemon's own body lookup had to learn that a row saying `approved` may
still have its body in quarantine, or the call it now receives would answer `memoryNotFound`.
**I-57** — the bootstrap DDL's `DEFAULT 'approved'` — is closed by item 9, and it costs no row
its meaning.

## Known limits (not fixed here)

- **The source-filter chips have no "Coding agent" entry.** `SourceFilter` still offers All /
  Chat / Safari asks / Agent sessions, so an agent row is visible under All (and tagged on its
  card) but cannot be filtered *to*. Additive whenever the chip row earns a fifth chip.
