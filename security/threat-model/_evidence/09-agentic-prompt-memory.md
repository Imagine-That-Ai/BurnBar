# 09 — Agentic / Prompt / Memory / RAG (domain: agentic-prompt-memory-rag)

Reviewer scope: prompt/context boundaries, memory/RAG, model-provider calls, CU tool-result
trust, browser SSRF. CODE is source of truth; verified against current HEAD (2026-06-13).

## Components & files reviewed
- `AgentLens/Services/ContextBuilder.swift` — `LLMSafeContent.wrapUntrusted` / `formatPack` / focus + summarize prompt wrappers.
- `AgentLens/Views/Chat/ChatSessionController.swift` — `augmentedSystem` assembly (~1600-1665), `buildFocusSessionPromptSection` (122-146), `sanitizedLocalOracleContext` (2411), `buildLocalIndexOracleResponse`/`appendJumpTargetSummary` (2179-2300).
- `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift` — `AgentToolBroker.payload` (500), `shouldWrapUntrustedComputerUseResult` (529), CU tool-call loop (1153-1170), `readWorkspaceFile`/`runShell`/`runShellUnrestricted` (258-410).
- `OpenBurnBarDaemon/.../OpenBurnBarAnthropicProviderExecutor.swift` — gateway translation, `anthropicToolResultBlock` (791).
- `OpenBurnBarDaemon/.../OpenBurnBarBrowserTargetPolicy.swift` — SSRF host policy.
- `OpenBurnBarDaemon/.../ComputerUse/ComputerUseRunCoordinator.swift` — browser dispatch (764-802).
- `functions/src/insightsHostedAnswer.ts` — hosted OpenRouter analyst (digest-only).
- `functions/src/callables/encryptedSearch.ts` — encrypted retrieval (no LLM call).
- `AgentLens/Services/Search/SearchService+Retrieval.swift`, `AgentLens/Services/LogParser/*` — RAG corpus origin.
- `AgentLensTests/Active/Security/PromptInjectionHardeningTests.swift` — assertion fixtures.

## Controls present (control — file:line symbol — strength — note)
- Untrusted wrapper w/ delimiter-breakout defense — `ContextBuilder.swift:11 wrapUntrusted`, `:38 defangSentinel` — strong — case-insensitive `UNTRUSTED_CONTENT`→U+2011 swap; provenance strips `" < > \n \r`; tested at PromptInjectionHardeningTests.swift:23-39.
- RAG snippets wrapped per-chunk — `ContextBuilder.swift:146 formatBlock` (provenance `rag_chunk:<id>`) — strong — every retrieved snippet wrapped; header at `:79`.
- Focus transcript wrapped — `ChatSessionController.swift:132 buildFocusSessionPromptSection` (provenance `focus_session:<id>`), capped 6k/2k chars — strong.
- CU browser_extract + mac_inspect_accessibility results wrapped — `OpenAICompatibleChatGatewayClient.swift:529 shouldWrapUntrustedComputerUseResult`, `:534 wrappedUntrustedComputerUseResult` (provenance `computer_use_tool_result:<tool>`) — moderate — RR-15 partially remediated, but ALLOWLIST of 2 tools only (see T-AI-01).
- Browser SSRF deny — `OpenBurnBarBrowserTargetPolicy.swift:52 isBlockedHost` enforced at `ComputerUseRunCoordinator.swift:785` — strong — blocks localhost/.localhost, metadata.google.internal, 0/8,10/8,127/8,100.64/10,169.254/16,172.16/12,192.168/16,198.18/15,224/4,255.255.255.255; IPv6 ::, ::1, fe80::/10, fc00::/7, ff00::/8, v4-mapped/compat; octal/hex/over-long IPv4 encodings. file:// rejected (only http/https/data).
- Shell sandboxing — `OpenAICompatibleChatGatewayClient.swift:344 runShell` via `workspaceSandboxedShellInvocation`; `:367 runShellUnrestricted` gated `grant.trustMode == .trusted && capabilities.contains(.shellUnrestricted)` — moderate — unrestricted path audits only cmd SHA-256 (`:386-398`), no plaintext.
- Hosted analyst privacy bound — `insightsHostedAnswer.ts:246 digestSummaryFor` (digest only, no raw transcripts), `:287 userPromptText` wraps question `<UNTRUSTED_USER_QUESTION>`, `:330` `response_format:json_object`, no tools — strong.
- Tool-call budget cap — `OpenAICompatibleChatGatewayClient.swift:1154 maxToolCalls` — moderate — bounds runaway agentic loops.

