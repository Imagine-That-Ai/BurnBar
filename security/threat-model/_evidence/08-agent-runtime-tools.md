# 08 — Agent Runtimes & Tool Execution (Phase 8.1–8.4 Agentic)

Domain: agent-runtime-tools. Source of truth = code. Commit state as of 2026-06-13.
Scope: CLI agent spawn lane, in-app tool broker, ComputerUse capability gate, capability
grants, panic/kill paths, autonomy & policy boundary (deterministic CODE vs model judgment).

## Components & files reviewed
- `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift` — builds argv per CLI runtime; YOLO/sandbox flags; prompt wrapping.
- `AgentLens/Services/CLIBridge/CLIProcessStreamRunner.swift` — spawns external CLI agents via `Process`.
- `AgentLens/Services/CLIBridge/CLIBridge.swift` — routes chat → runner with grant.
- `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift` — in-app tool broker (`AgentToolBroker`): capability gate, approval gate, sandboxed/unrestricted shell.
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/AgentCapabilityGrant.swift` — grant/preset/capability model.
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseCapabilityGate.swift` — deterministic capability gate (`DefaultComputerUseCapabilityGate`).
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseDenyRegistry.swift` — hard-coded deny rules.
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift` — `invoke(_:)` dispatch, panicHalt, approval.
- `AgentLens/Services/ComputerUse/ComputerUsePanicHaltCoordinator.swift` — kill paths (hotkey/lock/remote-config).
- `AgentLens/Services/ComputerUse/AgentCapabilityGrantStore.swift` — `apply()` grant admission.
- `AgentLens/Services/ComputerUse/AgentCapabilityGrantQueueListener.swift` — verified remote grant intake.
- `AgentLens/Views/Chat/ChatSessionController.swift` — local grant mint, revoke, prompt section.
- `AgentLens/Views/Chat/Components/ChatPanelHeader.swift` — local-auth-gated grant UI.

## Two execution lanes (key architectural finding)
1. **In-app broker** (`OpenAICompatibleChatGatewayClient`/`AgentToolBroker`): each tool declares
   `requiredCapabilities`; `grant.supportsAll(...)` enforced in-process; privileged tools require
   per-action approval unless trusted; `shell_run` is `sandbox-exec`-confined. STRONG.
2. **External CLI agents** (`CLIArgumentBuilder` → `CLIProcessStreamRunner`): OpenBurnBar spawns a
   third-party CLI (claude/codex/droid/forge/antigravity/cursor) and delegates ALL runtime
   enforcement to that CLI's own flags. The grant only selects which flags are passed at spawn;
   after spawn OpenBurnBar has NO in-process gate, no per-action approval, no revocation kill.

