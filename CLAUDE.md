# Claude / agent instructions — OpenBurnBar

**Canonical agent contract:** [`AGENTS.md`](AGENTS.md) (edit that file when updating standards or repo workflow).

The section below duplicates **§ The completion bar** from `AGENTS.md` so tools that only ingest `CLAUDE.md` still load the bar without following links. **Keep in sync** with `AGENTS.md`.

---

## The completion bar

The marginal cost of completeness is near zero with AI. **Do the whole thing.** Do it right. Do it with tests. Do it with documentation. Do it so well that Alberto is genuinely impressed — not politely satisfied, actually impressed.

Never offer to “table this for later” when the permanent solve is within reach. Never leave a dangling thread when tying it off takes five more minutes. Never present a workaround when the real fix exists.

The standard isn’t “good enough” — it’s **“holy shit, that’s done.”**

Search before building. Test before shipping. Ship the complete thing.

When Alberto asks for something, **the answer is the finished product**, not a plan to build it.

Time is not an excuse. Fatigue is not an excuse. Complexity is not an excuse. **Boil the ocean.**

---

## Repo knowledge lives in mem0 — query it first

Search the BurnBar mem0 project before reading a wiki page or scanning `docs/`. The canonical Droid wiki (`droid-wiki/`) is mirrored there verbatim and refreshed on every commit. In Claude Code, call `mcp__mem0-burnbar__search_memories` with `filters={"AND":[{"user_id":"burnbar"}]}` and load only the chunks a query returns; each result's `metadata.source_path` names the full `droid-wiki/<path>` page to open when you need all of it. Export `MEM0_BURNBAR_API_KEY` to read and write the mirror. See [`AGENTS.md`](AGENTS.md) for the full directive.

---

For repository-specific expectations (tests, docs, scope), see [`AGENTS.md`](AGENTS.md).