## Claims verified against code (claim — status — evidence — note)
- "All untrusted content (RAG, logs, focus, summaries, CU extracts) MUST be wrapped" (ContextBuilder.swift:4 header) — **Partial** — RAG/focus/summarize wrapped; CU extracts wrapped ONLY for browser_extract + mac_inspect_accessibility (`:529-531`); file/shell/screenshot tool results forwarded raw (`:1168`). Overclaim — see Overclaims.
- "CU tool results wrapped as untrusted" (RR-15 remediation) — **Partial** — `shouldWrapUntrustedComputerUseResult` allowlist of 2 tools; other content-returning tools unwrapped.
- Browser blocks loopback/metadata/file:// (SSRF) — **Defensible** for initial `goto` — `OpenBurnBarBrowserTargetPolicy.swift` + `ComputerUseRunCoordinator.swift:785`. Gap: no re-validation on redirect / JS navigation / `browser_click`; DNS-rebind not mitigated (string host check) — see T-AI-04.
- Hosted analyst never receives raw transcripts/keys — **Defensible** — `insightsHostedAnswer.ts:241-273 digestSummaryFor` projects only totals/providers/models/projects/anomalies/quotas/daily.
- encryptedSearch keeps plaintext server-side hidden — **Defensible** (for this domain) — opaque docIDs, no plaintext slug projection (`encryptedSearch.ts:499,552`); no model-provider call in path.
- Oracle "authoritative local search results" are trusted findings — **NotDefensible as safe** — oracle message embeds raw indexed snippets (`appendJumpTargetSummary` `target.snippet`) and is injected UNWRAPPED framed authoritative (`ChatSessionController.swift:1609-1614`); `sanitizedLocalOracleContext:2411` only strips 4 UI strings — see T-AI-02.

## Threats (T-AI-NN)
- **T-AI-01** — CU tool results outside 2-tool allowlist injected raw — LLM01 Prompt Injection / Agentic-T1 (Memory/Tool-output) / ATLAS AML.T0051 — **High** — `OpenAICompatibleChatGatewayClient.swift:529,1168`. Path: agent calls `read_file`/`run_terminal`/`browser_screenshot` (or any non-allowlisted tool) on attacker-controlled file/page/process output → `result.content` appended verbatim as `role:"tool"` (`:1165-1169`) → daemon forwards as Anthropic `tool_result` (`OpenBurnBarAnthropicProviderExecutor.swift:798`). Existing mitigation: only browser_extract + mac_inspect_accessibility wrapped. Gap: file/shell/screenshot/other tool output unwrapped. Residual: indirect prompt injection that can chain into further tool calls (incl. shell under YOLO).
- **T-AI-02** — Oracle "authoritative findings" inject unwrapped indexed snippets — LLM01 / LLM08 Vector&Embedding Weaknesses / Agentic memory poisoning — **High** — `ChatSessionController.swift:1604-1614` + `appendJumpTargetSummary` (`:2300`). Path: malicious agent log on disk → parsed into `ConversationRecord.fullText` → indexed → matched by query → snippet placed in oracle `message` → injected as "Treat the following as authoritative local search results". Mitigation: `sanitizedLocalOracleContext` (UI-string strip only). Gap: no untrusted wrapping; SAME snippet is wrapped in the evidence pack but UNWRAPPED here. Residual: instruction-injection via own conversation history while explicitly framed trusted.
- **T-AI-03** — Memory/RAG poisoning via parsed agent logs — LLM08 / Agentic-T memory poisoning / ATLAS AML.T0070 — **Medium** — `LogParser/*`, `SearchService+Retrieval.swift`. Path: third-party content makes a coding agent (Claude Code/Cursor/etc.) emit attacker text into its CLI log → parsers ingest with no provenance/trust label (`LogParserProtocol.swift` `ConversationRecord`) → enters RAG corpus, persists, retrieved later. Mitigation: retrieval output wrapped at `formatPack`. Gap: no write-time validation, no provenance trust tier, no deletion/quarantine of poisoned chunks; also reaches model unwrapped via oracle path (T-AI-02). Residual: durable cross-session influence.
- **T-AI-04** — Browser SSRF via redirect / JS nav / click after validated goto; DNS rebinding — LLM01 / SSRF / ATLAS — **Medium** — `ComputerUseRunCoordinator.swift:785`. Path: agent `goto` a public host that 302/meta-refresh/JS-redirects to `http://169.254.169.254/...` or a public hostname whose DNS A-record points to a private IP; or `browser_click` a link to an internal URL; then `browser_extract` returns the body into context. Mitigation: initial-URL string host policy. Gap: no per-navigation/redirect re-check; no resolved-IP (post-DNS) enforcement; click/JS nav unbounded. Residual: internal/metadata exfiltration into model context (note: extract output IS wrapped, limiting injection but not data exfiltration).
- **T-AI-05** — Insecure output handling: model JSON → widgets/missions — LLM05 Improper Output Handling — **Low/Medium** — `insightsHostedAnswer.ts:301-308`. Path: provider output parsed as `InsightAnalysisResult` and rendered as recommendations/missionCandidates; a `missionCandidate` could nudge the user toward a harmful next mission. Mitigation: strict JSON envelope, bounded sizes, digest-only input. Gap: no semantic validation that recommended missions are safe; client trust of model-authored action proposals.
- **T-AI-06** — No content-level secret redaction before model providers — LLM02 Sensitive Information Disclosure — **Medium** — no redactor on prompt payload path (only `CLILaunchRedactor` for log display, `CLIProfileStreamFailoverRunner.swift:260`). Path: focus transcript / RAG snippet / file read containing API keys/tokens is wrapped (as untrusted) but still transmitted verbatim to the model provider (local gateway or, for insights, OpenRouter). Mitigation: insights path sends digest only (no raw text). Gap: chat path sends raw secrets; no `no-train`/zero-retention header asserted on any provider call. Residual: secret leakage to provider + provider retention (UNKNOWN, deployment-dependent).
- **T-AI-07** — Unrestricted shell obeys injected instructions under YOLO — LLM01→Excessive Agency (LLM06) / Agentic — **High (conditional)** — `OpenAICompatibleChatGatewayClient.swift:367`. Path: indirect injection (T-AI-01/02/03) instructs model → `shell_run_unrestricted` runs unsandboxed at user privilege. Mitigation: requires `.trusted` mode + `.shellUnrestricted` capability + SHA-256 audit. Gap: no per-N-action re-auth (acknowledged in code comment `:380`); injection-to-RCE if YOLO enabled. Residual: full local compromise when YOLO on.