## Controls present
- Deterministic capability gate, pure fn, fail-closed ordering ("harshest denial wins") — `ComputerUseCapabilityGate.swift:226 DefaultComputerUseCapabilityGate.check` — strong — kill switch first (`:233`), entitlement (`:246`), caps, deny region beats everything (`:335`).
- Hard-coded deny registry not removable via editor — `ComputerUseDenyRegistry.swift:13 builtInRules` — strong — loginwindow/SecurityAgent/Keychain/Privacy pane/OAuth/metadata/loopback/file:// denied.
- Accessibility deny-region beats agent+mac+phone — `ComputerUseCapabilityGate.swift:335` — strong — secure text field / auth sheet / keychain prompt fail closed (`ComputerUseDenyRegistry.swift:214`).
- Per-tool capability enforcement in broker — `OpenAICompatibleChatGatewayClient.swift:136-139 invokeOpenAITool` — strong — `grant.supportsAll(definition.requiredCapabilities)` else denied.
- Per-action approval for privileged broker tools (non-trusted) — `OpenAICompatibleChatGatewayClient.swift:155-164` — moderate — fails closed when no approver wired; BUT skipped entirely under `.trusted` (YOLO).
- Workspace-confined sandbox for `shell_run` — `OpenAICompatibleChatGatewayClient.swift:344-357 runShell` + `:662 restrictedShellSandboxProfile` — strong — `(deny network*)`, write-confined to workspace, deny-read of ~/.ssh,~/.aws,keychains,browser stores, and OpenBurnBar's own state (F9). Note `(allow default)` (`:723`) => general reads outside deny list permitted.
- Grant is time/thread/runtime/device scoped, non-sticky — `AgentCapabilityGrant.swift:311,374 isActive` — strong — 30-min default expiry (`:186,360`), `runtimeID`+`threadID`+`sourceDeviceID`.
- Remote grant intake is Ed25519/pinned-controller verified — `AgentCapabilityGrantQueueListener.swift:81-90 verifiedReceipt` — strong — registerPeer pin (F1), `validator.validate(envelope:)`, denied receipt on signature failure (`:167`).
- Grant admission requires local-auth proof + Mac approval for privileged/YOLO — `AgentCapabilityGrantStore.swift:75-104 apply` — moderate — `requiresLocalAuthentication`/`requiresMacApproval`; queued path calls `apply(request)` with default `macApprovalSatisfied:false` (`Queue:90`).
- Local Mac grant gated by device LocalAuthentication — `ChatPanelHeader.swift:379-385 DesktopGrantLocalAuthenticator.authenticateIfNeeded` — moderate — biometric/passcode before `grantDesktopControl`.
- Independent panic/kill paths — `ComputerUsePanicHaltCoordinator.swift:29 install` — moderate — hotkey ⌃⌥⌘. (`:67`), screen-lock/resign (`:112`), remote-config flag (`:54`). NOTE: whole file is `#if canImport(AppKit) && !DISTRIBUTION_MAS` (`:1`) — excluded from MAS build.
- Audit-before-action fail-closed — `ComputerUseSessionCoordinator.swift:871-902 reserveAuditEntry` — strong — action NOT executed if audit reservation append throws.
- YOLO unrestricted shell blocked in MAS build — `AgentCapabilityGrantStore.swift:166-172 yoloUnavailable` (`#if DISTRIBUTION_MAS` denies `.shellUnrestricted`); broker re-check `OpenAICompatibleChatGatewayClient.swift:368`.
- Prompt-injection wrapping of untrusted content — `CLIArgumentBuilder.swift:248 combinedPrompt` — weak/moderate — wraps user message in `<UNTRUSTED_CONTENT>`; advisory-only, model can still ignore.
- Default-deny when no grant — `CLIArgumentBuilder.swift:57-64` (claude `--permission-mode plan --disallowedTools Bash,Write,...`), `:95-101` (codex `--sandbox read-only --ignore-user-config`), `forgePrompt :223-228` read-only instruction.

## Claims verified against code
- "No assistant receives any capability by default" — Defensible — `AgentCapabilityGrant.swift:5-6`; no-grant lane forces read-only/plan (`CLIArgumentBuilder.swift:57`,`95`).
- "Grants are scoped to runtime+thread+expiry, never sticky" — Defensible — `AgentCapabilityGrant.swift:308-322,374`; store keyed by runtime+thread (`AgentCapabilityGrantStore.swift:11-23`).
- "Permissions bound to user+device identity, time/task-scoped" — Partial — time+thread+runtime+`sourceDeviceID` bound (`AgentCapabilityGrant.swift:320`), but `sourceDeviceID` not re-bound/re-verified at CLI spawn or broker invoke; per-tool re-check is grant-active only.
- "Deny rules cannot be removed via scope editor" — Defensible — `ComputerUseDenyRegistry.swift:182 isBuiltIn` + matcher overlap probes (`:189`).
- "Approval is the only ground truth for Mac/phone input" — Partial — true for ComputerUse lane (`Gate :366` notMatched ⇒ `.mac` ⇒ sheet; phone first-action ⇒ `.mac`); NOT applied to external CLI agents (no per-action approval after spawn).
- "Unrestricted shell leaves a forensic record" — Defensible — `OpenAICompatibleChatGatewayClient.swift:382-387` logs grant id + runtime + cmd sha256 (not plaintext); but only a hash, no content, no per-action approval (by design, `:374-381`).
- "YOLO desktop grants unavailable in MAS build" — Partial — only `.shellUnrestricted` is blocked in MAS (`AgentCapabilityGrantStore.swift:167-168`); other YOLO `--dangerously-skip-permissions` CLI flags are emitted by `CLIArgumentBuilder` regardless of build (no `#if DISTRIBUTION_MAS` guard there).
- "Mac input/browser still pass through approval, scope, audit pipeline" (model prompt) — Defensible for broker→ComputerUse tools (`OpenAICompatibleChatGatewayClient.swift:186-225` → coordinator gate); NotDefensible as a claim about external CLI agents, which bypass that pipeline entirely.
- "Phone control respects deny regions by default" — Defensible — `ComputerUseCapabilityGate.swift:321,335`; legacy bypass only when `phoneControlRespectsDenyRegions=false` AND `accessibilityDeny==nil`.

