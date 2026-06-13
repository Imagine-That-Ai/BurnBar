# Agentic AI Threat Model

Agentic AI is a primary risk driver for BurnBar. The secure posture is not "agents are trustworthy"; it is "agents are constrained, observable, reversible where possible, and denied dangerous actions unless deterministic policy and the user allow them."

## Agent Inventory

| Agent/component | Purpose | Autonomy | User represented | Identity used | Tools/data | Network/filesystem | Approval | Logs/kill switch | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Desktop run service | Manage agent runs and tool calls | Level 2-4 depending tool | Local desktop user | Daemon/controller/run identity | read/search/apply/terminal/browser/mac input | Local filesystem/process/browser | high-risk approval | daemon journal/audit; run stop | Desktop |
| CLI agents (Claude/Codex/Droid/Forge/etc.) | Model-driven coding/actions | Level 1-5 depending YOLO/grants | Local desktop user | Local process credentials | workspace, shell, provider creds if accessible | Filesystem/network/shell | varies by grant/profile | CLI logs, process kill | Desktop |
| Computer Use coordinator | Browser/desktop automation | Level 2-4 | Local user | session/capability identity | browser/mac input/screenshot | Browser/desktop | gate/approval except read-only/trusted scopes | parent-hash audit | Desktop |
| Hosted MCP agent surface | Remote MCP access to cloud search/status/resume | Level 0-3 | Authenticated user | bearer token, client grant, scopes | encrypted search, bodies, resume, status | Cloud APIs/local decrypt shim | scope/entitlement/rate | hosted audit | Cloud |
| Local MCP server | Local history/search/decrypt/resume/budget | Level 0-4 | Local user | local process trust | SQLite, CloudVault, memory, resume | Local files/network | local process trust | local logs | Tools |
| Memory hook | Extract and store memories from transcripts | Level 1-3 | User/project | local CLI/provider identity | transcripts, embedding/cloak/seal queues | Local/cloud | not fully proven | hook/test logs | Tools |
| Hosted answer/insights | Generate insight answers via provider | Level 0-1 | Authenticated user | Function/provider key | digest, question, usage | OpenRouter/provider | no direct tool execution | audit metadata | Cloud |
| Hermes remote control agent | Device-to-device command/approval path | Level 2-4 | User on paired devices | Gateway client token + PoP | messages, approvals, attachments | Relay/local agent | approvals for high-risk | Gateway/audit | Cloud/Desktop |

Level 5 exists when a user enables YOLO/unrestricted shell or trusted scopes that permit high-impact execution without per-action approval. Treat Level 5 as high risk and acceptable only for explicit expert/operator modes with strong warnings, short duration, and audit.

## Autonomy Classification

| Level | Definition | BurnBar examples | Risk |
| --- | --- | --- | --- |
| 0 | Read/display only | hosted status, read-only browser inspect | Low/Medium if data sensitive |
| 1 | Suggest action, no execution | insight analysis, draft response | Medium due prompt disclosure |
| 2 | Draft action requiring user approval | model requests patch/terminal approval | Medium |
| 3 | Execute low-risk reversible action | search/read within workspace | Medium due data exfiltration |
| 4 | Execute high-risk action only with explicit approval | apply patch, terminal, browser/mac input approval | High |
| 5 | Autonomous high-impact action | YOLO shell, unrestricted grants, trusted desktop scopes | Critical/High |

## Tool Capability Matrix

| Tool | Description | Risk | Inputs | Outputs | Side effects | Data accessible | External calls | Auth used | Approval | Rate limit | Sandboxing | Logging | Reversible | Abuse cases | Validation | Code |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| read/search | Read workspace/context | Medium | paths/query | file/text snippets | none | local files/history | no | daemon/run | usually no | local | workspace policy | journal | no | secret exfil via prompt | path/workspace checks partial | `BurnBarToolContracts.swift` |
| applyPatch | Modify files | High | patch/path | success/errors | file writes | workspace | no | daemon/run | yes unless bypass | local | workspace policy | journal/audit | partly via git/manual | malicious code injection | pending invocation/controller | `ToolDispatch.swift` |
| runTerminal | Execute shell | Critical | command/env/cwd | stdout/stderr | arbitrary process | user account | yes | daemon/run | yes unless YOLO | local | limited allowlists in launch service; not full sandbox | audit/redacted logs | no | RCE, exfil, persistence | arg/env/cwd checks for launch paths | `SwitcherCLILAunchService.swift` |
| browser action | Browser automation | High | URL/action/selector | page state | clicks/forms/downloads | browser session | yes | session/capability | usually yes | session | target checks | audit chain | partly | CSRF/account abuse | URL/capability gate | `ComputerUseRunCoordinator.swift` |
| mac input | Desktop input/screenshot | Critical | coordinates/keys | UI state | desktop control | screen/apps | no/indirect | session/capability | yes | session | app mode limits | audit chain | no | approve prompts/click secrets | capability gate | `ComputerUseRunCoordinator.swift` |
| hosted search | Cloud encrypted search | Medium | query hashes/facets | sealed results/metadata | none | user cloud index | no | bearer/scopes/Pro | no | yes | service isolation | hosted audit | no | scoped data scraping | owner/scopes | `services/hosted-mcp/src/search.ts` |
| hosted body read | Read encrypted body page | Medium/High | resource URI/cursor | encrypted page/local decrypt mode | none | user cloud bodies | no | bearer/scopes/Pro | no | yes | scopes | hosted audit | no | token theft data access | owner path/hash | `resources.ts` |
| resume/spawn | Start local/remote resume | High | argv/session | process/run status | process execution | local workspace/history | yes | MCP grant/local trust | uncertain | partial | allowlisted argv; no shell | audit/logs | no | arbitrary agent launch | argv allowlist | `resume.ts` |
| memory write | Extract/store memory | High | transcript/context | memory item | persistent memory | prompts/secrets | provider/embed | local/cloud auth | not fully proven | partial | redaction/sealing | hook logs | maybe delete | poisoning/secret retention | redaction/confidence only | `memoryHook.ts` |
| provider answer | Model inference | Medium/High | digest/question | JSON answer | provider disclosure | digest/user question | OpenRouter/provider | API key | no direct tools | provider | JSON schema/output filter | audit | no | malicious answer/data leak | prompt wrapping/schema | `insightsHostedAnswer.ts` |