## Gaps / missing controls
- CU result wrapping is a 2-tool allowlist, not default-deny; should wrap ALL tool outputs carrying external/attacker-influenceable text (file reads, shell stdout/stderr, screenshot OCR, clipboard).
- Oracle/"authoritative" context path bypasses the untrusted wrapper entirely — needs `wrapUntrusted` or removal of the "authoritative" framing.
- No provenance/trust tier on indexed conversation chunks; no poisoned-chunk quarantine/deletion workflow.
- Browser SSRF check is one-shot on the typed URL; no redirect/JS-nav/click re-validation and no resolved-IP (DNS-rebind) enforcement.
- No content-level secret scrubbing before sending prompts to model providers; no provider zero-retention/no-train assertion in code.

## Overclaims
- `ContextBuilder.swift:4` "All untrusted content (… CU extracts) MUST be wrapped" — CU extracts are wrapped only for 2 tools; file/shell/screenshot/clipboard tool results are forwarded raw (`OpenAICompatibleChatGatewayClient.swift:1168`).
- `ChatSessionController.swift:1612` frames oracle snippets as "authoritative local search results" though they originate from the same untrusted indexed corpus that `formatPack` treats as untrusted.

## Crypto/protocol notes
- Out of domain; encryptedSearch keeps plaintext slug/name unprojected (`encryptedSearch.ts:499,552`) and performs no LLM call — no prompt/RAG exposure there.

## Open questions / UNKNOWN
- Provider retention/no-train: does the local gateway forward to a hosted Anthropic/OpenAI endpoint with retention enabled? OpenRouter (insights) retention policy? Needs deployed config/keys — UNKNOWN.
- Does any production CU path return OCR/clipboard text through a content-returning tool not in the wrap allowlist? `MacInspectAction.Kind` currently only `.accessibility` (wrapped); browser_screenshot returns image (no text) — but confirm no future tool returns text unwrapped.
- Are Playwright `goto` redirects actually followed without re-validation in the daemon driver? Needs `OpenBurnBarPlaywrightDriver.goto` body (not read) — likely yes (standard Playwright).
