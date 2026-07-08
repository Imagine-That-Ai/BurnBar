---
name: zenith
description: Runs a long-running mission using the Zenith continuous-improvement harness to dynamically orchestrate workers, testing, and stopping discipline.
---

# Zenith: Long-Running Task Harness

When this skill is invoked:
1. First read [.agents/orchestrator_prompt.md](file:///Users/albertonunez/Documents/Developer/BurnBar/.agents/orchestrator_prompt.md) and treat it as your primary role.
2. Use Zenith to run this mission.

## About the Zenith Harness
Zenith is a continuous-improvement harness designed specifically for long-horizon, complex tasks where the primary failure mode is premature completion. It uses an adaptive control loop to dynamically allocate workers, run validators, update task lists, and make authoritative stopping decisions.

## Setting Up Zenith in a Workspace
Initialize the workspace using the Zenith CLI:
```bash
# Run from the local share zenith checkout:
uv run zenith init --workspace-dir /Users/albertonunez/Documents/Developer/BurnBar --agent antigravity
```
This writes `.mcp.json` with the Zenith stdio server registration, and stages the orchestrator system prompt at `.agents/orchestrator_prompt.md`.

## Running Zenith
Start your agent from the workspace:
```bash
# Verify the zenith MCP server is running in the agent environment.
# Then ask the agent:
First read .agents/orchestrator_prompt.md and treat it as your primary role, then use Zenith to run this mission.
<your instructions/query>
```
