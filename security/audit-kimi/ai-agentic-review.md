# AI, Agentic, Tool, Memory, and RAG Security Review

## A.11.1 Threat Surface

OpenBurnBar intentionally processes untrusted agent logs and feeds them into:

1. **Local dashboard** — parsed logs rendered in UI.
2. **Chat / RAG** — `ContextBuilder.swift` retrieves relevant log snippets and builds prompts.
3. **Hosted encrypted search** — server indexes sealed content; returns matching hashes.
4. **Remote MCP** — external agents can query/search the user's BurnBar data.
5. **Computer Use** — tools can read screen, type, click, run browser, execute shell.

## A.11.2 Log Parser Security

- 17 parsers in `AgentLens/Services/LogParser/`.
- Parsers read JSON/XML/text from AI agent logs.
- Risk: malicious log files could exploit parser bugs, cause memory exhaustion, or inject control sequences.
- Mitigation: parsers use Codable/XMLParser; delimiter wrappers were added recently.

**Finding**: FINDING-019 — parser size/depth limits and adversarial tests incomplete.

## A.11.3 Prompt / RAG Injection

- `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` documents the threat.
- Delimiter wrappers added around untrusted content.
- **Gap**: coverage not uniform across all 17 parsers, `ContextBuilder`, `ChatSessionController`, and Computer Use tool-result paths.
- **Gap**: no provenance wrapper (e.g., signed digest) proving a snippet came from a real log vs. injected.

**Finding**: FINDING-004 — prompt/RAG injection defenses partial.

## A.11.4 Computer Use

- Implemented in `AgentLens/Services/ComputerUse/` and daemon helpers.
- Approval modes: Trusted / Step / Manual.
- Kill switch: hotkey, phone gesture, auth gate, Remote Config.
- Audit chain: SHA-256 chain + optional OTS.

### Gaps

- **Adversarial tests** for UI bypass, scope escalation, and tool-kind abuse are not complete.
- **Scope enforcement** relies on daemon implementation; no formal policy language.
- **Phone HID binding** (M-028) needs stronger capability-token binding.
- **Remote Unlock helper** (M-001) missing from bundle.

**Finding**: FINDING-003 — Computer Use adversarial test gaps.

## A.11.5 MCP and Tool Access

### Local MCP

- `tools/openburnbar-mcp/server.py` exposes `search_burnbar` tool.
- Returns semantic-search snippets from local DB to any MCP client.
- **No human gate**: an external agent can request arbitrary context.

**Finding**: FINDING-008 — local MCP exposes raw search snippets.

### Hosted Remote MCP

- `services/hosted-mcp/src/toolRegistry.ts` defines tools.
- Audience-bound bearer tokens; entitlement rechecks.
- Server cannot decrypt content; search operates on sealed index.
- Stronger than local MCP but still allows automated access.

## A.11.6 Memory / Knowledge

- `functions/src/callables/knowledgeMemory.ts` writes memory entries.
- Encrypted hosted search indexes them.
- Risk: poisoned memory — a malicious log or external query could corrupt future RAG.
- No integrity check on memory provenance visible.

## A.11.7 Prior Audit Items (AI/Agentic)

| ID | Title | Status | Notes |
|---|---|---|---|
| M-001 | Remote Unlock helper missing | Open | Security feature incomplete |
| M-028 | Capability token HID binding | Open | Phone control needs token binding |
