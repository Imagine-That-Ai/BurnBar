# TODOS

## Agent Roadmap

### Add Browser Tools After Core Agent Stabilizes

**What:** Add browser automation tools to BurnBar after the daemon-native coding agent is stable.

**Why:** Browser actions unlock end-to-end UI debugging, auth-flow reproduction, and web app verification that terminal and file tools alone cannot cover.

**Context:** The current review intentionally kept browser tooling out of the v1 coding-agent lake so the team can ship planning, context selection, recovery, journaling, and workspace execution first. BurnBar already has the right daemon/extension split, so browser tools should be added as another policy-governed tool family after the single-agent core is proven reliable.

**Effort:** L
**Priority:** P2
**Depends on:** Stable daemon-native planner, recovery engine, policy engine, and run journal

### Add Rich Run Playback And Diff Inspector

**What:** Add a richer run playback view in the Cursor extension showing plan steps, tool calls, applied edits, terminal commands, approvals, and recovery decisions.

**Why:** Users will need to understand what BurnBar did, why it paused, and how it recovered when real coding runs become common.

**Context:** This review chose a daemon-owned persistent run journal specifically so richer playback can be added later without redesigning the backend. The current extension surfaces only compact run detail and recovery hints; once the full coding agent lands, that will not be enough for trust and debugging.

**Effort:** M
**Priority:** P2
**Depends on:** Run journal with typed planner, tool, approval, and recovery events

### Add Multi-Agent Orchestration After Single-Agent Matures

**What:** Add multi-agent orchestration for parallel investigate/implement/verify workflows after the single-agent system is stable.

**Why:** Multi-agent execution can improve throughput on larger tasks, but it is not necessary to deliver a full single-agent coding experience.

**Context:** The current review explicitly kept multi-agent work out of scope because it would expand the run graph, approvals, arbitration, UI, and test matrix significantly. This should only be revisited once the single-agent daemon-native flow is reliable and well-observed in production-like use.

**Effort:** XL
**Priority:** P3
**Depends on:** Stable single-agent planner, policy engine, run journal, and reconnect/arbitration behavior

### Expand Provider And Model Coverage After Core Agent Launch

**What:** Expand BurnBar’s routed provider/model support beyond the current core set after the full coding agent is stable.

**Why:** Broader model support increases user choice and market coverage, but it should not be mixed into the core agent stabilization work.

**Context:** BurnBar’s current provider scope is intentionally narrow in the docs and current architecture. This review kept provider breadth separate from agent depth so routing/auth/test complexity does not distract from planner, context, recovery, and execution reliability.

**Effort:** L
**Priority:** P3
**Depends on:** Stable daemon-native coding agent core and provider-routing test coverage

## Completed