## Threats (T-TOOL-NN)
- T-TOOL-01 — External CLI agents run with no in-process policy gate — Agentic (Excessive Agency / LLM06 2025; OWASP-Agentic Tool-Misuse) — High — CLIProcessStreamRunner — A model the CLI obeys (incl. via prompt injection in repo files / tool output) can do anything the granted CLI flags permit; OpenBurnBar only chooses flags at spawn (`CLIArgumentBuilder.swift:47-103`) and cannot intercept individual tool calls — existing mitigation: flag selection per capability, default read-only — gap: no per-action gate/approval/scope for CLI lane — residual: High under workspace/all/YOLO presets.
- T-TOOL-02 — YOLO emits `--dangerously-skip-permissions`/`--dangerously-bypass-approvals-and-sandbox` running unsandboxed at full user privilege — Agentic Excessive Agency / LLM02 (insecure output handling) — Critical — CLIArgumentBuilder/OpenAICompatibleChatGatewayClient — `isYOLOGrant` (`CLIArgumentBuilder.swift:52,87,168,189,215`) + `runShellUnrestricted` (`:367`) execute arbitrary commands with no approval and no sandbox — existing mitigation: requires `.trusted`+all caps, local-auth at mint, hashed audit log — gap: prompt injection → arbitrary RCE; no per-N-action re-auth (TODO at `:381`) — residual: Critical (non-MAS); partially reduced in MAS (`.shellUnrestricted` blocked, but CLI `--dangerously-skip-permissions` still un-guarded).
- T-TOOL-03 — Grant revocation does not terminate in-flight CLI agent — Agentic (loss of control / kill-switch gap) — High — CLIProcessStreamRunner / ChatSessionController.revokeDesktopControl — `revokeDesktopControl()` (`ChatSessionController.swift:382`) only flips store state; spawned `Process` keeps its flags and runs to completion; no `grantStillActive` re-check on CLI lane (unlike broker `OpenAICompatibleChatGatewayClient.swift:130-135`) — existing mitigation: AsyncStream cancellation kills process if the chat stream is torn down — gap: revoke alone ≠ kill — residual: High for long YOLO CLI runs.
- T-TOOL-04 — Panic/kill coordinator excluded from MAS distribution build — Agentic kill-switch availability — High — ComputerUsePanicHaltCoordinator — entire file `#if canImport(AppKit) && !DISTRIBUTION_MAS` (`:1`); hotkey/lock/remote-config kill paths absent in MAS — existing mitigation: ComputerUse system lane also gated off in MAS (`OpenAICompatibleChatGatewayClient.swift:223-224`), remote-config kill still reachable via coordinator `updateKillSwitch` — gap: physical-hotkey + lock-screen kill absent in MAS — residual: Medium (MAS also disables the riskiest lanes).
- T-TOOL-05 — CLI lane does not wrap tool output / repo content as untrusted — LLM01 prompt injection (2025) / Agentic indirect injection — High — CLIBridge/CLIArgumentBuilder — `combinedPrompt` (`:248`) wraps only the user chat message; file/web/tool outputs the CLI agent itself ingests are never tagged untrusted and OpenBurnBar cannot interpose — existing mitigation: combinedPrompt wrapping for in-app chat turns only — gap: indirect injection via workspace files/tool results in CLI lane — residual: High when write/shell granted.
- T-TOOL-06 — Queued grant authority key fetched from cloud Firestore — Spoofing/Tampering (STRIDE) — Medium — AgentCapabilityGrantQueueListener.authorityPublicKey — `agent_grant_authorities/{deviceId}` doc read (`:97-110`); a Firestore-write-capable attacker could substitute a public key, then forge signed grant requests — existing mitigation: F1 controller pin (`validator.registerPeer` `:81`) rejects key differing from operator-pinned key — gap: trust still rooted in cloud doc on first pin (TOFU); pin store integrity is the real anchor — residual: Medium (depends on pin enforcement — see pairing/trust evidence).
- T-TOOL-07 — `.workspace` preset bundles `.shell` and maps codex to `--sandbox workspace-write` and droid to `--auto medium` — Excessive Agency — Medium — CLIArgumentBuilder.codexArguments/droidArguments — `:89-91` (codex shell⇒workspace-write), `:124-126` (droid shell⇒`--auto medium` autonomous) — existing mitigation: not YOLO (sandbox/auto-mid, not bypass) — gap: a non-trusted "workspace" grant still authorizes autonomous shell within workspace with CLI-side sandbox only; OpenBurnBar cannot verify the CLI honors `workspace-write` — residual: Medium.
- T-TOOL-08 — Deny rules for /admin,/billing use windowTitleRegex against URL substring — Tampering/scope bypass — Low — ComputerUseDenyRegistry — `:165-177` rely on the URL appearing in the window title; SPA/path-only routes or titles without the path evade the deny — existing mitigation: browser file://, loopback, metadata, OAuth denies are urlPrefix-based and robust — gap: path-based denies are heuristic — residual: Low.
- T-TOOL-09 — Local `grantDesktopControl` bypasses signed/`apply()` admission path — Privilege (local) — Low/Info — ChatSessionController.grantDesktopControl — `:358-380` constructs+`activate()`s a grant directly without `AgentCapabilityGrantStore.apply()` checks — existing mitigation: only reachable from local Mac UI (`ChatPanelHeader.swift:387`) which first calls `DesktopGrantLocalAuthenticator.authenticateIfNeeded` (`:379`) — gap: relies on caller to local-auth; no defense-in-depth inside `grantDesktopControl` itself — residual: Low (local operator is the trust root).
- T-TOOL-10 — `shell_run` sandbox allows general file reads outside deny list — Information disclosure — Low — OpenAICompatibleChatGatewayClient.restrictedShellSandboxProfile — `(allow default)` (`:723`) after targeted `(deny file-read*)`; sensitive files not in the curated list (`:672-698`) remain readable — existing mitigation: network denied (`:702`) so exfil path limited; secret stores + app state denied — gap: deny list is hand-curated, not allow-list — residual: Low.

