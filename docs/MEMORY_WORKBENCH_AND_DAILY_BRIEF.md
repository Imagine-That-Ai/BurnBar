# Memory Workbench & Daily Brief — build brief

**For:** the agent implementing OpenBurnBar's member-facing memory management surface and its
AI-drafted daily brief.
**Status of this document:** design brief + verified inventory, researched 2026-08-15 against
`main` at `4244eba754` and the in-flight `usage-memory/*` stack (PRs #2257–#2275). Everything
under *What already exists* was read in the tree. Nothing under *The gap* is built.

---

## 1. Mission

Two halves of one feature.

**The workbench.** Give a member one place — on every client, and on the web — to see everything
OpenBurnBar remembers about them and *do something about it*: search it, read it, correct it,
write their own, merge duplicates, tag it, forget it. Today a member can approve or reject what
the machine proposes and nothing else. That is a review queue, not a memory they own.

**The daily brief.** Give a founder one thing to read each morning that is worth reading: what
moved, what stalled, what it cost, what they committed to, and the single next move — in the
Founder Lens voice, with receipts, never repeating itself.

They are one feature because they feed each other. The brief cites memories and standing
commitments; the workbench is where a member corrects what the brief got wrong, and a corrected
memory changes tomorrow's brief. Ship them apart and you get a summarizer nobody trusts and an
archive nobody visits.

The bar: a member should be able to say *"no, it's like this"* and watch the product agree
tomorrow.

---

## 2. What already exists (verified — do not rebuild)

### 2.1 The backend already implements the workbench; no UI calls it

`OpenBurnBarCore/Sources/OpenBurnBarKernel/Memory/MemoryServing.swift` is a **frozen contract**
(its header says so) already declaring the full mem0-class surface:
`add / search / get / getAll / update(id:patch:) / delete / deleteAll / listEntities /
eventStatus / recallForPrompt / approve / reject / enqueueExtraction`.

`AgentLens/Services/DataStore/ControlPlaneStore+Memory*.swift` implements it. Caller counts today:

| Store method | UI callers |
|---|---|
| `updateChatMemoryAuthorityRecord(id:patch:now:)` | **0** |
| `deleteChatMemoryAuthorityRecord(id:now:)` | **0** (Settings → Reset memory uses the scope-wide variant) |
| `searchChatMemoryAuthorityRecords(_:)` | **0** |
| `listChatMemoryEntities()` | **0** |
| `chatMemoryPage(_:)` / `openChatMemoryBody(id:)` / `setChatMemoryReviewStatus(...)` | review inbox |

**A workbench needs very little new backend. It needs UI, one new RPC verb, and an edit model.**

### 2.2 Per-client reality (they disagree, architecturally)

| Client | view | search | edit | compose | forget | organize |
|---|---|---|---|---|---|---|
| macOS `DashboardMainRoute.memoryReview` | 3-line truncation | ✗ | ✗ | ✗ | reject/revoke only | 2 filters |
| macOS AI Inbox candidate card | ✓ | ✗ | ✗ | ✓ *accept fixed text* | dismiss | ✗ |
| iOS `PensieveMemorySearchView` | ✓ | **✓ (only client)** | ✗ | ✗ | ✗ | ✗ |
| Android inbox card | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| Windows `MemoryPage` | ✓ | ✗ | ✗ | ✗ | **throws `MemoryReviewMacOnlyException`** | 2 filters |
| Linux `MemorySurface` | ✓ full body | ✗ | ✗ | ✗ | **✓ forget** | **5 filters + audit trail** |
| Safari popup learning drawer | ✓ | ✗ | **✓ free text ≤4 KiB** | **✓ teach correction** | ✓ forget | ✗ |
| Web console `/pensieve` | ✓ recall card | ✓ `searchKnowledge` | ✗ | ✗ | source-level only | sources card |

Three consequences worth internalizing before designing anything:

- **Linux already ships the button macOS lacks** ("Forget permanently") and the *only* surfacing
  of `daemon.memory.audit_trail` — macOS writes audit events it never shows.
- **iOS is the only client with a search box, and it searches a different corpus** (cloud
  `searchKnowledge` over Pensieve chunks, not the local `agent_memories` authority table). "Search
  my memories" currently means two different things on two clients. Pick one canonical answer.
- **Windows ships a complete hybrid ranking engine wired to nothing**
  (`windows/app/OpenBurnBar.App.MemorySearch/` — RRF, recency, exact-token coverage, 157 tests).
  Android deliberately refuses to act, with an honest comment: the phone "has no equivalent" of
  the PII/provenance/audit treatment, so it shows the proposal and says where it can be acted on.

### 2.3 The design precedent is stranded on an unmerged branch

`AgentLens/Views/SafariLearning/SafariLearningTimelineView.swift` (1331 lines) exists **only** on
`fix/quota-multi-account-readiness`, in a commit titled *"wip: save local state"*. It is a nearly
complete workbench and the blueprint for the editor:

- standalone `NSWindow`, **"What BurnBar Learned About You"**, autosaved frame
- live search field + four filter chips (`all/proposed/active/archived`)
- `SafariLearningEditorSheet`: `TextField` title + **`TextEditor` body**, live byte counters
- **optimistic concurrency**: `BurnBarSafariLearningUpdateRequest(proposalId:expectedVersion:title:content:)`;
  on conflict it reloads, shows *"This item changed while you were editing it. Review the current
  version before saving again."*, and **preserves the member's draft**
- an eligibility rule worth adopting verbatim: *"Rejected and archived learning can be reviewed,
  forgotten, or rolled back, but not edited in place."*
- 11 `daemon.learning.*` RPC verbs, accessibility ids, a 665-line view-model test suite

**Salvage this before it rots.** It is one `git gc` away from being folklore.

### 2.4 The daily brief exists three times, at three levels of aliveness

| Thing | Where | State |
|---|---|---|
| `.brief` inbox item kind | daemon AI Inbox | **live**, fingerprint = `dayBucket` (`yyyy-MM-dd`) |
| `DailyDigestManager` local notification | macOS app | **live but broken** |
| `CadenceScheduler` + `MorningBriefRenderer` | `OpenBurnBarInsights` | **dead code**, tests only |

- The `.brief` item is already *one per day, upserted in place* — the dedupe primitive a daily
  summary needs is solved. It has two authors: the analyst model and
  `BurnBarAIInboxBriefAuthor.ruleBasedBrief`, a genuine zero-egress writer (not a stub) that
  refuses to emit arithmetic glue: *"9 sessions mostly in X (9 sessions)" is not a brief.*
- But it summarizes **the last 2 hours** (`lookbackMinutes` default 120) and is **priority P4**,
  which structurally can never notify (only P1 may). There is no "at 8am, tell me."
- `DailyDigestManager` renders its body **once at app launch** and then repeats it verbatim
  forever via `UNCalendarNotificationTrigger(repeats: true)`; its copy promises "yesterday's burn"
  while `InsightEngine` filters `isDateInToday` — at launch that is usually the empty
  "Quiet morning" branch.
- `CadenceScheduler` was designed for exactly this job (daily 07:00, ±15-min window, 20h min-gap,
  weekly/monthly/anomaly/milestone) and is missing exactly one thing: a `CadenceSchedulerBackend`.
  No such backend exists on any platform.

### 2.5 Founder Lens is real, shipped, and on by default

`OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/AIInbox/BurnBarFounderLens.swift` — voice rules
(*"Blunt diagnosis → citations → exactly one next move (or one sharp question). Position +
falsifier. Numbers over adjectives."*), a 17-entry banned-phrase list ("delve", "robust",
"comprehensive", "it looks like", "you might want to"), SHIP/KILL/NARROW/WAIT decision filters,
two judgment packs (`engOps` default; `productStrategy` deliberately gated so a CI-waste finding
is never answered with fundraising doctrine), and `NextMoveRouter` enforcing exactly one primary
action. Migration `v59_founder_lens` adds threads, a plan ledger, and **memory export**;
`standingCommitments(now:)` already feeds active plans + exported memories back into synthesis —
**including on the zero-egress path**.

The product sentence already exists in `docs/AI_INBOX.md`: *"Suggestion → accepted plan step →
implementation → audit → grade → memory → next suggestion builds on it."*

**The website never says "founder" or "builder" once.** The motif lives in daemon code and docs
only. `website/CLAIMS.md` already cites the daily digest as shipped evidence — backed by the
broken implementation in §2.4.

### 2.6 Non-redundancy is the strongest asset you inherit

Seven independent mechanisms, all live: a **partial unique index** enforcing at most one *open*
item per fingerprint; fingerprint discipline (identity, never measurement); a 4-source change
gate; a notification cooldown (1/hour, P1 only, 24h stamp pruning); conservative positive-evidence
auto-resolution; 👍/👎 calibration that demotes by one band and never silences; and a bounded
suppression set for refuted findings. Prompt rule 6 already forbids restating already-open items.

**Do not build a second dedupe system. Extend this one.**

### 2.7 The web console is further along than folklore suggests

`apps/console` (Next.js static export, Firebase Auth + App Check, hosted at `app.burnbar.ai`)
already ships **a working browser path to the real vault key**: `apps/console/lib/escrow.ts`
implements P-256 ECDH + HKDF-SHA256 + AES-256-GCM wire-compatible with Swift `CloudVaultCrypto`.
A trusted native device approves the browser (`approveEscrowDeviceTrust`), which unwraps the
member's actual vault key into tab memory. `PensieveRecallCard.tsx` already does
embed → cloak → `searchKnowledge` → decrypt → render.

**So "E2EE forbids a web memory UI" is false.** The real constraints are narrower:

1. the key lives in a module singleton and **dies on refresh** (no session-restore path),
2. bootstrap **requires an existing trusted native device** (a web-only member can never decrypt —
   correct, but the UI must degrade to metadata-only),
3. **the recall path is broken today**: `PensieveRecallCard.tsx:39` calls `openText(ciphertext,
   vaultKey)` with no options, but `openText` throws on any v2 envelope without matching AAD, and
   the device seals every chunk with a v2 AAD (`PensieveKnowledgeChunker.swift:277-285`). Zero
   test coverage on that path,
4. **there is no per-item write or delete API** reachable from the web; `cloud_search_knowledge`
   is admin-SDK-only, and the one destructive precedent
   (`DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE`) deliberately routes deletion through a trusted device.

Also: `memory_facts` cloud egress is **default-OFF**, so most accounts have nothing server-side
to manage. Memory belongs to the existing `pensieve` data domain in
`packages/data-domains/registry.json` — not a new one.

---

## 3. The gap

1. **No editor anywhere in shipping code, and no RPC verb to build one on.** Over the daemon
   socket there is `remember`, `recall`, `review_status`, `forget`, `audit_trail`, `analytics` —
   **no `daemon.memory.update`**. Linux, Windows, and Safari cannot edit even in principle.
2. **No compose.** A member cannot type a memory from scratch anywhere. The only sanctioned human
   authoring is *approving a proposal* (`InboxMemoryApprovalHandler`, "Remember this").
3. **No desktop search**, and the two corpora disagree (§2.2).
4. **No organizing primitives**: no tags in the app lane, no folders, no pinning, no archive, no
   merge UI, no dedupe-cluster review, no entity browser, no sort, no multi-select.
5. **Delete is all-or-nothing on macOS**, and the lifecycle's own fourth state
   (`MemoryReviewStatus.forgotten`, "a metadata tombstone… its sealed body is removed") is
   **never set by production code** on any platform.
6. **The brief is 2 hours wide, cannot notify, and has no deltas** — nothing computes
   "spend up 40% on last week." Quota (`BurnBarQuotaSignalStore`) and chat threads
   (`BurnBarChatThreadService`) are daemon siblings the evidence pack never consults.
7. **Two competing daily surfaces** (`.brief` P4 in-app vs `DailyDigestManager` 18:00 notification)
   will confuse members. Converge or kill one.

---

## 4. Hard constraints (violating any of these fails the build)

1. **G1 — no plaintext at rest, anywhere new.** Bodies live only in
   `memory_body_snapshots.snapshot_json` inside the SQLCipher database. The body FTS index was
   *deliberately dropped* (`v51a_drop_body_fts`) because it violated G1. **Do not resurrect body
   FTS.** The sanctioned alternatives are named in `MEMORY_BACKEND_PLAN.md:177`: index redacted
   metadata, and/or transient in-memory match over a metadata-narrowed candidate set after
   decrypt, never persisted.
2. **G7 — the secret/PII gate runs on every write path, fail-closed.** `addMemoryAuthorityRecord`
   and `updateMemoryAuthorityRecord` both call it today. Any new authoring path must too.
3. **Provenance may not lie.** `memory_provenance.content_hash` is the SHA-256 of the *cited
   source message*, not the memory body. A member-rewritten body keeps citations that no longer
   justify it. This is the single most important design constraint — see §5.1.
4. **Approved + edited must not silently re-enter prompts.** Today `recallChatMemorySnippets`
   filters only `reviewStatus == .approved && validTo == nil`, so an approved memory edited to
   arbitrary text is injected with no re-review. Any body change must land `.quarantined`.
5. **The `MemoryServing` contract is frozen** and cross-track coordinated. `MemoryPatch` carries
   only `text/kind/confidence`. Extending it (tags, etc.) is a deliberate, announced change — not
   a drive-by.
6. **Platform authority must be explicit, not accidental.** Windows throws, Android refuses, iOS
   defers, Linux acts. Replace hard-coded per-platform behavior with a capability matrix the UI
   reads, and make the *reason* visible to the member (Android's copy is the model).
7. **The daily brief must not become an interrupt by accident.** P4 is a deliberate wall between
   narrative and interrupt. Crossing it needs its own delivery path with its own cooldown.
8. **Cloud writes stay within the shipped envelope.** `memory_facts` forbids
   `text/body/citations/vector/cloakedVector/embedding` and accepts `reviewStatus == "approved"`
   only. Web deletion follows the trusted-device step-up precedent unless you deliberately decide
   otherwise and say so out loud.

---

## 5. The implementation to build

### 5.0 P0 pre-requisites (fix these first — they are live defects)

- **`updateMemoryAuthorityRecord` destroys usage-memory context.** `+MemoryWrite.swift` reseals
  without passing `context:`, and `memoryBodySnapshotJSON` sets `schemaVersion: context == nil ? 1 : 2`
  — so editing a `safari_ask`/`agent_session` memory silently drops its A-MEM context sentence and
  downgrades the snapshot to v1. Two-line fix; do it before any edit UI exists.
- **`DailyDigestManager` frozen body + wrong day window** (§2.4).
- **Console recall AAD mismatch** (§2.7 item 3) — every web decrypt currently throws.

### 5.1 The edit model: supersede-with-lineage, not in-place mutation

The schema is already bitemporal and append-only — `valid_from` / `valid_to` / `superseded_by`, a
hash-chained audit, immutable content-hashed provenance, and a `body_ref` that is *derived from the
memory id and UNIQUE* (so storage physically permits exactly one body per memory). In-place
mutation is the one primitive that fights all of that.

**Every EDIT / COMPOSE / MERGE / SPLIT mints a new memory id through `addMemoryAuthorityRecord`,
then supersedes its parents.** Concretely:

- **EDIT** → new row (new body, new hash, fresh seal, G7 re-run, lands `.quarantined`) → parent
  gets `valid_to = now`, `superseded_by = newID` → audit `memory.supersede` + new `memory.revise`.
  Carry lineage with `copyMemoryProvenance`, and **demote every inherited citation** — add
  `MemoryCitationState.supersededBody` rather than abusing `sourcePruned`. Write a `memory_links`
  row `link_kind = 'revision_of'`.
- **COMPOSE** → `addMemoryAuthorityRecord` with a synthetic citation in its own namespace, exactly
  as `InboxMemoryApprovalHandler` already does (`ai-inbox:item:<fingerprint>` → use
  `authored:<uuid>`). Add **`MemorySourceKind.userAuthored`** with its own storage partition so
  hand-written facts never dedup against extractions, and give it `MemoryTrustTier.userAttested`
  (note: `recallChatMemorySnippets` currently hardcodes `.untrusted` for every snippet — decide
  deliberately whether member-authored memory earns a different tier, and if so, whether the G8
  untrusted-wrapping changes. Default answer: **it does not** — a memory is still data, not
  instruction).
- **MERGE** → new row with the combined body, both parents superseded, both provenance sets
  unioned into the child. This is `mergeDuplicateMemories` generalized past exact-hash.
  `link_kind = 'merged_from'`.
- **SPLIT** → N new rows, parent superseded once. Splitting raises "which citation belongs to
  which fragment?" — the model cannot answer it; require the member to assign, or mark all
  inherited citations degraded. `link_kind = 'split_from'`.
- **TAG** → the *only* operation that mutates in place, because it touches no sealed content and
  no hash. Populate `tags_json`, add `tags` to `Memory` and `MemoryPatch`, decode it in
  `memory(from:)`, and index it — this doubles as the G1-legal search index.
- **DELETE** → keep hard delete + fact tombstone; ensure the cascade covers `memory_links` and
  `memory_salience` (already added on the usage-memory stack — verify after merge).
- **FORGET** → finally implement `MemoryReviewStatus.forgotten` as the contract describes: sealed
  body removed, metadata tombstone retained, never recallable. Linux's copy is the model:
  *"It will be deleted from local recall (not returned to pending)."*

Cheap wins to fold in: add `body_hash_before` / `body_hash_after` labels to the update audit event
(hashes are G1-safe; the chain currently cannot prove *what* changed), and clear
`valid_to`/`superseded_by` on any surviving in-place path when the hash changes.

### 5.2 One RPC verb, one view-model, N thin shells

- Add **`daemon.memory.update`** with an `expectedVersion` optimistic-concurrency envelope (copy
  `BurnBarSafariLearningUpdateRequest`), plus the workbench reads: a faceted list/search and a
  dedupe-cluster query. Register capability scopes the way the usage-memory RPCs do.
- Add a **capability matrix** the shells read (`canEdit`, `canCompose`, `canForget`, `canApprove`,
  `canMerge`) instead of hard-coded platform behavior, and render the *reason* when false. Delete
  `MemoryReviewMacOnlyException` in favor of a matrix-driven disabled state with honest copy.
- **Port the view-model once.** `MemoryReviewInboxModel` → `MemoryReviewInboxModel.cs` already
  proves the pattern; do the same for the workbench model so macOS/Windows/Linux/web stay honest.

### 5.3 Search that is honest about the corpus

Ship **two clearly-labeled scopes**, never a silent blend:

- **"My memories"** — the local authority table. Build the G1-legal index: `kind`, `tags`,
  `source_kind`, `review_status`, `updated_at`, citation thread ids, plus SimHash buckets
  (`UsageMemorySimHash` already exists) for near-duplicate grouping. Rank with the Windows
  engine's shape (`SearchRankingMath.cs`: RRF + recency + exact-token coverage) so the port stays
  a port. Body matching happens only as a transient pass over the narrowed candidate set.
- **"My knowledge"** — Pensieve cloud chunks via `searchKnowledge` (already shipped on iOS and
  the console).

Today's `searchChatMemoryAuthorityRecords` is an O(N) full-table scan that decrypts every body;
it is not viable for interactive typing and must not back the search box unchanged.

### 5.4 The workbench UI (one design, four shells + web)

Sections, in priority order:

1. **Browse** — faceted list (source kind, status incl. *forgotten*, kind, tags, date), sort,
   multi-select, real pagination (the inbox's `pageSize = 200` single page is explicitly "a review
   surface, not a paginated browser").
2. **Inspect** — full body, provenance with jump-to-source (`MemoryCitationResolver` +
   `MemoryJumpHighlight` already work), lineage (revision/merge/split links), salience and
   corroboration, **and the audit trail** (macOS writes it and shows it nowhere; Linux's rendering
   is the model).
3. **Edit / compose** — the `SafariLearningEditorSheet` blueprint: byte counters, conflict copy,
   draft preservation, and a visible consequence line — *"Saving creates a new version. The
   original is kept and superseded, and the new version goes back to review."*
4. **Curate** — duplicate clusters (SimHash + embedding neighbors from the usage-memory stack)
   with merge, and contradiction pairs from the consolidation worker with a resolve action.
5. **Forget** — per-row, with the receipt made visible; bulk select; and the existing scope-wide
   reset kept where it is.

Reuse `ProjectMemoryWikiPrimitives` (TOC, breadcrumbs, see-also) — the app's only organize/navigate
vocabulary is currently stranded on the read-only project-memory lane.

**Web (`apps/console/app/memory/`)**: follow the `/pensieve` pattern exactly (client component,
typed callable in `lib/api.ts`, tier from `getDataDomainUsage`, key from `vaultKeySession`). v1 is
**read + search + decrypt + coarse delete**, with an explicit metadata-only degradation for members
who have not trusted the browser from a native device. Add session-restore for the vault key
(re-poll on mount; the wrapper persists server-side and the IndexedDB device key survives).
Per-item mutation from the web is a **product decision**, not a default — see §8.

### 5.5 The daily brief: converge, widen, deliver, compare

- **Converge.** One brief. Keep the `.brief` item as the canonical artifact (its day-bucket
  fingerprint already guarantees one per day). Retire `DailyDigestManager`'s independent body and
  make the notification a *delivery* of the brief, not a second author. Windows'
  `DailyDigestComposer.Compose(events, day)` is the right shape: a pure function of a day.
- **Widen.** A day-scoped evidence query, not `lookbackMinutes = 120`. Note `maxConversations = 25`
  and `perTickPromptTokenCap = 60_000` will bind first — page or summarize hierarchically rather
  than silently truncating a day.
- **Deliver.** Give `CadenceScheduler` the `CadenceSchedulerBackend` it was designed for (daemon
  tick on macOS, `WorkManager` on Android, cloud schedule for push; iOS has **no** `BGTaskScheduler`
  anywhere in the repo today). Delivery is its own path with its own cooldown — do not promote the
  brief to P1.
- **Compare.** Add deltas: yesterday-vs-today, week-over-week, and plan movement. `costBaselines`
  (median + MAD) exists for anomaly detection only; resolved items are retained "for trend reading"
  and nothing reads them.
- **Feed it what it's missing.** Quota (`BurnBarQuotaSignalStore`) and chat threads
  (`BurnBarChatThreadService`) are daemon siblings the evidence pack never consults; memories and
  standing commitments already flow.
- **Keep the honest voice.** Founder Lens supplies it. Keep the rule-based author working with
  egress off — a daily brief that works with zero egress is a claim worth making, and
  `CLAIMS.md` needs a row that is actually true.

### 5.6 Where the two halves meet

- The brief cites memories and commitments; each citation deep-links into the workbench.
- The workbench shows **"used in your brief"** on memories the brief actually cited — that is the
  reinforce-on-use signal the salience layer already wants (bump on use, not on retrieval).
- Correcting a memory from the brief is one click, and tomorrow's brief reflects it.
- A member-authored memory ("remember that I ship on Thursdays") becomes a standing commitment the
  brief reasons about.

---

## 6. Deliverables

1. A design doc reconciling with `MEMORY_BACKEND_PLAN.md`, `MEMORY_FRONTEND_PLAN.md`,
   `PENSIEVE.md`, and `AI_INBOX.md`, stating precisely what is added.
2. The three P0 fixes (§5.0), each with a regression test.
3. Schema + contract changes: `MemoryCitationState.supersededBody`, `MemorySourceKind.userAuthored`,
   `tags` on `Memory`/`MemoryPatch`, `memory_links` lineage kinds — with the frozen-contract change
   announced in the PR body.
4. `daemon.memory.update` (+ optimistic concurrency) and the faceted list/search verbs.
5. The G1-legal search index and the ranking port.
6. The workbench view-model + macOS shell, then Windows/Linux/web shells; iOS/Android read+search
   parity at minimum.
7. The salvaged Safari Learning editor, merged rather than stranded.
8. The converged daily brief: day-scoped evidence, delivery backend, deltas, quota + chat facts.
9. Tests: edit lands quarantined; citations demote on body change; G7 on every write path; forget
   is complete and receipted; no plaintext in any new index; capability matrix honored per platform;
   brief is exactly one per day and never repeats a resolved finding.

## 7. Acceptance criteria

- A member can search, read, correct, compose, tag, merge, and forget a memory on macOS — and the
  same operations either work or are honestly disabled with a reason on every other client.
- Editing an approved memory returns it to review; the original remains, superseded, with lineage.
- No search path persists a decrypted body; verified by test.
- The daily brief arrives once a day at a chosen time, cites real facts including quota and
  commitments, shows a delta against yesterday, and never restates an open or resolved item.
- The brief works with egress fully off (rule-based author), and `CLAIMS.md` cites a true
  implementation.
- Forget is verifiable end to end, including the cloud replica, with a receipt the member can see.

## 8. Check in before you build (product decisions, not engineering ones)

1. **Web mutation.** Does per-item edit/delete from `app.burnbar.ai` follow the trusted-device
   step-up precedent, or does memory become the first E2EE write surface on the web?
2. **Authority on phones.** Android's refusal is principled. Does the workbench keep "authority is
   Mac-only," or do we build the PII/provenance/audit path on mobile so a member can act where
   they actually are?
3. **Canonical corpus.** Is "my memories" the local authority table (macOS/Linux/Windows) or the
   cloud knowledge index (iOS/web)? They are different sets today; a member will not accept that.
4. **Delivery moment.** Morning brief (07:00, matching the dead scheduler's design) or the current
   18:00 digest hour? One default, member-adjustable.
5. **Founder positioning.** The motif is real in code and absent from the website. Does this ship
   as founder-facing — and if so, who updates the site and `CLAIMS.md`?

---

## 9. Reference points

| Concern | Read this first |
|---|---|
| Contract + gates | `OpenBurnBarKernel/Memory/MemoryServing.swift`, `docs/MEMORY_BACKEND_PLAN.md` |
| Store CRUD | `AgentLens/Services/DataStore/ControlPlaneStore+Memory{,Write,Recall,Support,Forget}.swift` |
| Editor blueprint | `SafariLearningTimelineView.swift` + `SafariLearningTimelineViewModel.swift` (branch `fix/quota-multi-account-readiness`) |
| Most capable shipped review UI | `apps/linux-desktop/src/surfaces/memory/MemorySurface.tsx` |
| Ranking port | `windows/app/OpenBurnBar.App.MemorySearch/Search/SearchRankingMath.cs` |
| Compose precedent | `AgentLens/Views/Inbox/InboxMemoryApprovalHandler.swift` |
| Inbox + brief | `OpenBurnBarDaemon/.../AIInbox/`, `docs/AI_INBOX.md` |
| Voice | `OpenBurnBarDaemon/.../AIInbox/BurnBarFounderLens.swift`, `docs/AI_INBOX_FOUNDER_LENS.md` |
| Dead scheduler to revive | `OpenBurnBarInsights/Services/Cadence/` |
| Web patterns | `apps/console/app/pensieve/`, `apps/console/lib/escrow.ts`, `apps/console/lib/api.ts` |
