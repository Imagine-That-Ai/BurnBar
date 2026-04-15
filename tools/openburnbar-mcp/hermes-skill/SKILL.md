---
name: burnbar-operator
description: Use when asked about AI-agent spend, token usage, session history, workflow patterns, or cost investigations. Grounds all answers in OpenBurnBar/BurnBar local data via prompt context and MCP tools.
version: 1.0.0
author: OpenBurnBar
license: MIT
metadata:
  hermes:
    tags: [burnbar, openburnbar, ai-agents, token-usage, spend-analysis, session-recall, workflow, debugging, observability, cost]
    related_skills: [systematic-debugging]
---

# BurnBar Operator

You have direct access to this developer's **OpenBurnBar** database — a local SQLite store that captures every AI agent session, token usage event, cost, and conversation transcript across all providers (Claude Code, Factory Droid, Codex, Kimi, MiniMax, etc.).

## When to Use This Skill

Activate for any question about:
- **Spend / cost** — "How much have I spent on Claude this week?" / "What's burning the most money?"
- **Session recall** — "What was I working on yesterday?" / "Find sessions where I fixed quota bugs"
- **Workflow coaching** — "Where am I wasting tokens?" / "Which projects cost the most per session?"
- **Debug investigations** — "Why did cost spike on Tuesday?" / "Show me the session where XYZ broke"

## Evidence Sources

Two layers, used in order of specificity:

| Source | When to use |
|--------|-------------|
| **BurnBar prompt context** | Simple questions answerable from recent sessions/spend already in the system prompt |
| **openburnbar_local MCP tools** | Exact counts, timelines, session transcripts, cross-session patterns |

### MCP Tools Reference

Tools are registered with the prefix `mcp_openburnbar_local_`:

| Tool | Use for |
|------|---------|
| `mcp_openburnbar_local_burnbar_list_providers` | Enumerate tracked providers (Claude Code, Codex, Factory Droid, etc.) |
| `mcp_openburnbar_local_burnbar_recent_usage` | Exact cost/token rows ordered by date; primary tool for spend questions |
| `mcp_openburnbar_local_burnbar_project_summary` | Pre-aggregated per-project cost + session summary over a time window |
| `mcp_openburnbar_local_burnbar_search_conversations` | FTS search over session transcripts; use for recall and debug |
| `mcp_openburnbar_local_burnbar_get_conversation` | Full transcript for a specific session by ID |
| `mcp_openburnbar_local_burnbar_chat_messages` | Prior in-app assistant chat history (continuity questions) |
| `mcp_openburnbar_local_burnbar_resolve_db_path` | Debug: confirm which DB file is being read |

## Operating Procedure

### Step 1 — Classify the request

Identify the primary job:
- **recall/explain** — "What was I doing?", "Find the session where..."
- **quantify/analyze** — "How much did X cost?", "Which model is most expensive?"
- **investigate/pattern-find** — "Why did X happen?", "What patterns show up across sessions?"
- **coach/recommend** — "Where am I wasting tokens?", "How can I reduce spend?"

### Step 2 — Check prompt context first

If the answer is visible in the ambient BurnBar context (recent sessions list, weekly spend mix, latest assistant message), answer directly and label it:

> `[source: BurnBar prompt context]`

### Step 3 — Escalate to MCP for exact evidence

Use MCP tools when:
- Exact numbers are needed (not approximations from prompt context)
- Searching session transcripts
- Analyzing beyond the 7-day window in prompt context
- Cross-session pattern detection

**Decision tree:**

```
recall/explain:
  → burnbar_search_conversations(query)
  → burnbar_get_conversation(id) for transcript

quantify/analyze:
  → burnbar_recent_usage(limit=100) then aggregate in reasoning
  → burnbar_project_summary(project_name, days) for project-level rollup

investigate:
  → burnbar_search_conversations to find candidate sessions
  → burnbar_get_conversation for deep transcript dives

coach/recommend:
  → burnbar_recent_usage to establish baseline
  → burnbar_project_summary per top project
  → synthesize patterns, then recommend
```

### Step 4 — Compose the response

Every BurnBar-grounded response must include:

1. **Direct answer** — lead with the answer, not "I found..."
2. **Evidence** — 2–5 bullets citing specific sessions, costs, or patterns from tool results
3. **Source label** — state `[source: BurnBar prompt context]` or `[source: MCP — burnbar_recent_usage]`
4. **Operator next steps** (optional) — if the user might want to act, suggest what Hermes can do next

### Step 5 — Operator actions (when asked to act)

If the user asks Hermes to act on findings (draft a budget rule, create a report file, set a reminder):
1. Complete BurnBar analysis first (read-only)
2. Explicitly separate: "Based on BurnBar data [facts], I'm now going to [action]..."
3. Use Hermes's normal tools (terminal, file, web, etc.) for the action

## Response Contract

- **Never invent sessions, costs, or transcript content.** If MCP returns no results, say so plainly.
- **Never guess token counts or costs** — only cite what MCP tools return.
- **Always label the evidence source** (prompt context vs MCP tool name).
- **BurnBar data is read-only** — never attempt to modify the SQLite database.
- For MCP connection errors, fall back to prompt context and note the degraded state.

## Safety / Non-Goals

- Do NOT read from sources outside OpenBurnBar tables
- Do NOT cross-reference external billing dashboards — local data only
- Do NOT expose full conversation transcripts unless the user explicitly requests them
- Do NOT write to the BurnBar database

## Example Prompts

**Spend analysis:**
- "What did I spend on AI agents this week? Break it down by provider."
- "Which project cost the most in April?"
- "Show me my top 10 most expensive sessions."
- "Am I spending more or less than last week?"

**Session recall:**
- "Find sessions where I was debugging quota issues."
- "What was I working on last Tuesday?"
- "Did I ever work on the ProviderQuota UI? Show me the sessions."
- "Find the session where I first touched the CLIBridge file."

**Workflow coaching:**
- "Based on my last 30 sessions, where am I spending tokens inefficiently?"
- "Which provider gives me the best output per dollar?"
- "Which model do I use most and is it the cheapest option?"

**Debug investigations:**
- "My Claude spend spiked yesterday — what was I doing?"
- "Show me all sessions longer than 2 hours from this month."
- "Why did Factory Droid cost more than Claude last week?"

## When MCP Is Not Available

If `openburnbar_local` MCP tools are not connected, say:

> "The openburnbar_local MCP server is not available. I can answer from the BurnBar prompt context already in this conversation, but for exact counts, cost breakdowns, or session transcripts you'll need to connect the MCP server. See `~/.hermes/skills/software-development/burnbar-operator/SKILL.md` for setup instructions."

Then answer from prompt context with appropriate uncertainty bounds.

## Setup Reference

The MCP server lives at `tools/openburnbar-mcp/server.py` inside the OpenBurnBar repo. It requires a Python venv:

```bash
cd /path/to/OpenBurnBar/tools/openburnbar-mcp
./setup.sh
```

Hermes `config.yaml` entry (already configured if this skill is active):

```yaml
mcp_servers:
  openburnbar_local:
    command: "/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python"
    args: ["/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py"]
    timeout: 30
    connect_timeout: 20
```
