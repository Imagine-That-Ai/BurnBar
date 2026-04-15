# OpenBurnBar Direction

## Where the product is now

OpenBurnBar already ships four real layers:

1. **Usage visibility** in the macOS app for spend, tokens, quota, and provider activity
2. **Local retrieval** over conversations and source artifacts in SQLite
3. **Daemon-backed operating surfaces** for projects, questions, followups, missions, replay, and connector status
4. **Editor integration** through the Cursor / VS Code extension and optional routed-provider connector

That shipped reality matters. The next phase is not a reset. It is tightening these layers into one coherent operating system for AI-assisted development.

## North star

OpenBurnBar should become the local-first operating layer for multi-agent software work.

That means a user should be able to open OpenBurnBar and reliably answer:

- What is my active project?
- What just happened across my agents?
- What is the current mission and direction call?
- What evidence supports that read?
- What should I do next?

## Strategic direction

### 1. Make operating summaries first-class

The new operating layer should stay grounded in indexed conversations, burn, and retrieval health rather than generic copy. Mission, direction, evidence, freshness, and controller runtime need to remain concise, explainable, and overrideable.

### 2. Keep retrieval as the spine

Search, chat context, operating summaries, and future workflow intelligence should all depend on the same local retrieval substrate. If a feature cannot point back to local evidence, it should not drive the operating view.

### 3. Strengthen the daemon/editor loop

The daemon and extension should keep moving from “helpful companion” to “working control plane”:

- stable project identity
- daemon-owned missions, questions, and followups
- replayable runs
- recoverable connector and browser-tool state
- useful state inside the editor while work is happening

### 4. Be explicit about confidence and degradation

Direction should know when signal is sparse. Mission should know when indexing health is degraded. Burn should know when values are estimated. The product should prefer honest partial answers over confident fiction.

### 5. Expand collaboration without giving up local authority

Firestore and shared artifacts can grow into a team feature set, but local SQLite and daemon-owned state remain the product spine. Shared memory only works if ownership, visibility, conflict handling, and auditability stay clear.

## What not to do

- Do not turn OpenBurnBar into a cloud-only dashboard.
- Do not let team features bypass local provenance.
- Do not add decorative analytics that are not operationally useful.
- Do not hide sparse signal behind polished language.

## 12-month aim

If this direction holds, OpenBurnBar should be known for three things:

- the clearest local operating read on multi-agent coding work
- the most credible local-first retrieval layer for agent conversations and artifacts
- a daemon + editor loop that helps during execution, not just after the fact