## Gaps / missing controls
- No unified policy enforcement point for external CLI agents — enforcement is fully delegated to third-party CLI flags; OpenBurnBar cannot observe/deny individual tool calls in that lane.
- No mid-run revocation/kill for spawned CLI processes (revoke ≠ terminate); no `grantStillActive` re-check on CLI lane.
- No per-N-action re-auth for YOLO unrestricted shell (acknowledged TODO, `OpenAICompatibleChatGatewayClient.swift:381`).
- CLI `--dangerously-skip-permissions` flags are not guarded by `#if DISTRIBUTION_MAS` (only `.shellUnrestricted` broker capability is).
- Panic hotkey + lock-screen kill paths absent in MAS build.
- Indirect prompt-injection (repo files, tool/web output) untagged for the CLI lane; only the in-app chat user message is wrapped.
- Autonomy level per runtime is implicit in flags, not a first-class, auditable field.

## Overclaims
- Prompt section asserts "Mac input and browser actions still pass through OpenBurnBar's approval, scope, and audit pipeline" (`ChatSessionController.swift:2000`). True for the in-app broker→ComputerUse path; NOT true for external CLI agents (claude/codex/etc.), which run outside that pipeline. The phrasing risks implying all granted actions are gated.
- "YOLO" naming + `isYOLOGrant` gating implies a contained mode; in practice non-MAS YOLO = arbitrary unsandboxed RCE with only hashed audit (`:374-387`). Conservative posture: treat YOLO/`--dangerously-skip-permissions` as full-trust delegation, not a safety control.
- Comment "we ALWAYS leave a forensic record" (`:378`) — record is a command SHA-256 + length only; not reversible/reviewable content, and gives attribution not prevention.

## Crypto/protocol notes
- Remote grant requests: Ed25519 (default) signed envelopes, controller-key pinned, counter/timestamp replay protection via `PhoneControlAuthorityValidator` (`AgentCapabilityGrantQueueListener.swift:84-88`; key kind `:115`). Local-auth proof (`localAuthProof`) is a separate signed artifact required for privileged/YOLO grants (`AgentCapabilityGrantStore.swift:85-94`).
- YOLO unrestricted-shell audit digest is a one-way SHA-256 of the command (privacy-preserving, non-reversible) — attribution-only.

## Open questions / UNKNOWN
- Does the Firestore-queued grant path ever reach `apply(macApprovalSatisfied:true)`? Need to trace the live (relay) path; queued path defaults to false ⇒ would deny privileged remote grants. UNKNOWN without the live relay grant-application site.
- Are `agent_grant_authorities` Firestore docs write-protected by rules so an attacker cannot pre-seed a key before first pin (TOFU window)? Resolve against firestore.rules (cross-domain).
- Does AsyncStream/chat teardown reliably terminate a YOLO CLI subprocess on app background/quit, or can it outlive the grant/session? Needs runtime test (`CLIBridgeStreamRuntimeCoordinator.cancelRunningProcess`).
- In MAS build, is there ANY kill path for an in-flight CLI agent besides quitting the app? Panic coordinator is compiled out.
- Is `DesktopGrantLocalAuthenticator.authenticateIfNeeded` enforcing (throws on failure) for `.trusted`/YOLO, or can it no-op when biometrics unavailable? Verify the authenticator body.
