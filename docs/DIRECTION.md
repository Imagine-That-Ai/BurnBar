# BurnBar Direction

## Thesis

BurnBar wins if it becomes the memory and control plane for AI-assisted software work.

Today, the product already sees valuable signals: local session logs, provider usage, summaries, session records, and editor/daemon state. The next step is not to add random surface area. The next step is to unify those pieces into one coherent system that makes prior work easy to find, easy to reuse, and eventually easy to improve.

## Strategic Direction

### 1. From metering to memory

The current product is strongest at observing usage and spend. That remains important, but it is not the long-term wedge by itself.

BurnBar should become the place where a user can search across all conversations with all agents, recover prior technical decisions, and continue work without context loss.

### 2. From summaries to retrieval

Summaries are helpful, but they are not enough. BurnBar should index the underlying artifacts and expose a shared retrieval layer across:

- conversations
- transcripts
- skills
- agent docs such as `AGENTS.md`
- stable derived rollups and insights

This retrieval layer is the foundation for search, drafting, context packs, and workflow improvement.

### 3. Local-first by default, cloud where it adds value

BurnBar should keep local GRDB/SQLite as the hot-path authority for interactive search and indexing. Cloud should add:

- replication across devices
- backup
- shared team libraries
- auditability
- collaboration
- organization-level insight

This keeps the core experience fast and private while still allowing a sellable team product.

### 4. Source artifacts are first-class

BurnBar should not flatten everything into summaries. The real source artifacts should remain first-class:

- raw session logs
- parsed conversation records
- discovered skill files
- agent instruction docs
- shared team artifacts

Derived assets like snippets, embeddings, summaries, and insights should be rebuildable.

### 5. Team features must be production-defensible

If BurnBar holds shared skills and shared agent docs, it also needs:

- RBAC and visibility rules
- audit events
- explicit health states
- conflict handling for collaboration
- clear degraded-mode behavior when cloud features are unavailable

The bar is "safe to trust with a real team," not "good enough for a demo."

## Product Pillars

### Observe

Capture the real work happening across agents, providers, editors, and machines.

### Remember

Index and retrieve work across conversations and artifacts with high recall and fast local latency.

### Reuse

Turn prior work into skills, agent docs, and context that help users move faster next time.

### Improve

Show patterns, bottlenecks, and high-leverage opportunities that change user behavior.

### Share

Let teams promote useful knowledge into shared memory with the right controls and collaboration model.

## Explicit Product Decisions

- BurnBar is not becoming a cloud-only system.
- BurnBar is not replacing the user's primary editor or terminal.
- BurnBar is not a shallow analytics dashboard with pretty graphs and weak operational value.
- BurnBar is not a generic enterprise knowledge base divorced from actual agent work.

## 12-Month Directional Outcomes

If we execute well, within 12 months BurnBar should be known for:

- the best cross-agent local search and memory layer for coding work
- a strong local-first team knowledge product for skills and agent docs
- credible workflow insights grounded in real work instead of vanity metrics
- a tighter extension + daemon loop that makes BurnBar useful during work, not only after it
