# AI and Agentic Security Review

This phase applies. The repository includes Computer Use, MCP, local tools, hosted MCP, approvals, local daemon execution, and cloud resource memory/search behavior.

## AI Component Inventory

| Component | Purpose | Data sent | Tools available | Memory available | Autonomy | Evidence |
|---|---|---|---|---|---|---|
| Computer Use coordinator | browser/system action orchestration | action intent and evidence | browser/system dispatch | session state/audit | Level 2-4 | `ComputerUseRunCoordinator.swift`, `ComputerUseCapabilityGate.swift` |
| Daemon Computer Use service | daemon-owned browser Computer Use | action parameters/session context | browser actions | daemon session state | Level 3-4 | `ComputerUseService.swift` |
| Mobile approval authority | approve/downgrade trust | signed approval response | approval only | pinned peer key/counter | Level 1-2 | `PhoneControlAuthorityValidator.swift` |
| Hosted MCP | remote tool/resource gateway | encrypted resources and metadata | registered MCP tools | search/resource metadata | Level 0-2 | `services/hosted-mcp/src` |
| Remote MCP local shim | local decrypt/search bridge | ciphertext/query hashes | local decrypt/search | Keychain vault key | Level 0-1 | `tools/openburnbar-mcp-remote/src/shim.ts` |

## Autonomy Classification

| Action class | Level | Notes |
|---|---:|---|
| view/search encrypted hosted MCP metadata | 0-1 | read/display or local decrypted read |
| draft/request Computer Use action | 2 | requires approval/trust context |
| execute low-risk browser actions under trusted policy | 3 | bounded by budget/session caps |
| execute high-impact Computer Use action | 4 intended | daemon proof gap weakens production claim |
| autonomous high-impact action without approval | 5 | not found as intended design |

## Tool Capability Matrix

| Surface | Side effects | Credentials | Approval | Policy check | Rate limit | Abuse cases |
|---|---|---|---|---|---|---|
| Daemon RPC | local actions | socket token | action-specific | capability profile + gate | daemon limiter | stolen token, compromised signed app |
| Daemon HTTP gateway | local gateway actions | bearer/x-api-key | method-specific | gateway auth/routes | gateway limiter | unauth debug misuse |
| Computer Use dispatcher | browser/system action | session/user authority | yes for high-risk | `ComputerUseCapabilityGate` | budgets/caps | prompt injection, confused deputy |
| Hosted MCP resources | read/search | bearer token | grant required | scope/client/entitlement | Firestore bucket | token theft/over-scope |
| Remote MCP shim | local decrypt | Keychain vault key/token | local user install | endpoint trust check | hosted side | credential exfiltration |

## Agentic Threats

| Threat | Status | Existing control | Gap |
|---|---|---|---|
| prompt injection causing tool misuse | partially controlled | deterministic capability gate, approvals | adversarial tests need expansion |
| indirect prompt injection | partially controlled | approval model/action scopes | browser content tests needed |
| tool-output injection | partially controlled | structured schemas/local policy | hosted MCP output tests needed |
| memory/context poisoning | partially controlled | scoped resources, local decrypt, audit | provenance review per memory feature |
| excessive agency | partially controlled | approval levels, trust modes, panic halt | daemon production proof gap |
| unauthorized high-impact action | open | approvals and daemon token/code-signature | FINDING-001, FINDING-002 |
| credential leakage to model/provider | partially controlled | local decrypt shim, scrubbers | provider integration review |
| lack of kill switch | partially controlled | capability gate | daemon context uses false |

## Required Controls

| Control | Status | Gap |
|---|---|---|
| deterministic policy engine | present | daemon context issue |
| least-privilege tool permissions | partial | map all daemon methods |
| explicit high-impact approval | partial | daemon local proof not wired |
| structured schemas | partial | verify all tools |
| input validation | present | URL bug |
| memory provenance | partial | review each memory feature |
| per-action authorization | present in many flows | daemon wiring gap |
| tamper-evident audit | present in Computer Use/export | deletion audit gap |
| kill switch | partial | daemon context issue |
| rate limits | partial | public Functions inventory |
| adversarial prompt-injection tests | partial/unknown | expand and map to threats |

