# The AI Inbox

A background analyst that turns OpenBurnBar's index into a proactive inbox.

Every five minutes it asks: *has anything changed?* Almost always the answer is
no, and the tick ends having spent nothing. When something has changed, it reads
the recent agent sessions, the workspace git state, and GitHub; runs deterministic
detectors; optionally asks a cheap model to write a short brief; has a second
model on a different provider try to refute each claim; and publishes what
survives as ranked inbox items.

The motivating case: a workflow was wasting 95% of its CI cycles for weeks. Each
individual red run looked like a normal flake — only the aggregate revealed it,
and nothing was looking at the aggregate. That class of blind spot is what this
closes.

---

The inbox is produced once, on the Mac, and read everywhere — Mac, iPhone, iPad,
and Android. See [Reaching the phone](#reaching-the-phone) for how.

## What you see

**⌘1 — Inbox** is a first-class dashboard section: a list of items on the left,
the selected item on the right.

An item states what happened, shows the evidence behind it (workflow runs,
pull requests, conversations, workspace state — all clickable), and offers the
obvious next step. Items are ranked *Urgent → Today → Worth knowing →
Background*; only Urgent may raise a notification, and only once per condition
per hour.

Items resolve themselves. When the PR you were nagged about merges, or the dirty
worktree gets committed, or the broken workflow starts passing, the item moves
to **Resolved** with a note saying what fixed it. The inbox reflects the present
rather than accumulating stale alerts.

Some items propose things worth remembering. Those are proposals: nothing is
saved to memory, or used in any prompt, until you press **Remember this**.

---

## What it detects

Eight deterministic detectors run on every non-skipped tick. They involve no model,
cost nothing, and work with egress turned off.

| Detector | Fires when | Priority |
|---|---|---|
| **CI waste** | ≥45% of a workflow's recent completed runs failed or were cancelled (≥6 runs). Escalates to Urgent at ≥80% **and** ≥60 wasted minutes. Also counts duplicate runs on one commit — the redundant-trigger smell. | up to P1 |
| **Promised not landed** | A session claimed completion, but no recent commit or PR in that repository matches the task. | P2–P3 |
| **Uncommitted work** | ≥3 changed files in a worktree whose session has been quiet ≥45 minutes. | P2–P3 |
| **Unpushed commits** | Local branch is ahead of `@{upstream}` and the session has been quiet ≥45 minutes. | P2–P3 |
| **Pushed, not merged** | Feature branch is not ahead of upstream, GitHub has no open/recently-merged PR for that head, and the session has been quiet ≥2 hours. | P3 |
| **Cost anomaly** | Spend for a project breaks its own trailing baseline (robust z-score ≥3.5 over median + MAD — heavy-tailed-safe, unlike mean + σ). | P2–P3 |
| **Stalled PR** | An open, non-draft PR with no activity for ≥5 days. Approved-and-forgotten ranks higher: the work is done and just needs a merge. | P2–P3 |
| **Index health** | Agent logs changed but nothing from that window is indexed yet, so the brief may be incomplete. | P4 |

Above these, the analyst model contributes narrative synthesis and cross-signal
patterns the detectors were not written to see. It is explicitly forbidden from
restating a deterministic finding — arithmetic wins over a guess.

### Intelligence tradeoff (settings)

When egress is `local` or `cloud`, **Settings → General → AI Inbox** shows a
**Fast / Balanced / Thorough** cockpit that writes `analystModel` /
`verifierModel` / `maxVerifierCallsPerTick`:

| Preset | Analyst | Verifier |
|---|---|---|
| Fast | `deepseek-v4-flash` | off |
| Balanced (default) | `deepseek-v4-flash` | `gpt-5.6-luna` ×3 |
| Thorough | `deepseek-v4-pro` | `gpt-5.6-luna` ×6 |

Advanced disclosure lets you pin any provider/model id the daemon router already
resolves. Detectors still run with egress off; the cockpit only gates narrative
synthesis.

### Memory closed loop

Unfinished-work detectors (and the analyst) may attach `memory_candidates`.
Approving **Remember this** writes an approved chat-memory row. The next tick
reads those approved snippets back into the evidence pack / analyst prompt as
`# Approved memories` — so long-running project facts persist across quiet days.
Nothing is auto-injected; dismiss stays local UI.

### It learns which of these you actually care about

Hand-picked thresholds are wrong for somebody. Rather than asking you to tune
sliders you have no basis to set, the inbox watches two signals it already
collects and adjusts itself:

- **Explicit feedback** — 👍/👎 on an item.
- **Time to resolution** — an item that resolves within 15 minutes of being
  raised was, by definition, not worth interrupting for. This is the more honest
  of the two, because it costs you nothing to produce.

The adjustment is deliberately bounded. A kind you consistently find unhelpful
drops **one** priority band and says why in the item footer. It can never be
demoted below P4, and it can never be promoted — a detector that thinks
something is P3 must not be able to escalate itself into an interruption because
you have been polite. Counters halve as they grow, so a workflow you actually
fixed can climb back rather than being judged forever on its worst week.

Below six observations for a kind, nothing is adjusted at all: three thumbs-down
on a new detector is an opinion, not evidence.

---

## Architecture

```
BurnBarAIInboxService (daemon actor, sleep-first 300s loop)
 │
 ├─ 0. Budget check ──────── daemon usage ledger, executionSourceID = "ai-inbox"
 │                            over budget → rules only + one 'budget' item
 │
 ├─ 1. Change gate ───────── LOCAL every tick: hash of (conversation watermark,
 │                            agent-log mtimes, git HEADs + dirty counts,
 │                            usage-ledger tail). Unchanged → record run, sleep.
 │                            REMOTE every 3rd tick: poll GitHub, auto-resolve.
 │
 ├─ 2. Evidence pack ─────── redact → byte-cap → token-budget
 │
 ├─ 3. Detectors ─────────── deterministic, free, always run
 │
 ├─ 4. Analyst ───────────── DeepSeek V4 Flash, strict JSON, one repair pass,
 │                            citation validation, PII gate on proposals
 │
 ├─ 5. Verifier ──────────── deterministic re-checks first; then GPT-5.6 Luna
 │                            adversarially, capped per tick
 │
 └─ 6. Publisher ─────────── fingerprint dedupe, auto-resolve, usage events,
                              one notification at most
```

### Why the daemon

The daemon is already the always-on, code-signed process that owns the local
index and holds provider credentials. Putting the analyst there means the loop
survives app restarts, needs no new launchd job (the daemon is `KeepAlive`, and
this repo has no `StartInterval` precedent anywhere), and conversation text never
crosses a process boundary to be analyzed.

### Why the change gate matters most

The loop wakes 288 times a day. If a wake were not free, the feature would be a
tax rather than a service. The gate short-circuits before any subprocess, network
call, or model call — one aggregate query plus a bounded `stat` sweep.

`messageCount` is in the conversation hash on purpose: a live session mutates its
row in place, so the id alone would look unchanged as the transcript grows.

GitHub is deliberately *not* in the signature. It changes for reasons unrelated
to this machine, and polling it every tick would burn API budget; it is sampled
on the remote phase instead, which is also what lets a PR that merged on another
machine auto-resolve an item here.

### Honesty about staleness

The app's parser refresh runs on its own ~10-minute cadence, so the index can
trail the files on disk. The inbox measures that gap on every tick rather than
pretending it does not exist, and acts on it three ways:

- The brief says so outright ("sessions from the last N minutes may not be
  included yet").
- The analyst prompt is told, with an explicit instruction not to read "I cannot
  see it" as "it does not exist".
- **`promised_not_landed` stops firing entirely** while the index is behind.
  Telling someone their work vanished when it did not is the worst failure this
  feature can have, so when it cannot see clearly, it stays quiet.

### Why two models from two providers

The analyst is a cheap, fast model reading partially-truncated logs. Its most
likely failure is a *fluent* wrong conclusion — exactly what a confident inbox
would amplify. So every model-authored claim faces a verifier instructed to
refute it, running on a different provider so correlated model-family blind spots
do not cancel out.

Deterministic re-checks run first and can settle a claim for free. If git shows a
commit landed since the finding was raised, the claim is refuted without any
model call. An unparseable verdict is treated as *unclear*, never as approval;
unclear findings are demoted so they cannot interrupt.

---

## Cost

| | Input | Output | Cached input |
|---|---|---|---|
| **DeepSeek V4 Flash** (analyst) | $0.14/Mtok | $0.28/Mtok | $0.0028/Mtok |
| **GPT-5.6 Luna** (verifier) | $0.20/Mtok | $1.20/Mtok | $0.02/Mtok |

A worst-case active tick is roughly **$0.016** (60k in / 4k out to the analyst,
plus up to three small verifier calls). With a realistic active-tick rate the
daily cost lands well under the **$1.50 default cap**. The analyst's system
prompt is byte-stable across ticks so DeepSeek's cache-hit pricing applies to the
largest fixed part of the prompt.

Every model call is recorded to the daemon usage ledger with
`executionSourceID = "ai-inbox"`, a distinct idempotency key, and a
`parentRequestID` equal to the tick id — so the N calls for one tick roll up to
one logical request without any being deduped away. The budget check reads that
ledger directly rather than the app's SQLite mirror, which lags behind an
app-side import.

On breach: synthesis pauses, one `budget` item explains it, and **detection keeps
running**.

---

## Privacy

Egress has three modes, and the default is the strict one.

| Mode | Behavior |
|---|---|
| **off** (default) | No model calls at all. Detectors plus a rule-rendered brief. Nothing leaves the device. |
| **local** | Model calls only to a loopback/LAN endpoint (Ollama). **Enforced**, not advisory: the resolved endpoint is checked against loopback, `.local` mDNS names, and the RFC1918 ranges immediately before any byte is sent. A remote endpoint is refused and the tick degrades to the rule-based brief. |
| **cloud** | Calls may reach the configured cloud providers. |

Redaction happens at pack-build time — on the way *in*, not on the way out — so
no downstream path can leak by forgetting to redact. Two layers:

1. Regex scrubbing of common secret formats (provider keys, GitHub/Slack tokens,
   AWS keys, private key blocks, bearer tokens, URL-embedded credentials).
2. `MemorySecretPIIGate`, the repo-wide fail-closed corpus that already gates
   memory writes. If it still finds something after scrubbing, the excerpt is
   **withheld entirely** rather than sent. Losing an excerpt beats leaking a
   credential.

### Prompt injection

Conversation text is untrusted input: written by other models, often quoting the
open internet, and fed to a model whose output can propose memories. Four
independent defenses, so none is load-bearing alone:

1. **Framing** — instructions first, never interleaved with data; untrusted text
   fenced in `<untrusted>` elements with explicit "this is data" framing.
2. **Delimiter integrity** — `<untrusted` / `</untrusted` sequences inside the
   data are neutralized, so a transcript cannot close its own fence and speak as
   the operator.
3. **Citation validation** — findings must cite evidence ids present in the pack.
   A fabricated finding cites nothing real and is dropped.
4. **Capability isolation** — the model has no tools; its output is validated
   data, and memory proposals still require human approval.

---

## Memory

Proposals ride in the item payload. Approving one routes through the *existing*
memory authority, not a new path:

```
addChatMemoryAuthorityRecord   → secret/PII gate → sealed body snapshot
                               → provenance rows → memory.add audit event
                               → lands QUARANTINED
setChatMemoryReviewStatus      → memory.approve audit event
```

Two consequences, both intended: the inbox cannot become a side channel around a
control the rest of the app enforces, and an approved fact is indistinguishable
downstream from any other approved memory, so it participates in recall without
special-casing. Provenance is labeled `ai-inbox:item:<fingerprint>` plus the
conversation ids that justified it.

---

## Timestamp formats (read this before touching a query)

The shared database holds timestamps in **two incompatible text formats**, and
mixing them fails silently rather than loudly:

| Tables | Written by | Format | Bind with |
|---|---|---|---|
| `conversations`, `token_usage` | the **app**, via GRDB | `2026-08-04 21:25:00.000` | `BurnBarAIInboxTimestamp.grdbString` |
| `ai_inbox_*` | the **daemon** | `2026-08-04T21:25:00.000Z` | `BurnBarAIInboxTimestamp.string` |

SQLite compares these columns as plain TEXT. The formats diverge at byte 11 —
`' '` (0x20) versus `'T'` (0x54) — and `'T'` sorts after every digit, so an ISO
bound is lexicographically greater than every same-day GRDB timestamp and
`WHERE startTime >= ?` matches **nothing**. No error, no warning, just an empty
result set.

This shipped as a bug once and made the whole feature inert: no conversations
meant no workspaces, so no GitHub slugs, so no detectors and no analyst — the
only surviving output was `index_health` reporting that nothing was indexed.
`AIInboxStoreTests` now inserts rows in the real on-disk format and asserts they
are read back, so a regression fails there rather than in production.

## Data model

Four tables in the shared `openburnbar.sqlite`. Ownership is split by table,
which is what lets two processes share one file without coordination:

| Table | Writer | Purpose |
|---|---|---|
| `ai_inbox_items` | daemon | The items |
| `ai_inbox_runs` | daemon | Per-tick telemetry (written even for skipped ticks) |
| `ai_inbox_state` | daemon | Config, gate signature, baselines, ETags, suppressions |
| `ai_inbox_item_state` | **app** | Read / archived / snoozed / feedback |

The dedupe invariant is enforced by the database, not by convention:

```sql
CREATE UNIQUE INDEX ai_inbox_items_open_fingerprint_idx
    ON ai_inbox_items(fingerprint) WHERE state IN ('new', 'updated');
```

At most one *open* item per fingerprint, so a condition recurring every five
minutes updates one row instead of minting 288 a day — while resolved rows
accumulate freely as history. A fingerprint is built from *identity* (kind +
scope + subject), never from a *measurement*; including a changing number would
mint a new item every tick.

The DDL exists in three places (daemon store, `OpenBurnBarData` migration v58,
AgentLens mirror) because the daemon self-heals its schema for profiles that have
not migrated yet. `AIInboxSchemaParityTests` reads the migration files from
source and fails the build if they drift.

---

## Reaching the phone

The analysis only happens on the Mac — it needs the local conversation index, the
git worktrees, and the `gh` CLI, none of which exist on a phone. So the inbox is
**produced once and mirrored**, never recomputed.

### Why a Firestore mirror and not a live link

The inbox exists to tell you what happened *while you weren't watching* — which
means the moment you reach for your phone is exactly the moment the Mac is most
likely to be asleep.

| | Awake Mac needed | Durable | Offline read | Push |
|---|---|---|---|---|
| **Firestore mirror** | **no** | **yes** | **yes** | **yes** |
| Hermes relay | yes | no (mailbox) | no | no |
| Iroh P2P | yes | no | no | no |
| Daemon socket | yes (same machine) | no | no | no |

Every live transport in this repo is used for something the user *initiated* while
both devices were awake. The inbox is the opposite shape, so it takes the one path
that survives a closed lid. The iroh module's own build file already calls
Firestore "the fallback" for precisely this reason.

### The plaintext/sealed split

Sorting, badge counts, and the push trigger all have to work *without* decrypting,
so the document is split:

```
users/{uid}/ai_inbox_items/{itemId}
  ├─ plaintext routing:  kind, priority, state, occurrenceCount,
  │                      firstSeenAt, lastSeenAt, resolvedAt,
  │                      modelProvenance, hasMemoryCandidates, schemaVersion
  └─ sealedPayload:      title, summaryMarkdown, projectName,
                         resolutionNote, evidence, memoryCandidates,
                         actions, metrics, verification
```

Everything that reads like your own work is sealed with the Cloud Vault before
Firestore sees it — same helper, same AAD binding, same `sealedSchemaVersion: 2`
as the existing `cli_sessions` mirror, so the same rules predicates apply.

The AAD binds each seal to `(uid, collection, documentID, field)`. A document
copied to another id — or another user — **will not open**. That is asserted, not
assumed: see `test_decodeRefusesDocumentReplayedUnderDifferentID` and
`…DifferentUID`.

The contract lives in one file, `AIInboxMirrorRecord.swift`, whose
`documentKeys` array *is* the `firestore.rules` allowlist. A field added there
without a rules update would have every write rejected, so
`AIInboxMirrorCodecTests` asserts the encoder's output is a subset of it.

### Who writes what

The local ownership split carries over to the cloud unchanged, which is what keeps
multi-device state conflict-free:

| Collection | Writer | Reader |
|---|---|---|
| `ai_inbox_items` | Mac app (`AIInboxSyncService`) | every device |
| `ai_inbox_item_state` | **any device** (read / archive / snooze / feedback) | every device, incl. the Mac |

The Mac publisher runs from the **app**, not the daemon: the daemon has no Firebase
and no auth context, while the app already holds both and can read the same SQLite.
A watermark gate means an idle sync uploads nothing, matching the daemon's own
change gate — the 5-minute tick stays free end to end.

### Notifications

A P1 item creates a Firestore document, which fires a Cloud Function, which pushes
to the user's devices. The push carries only an item id and a generic body — the
content is sealed and the function cannot read it, so each client hydrates the real
text after decrypting locally. That is the same privacy posture the existing agent-
reply pushes use.

Rate limiting is inherited rather than re-implemented: the Mac already caps
notifications at one per tick with a one-hour cooldown per fingerprint, and the
trigger fires only on document *create*, so an occurrence bump never re-alerts.

### Platform surfaces

| Platform | Surface | Reached from |
|---|---|---|
| macOS | `AgentLens/Views/Inbox/` — two-pane | Its own dashboard section (⌘1) |
| iOS | `OpenBurnBarMobile/Views/Inbox/` — single column | **Inside Streams**, not its own tab |
| iPadOS | same views, two columns above 720pt with a draggable divider | same |
| Android | `android/…/ui/inbox/` — Compose list + detail | Its own nav destination |

All four rank through the same `AIInboxMirrorRecord.rank` and use the same section
grouping, so the inbox reads as one product rather than four ports.

**Why iOS lives inside Streams rather than as a seventh tab.** Promoting a
top-level destination on iOS means a new hand-drawn Aurora glyph plus edits to
two default-tab arrays that existing users have already persisted — so the tab
would be invisible to everyone who has ever reordered their tabs, which is the
worst of both outcomes. Streams is already "what my agents have been doing,"
so the inbox reads as its summary rather than a stranger. `AIInboxSplitLayout`
resolves one column or two from the width it is handed, so the same expression
serves an iPhone, a Slide Over, and a full-width iPad. Streams also feeds its
existing search field through rather than adding a second one.

Promote it later by adding cases to `AuroraNavDestination` and `AppDestination`
and wiring both roots; nothing here blocks that.

**Memory approval stays on the Mac.** Mobile shows proposed memories read-only and
says so: the memory authority (PII gate, sealed body snapshots, provenance, the
audit chain) is Mac-side, and an approve button that silently did nothing would be
worse than none.

---

## Interfaces

### Daemon RPC

| Method | Capability | Purpose |
|---|---|---|
| `daemon.inbox.list` | observability | List item summaries |
| `daemon.inbox.get` | observability | One item in full |
| `daemon.inbox.runs.recent` | observability | Tick telemetry + spend |
| `daemon.inbox.config.get` | observability | Read config |
| `daemon.inbox.config.update` | config | Write config (values are clamped) |
| `daemon.inbox.run_now` | config | Force a tick |

Config writes and `run_now` are `config`-scoped because they change the egress
posture, the spend ceiling, or immediately spend money.

### MCP

`burnbar_inbox_list`, `burnbar_inbox_get` (sensitive-read), and
`burnbar_inbox_status` are read-through views routed via the daemon socket — so
they keep working when SQLCipher keying lands, and there is one definition of an
"item". There is deliberately no write tool.

---

## Configuration

| Setting | Default | Notes |
|---|---|---|
| `enabled` | `false` | Off until you opt in |
| `egressMode` | `off` | Nothing leaves the device |
| `tickSeconds` | `300` | Clamped to 60–3600 |
| `remotePhaseEveryNTicks` | `3` | GitHub polled every ~15 min |
| `dailyBudgetUSD` | `1.50` | 0 means unlimited |
| `maxVerifierCallsPerTick` | `3` | |
| `perTickPromptTokenCap` | `60000` | Oldest sessions dropped to fit |
| `lookbackMinutes` | `120` | |
| `githubEnabled` | `true` | Degrades gracefully when `gh` is absent |
| `notifyOnP1` | `true` | |

Every value is re-clamped on write, so an RPC caller cannot persist a 1-second
cadence or a negative budget.

---

## GitHub

Read through the user's own authenticated `gh` CLI rather than a stored token:
`gh` already handles refresh, enterprise hosts, and SSO, and the daemon's threat
surface does not grow to hold a new long-lived secret.

`gh` is located by absolute path probing (a LaunchAgent inherits a minimal
`PATH`). Requests are read-only, bounded by timeout, and served from `gh`'s own
HTTP cache. When `gh` is missing or unauthenticated, GitHub checks degrade and a
one-time `system` item explains what to install or run — a silent capability gap
would otherwise look like "nothing to report".

Repository slugs are parsed from `remote.origin.url` and validated against a
strict `owner/repo` character set before being interpolated into an API path.

---

## Testing

112 daemon tests, 19 mirror-contract tests, and 39 Android JVM tests, all
passing. Notable beyond the detector and pipeline coverage: the change gate is
proven to spawn **zero** subprocesses (`test_gateFingerprintSpawnsNoSubprocesses`),
request limits are proven to clamp on decode so a socket caller cannot force an
unbounded scan, and the subprocess environment is asserted non-interactive by
reading what a real child actually receives.

Two guards are worth calling out because they defend against failures that
produce no crash, no log, and no red build:

- **`AIInboxCrossPlatformContractTests`** pins the document shape across Swift,
  Kotlin, and `firestore.rules` — three languages no compiler checks against
  each other. It was verified by mutation: injecting a single-token drift into
  the rules turns the suite red, and restoring it turns it green. A parity test
  that cannot fail is worse than none, because it reads as coverage.
- **Forward compatibility.** An unrecognized `kind` degrades to the generic
  notice category rather than dropping the item, because the Mac ships detectors
  ahead of the phones that read them. `state` deliberately stays strict — an
  unknown lifecycle state would file a row under the wrong filter, which is
  worse than omitting it.

| Suite | Covers |
|---|---|
| `AIInboxCIWasteDetectionTests` | The marquee case: 38/40 wasted runs → P1 with 304 quantified minutes and cited evidence, **zero model calls**. Plus threshold resistance (healthy workflow, small sample, trivial duration, in-progress runs), per-workflow separation, duplicate-run detection. |
| `AIInboxStoreTests` | Dedupe (recurrence updates one row; recurrence *after* resolution opens a new one), payload round trip, degradation on unreadable payloads, pagination, expiry, cross-writer tolerance, deterministic hashing. |
| `AIInboxPipelineTests` | Citation validation rejects fabricated evidence; secrets and ungrounded citations drop memory proposals; delimiter and attribute injection are neutralized; redaction across six secret formats; unparseable verdicts are never approvals; config clamping; token budgeting; `gh` decoding. |
| `AIInboxServiceEndToEndTests` | Full publish path: P1 item with materialized evidence, two ledger events sharing a `parentRequestID`; idempotent second tick; PR auto-resolution; GitHub outage does **not** mass-resolve; refuted findings stay suppressed; only P1 notifies; the rule-based brief is useful with no model. |
| `AIInboxSchemaParityTests` | The three DDL copies cannot drift; the partial unique index exists and is partial. |
| `AIInboxCrossPlatformContractTests` | Swift ↔ Kotlin ↔ `firestore.rules` agree on all 11 kinds, all 4 states, both field allowlists, the feedback vocabulary, and the AAD binding. Mutation-verified. |
| `AIInboxMirrorCodecTests` (Core) | Sealed round trip; no plaintext leaks into the document; a document replayed under a different id or uid refuses to decrypt; unknown kind degrades, unknown state drops. |
| `AIInboxRefreshPartsTest` (Android, JVM) | Parse, join, rank, section, filter, unread counting, forward compatibility — all with no Firebase, so the logic that decides what the user sees is testable without an emulator. |
| `AIInboxCalibrationTests` | The learning loop needs real evidence before acting, demotes by at most one band, never silences a kind, never promotes, and lets a kind recover after decay. |

```bash
cd OpenBurnBarDaemon && swift test --filter AIInbox
```

---

## Deploying the mirror

The mobile inbox reads `users/{uid}/ai_inbox_items`. Until `firestore.rules` is
deployed, **every mirror write returns `PERMISSION_DENIED`** and the phone shows
an empty inbox with no error — the failure is silent, so verify the deploy rather
than assuming it.

`.github/workflows/deploy-firestore.yml` handles it: a push touching
`firestore.rules` triggers the job, gated on the `production` environment. It is
a merge-time action requiring production credentials, not something to run from a
laptop.

**Check whether a deploy is pending:**

```bash
node scripts/ci/check-firestore-deploy-drift.mjs
```

It compares the repo's rules hash against what is live and names the project to
deploy to. A non-zero exit means the deployed rules are behind.

**Pre-deploy gates, all runnable locally:**

```bash
node scripts/ci/check-firestore-rules-size.mjs      # 60.6% of the source limit
node packages/data-domains/driftcheck.mjs           # every subcollection registered
cd firestore-rules-tests && npm test                # emulator suite
```

Note that rules drift at this repo predates the inbox — the hash was already
behind before these collections existed. Deploying is therefore a broader
prerequisite than this feature, and worth confirming independently.

---

## Operating notes

- **Nothing appears?** The inbox is off by default. Turn it on in settings; the
  first tick runs within `tickSeconds`.
- **Is it running?** The list header states when the last analysis ran and what
  it cost. `burnbar_inbox_status` returns the same telemetry.
- **Index lag.** The app's parser refresh runs on a ~10-minute cadence, so
  indexed tables trail reality. Agent-log mtimes are in the gate signature
  precisely so the tick after indexing catches up; `index_health` surfaces the
  gap when it matters.
- **The daemon needs `OPENBURNBAR_INDEX_DATABASE_PATH`.** Without it the inbox
  (like code memory and resume) is unavailable.
