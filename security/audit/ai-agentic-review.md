# AI and Agentic Security Review

This phase applies. The repository includes Computer Use, MCP, local tools, hosted MCP, approval policies, local daemon execution, and memory-like cloud resources.

## L.1 AI Component Inventory

| Component | Purpose | Provider/model | Data sent | Tools available | Memory available | Autonomy | Logs | Evidence |
|---|---|---|---|---|---|---|---|---|
| Computer Use coordinator | Browser/system action orchestration | local/browser automation and agent integrations | action intent, evidence, screenshots depending on flow | browser/system action dispatch | session state/audit | Level 2-4 depending on trust/action | audit chain, app logs | `ComputerUseRunCoordinator.swift`, `ComputerUseCapabilityGate.swift` |
| Daemon Computer Use service | Daemon-owned browser Computer Use | local daemon/browser | action parameters and session context | browser actions | daemon session state | Level 3-4 | daemon audit/logs | `ComputerUseService.swift` |
| Mobile approval authority | Approve/downgrade trust | mobile app/user | signed approval response | approval only | pinned peer key/counter | Level 1-2 | app/audit logs | `PhoneControlAuthorityValidator.swift` |
| Hosted MCP | Remote tool/resource gateway | MCP clients/hosts | encrypted resources, metadata, tool input | registered MCP tools | cloud search/resource metadata | Level 0-2 in current resource model | audit events | `services/hosted-mcp/src` |
| Remote MCP local shim | Local decryption and query prep | local process | ciphertext to local decrypt; query hashes | local decrypt/search bridge | Keychain vault key | Level 0-1 | local logs | `tools/openburnbar-mcp-remote/src/shim.ts` |

## L.2 Autonomy Classification

| Action class | Level | Evidence | Notes |
|---|---:|---|---|
| View/search encrypted hosted MCP metadata | 0-1 | hosted MCP resources and local shim | read/display or local decrypted read |
| Draft or request Computer Use action | 2 | Computer Use coordinator approval flow | requires approval/trust context |
| Execute low-risk browser actions under trusted policy | 3 | capability gate/action scopes | bounded by budget/session caps |
| Execute high-impact Computer Use action | 4 intended | approval and phone authority | daemon local-auth proof gap weakens production claim |
| Autonomous high-impact actions without approval | 5 | not found as intended design | should remain prohibited |

## L.3 Tool Capability Matrix

| Tool/surface | Inputs | Outputs | Side effects | Credentials | Network/file access | Approval required | Policy check | Rate limit | Sandboxing | Logging | Reversibility | Abuse cases |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Daemon RPC | JSON RPC request | result/error | local actions | socket token | local process/browser | for Computer Use actions | capability profile + gate | daemon limiter | local endpoint/code-signature peer | daemon logs/audit | varies | stolen token, compromised signed app |
| Daemon HTTP gateway | HTTP JSON | result/error | local gateway actions | bearer/x-api-key | loopback HTTP | method-specific | gateway auth/routes | gateway limiter | loopback/CORS | gateway logs | varies | unauth debug misuse |
| Computer Use action dispatcher | action intent | action result/audit | browser/system action | session/user authority | browser/system | yes for high-risk | `ComputerUseCapabilityGate` | budgets/caps | action kind/scope/deny regions | audit chain | varies | prompt injection, confused deputy |
| Hosted MCP resources | MCP method/tool input | encrypted resource/search output | read/search | bearer token | Firestore/Storage | token grant required | scope/client/entitlement | Firestore-backed bucket | server resource constraints/local decrypt | hashed audit | read-only mainly | token theft/over-scope |
| Remote MCP local shim | ciphertext/query | plaintext local results | local decrypt | Keychain vault key/token | trusted HTTPS/loopback | local user install | endpoint trust check | hosted side | local process | local logs | read-only mainly | credential exfiltration |

## L.4 Agentic Threats

| Threat | Status | Existing control | Gap |
|---|---|---|---|
| Prompt injection causing tool misuse | partially controlled | deterministic capability gate, approvals, deny regions | expand adversarial tests |
| Indirect prompt injection from webpages/docs | partially controlled | approval model, action scopes | browser content threat tests needed |
| Tool-output injection | partially controlled | structured schemas and local policy | hosted MCP output-injection tests needed |
| Memory/context poisoning | partially controlled | scoped resources, local decrypt, audit | provenance and write controls should be reviewed for each memory feature |
| Excessive agency | partially controlled | approval levels, trust modes, panic halt | daemon production proof gap |
| Unauthorized high-impact action | open | approvals, high-risk proofs, daemon token/code-signature | FINDING-001, FINDING-002 |
| Credential leakage to model/provider | partially controlled | local decrypt shim, scrubbers | provider integration review needed |
| Data exfiltration via tools | partially controlled | scopes/rate limits/owner checks | adversarial test suite should expand |
| Lack of kill switch | partially controlled | capability gate has kill switch | daemon context uses false |
| Lack of monitoring | partially controlled | audit chain, structured logs | alert playbooks need proof |

## L.5 Required Agentic Controls

| Control | Status | Evidence | Gap |
|---|---|---|---|
| deterministic policy engine for tool calls | present | `ComputerUseCapabilityGate.swift:232-373` | daemon context issue |
| least-privilege tool permissions | partial | hosted MCP scopes, daemon capability profile | map all daemon methods |
| explicit approval for high-impact actions | partial | approvals and high-risk owner proof | daemon local proof not wired |
| structured tool schemas | partial | hosted MCP tool registry input schemas | verify all tools |
| input validation | present | validators, daemon limits, hosted MCP bounds | URL bug |
| output validation | partial | resource wrappers/redaction | tool-output injection tests needed |
| memory write controls | partial | Firestore rules and owner scopes | memory provenance review needed |
| context isolation | partial | uid/client scopes | cross-session tests needed |
| short-lived credentials | present for hosted MCP | 15 minute access tokens | rotation runbook unknown |
| per-action authorization | present in many flows | gate/high-risk nonces | daemon wiring gap |
| network/file sandboxing | partial | daemon local boundary, endpoint trust check | Mac System path distribution review |
| tamper-evident audit logs | present in Computer Use/export | audit chain and audit log | deletion audit gap |
| user-visible action history | partial | audit/action logs | UX not reviewed |
| kill switch | partial | capability gate | daemon context issue |
| rate limits | partial | hosted MCP and daemon | public Functions need inventory |
| adversarial prompt-injection tests | partial/unknown | security smoke referenced | expand and map to threats |

