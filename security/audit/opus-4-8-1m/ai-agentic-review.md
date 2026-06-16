# AI / LLM / Agentic Security Review — Opus 4.8 1M lane

Frameworks: OWASP LLM Top 10 (2025), OWASP Agentic Top 10 (2026). Verdict: **strong and code-enforced.** Both load-bearing claims hold: "untrusted content cannot trigger dangerous actions without approval" and "approval is enforced in code (not prompt)."

## L.1 Components
- **Hermes gateway:** blind store-and-forward E2EE relay; server validates envelope **shape** only, never holds recipient private keys, never decrypts `payloadCiphertext`; prod rejects plaintext writes (`gatewayPlaintextWriteAllowed()=false`). Model routing is agent-side (sealed in envelope). Confirmed user-blind by design and in code (`hermesGatewayEnvelope.ts`).
- **Computer Use:** agentic Mac control with trust modes.
- **Hosted insights / chat analyst:** produces text/JSON, no side effects; sends only a privacy-bounded usage digest (never raw transcripts — `insightsHostedAnswer.ts:241,279`).
- **MCP (remote + local):** hosted = 12 read-only sealed tools; local write tools off by default.
- **Provider adapters (kimi/mimo/etc.):** GET-only quota checks — **no user content** POSTed.

## L.2 Autonomy classification
| Surface | Level | Evidence |
|---|---|---|
| Computer Use — Manual | L1 (per-action approval) | `ComputerUseCapabilityGate.swift:359-372`; coordinator awaits `requestApproval` before `dispatch` `ComputerUseSessionCoordinator.swift:845` |
| Computer Use — Step | L2 (bounded burst) | trust-mode gate fallback |
| Computer Use — Trusted+scope-rule | L3 (deterministic operator policy) | auto-approve ONLY `scopeOutcome==.allowed` `:362-364`; else approval |
| CLI agents (YOLO) | L4 (sandboxed workspace, user-granted) | `CLIArgumentBuilder.isYOLOGrant`; input wrapped `:252` |
| Hosted insights / MCP | L1 read-only | structured JSON / sealed read tools |

**No L5 (fully autonomous high-impact) action exists.** Trusted-mode (L3) is hard-bounded by deterministic scope rules, action cap, session timeout, daily/budget caps, accessibility deny-regions, and 4 panic-kill paths.

## L.3 Computer Use safety invariants — claimed vs enforced
| Invariant | Enforced | Evidence |
|---|---|---|
| Approval is ground truth; no silent auto-pilot | yes | gate `:359-372`; `invoke` awaits approval before dispatch `:845,919` |
| Panic path 1: global hotkey ⌃⌥⌘. | yes | `ComputerUsePanicHaltCoordinator.swift:98-120` |
| Panic path 2: phone gesture | yes | `ComputerUseSessionCoordinator.swift:840,1119,1790` |
| Panic path 3: NSWorkspace auth gate | yes | `ComputerUsePanicHaltCoordinator.swift:161-180` (+AX-revocation poll = 4th path) |
| Remote Config `computer_use_kill_switch` | yes | `:85-87`; gate first check `:233` |
| Leaf kill re-check (race) | yes (stronger than doc) | `MacActionDispatcher.swift:37` |
| Content-addressed tamper-evident audit chain | yes, audit-BEFORE-action | `ComputerUseSessionCoordinator.swift:885-916` reserve entry before dispatch, fail-closed on append failure |
| Budget/loop caps | yes | per-session actionCap+timeout; hard cap $2500 flips kill switch `computerUseBudget.ts:11-12,126` |
| Deny-regions beat signed authority | yes (stronger than doc) | gate `:335` precedes phone-authority honor |
| Untrusted tool-result wrapping (default-deny) | yes | `OpenAICompatibleChatGatewayClient.swift:596-629`; `AgentSecurityPolicy.swift:106-110` `controlOnlyTools=[]` |

## L.4 Prompt-injection baseline (LLM01) — real and applied
`LLMSafeContent.wrapUntrusted` (boundary-token defanged, `ContextBuilder.swift:11-42`) wraps RAG chunks, focus transcripts, summaries, spawned-CLI output, chat user/history, and Computer Use tool results (default-deny). Model output is never trusted as code/commands; tool-call args are decoded into typed structs (`ComputerUseRunCoordinator.swift:509-549`) — an unknown/mistyped action is rejected at decode, not executed. **Residual (OPUS-F-017, Info):** the oracle-injection denylist is bypassable; the *prompt-framing* (untrusted-evidence wrapping) is the real protection, not the denylist — and that framing is correctly applied.

## L.5 Tool capability & MCP least privilege
- Hosted MCP tools all read-only, sealed results; scopes re-checked **server-side per request** (`entitlements.ts:130-136`, `mcp.ts:109-113`); scope-downgrade rejected (403); revocation re-checked every request (no cache); OAuth refresh-token-only (no auth-code/redirect → no open-redirect); Origin allowlisted. Untrusted content cannot escalate a grant or trigger a write.
- HTTP gateway proxy spawns CLI providers (its purpose) behind a bearer-token gate, wildcard-bind rejection, non-loopback token requirement, rate limits, argv arrays, restricted tools (`--disabled-tools ApplyPatch,execute-cli`), sanitized env. The **control** RPC socket handlers do **not** spawn subprocesses.

## L.6 OWASP coverage
- LLM01 prompt injection — wrapping default-deny: **defensible**.
- LLM02 sensitive disclosure — blind relay; providers get no content; insights digest-only: **strong**.
- LLM05 improper output handling — typed decode; SSRF defense-in-depth caveat (OPUS-F-007).
- LLM06 excessive agency — deterministic gate, no L5, budget/deny-region caps: **strong**.
- LLM10 unbounded consumption — soft/hard/daily/spend caps + kill switch: **strong**.
- Agentic 2026 (tool misuse, privilege compromise, hijack) — server-side scope re-checks, fail-closed gates, 4 kill paths, audit-before-action: **strong**.

**Only actionable item:** harden `ssrfGuard.ts` (OPUS-F-007) before any user-supplied-URL fetch ships, and refresh the LLM threat-model doc (OPUS-F-017).