## Policy Boundary

| Question | Current answer |
| --- | --- |
| Who decides whether a tool call is allowed? | Deterministic Swift/TypeScript policy and grant/scope checks for reviewed paths. |
| Is policy model judgment? | High-risk approval is deterministic; model can request tools or approvals but should not be final authority. |
| Can model output bypass policy? | Not directly in reviewed high-risk paths, but YOLO/trusted grants and local MCP may provide broad authority. |
| Bound to user identity? | Cloud paths bind to Firebase uid; local paths bind to local OS user/run/controller. |
| Bound to device identity? | Gateway and trusted-device proofs bind to device identities; local tools bind less strongly. |
| Time/task scoped? | Some tokens/nonces expire; local grants/task scopes need complete inventory. |
| Can agent request privilege escalation? | It can request approval/high-risk actions; user or policy must grant. |
| Can agent modify its policy? | Not directly proven; local shell can modify files/config if granted. |
| Are high-impact actions hard-blocked without approval? | Partially; bypass modes/trusted scopes exist. |

## Prompt and Context Boundaries

| Source | Trust | Risk | Existing control | Gap |
| --- | --- | --- | --- | --- |
| System/developer prompts | Trusted if shipped code | Prompt leakage/override | prompt construction code | Full prompt inventory not included |
| User prompts | User-controlled | unsafe instructions/secrets | direct user intent | no automatic safety guarantee |
| Retrieved documents/webpages/emails | Attacker-controlled | indirect prompt injection | `<UNTRUSTED_CONTENT>` wrappers, truncation | no hard instruction/data separation |
| Tool outputs | Untrusted | tool-output injection | journal/tool schema | model may treat output as instruction |
| Memory | Partially trusted | persistent poisoning | redaction/confidence/sealing | provenance/quarantine incomplete |
| Logs/code files | Partially trusted | malicious instructions in code/comments/logs | wrappers/truncation | no deterministic semantic firewall |
| Model provider responses | Untrusted | unsafe recommendations/tool requests | JSON schema/filter, policy gating | malicious output can still socially engineer |

## Memory and RAG Security

Findings:

- Memory extraction from transcripts is model-mediated and can process attacker-controlled content.
- Redaction and confidence filtering reduce obvious leakage but do not prove absence of poisoned instructions or secrets.
- Knowledge memory uses sealed/cloaked storage and owner scoping, but metadata remains visible.
- Retrieval results need stronger source attribution and trust labels in every agent prompt.
- Old memory can affect new tasks unless task/project/user scoping and deletion are enforced.

Required controls:

- Memory write allowlist by source and trust level.
- Secret scanner before memory commit.
- Quarantine lane for low-confidence or instruction-like memory.
- Provenance fields: source file/session, timestamp, author/device, trust label, model used, redaction version.
- User-visible delete and purge tests.
- Canary prompt/documents to detect instruction following from memory.

## Agent Monitoring

Existing:

- Computer-use parent-hash audit chain.
- Daemon run journals and approval state.
- Hosted MCP audit events with hashed client/IP/JTI/scopes/tool/latency.
- Server logging/Sentry scrubbing.

Gaps:

- Central cross-device action timeline not proven.
- Tamper-evident cloud audit not proven.
- Goal drift/anomaly detection not proven.
- Complete prompt/context logging is risky and not implemented as a safe audit channel.
- Local logs may leak context; redaction coverage incomplete.

## Agentic Controls To Implement

1. Least agency: default to Level 0-2 unless the user explicitly chooses higher autonomy.
2. Least privilege: per-tool, per-project, per-time grants.
3. Deterministic policy engine for every tool and MCP function.
4. Structured tool schemas with strict argument validation.
5. Output validation and safe renderers for untrusted tool/model output.
6. Explicit user approval for high-impact actions, with exact command/path/domain/diff shown.
7. Reversible operations where feasible; snapshot before patch/terminal destructive actions.
8. Execution sandbox for shell and browser agents.
9. Network egress controls for local agents.
10. Filesystem scoping and deny-by-default secrets paths.
11. Prompt-injection filters only as defense-in-depth.
12. Memory write gates, provenance, and delete tests.
13. Agent identities and per-action authorization.
14. Just-in-time short-lived credentials.
15. Tamper-evident audit logs with privacy-preserving redaction.
16. Kill switch for local daemon, Gateway clients, hosted MCP grants, provider keys, and memory ingestion.
17. Rate limits and cost limits per user/device/tool.
18. Canary documents and regression red-team suite.
