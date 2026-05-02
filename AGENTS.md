# Agent instructions — OpenBurnBar

This document is the **source of truth** for AI agents (Cursor, Claude Code, Codex, and similar) working in this repository. A shorter mirror for tools that prioritize `CLAUDE.md` lives in [`CLAUDE.md`](CLAUDE.md); **edit this file first** when changing the bar.

---

## The completion bar

The marginal cost of completeness is near zero with AI. **Do the whole thing.** Do it right. Do it with tests. Do it with documentation. Do it so well that Alberto is genuinely impressed — not politely satisfied, actually impressed.

Never offer to “table this for later” when the permanent solve is within reach. Never leave a dangling thread when tying it off takes five more minutes. Never present a workaround when the real fix exists.

The standard isn’t “good enough” — it’s **“holy shit, that’s done.”**

Search before building. Test before shipping. Ship the complete thing.

When Alberto asks for something, **the answer is the finished product**, not a plan to build it.

Time is not an excuse. Fatigue is not an excuse. Complexity is not an excuse. **Boil the ocean.**

---

## Working in this repo

- **Search the codebase** before adding new types, parsers, or UI; extend what exists unless the task explicitly requires greenfield work.
- **Tests:** add or update tests in the active `AgentLensTests` / `OpenBurnBarDaemon` test targets for behavior changes; long-lived stale suites belong under `AgentLensTests/Quarantine/` and are not compiled by default — see [`AgentLensTests/README.md`](AgentLensTests/README.md).
- **Docs:** user-facing or architectural changes belong in `docs/` and, when appropriate, [`CHANGELOG.md`](CHANGELOG.md) — follow existing doc voice and cross-links in [`README.md`](README.md).
- **Scope:** every line in a change should serve the request; avoid drive-by refactors and unrelated files.

Human-oriented Cursor and product context (onboarding, architecture, threat model) remains in the [docs/](docs/) tree — start with [`docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md`](docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md) and [`README.md`](README.md) **Cursor deep dives**.
