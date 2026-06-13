> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# BurnBar Threat Register (human-readable)

Machine-readable companion: [`threat-register.csv`](threat-register.csv). Per-domain raw findings: [`_evidence/`](_evidence/). Severity model in [`_evidence/_INDEX.md`](_evidence/_INDEX.md §10). Total threats: **106** (2 Critical, 21 High, 41 Medium, 34 Low, 8 Info).

## Critical (2)

### T-TOOL-02 — YOLO emits --dangerously-skip-permissions and runs unsandboxed shell at full user privilege
- **Category / framework:** Agentic: Excessive Agency; LLM02 insecure output handling
- **Component / evidence:** `CLIArgumentBuilder / OpenAICompatibleChatGatewayClient.runShellUnrestricted`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** isYOLOGrant (CLIArgumentBuilder.swift:52,87,168,189,215) adds --dangerously-skip-permissions/--dangerously-bypass-approvals-and-sandbox; broker runShellUnrestricted (:367) runs /bin/zsh unsandboxed with no approval. Prompt injection the model obeys => arbitrary RCE.
- **Existing mitigation:** Requires .trusted+all caps, local-auth (LAContext) at mint, hashed audit log of command
- **Gap:** No per-N-action re-auth (TODO :381); audit is attribution not prevention
- **Residual risk:** Critical (non-MAS); partly reduced in MAS where .shellUnrestricted blocked but CLI dangerous flags still un-guarded
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P0 (must-fix before audit)

### T-TRN-01 — Cloud-substituted pairing public key MITMs the verified iroh link
- **Category / framework:** STRIDE:Spoofing/Tampering; LINDDUN:Non-repudiation; Agentic:control-channel-hijack
- **Component / evidence:** `FirestoreIrohPairingPublicKeyProvider + iOS pairing verify`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** Malicious/compromised cloud, Firebase project takeover, or rogue admin writes users/{uid}/iroh_pairing_keys/host plus a matching signed iroh_pairing record at an attacker NodeId; iOS fetches that key with no out-of-band/TOFU pin (FirestoreIrohPairingPublicKeyProvider.swift:27-47, in-memory cache only, never persisted/rotated), verifies the attacker signature (HermesIrohRelayTransport.swift:385), and dials the attacker QUIC endpoint
- **Existing mitigation:** firestore.rules:2661-2665 keep docs server-owned + callable-gated (AppCheck/high-risk nonce/trusted escrow); separate E2E HermesRelayCrypto layer means MITM still cannot read payloads
- **Gap:** No TOFU/safety-code pinning of host pairing key on iOS; transport identity trust = whatever Firestore returns
- **Residual risk:** Compromised cloud can redirect/hijack/drop the iroh control channel and force downgrade; payload confidentiality survives only via the independent E2E layer
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P0 (must-fix before audit)

## High (21)

### T-AI-01 — CU tool results outside 2-tool allowlist injected raw into model context
- **Category / framework:** OWASP LLM01 Prompt Injection / Agentic tool-output poisoning / MITRE ATLAS AML.T0051
- **Component / evidence:** `OpenAICompatibleChatGatewayClient (AgentToolBroker.payload / tool loop)`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Agent calls read_file/run_terminal/browser_screenshot or any non-allowlisted tool on attacker-controlled file/page/process; result.content appended verbatim as role:tool (OpenAICompatibleChatGatewayClient.swift:1165-1169); daemon forwards as Anthropic tool_result (OpenBurnBarAnthropicProviderExecutor.swift:798).
- **Existing mitigation:** browser_extract + mac_inspect_accessibility wrapped (shouldWrapUntrustedComputerUseResult:529).
- **Gap:** Allowlist not default-deny; file/shell/screenshot/clipboard tool output unwrapped.
- **Residual risk:** Indirect prompt injection that can chain into further tool calls including shell under YOLO.
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P1 (should-fix before launch)

### T-AI-02 — Oracle 'authoritative findings' inject unwrapped indexed snippets
- **Category / framework:** OWASP LLM01 / LLM08 Vector&Embedding Weaknesses / Agentic memory poisoning
- **Component / evidence:** `ChatSessionController oracle/hybrid context path`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Malicious agent log on disk -> parsed ConversationRecord.fullText -> indexed -> matched -> snippet placed in oracle message (appendJumpTargetSummary) -> injected at ChatSessionController.swift:1609-1614 as 'authoritative local search results'.
- **Existing mitigation:** sanitizedLocalOracleContext (ChatSessionController.swift:2411) strips 4 UI strings only.
- **Gap:** No untrusted wrapping; same snippet is wrapped in evidence pack but UNWRAPPED here and explicitly framed trusted.
- **Residual risk:** Instruction injection via own conversation history presented to model as authoritative.
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P1 (should-fix before launch)

### T-AI-07 — Unrestricted shell obeys injected instructions under YOLO (injection-to-RCE)
- **Category / framework:** OWASP LLM01 -> LLM06 Excessive Agency / Agentic
- **Component / evidence:** `OpenAICompatibleChatGatewayClient runShellUnrestricted`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Indirect injection (T-AI-01/02/03) instructs model to call shell_run_unrestricted (OpenAICompatibleChatGatewayClient.swift:367), which runs unsandboxed at user privilege.
- **Existing mitigation:** Requires trustMode==.trusted + .shellUnrestricted capability + SHA-256 command audit.
- **Gap:** No per-N-action re-auth (acknowledged in code comment); skips per-action approver by design.
- **Residual risk:** Full local compromise when YOLO/trusted mode is enabled; conditional on user opt-in.
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P1 (should-fix before launch)

### T-ATT-01 — Decompression/oversize resource exhaustion via lied-about Mercury manifest.size
- **Category / framework:** STRIDE Tampering+DoS / Agentic resource-exhaustion; CWE-409/770/400
- **Component / evidence:** `MediaFileTransferService.fetch + iroh fetch_blob + Mac capability gate`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Peer advertises size=1KB (passes daily byte cap charged on manifest.size at MacFileTransferService.swift:391-395) but BlobTicket commits to a multi-GB blob; fetch_blob (blobs.rs:258-282) downloads the full committed blob to Caches with no streaming size cap and never compares actual bytes_total (284) to manifest.size.
- **Existing mitigation:** Capability gate on advertised size; iroh BLAKE3 integrity
- **Gap:** No streaming byte ceiling on iroh download and no post-fetch size==manifest.size reject; GCS finalize size-equality check (1570) has no Mercury equivalent.
- **Residual risk:** Disk-fill / quota exhaustion on receiver before any reject.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P1 (should-fix before launch)

### T-CVS-03 — Identity/vault private key extractable on compromised unlocked endpoint
- **Category / framework:** STRIDE:Information Disclosure; Agentic endpoint compromise
- **Component / evidence:** `iOS Keychain / AndroidLocalSecretBox / vault key store`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** Keys at WhenUnlockedThisDeviceOnly (no biometric/SecAccessControl) and AndroidKeyStore wrap without user-auth/StrongBox; app-context code on unlocked device reads raw private/vault key bytes -> forge sender-auth + decrypt all at-rest
- **Existing mitigation:** Device-only accessibility blocks iCloud/backup exfil; TEE wrap blocks raw-prefs theft
- **Gap:** No hardware-bound non-extractable signing, no per-use auth
- **Residual risk:** Endpoint compromise = total at-rest + sender-auth compromise; no PFS to limit blast radius
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P1 (should-fix before launch)

### T-DMN-01 — Compromised first-party app is fully trusted by daemon (code-sign == authZ)
- **Category / framework:** STRIDE:Elevation / Agentic:excessive-agency (no per-op attenuation)
- **Component / evidence:** `Main + HID sockets / BurnBarDaemonPeerAuthenticator, PrivilegedPeerAuthenticator`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** Code running inside or injected into the signed com.openburnbar.app/.daemon passes the DR gate, then has full main-socket RPC (run dispatch, config writes, provider creds) + HID input.
- **Existing mitigation:** Hardened runtime + library validation block non-first-party dylib injection; bearer token + DR gate.
- **Gap:** Code-signature identity is used as authorization; no capability attenuation at daemon; no sandbox to contain post-compromise.
- **Residual risk:** High — single signed-app RCE = full local agency + credential access (acknowledged in threat-model:154).
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P1 (should-fix before launch)

### T-DMN-02 — Daemon runs unsandboxed as login user with broad filesystem access
- **Category / framework:** STRIDE:Elevation
- **Component / evidence:** `Daemon process / entitlements (app-sandbox=false)`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** User LaunchAgent runs daemon with App Sandbox disabled; an RPC-handler parsing bug or memory bug gives a foothold with no OS sandbox boundary, home-dir FS + provider creds + sockets in reach.
- **Existing mitigation:** Gatekeeper/notarization (install-time only), hardened runtime.
- **Gap:** No runtime seatbelt sandbox; no entitlement minimization on daemon binary.
- **Residual risk:** High
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P1 (should-fix before launch)

### T-IOS-02 — No app-level biometric/passcode re-auth gate
- **Category / framework:** Spoofing / Elevation (MASVS-AUTH-1)
- **Component / evidence:** `AuthGateView.swift, OpenBurnBarMobileApp.swift`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Lost-but-unlocked iPhone gives full app access: send prompts, control paired Mac, read chat, trigger panic; Firebase session persists; WhenUnlocked vault/escrow keys decrypt freely
- **Existing mitigation:** Per-sensitive-ComputerUse-action step-up for some flows
- **Gap:** No global Face ID/passcode gate to enter app or view chat/vault data
- **Residual risk:** Full takeover of a high-trust endpoint on an unlocked unattended device
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P1 (should-fix before launch)

### T-PRV-01 — VoIP/call push leaks cleartext caller display name + call graph to Apple & Google
- **Category / framework:** LINDDUN Disclosure + Identifying; STRIDE Information Disclosure
- **Component / evidence:** `functions/src/callables/voipPush.ts:39-87, apnsSender.ts:141-221, fcmAndroidSender.ts:57-106`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** triggerVoIPCall writes voip_outbound/fcm_outbound with cleartext displayName/caller_name + stable callId/connectionId/pairedDeviceId; APNs+FCM sub-processors receive and can log them, building a social/device graph over time
- **Existing mitigation:** Entitlement gate; App Check; doc admits the leak
- **Gap:** Display name unnecessary for wake-up; connection_id/paired_device_id are stable correlators
- **Residual risk:** High; every call exposes caller identity + persistent device link to two external processors
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P1 (should-fix before launch)

### T-PRV-02 — Push-queue root collections never deleted on account erase, no TTL
- **Category / framework:** LINDDUN Non-compliance (right-to-erasure) + Disclosure; GDPR Art.17
- **Component / evidence:** `functions/src/callables/voipPush.ts:57,78, accountDeletion.ts:112-113`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** eraseUserCloudData walks only users/{uid}+workspaces+secret_refs; voip_outbound/fcm_outbound are TOP-LEVEL with uid+cleartext displayName/callId/connectionId/pairedDeviceId/tokens and have no TTL; persist indefinitely after account deletion
- **Existing mitigation:** Default-deny client reads; terminal-state docs not re-read
- **Gap:** No TTL; no deletion in eraseUserCloudData; no scheduled purge
- **Residual risk:** High; erasure contract violated for call metadata; unbounded retention of identifying push payloads
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P1 (should-fix before launch)

### T-PRV-03 — Client crash reports (iOS+macOS) ship to Sentry with no scrubber/consent
- **Category / framework:** LINDDUN Disclosure + Unawareness; STRIDE Information Disclosure
- **Component / evidence:** `OpenBurnBarMobile/App/AppDelegate.swift:53-85, AgentLens/App/AgentLensApp.swift:1168-1202`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** Client Sentry started with no beforeSend/beforeBreadcrumb/sendDefaultPii=false; default breadcrumbs (network URLs+params, lifecycle, logs) + exception context can carry plaintext prompts/paths/peer IDs/tokens to Sentry SaaS; no consent UX; macOS user-id seed uses real name
- **Existing mitigation:** tracesSampleRate=0; DSN absent in OSS builds; server Sentry scrubbed
- **Gap:** Client/server scrubbing asymmetry; no client beforeSend; no consent UX
- **Residual risk:** High for internal/CI-DSN builds; uncontrolled PII/prompt egress to third-party processor
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P1 (should-fix before launch)

### T-PTR-03 — iOS host-pairing-key in-memory TOFU enables cloud-MITM dial redirection
- **Category / framework:** STRIDE:Spoofing/Tampering; LINDDUN-Detectability
- **Component / evidence:** `FirestoreIrohPairingPublicKeyProvider`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** Cloud is untrusted. Phone verifies the Mac's signed iroh NodeAddr against iroh_pairing_keys/host fetched from Firestore and cached in-memory only (no Keychain pin/safety code/persistence). A backend serving a swapped host key to a cold-start session makes the phone accept an attacker-signed NodeAddr and dial an attacker NodeId.
- **Existing mitigation:** Defense-in-depth: control intents still gated by Mac-side controller pin + Signal at-rest sealer, so this is transport MITM/redirection not direct command injection. Host key is server-only-write at rules layer (but cloud itself is the threat here).
- **Gap:** Asymmetric trust: Mac->phone controller key is Keychain-pinned; phone->Mac host key is not pinned/persisted.
- **Residual risk:** Relay/transport interception, traffic analysis, fallback coercion on first/cold pairing.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P1 (should-fix before launch)

### T-SC-01 — Mutable action tags enable CI compromise of build/release
- **Category / framework:** STRIDE:Tampering / SSDF PW.4,PO.3 / SLSA build
- **Component / evidence:** `fast-feedback.yml:478; codeql.yml:129; security-pr.yml:199; nightly-e2e.yml:110,142`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Upstream owner or tag-mover repoints @stable/@v2/@v4/@v0.x to malicious commit; executes in CI with repo token.
- **Existing mitigation:** Most actions SHA-pinned; security/test lanes read-only perms.
- **Gap:** These refs are tag/branch not SHA; no Dependabot for actions found.
- **Residual risk:** Medium
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P1 (should-fix before launch)

### T-SC-02 — Provenance lane ecosystem-deny silently no-ops
- **Category / framework:** STRIDE:Tampering/Repudiation / SSDF PW.7,RV.1 / SCVS V2
- **Component / evidence:** `supply-chain-provenance.yml:103-104; run-ecosystem-deny-checks.sh:10-18,25-34`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Vulnerable/yanked dep ships; provenance deny check passes because cargo-deny/osv-scanner not installed so script skips them.
- **Existing mitigation:** rust-sast.yml + security-pr.yml cover crates/npm-locks on PR.
- **Gap:** cargo deny check never actually runs in CI; false assurance on provenance lane.
- **Residual risk:** Medium
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P1 (should-fix before launch)

### T-SC-03 — Single CODEOWNER = no separation of duties / insider single point of compromise
- **Category / framework:** STRIDE:Elevation/Repudiation / SSDF PO.2,PW.7
- **Component / evidence:** `.github/CODEOWNERS:4,18`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Compromise/coercion of @Ajnunezg or a token merges malicious workflow/firestore.rules/release with self-review; CODEOWNERS owns its own .github/workflows.
- **Existing mitigation:** Branch protection MAY require review (not in repo).
- **Gap:** No second reviewer; required-reviews/checks not verifiable from code.
- **Residual risk:** High
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P1 (should-fix before launch)

### T-TOOL-01 — External CLI agents run with no in-process policy gate
- **Category / framework:** Agentic: Excessive Agency / Tool Misuse; LLM06 2025
- **Component / evidence:** `CLIProcessStreamRunner / CLIArgumentBuilder`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** Granted CLI (claude/codex/droid/forge/antigravity/cursor) is spawned with capability-derived flags at CLIArgumentBuilder.swift:47-103; thereafter OpenBurnBar cannot intercept individual tool calls. A model the CLI obeys (incl. via prompt injection in workspace files/tool output) acts within the CLI's flag-granted authority.
- **Existing mitigation:** Per-capability flag selection; default read-only/plan when no grant
- **Gap:** No per-action gate, approval, or scope enforcement for the CLI lane
- **Residual risk:** High under workspace/all/YOLO presets
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P1 (should-fix before launch)

### T-TOOL-03 — Grant revocation does not terminate in-flight CLI agent
- **Category / framework:** Agentic: loss of control / kill-switch gap; STRIDE Tampering(authz drift)
- **Component / evidence:** `ChatSessionController.revokeDesktopControl / CLIProcessStreamRunner`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** revokeDesktopControl (ChatSessionController.swift:382) only flips grant-store state; the already-spawned Process keeps its YOLO/sandbox flags and runs to completion. No grantStillActive re-check on CLI lane (broker has one at OpenAICompatibleChatGatewayClient.swift:130-135).
- **Existing mitigation:** AsyncStream cancellation terminates the process if the chat stream is torn down
- **Gap:** Revoke alone != kill; expiry not re-checked mid-run by the subprocess
- **Residual risk:** High for long-running YOLO CLI runs
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P1 (should-fix before launch)

### T-TOOL-04 — Panic/kill coordinator compiled out of MAS distribution build
- **Category / framework:** Agentic: kill-switch availability
- **Component / evidence:** `ComputerUsePanicHaltCoordinator`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** Entire file guarded by #if canImport(AppKit) && !DISTRIBUTION_MAS (:1); the global hotkey, screen-lock, and remote-config kill paths are absent from the shipped MAS app.
- **Existing mitigation:** MAS build also disables system ComputerUse lane (OpenAICompatibleChatGatewayClient.swift:223); remote-config kill switch still reachable via coordinator updateKillSwitch
- **Gap:** Physical hotkey + lock-screen kill unavailable in MAS
- **Residual risk:** Medium
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P1 (should-fix before launch)

### T-TOOL-05 — CLI lane does not tag repo/tool/web content as untrusted (indirect prompt injection)
- **Category / framework:** LLM01 prompt injection 2025; Agentic indirect injection
- **Component / evidence:** `CLIBridge / CLIArgumentBuilder.combinedPrompt`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** combinedPrompt (:248) wraps only the chat user message in <UNTRUSTED_CONTENT>. Files, tool results, and web content the CLI agent itself ingests are never tagged and OpenBurnBar cannot interpose, so a poisoned file/output can steer a write/shell-granted agent.
- **Existing mitigation:** combinedPrompt wrapping for in-app chat turns only
- **Gap:** No untrusted-content tagging or interposition in the CLI lane
- **Residual risk:** High when workspaceWrite/shell granted
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P1 (should-fix before launch)

### T-TRN-02 — Cloud-controlled inbound allowlist admits attacker or locks out owner
- **Category / framework:** STRIDE:Elevation/DoS; Agentic:authz-bypass
- **Component / evidence:** `FirestoreIrohInboundPeerAllowlist + host accept gate`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** Allowlist read from iroh_pairing/{conn}/controllers/* in Firestore (FirestoreIrohInboundPeerAllowlist.swift:16-29); cloud/admin injecting a controllers/{attackerNodeId} doc adds attacker to Mac accept set (HermesIrohRelayHostClient.swift:292); deleting docs DoSes the owner
- **Existing mitigation:** controller docs callable-gated firestore.rules:2774; default-deny empty set; per-peer purge HermesIrohRelayHostClient.swift:430; downstream PhoneControlAuthorityValidator + E2E still gate control actions
- **Gap:** No local/out-of-band confirmation of allowlist membership; transport admission is cloud-authoritative
- **Residual risk:** Admitted attacker reaches request handler but is blocked by app-layer authority; main impact handler reachability + DoS
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P1 (should-fix before launch)

### T-TRN-03 — Attacker-induced silent downgrade iroh->Firestore
- **Category / framework:** STRIDE:Tampering/DoS; Agentic:forced-path/observability-evasion
- **Component / evidence:** `HermesCompositeRelayTransport`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** On-path adversary or relay drops/blackholes iroh dials; for any op except .chatCompletions the cascade silently falls back to Firestore long-poll (HermesCompositeRelayTransport.swift:64,108), a cloud-mediated path exposing more timing/size/connection metadata and removing P2P directness
- **Existing mitigation:** selected-model chat hard-fails (:119-121,126-132); each fallback audited (:134-148); Firestore payloads remain E2E-sealed
- **Gap:** Control-plane + CLI streams fall back automatically; attacker can cheaply force the more-observable path; no in-code fallback-rate alarm
- **Residual risk:** Metadata exposure + degraded P2P guarantees, not payload disclosure
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P1 (should-fix before launch)

## Medium (41)

### T-AI-03 — Memory/RAG poisoning via parsed third-party agent logs
- **Category / framework:** OWASP LLM08 / Agentic memory poisoning / MITRE ATLAS AML.T0070
- **Component / evidence:** `LogParser/* + SearchService+Retrieval`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Third-party content makes a coding agent emit attacker text into its CLI log -> parsers ingest with no provenance/trust tier (LogParserProtocol.swift ConversationRecord) -> enters RAG corpus, persists, retrieved in later sessions.
- **Existing mitigation:** Retrieval output wrapped at formatPack.
- **Gap:** No write-time validation, no provenance trust tier, no poisoned-chunk quarantine/deletion; also reaches model unwrapped via oracle path (T-AI-02).
- **Residual risk:** Durable cross-session influence on agent behavior.
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P2 (important hardening)

### T-AI-04 — Browser SSRF via redirect / JS-nav / click after validated goto, and DNS rebinding
- **Category / framework:** OWASP LLM01 / SSRF / MITRE ATLAS
- **Component / evidence:** `ComputerUseRunCoordinator / OpenBurnBarPlaywrightDriver`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Agent goto a public host that 302/meta-refresh/JS-redirects to http://169.254.169.254/, or a public hostname resolving to a private IP, or browser_click an internal link; then browser_extract returns the body into context. PlaywrightDriver.swift:241 goto forwards URL with no post-navigation host re-check.
- **Existing mitigation:** OpenBurnBarBrowserTargetPolicy.validatedURL on initial goto URL (ComputerUseRunCoordinator.swift:785).
- **Gap:** No per-navigation/redirect re-validation; no resolved-IP (post-DNS) enforcement; click/JS nav unbounded.
- **Residual risk:** Internal/cloud-metadata exfiltration into model context (extract output is wrapped, limiting injection but not data exfiltration).
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P2 (important hardening)

### T-AI-06 — No content-level secret redaction before sending prompts to model providers
- **Category / framework:** OWASP LLM02 Sensitive Information Disclosure
- **Component / evidence:** `Chat prompt assembly / provider calls`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Focus transcript / RAG snippet / file read containing API keys or tokens is wrapped (as untrusted) but transmitted verbatim to the model provider (local gateway, or OpenRouter for insights).
- **Existing mitigation:** Insights path sends digest only; CLILaunchRedactor exists for log display (CLIProfileStreamFailoverRunner.swift:260) but not prompt payload.
- **Gap:** Chat path sends raw secrets; no zero-retention/no-train header asserted in code.
- **Residual risk:** Secret leakage to provider plus provider retention (UNKNOWN, deployment-dependent).
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P2 (important hardening)

### T-AND-01 — Vault/Signal/relay private keys recoverable on rooted/forensic device
- **Category / framework:** STRIDE-S/T / MASVS-STORAGE-1,CRYPTO-2
- **Component / evidence:** `AndroidLocalSecretBox + SharedPreferences (CloudVaultCrypto.kt:1206-1221, AndroidSignalIdentityKeyStore.kt, HermesRelayKeyStore.kt:33)`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** Root/Keystore-extraction reads prefs and unwraps via non-auth Keystore AES key (no biometric, no StrongBox) -> decrypts wrapped vault key -> reads all cloud chat
- **Existing mitigation:** Keystore-wrapped non-exportable key, allowBackup=false, FLAG_SECURE
- **Gap:** Wrapping key not StrongBox/user-auth-bound; raw key blobs in plain SharedPreferences
- **Residual risk:** HIGH on rooted device, LOW on stock locked device
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P2 (important hardening)

### T-AND-02 — Base-config cleartext permits HTTP to non-deny-listed hosts
- **Category / framework:** STRIDE-I / MASVS-NETWORK-1
- **Component / evidence:** `network_security_config.xml:33`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** SDK/image-loader/relay-or-tunnel host not in deny list issues plain HTTP on hostile network -> interception/injection; only app-layer validatedBaseURL blocks public HTTP and does not cover all callers
- **Existing mitigation:** Backend hosts hard-denied @40-54, app-layer validatedBaseURL
- **Gap:** No OS-level LAN-only scoping (cannot express RFC1918 CIDR); LAN-direct TLS migration unimplemented
- **Residual risk:** MEDIUM
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P2 (important hardening)

### T-AND-04 — Sender-auth downgrade window while trusted-sender set 'incomplete'
- **Category / framework:** STRIDE-S/T / Agentic-supply-chain / MASVS-AUTH
- **Component / evidence:** `SignalAtRestFallbackPolicy.kt:34-50 + senderSetComplete=size>1 heuristic`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** Firestore writer supplies unknown-sender envelope; while trustedSenderPublicKeys.size==1 (single peer or escrow_devices fetch failure @AndroidCloudVaultSignalPayloads.kt:143) SenderNotTrusted stays legacy-eligible -> recipient decodes sender-unauthenticated legacy sealedPayload
- **Existing mitigation:** Forged-sig & stripped-block always fail-closed (@38-40); binding-mismatch fail-closed (@45)
- **Gap:** size>1 is coarse readiness proxy, not 'published set complete'; transient fetch failure silently downgrades
- **Residual risk:** MEDIUM (narrows to readiness/single-peer cases)
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P2 (important hardening)

### T-ATT-02 — iOS received media stored plaintext at rest (no seal/quarantine/gate)
- **Category / framework:** STRIDE Information disclosure; CWE-312/770
- **Component / evidence:** `iOSFileTransferService.handleAdvertise`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** handleAdvertise (135-208) fetches blob and records URL only; lacks Mac path's capabilityGate (391), sealReceivedFileAtRest (421), applyInboundQuarantine (423); inbox in Caches/Mercury/Inbox; no FileProtection set.
- **Existing mitigation:** iOS sandbox + default Data Protection
- **Gap:** Platform parity; no explicit complete protection; no inbound byte budget.
- **Residual risk:** Plaintext media recoverable from unlocked/jailbroken device or backup; unbounded inbound.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P2 (important hardening)

### T-ATT-03 — Wire-manifest filename/mime/size leak metadata to relay if frame not E2EE-sealed
- **Category / framework:** STRIDE Information disclosure / LINDDUN Disclosure; CWE-201/359
- **Component / evidence:** `HermesRealtimeRelayAttachmentManifest in advertise frame`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Plaintext filename/mime/size (HermesRealtimeRelayTypes.swift:1712-1738) embedded in frame.media.attachment (MacFileTransferService.swift:211-218); confidentiality depends entirely on relay frame-sealing at another layer.
- **Existing mitigation:** At-rest Firestore manifest seals filename
- **Gap:** Transport manifest unsealed at this layer; trust doc implies 'never readable by server'.
- **Residual risk:** Filename/size metadata visible to relay if frame E2EE inactive.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P2 (important hardening)

### T-ATT-04 — Unauthenticated Mercury manifest metadata (no MAC/signature)
- **Category / framework:** STRIDE Tampering; CWE-345/646
- **Component / evidence:** `HermesRealtimeRelayAttachmentManifest`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Manifest has no signature field (Types 1712-1738); filename/mime/size/peerDeviceId all sender-controlled; only blobHash self-authenticates via iroh, so displayed name/type not bound to bytes.
- **Existing mitigation:** Bytes bound to blobHash on export
- **Gap:** Displayed filename/mime not bound to content.
- **Residual risk:** Spoofed file identity / content-type confusion (e.g. .jpg name on executable payload).
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P2 (important hardening)

### T-ATT-06 — Seal-at-rest silently skipped when no media session key (fail-open)
- **Category / framework:** STRIDE Information disclosure; CWE-311
- **Component / evidence:** `MacFileTransferService:420-422`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** if let sealKey = frameSealKeyProvider(...) — when nil, freshly-fetched plaintext blob persists in Caches inbox (quarantine-only).
- **Existing mitigation:** Quarantine xattr; sandbox
- **Gap:** Fail-open: no key keeps plaintext rather than refusing transfer.
- **Residual risk:** Plaintext media at rest when key negotiation absent.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P2 (important hardening)

### T-AZ-03 — Metadata leakage in sealed cloud sync
- **Category / framework:** STRIDE:InformationDisclosure / LINDDUN:Detectability
- **Component / evidence:** `users/{uid}/{usage,budgetRules,conversations,...}`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Operator/server with Firestore access reads cleartext metadata (counts, timestamps, deviceIds, projectKeyHash)
- **Existing mitigation:** Content fields sealed (:462-500); plaintext-name fail-closed create (:1163-1165)
- **Gap:** Sealing covers named fields only; surrounding metadata cleartext by design
- **Residual risk:** Traffic-analysis / activity inference; not an auth bypass
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P2 (important hardening)

### T-AZ-04 — Plaintext secret in a non-denylisted field
- **Category / framework:** STRIDE:InformationDisclosure / OWASP-API3:BOPLA / ASVS-V8
- **Component / evidence:** `Any owner-writable collection using ownerWritableNonSecret`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Client serializes credential under key not in 12-name denylist or nested map
- **Existing mitigation:** hasNoPlaintextSecretFields (:56-69) + sealed validators + client unit tests
- **Gap:** Denylist exact-top-level names only; rules cannot enforce universally
- **Residual risk:** Depends on client correctness; defense-in-depth only
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P2 (important hardening)

### T-AZ-05 — Admin-SDK rule-bypass via callable missing ownership check
- **Category / framework:** STRIDE:ElevationOfPrivilege / OWASP-API5:BFLA / ASVS-V4
- **Component / evidence:** `100 onCall + 8 onRequest endpoints`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Handler performs Admin-SDK I/O for a uid it did not authorize (Admin SDK ignores rules)
- **Existing mitigation:** enforceAuthAndAppCheck/assertOwnership (auth.ts:22-31,69-73); assertUserStoragePath (shared.ts:514)
- **Gap:** Enforcement is per-handler convention, not structural; full 100-handler enumeration out of scope
- **Residual risk:** One handler deriving uid from body without assertOwnership = cross-tenant read/write
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P2 (important hardening)

### T-AZ-06 — App Check console enforcement not provable from code
- **Category / framework:** STRIDE:Spoofing / OWASP-API2:BrokenAuth / ASVS-V2
- **Component / evidence:** `Firestore/Storage SDK datapath`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Non-app client with stolen/forged ID token writes directly via SDK if console App Check enforcement is OFF
- **Existing mitigation:** Callables fail-closed in prod (config.ts:78-84); rules require request.auth
- **Gap:** rules request.auth alone does not attest the app; SDK App Check is a console toggle absent from repo (firestore.rules:20-23)
- **Residual risk:** UNKNOWN until deployed enforcement state confirmed
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P2 (important hardening)

### T-CRY-01 — Gateway lane crypto downgrade v3->v2 via server-supplied version advertisement
- **Category / framework:** STRIDE:Tampering/Spoofing-of-policy; Agentic: MITRE ATLAS AML.T0048
- **Component / evidence:** `GatewayEventSealer / HermesGatewayAPI`
- **Actor:** Network attacker / malicious or compromised relay | **Asset:** Relay & gateway message payloads | **Data flow:** Phone<->Cloud<->Mac sealed relay/gateway
- **Preconditions:** On-path network position or control of a relay/gateway lane
- **Attack path:** Hostile/compromised relay or Firestore writer sets client record supportsRelayEnvelopeVersions=[2]/preferredRelayEnvelopeVersion=2 (HermesGatewayAPI.swift:1229-1230); phone seals phone->agent events with weaker bespoke v2 2-DH wrap (GatewayEventSealer.swift:210-218); reply side accepts v2 when wire relayKeyVersion==2 (:890-897).
- **Existing mitigation:** v2 is still sender-authenticated + confidential (no forgery/plaintext downgrade); keys TOFU-pinned and immutable.
- **Gap:** No cryptographic version floor that refuses v2 once v3 negotiated; server controls advertised version. CURE53 T-GW-5 confirms _emit_version_or_refuse unmerged.
- **Residual risk:** Relay forces older, less-standard primitive; cryptanalytic margin only, no practical break of v2.
- **Detection:** Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing) | **Owner:** Crypto/Core (OpenBurnBarCore) | **Priority:** P2 (important hardening)

### T-CRY-02 — Pi-agent relay request lane has NO sender authentication (v1 ephemeral-static wrap)
- **Category / framework:** STRIDE:Spoofing/Tampering
- **Component / evidence:** `PiAgentCloudRelayHostService`
- **Actor:** Network attacker / malicious or compromised relay | **Asset:** Relay & gateway message payloads | **Data flow:** Phone<->Cloud<->Mac sealed relay/gateway
- **Preconditions:** On-path network position or control of a relay/gateway lane
- **Attack path:** decryptRelayRequest opens with PiAgentRelayCrypto.unwrapSymmetricKey (no sender key) at PiAgentCloudRelayHostService.swift:336-340; any writer of users/{uid}/pi_agent_relay_requests with the recipient's published public key can mint a ciphertext that opens, since v1 wrap binds no sender.
- **Existing mitigation:** Firestore rules scope writes to owner namespace (firestore.rules:3161-3163); confidentiality vs relay holds.
- **Gap:** No pinned-sender binding, no counter/replay cache on this lane.
- **Residual risk:** Forged/replayed Pi-agent requests within a compromised owner account or by a write-capable relay; relay cannot read but could inject.
- **Detection:** Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing) | **Owner:** Crypto/Core (OpenBurnBarCore) | **Priority:** P2 (important hardening)

### T-CVS-01 — Server strips signalEnvelope to force unauthenticated legacy decode
- **Category / framework:** STRIDE:Tampering/Repudiation; agentic-supply-chain
- **Component / evidence:** `AssistantChatHistoryStore.kt reader fallback / dual-write`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** Malicious Firestore writer deletes signalEnvelope field; reader sees null -> FallThrough -> decodes unauthenticated legacy sealedPayload; fail-closed policy never runs (no envelope present)
- **Existing mitigation:** Legacy AES-GCM still confidential + path-AAD; fail-closed only for PRESENT-but-broken envelopes
- **Gap:** No per-doc Signal-required pin; strip indistinguishable from legacy-only doc
- **Residual risk:** Full sender-auth bypass survives until legacy floor removed post-activation (latent; bites once Signal is live)
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P2 (important hardening)

### T-CVS-02 — senderNotTrusted legacy downgrade window during rollout
- **Category / framework:** STRIDE:Spoofing
- **Component / evidence:** `SignalAtRestFallbackPolicy + senderSetComplete heuristic`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** Before all trusted devices publish, senderSetComplete==false (size>1 heuristic), so server-forged envelope naming an unpublished device id is accepted as a readiness gap rather than dropped
- **Existing mitigation:** Only senderNotTrusted is downgrade-eligible; signature required once id resolves
- **Gap:** size>1 heuristic; single legitimate peer mis-handled
- **Residual risk:** Time-boxed spoof window during activation ramp
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P2 (important hardening)

### T-CVS-04 — Weak/empty passphrase + low-iteration recovery bundle brute-forced offline
- **Category / framework:** STRIDE:Information Disclosure
- **Component / evidence:** `DatabaseEncryptionService recovery bundle`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** exportRecoveryBundle(empty) derives key from empty/weak password at 100k iters; bundle on disk/cloud offline-grindable; import trusts attacker-supplied iteration count (no floor)
- **Existing mitigation:** Random 16B salt + AES-GCM integrity
- **Gap:** No min-length/zxcvbn gate, no import-side iteration floor, 100k < OWASP 600k
- **Residual risk:** Leaked bundle with weak passphrase yields SQLCipher DB key
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P2 (important hardening)

### T-CVS-05 — No forward secrecy for at-rest sealing
- **Category / framework:** STRIDE:Cryptography/Repudiation
- **Component / evidence:** `SignalAtRestSealer recipient identity seal + persistent vault key`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** Content keys wrap to static recipient identity key; vault key long-lived; future identity/vault-key compromise retroactively decrypts all previously captured sealed docs
- **Existing mitigation:** Per-message random content key; rotation via rewrapCloudVaultDocument (rewrap, not ratchet)
- **Gap:** No ephemeral/ratcheted at-rest scheme
- **Residual risk:** No PFS at rest (consistent with threat-model:33 relay concession)
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P2 (important hardening)

### T-DMN-03 — User-writable daemon binary; pre-exec signature check is TOCTOU and launchd does not re-verify
- **Category / framework:** STRIDE:Tampering/Elevation
- **Component / evidence:** `OpenBurnBarDaemonManager+Lifecycle.swift / ~/Library/Application Support/.../daemon/OpenBurnBarDaemon (0755)`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** Same-uid attacker swaps the installed binary between the app's validateStaticCode and launchd KeepAlive exec; launchd execs whatever is at the path without signature check.
- **Existing mitigation:** RR-3 live socket peer code-sig gate (swapped binary fails DR when real app connects); atomic swap + pre-exec check shrink window.
- **Gap:** A hostile swapped binary still runs as the user and can abuse the daemon's own creds/entitlements before any app connects; peer-auth only contains impersonation TO the app.
- **Residual risk:** Medium
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P2 (important hardening)

### T-DMN-04 — Daemon does not cryptographically re-verify the phone single-use local-auth proof
- **Category / framework:** Agentic:authority-confusion / STRIDE:Elevation
- **Component / evidence:** `ComputerUseRunCoordinator (daemon) vs PhoneControlAuthorityValidator (app)`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** Op-hash-bound Ed25519 proof is validated only in the app/relay; daemon gate is entitlement+scope+burst-signature, trusting the app to have done step-up. If app is compromised (T-DMN-01) the proof requirement is bypassed for shell/system-input/workspace-write.
- **Existing mitigation:** App peer code-sig gate; daemon scope/deny/budget gate.
- **Gap:** No daemon-side proof verification; proof binding is only as strong as app integrity (daemon does not hold the phone verifying key).
- **Residual risk:** Medium (High if app compromised)
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P2 (important hardening)

### T-DMN-05 — Production env escape hatch disables peer code-sig enforcement
- **Category / framework:** STRIDE:Spoofing
- **Component / evidence:** `OpenBurnBarDaemonMain.swift:76 makePeerAuthenticator`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** Same-uid actor influencing the daemon launch env sets OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1, dropping the main-socket gate to .disabled (every peer admitted); only the bearer token remains.
- **Existing mitigation:** launchd plist app-written 0600; bearer token still required.
- **Gap:** Opt-out ships in the released binary; attacker controlling plist/env removes the load-bearing gate.
- **Residual risk:** Medium
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P2 (important hardening)

### T-IOS-01 — App Group container data not file-protected
- **Category / framework:** Information Disclosure / LINDDUN Disclosure (MASVS-STORAGE-1)
- **Component / evidence:** `BurnBarWidgetSnapshot.swift:86-92, TextExpansionInbox.swift:29-38`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** App Group files written via Data.write(.atomic) with no protection class; keyboard/widget extensions have no data-protection entitlement; readable from a locked stolen device or Finder backup
- **Existing mitigation:** Main-app entitlement floor; chat uses .complete
- **Gap:** App Group container outside entitlement floor; no explicit protection class on shared-container writes
- **Residual risk:** Disclosure of text-expansion snippet bodies, keyboard inbox, cost/model aggregates (not key material)
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P2 (important hardening)

### T-IOS-03 — Mirror privacy mask is surface-scoped, not app-wide
- **Category / framework:** Information Disclosure (MASVS-PLATFORM-3 screenshot/recording)
- **Component / evidence:** `ScreenPrivacyGuard.swift; InlineAgentMirrorView.swift:222, AgentWatchView.swift:92`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Screen recording/AirPlay/app-switcher snapshot captures chat, revealed provider-key SecureFields, vault recovery-key entry, dashboards; only the live Mac mirror is masked
- **Existing mitigation:** screenPrivacyGuard() on two mirror views; SecureField hides input
- **Gap:** No app-wide app-switcher cover; sensitive non-mirror screens recordable
- **Residual risk:** Leak of conversation content, provider credentials, recovery keys via recording/recents
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P2 (important hardening)

### T-IOS-04 — Push preview/title carried as plaintext in APNs payload
- **Category / framework:** Information Disclosure (MASVS-NETWORK / data minimization)
- **Component / evidence:** `AgentReplyNotificationService.swift:36-45,188-206,260`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Pushes put title/preview into UNNotificationContent.body and userInfo; APNs sees them and they render on lock screen; previews 'generic today' is not a code-level guarantee
- **Existing mitigation:** Markdown flattening; device fan-out respects auth state
- **Gap:** No enforced redaction or mutable-content + NSE to fetch/decrypt body client-side
- **Residual risk:** Sensitive agent reply text could surface on lock screen and transit APNs cleartext
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P2 (important hardening)

### T-IOS-05 — Sensitive material copied to system pasteboard without expiry/local-only
- **Category / framework:** Information Disclosure (MASVS-STORAGE-2 pasteboard)
- **Component / evidence:** `SmartHubDisplaySettingsAdapter.swift:106, HermesSettingsView.swift:2101, MercuryLiveSheet.swift:1969`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** UIPasteboard.general.string writes with no expirationDate/localOnly; can include bootstrap/refresh URLs, curl snippets w/ bearer tokens, Mac clipboard; readable by other apps + Universal Clipboard
- **Existing mitigation:** Size bound on Mac-clipboard paste
- **Gap:** No UIPasteboard expirationDate/localOnly; no clearing
- **Residual risk:** Token/URL/clipboard disclosure to other apps and Handoff-paired devices
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P2 (important hardening)

### T-IOS-09 — Vault/escrow keys not biometry- or Secure-Enclave-bound
- **Category / framework:** Tampering / Information Disclosure (MASVS-CRYPTO-2 key protection)
- **Component / evidence:** `CloudVaultCrypto.swift:1414-1429, iOSDeviceKeypair.swift:101-116`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** 32-byte vault key and P-256 escrow private key stored as raw kSecValueData (WhenUnlockedThisDeviceOnly), not SE-wrapped or .biometryCurrentSet-gated; any app-context code on an unlocked device reads the vault key and decrypts CloudVault
- **Existing mitigation:** Device-only accessibility; ComputerUse uses a separate SE+biometry proof credential
- **Gap:** Vault and escrow secrets are not SE-wrapped or biometric-gated despite an implemented pattern elsewhere
- **Residual risk:** Whole-vault decryption from app context on an unlocked device
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P2 (important hardening)

### T-PRV-04 — Server log scrubber is pattern-based; numeric/non-pattern PII bypasses
- **Category / framework:** LINDDUN Disclosure; STRIDE Information Disclosure
- **Component / evidence:** `functions/src/logging.ts:16-29,48-90`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** scrubValue only transforms strings; numbers/booleans pass through; values not matching {email,IPv4,sk-|AIza|ya29.|eyJ,16-digit CC} logged verbatim; new provider key formats not all covered; free-form String(error) may carry tokens/paths
- **Existing mitigation:** Known-prefix + key-name redaction + 1024-char truncation
- **Gap:** No allowlist model; numeric values unscrubbed; depends on sensitive field naming
- **Residual risk:** Medium; log/Sentry secret disclosure on edge fields
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P2 (important hardening)

### T-PRV-05 — Encrypted-search metadata: facets + posting graph + access patterns enable inference
- **Category / framework:** LINDDUN Linking + Detecting + Disclosure; SSE leakage
- **Component / evidence:** `functions/src/callables/encryptedSearchIndex.ts:44-67, encryptedSearch.ts:618-757`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** Server observes co-occurring tokenHashes per chunk, posting fan-out, query-time hashes, result sizes/scores, and cleartext facets (provider/model/deviceId/cost/tokens/startTime); frequency+facet analysis yields providers used, spend, timeline, device, repeated query topics
- **Existing mitigation:** Per-user HKDF keying; sealed snippets/titles; bounded hash counts
- **Gap:** No padding/dummy-posting noise; cleartext facets; query hashes sent in clear
- **Residual risk:** Medium; content-adjacent inference and behavioral profiling by curious/compromised operator
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P2 (important hardening)

### T-PTR-01 — Revocation leaves pre-revocation vault key un-clawed-back (cached-key window)
- **Category / framework:** STRIDE:Info/Elevation; framework T-ID-4 / RR-5
- **Component / evidence:** `revokeEscrowDeviceTrust + rotation chain`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** Trusted device compromised/lost -> operator revokes -> grants/controllers/sessions severed immediately and rotation queued -> revoked device's already-cached vault key still decrypts pre-revocation synced content until a survivor finishes rotation+rewrap.
- **Existing mitigation:** Inline + survivor + stale-detector rotation now wired (computerUseSecurity.ts:1532; ComputerUseSecurityCallableClient.swift:302,370); active wrappers revoked at revoke (:1508).
- **Gap:** No claw-back: nothing invalidates a key already resident on the revoked device.
- **Residual risk:** Time-bounded read of pre-revocation content by an offline thief; new wraps blocked. Down-graded from package's 'rotation entirely unwired'.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P2 (important hardening)

### T-PTR-02 — Rotation requirement starves on uneven survivor-pickup trigger coverage
- **Category / framework:** STRIDE:DoS; Agentic-availability
- **Component / evidence:** `pickUpPendingCloudVaultRotations (Mac/Android/iOS)`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** Revoking device offline; only online survivor is iOS (no rotate-pickup trigger) or an Android device whose user never opens the Devices screen (pickup fires only 'once per store instance from devices surface first load', DevicesStore.kt:110-115). Requirement stays pending; stale detector only flags.
- **Existing mitigation:** Mac: launch+every-foreground+post-revoke (AppDelegate.swift:119,134,143). Android: full rotate path (AndroidCloudVaultRevocationRotation.kt:135). Detector cloudVaultRotationResilience.ts:268.
- **Gap:** No server-driven rotation; iOS has no survivor rotate-pickup; Android pickup is Devices-screen-gated, not per-foreground.
- **Residual risk:** Prolonged cached-key window for iOS-survivor or Devices-screen-avoidant fleets.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P2 (important hardening)

### T-PTR-04 — Approve-time safety-code compare UI defaults OFF
- **Category / framework:** STRIDE:Spoofing; LINDDUN
- **Component / evidence:** `EscrowDeviceTrustSafetyCheckFlag`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** Operator approving a new device is not, by default, prompted to compare an out-of-band safety code at the moment of approval (EscrowDeviceSafetyCode.swift:202 defaultEnabled=false).
- **Existing mitigation:** Server fingerprint->bytes binding enforced (computerUseSecurity.ts:270) and trust-chain signature bind the key; runtime controller pin gate is ON.
- **Gap:** Missing user-facing OOB confirmation at approval time.
- **Residual risk:** A captured-but-valid approval that App Check + nonce admit enrolls a device the human never visually confirmed.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P2 (important hardening)

### T-SC-04 — Cargo.lock / SwiftPM / Gradle locks not OSV-scanned
- **Category / framework:** STRIDE:Tampering / SSDF RV.1 / SCVS V2
- **Component / evidence:** `security-pr.yml:199-209; rust-sast.yml:50-55`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Malicious transitive crate not yet in RustSec, or vulnerable SwiftPM/Gradle dep, lands undetected by OSV.
- **Existing mitigation:** cargo-audit on 2 crates; PR dependency-review.
- **Gap:** No OSV/grype over Cargo.lock or Package.resolved or Android Gradle locks.
- **Residual risk:** Medium
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P2 (important hardening)

### T-SC-06 — GPG checksum signing best-effort, not enforced
- **Category / framework:** STRIDE:Repudiation / SSDF PS.2
- **Component / evidence:** `release.yml:658-664`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** If RELEASE_SIGNING_KEY unset/cleared, release publishes UNSIGNED checksums; only Sparkle Ed25519 + notarization remain.
- **Existing mitigation:** Strict-secret gate at :139-170 (does NOT include this key); live-feed Ed25519 verify still runs.
- **Gap:** GPG provenance silently optional.
- **Residual risk:** Low
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P2 (important hardening)

### T-SC-08 — Provenance SBOM attests source tree, not as-shipped artifact bytes
- **Category / framework:** STRIDE:Spoofing/Repudiation / SSDF PS.3,RV
- **Component / evidence:** `supply-chain-provenance.yml:59-69,84-93`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Attested SBOM describes re-checked-out source, not the bytes built/published in triggering run; subject/artifact mismatch.
- **Existing mitigation:** release.yml attests actual DMG/zip at :707-737.
- **Gap:** Provenance lane generates+attests SBOM regardless of downloaded artifacts.
- **Residual risk:** Medium
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P2 (important hardening)

### T-TOOL-06 — Queued grant authority public key sourced from cloud Firestore (TOFU)
- **Category / framework:** STRIDE Spoofing/Tampering
- **Component / evidence:** `AgentCapabilityGrantQueueListener.authorityPublicKey`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** agent_grant_authorities/{deviceId} doc is read (:97-110); a Firestore-write-capable attacker who pre-seeds a key before first pin could forge signed grant requests.
- **Existing mitigation:** F1 controller pin (validator.registerPeer :81) rejects a key differing from the operator-pinned key
- **Gap:** Trust rooted in cloud doc at first pin; pin-store integrity is the real anchor
- **Residual risk:** Medium — depends on pin enforcement and firestore.rules write protection
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P2 (important hardening)

### T-TOOL-07 — Non-trusted workspace preset authorizes autonomous shell (codex workspace-write, droid auto medium)
- **Category / framework:** Agentic: Excessive Agency
- **Component / evidence:** `CLIArgumentBuilder.codexArguments/droidArguments`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** A .workspace grant maps shell capability to codex --sandbox workspace-write (:89-91) and droid --auto medium (:124-126), enabling autonomous in-workspace command execution with only the CLI's own sandbox.
- **Existing mitigation:** Not YOLO — relies on CLI-side sandbox/auto-mid
- **Gap:** OpenBurnBar cannot verify the CLI honors workspace-write/auto level
- **Residual risk:** Medium
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P2 (important hardening)

### T-TRN-04 — Metadata exposure to cloud (NodeIds, relay URL, direct IPs, timing, sizes)
- **Category / framework:** STRIDE:InformationDisclosure; LINDDUN:Linkability/Identifiability
- **Component / evidence:** `Firestore pairing/audit docs + n0 relay`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** FirestoreIrohPairingDirectory.swift:42-81 and pairing records store raw long-lived NodeIds, relay URL, and direct LAN/WAN IPs in plaintext Firestore; audit details log localNodeId/targetNodeId/relayURL (HermesIrohRelayTransport.swift:441-447); n0 relay observes IP+NodeId+sizes+timing -> user localization/presence correlation
- **Existing mitigation:** payload E2E-sealed; iOS dials without published direct IPs (HermesIrohRelayTransport.swift:452); media telemetry bucketed/hashed (firestore.rules:2718-2757)
- **Gap:** control-plane pairing/audit docs store raw NodeIds + relay URL + direct IPs; NodeIds are persistent never-rotated identifiers
- **Residual risk:** Metadata-based tracking/correlation by cloud or anyone with namespace read access
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P2 (important hardening)

### T-TRN-05 — Stale/replayed pairing record steers iOS to dead/hijacked NodeAddr
- **Category / framework:** STRIDE:Tampering/Spoofing
- **Component / evidence:** `IrohPairingSignature.verify`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** Replay an old signed pairing record within the 180s freshness window (or with client clock skew) to point iOS at a previously-valid-but-reassigned relay/NodeAddr (IrohRelayPairing.swift:133-168)
- **Existing mitigation:** 180s freshness window (:74,165); Ed25519 sig over canonical payload incl publishedAtMillis; Mac republishes <=60s (pairingPublishInterval=60)
- **Gap:** No per-record nonce/monotonic counter; freshness relies on client clock; no session-challenge binding
- **Residual risk:** Bounded ~3-min replay window; NodeId reassignment in-window unlikely but possible
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P2 (important hardening)

### T-TRN-06 — DoS via connection flood / post-handshake allowlist rejection
- **Category / framework:** STRIDE:DoS
- **Component / evidence:** `iroh accept_one + Swift acceptLoop`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** Any peer completing ALPN/QUIC handshake reaches accept_one (lib.rs:450); non-allowlisted peers rejected only AFTER handshake+stream accept (HermesIrohRelayHostClient.swift:292) with no per-source rate limit or concurrent-connection cap in the Rust crate; repeated dials force handshakes + Firestore allowlist reads
- **Existing mitigation:** default-deny allowlist closes streams fast (:304); QUIC idle timeout; consecutive-failure rebuild (:392-405)
- **Gap:** no connection-rate limit, no concurrent-handshake cap, allowlist lookup per-accept
- **Residual risk:** CPU/handshake amplification + Firestore read pressure from unauthenticated flood; no plaintext exposure
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P2 (important hardening)

## Low (34)

### T-AI-05 — Insecure output handling: model JSON rendered as missions/recommendations
- **Category / framework:** OWASP LLM05 Improper Output Handling
- **Component / evidence:** `insightsHostedAnswer client rendering`
- **Actor:** Indirect prompt-injection adversary (content author) | **Asset:** Agent context/memory; downstream tool-call decisions | **Data flow:** Untrusted content (RAG/tool/web/log)<->model context
- **Preconditions:** Attacker controls text that enters an active agent's context
- **Attack path:** Provider output parsed as InsightAnalysisResult and rendered as recommendations/missionCandidates (insightsHostedAnswer.ts:301-308); model-authored action proposals trusted by UI.
- **Existing mitigation:** Strict JSON envelope, bounded sizes, digest-only input.
- **Gap:** No semantic safety validation of recommended missions/actions.
- **Residual risk:** User nudged toward a model-suggested harmful next mission.
- **Detection:** Provenance-wrap coverage gaps; tool-loop audit; oracle/RAG source tagging (missing) | **Owner:** AgentLens (Context/Chat) | **Priority:** P3 (defense-in-depth)

### T-AND-03 — Exported deep-link / widget / IME / wallpaper attack surface
- **Category / framework:** STRIDE-T/E / MASVS-PLATFORM-1
- **Component / evidence:** `AndroidManifest.xml MainActivity@66-78, widget receivers@87-146, QuickGlanceActivity@195-205`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** Malicious app fires burnbar:// or AppWidget broadcasts -> navigation/UI side effects
- **Existing mitigation:** Deep-link navigation-only no auto-submit (MainActivityIntentActions.kt), E2E launchers BuildConfig.DEBUG-gated requiring non-URL extras, services behind BIND perms
- **Gap:** Deep-link input still parsed in release; receivers lack signature permission
- **Residual risk:** LOW
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P3 (defense-in-depth)

### T-AND-05 — Remote Unlock saved-credential read not code-coupled to biometric prompt
- **Category / framework:** STRIDE-I / MASVS-AUTH-2
- **Component / evidence:** `RemoteUnlockSavedCredentialStore.load:47-64`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** load() swallows auth/crypto exception returning null; if a caller reads without first calling authenticateForRemoteUnlock the Keystore still throws (auth required) so value not exposed, but no compile-time guarantee
- **Existing mitigation:** Keystore setUserAuthenticationRequired(true) forces fresh auth on decrypt regardless of caller
- **Gap:** No code-level binding between prompt success and store read
- **Residual risk:** LOW
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P3 (defense-in-depth)

### T-AND-06 — Crash/observability pipeline may capture sensitive in-memory data
- **Category / framework:** STRIDE-I / MASVS-PRIVACY
- **Component / evidence:** `AndroidManifest.xml:49-62 Sentry DSN/traces/ANR + Crashlytics`
- **Actor:** Thief with unlocked phone or malicious app | **Asset:** Android local data, keys, FCM payloads | **Data flow:** Android app<->Keystore/FCM
- **Preconditions:** Physical access to an unlocked device or a malicious app with shared access
- **Attack path:** Crash/ANR payloads or breadcrumbs include prompt/credential fragments shipped off-device
- **Existing mitigation:** DSN injected only in CI/non-debug, FLAG_SECURE limits screen capture
- **Gap:** No reviewed PII-scrubbing/beforeSend config
- **Residual risk:** LOW (needs Sentry config review)
- **Detection:** n/a on-device; FCM payload review; Play Integrity (server-side) | **Owner:** Mobile-Android | **Priority:** P3 (defense-in-depth)

### T-ATT-05 — Content-type trust on display via extension-only inferMime
- **Category / framework:** STRIDE Spoofing; CWE-434/646
- **Component / evidence:** `MediaFileTransferService.inferMime:179-194`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Receiver mime derived from sender-chosen extension; UI may render/preview by mime.
- **Existing mitigation:** Mac quarantine xattr gates Gatekeeper on open
- **Gap:** No receiver content sniffing on Mercury path.
- **Residual risk:** Type confusion in preview.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P3 (defense-in-depth)

### T-ATT-08 — Gateway download URL lacks forced Content-Disposition/Content-Type
- **Category / framework:** STRIDE Information disclosure / XSS-adjacent; CWE-79
- **Component / evidence:** `handleHermesGatewayAttachmentDownloadUrl:1653-1658`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Read signed URL issued with no responseDisposition/responseType; a legacy non-octet object served inline could render in a browser web client.
- **Existing mitigation:** Sealed objects are application/octet-stream
- **Gap:** No explicit responseDisposition=attachment.
- **Residual risk:** Low (sealed objects).
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P3 (defense-in-depth)

### T-AZ-01 — Cross-tenant avatar read (profile-photo BOLA)
- **Category / framework:** STRIDE:InformationDisclosure / LINDDUN:Linkability / OWASP-API1:BOLA / ASVS-V4
- **Component / evidence:** `Cloud Storage avatars/{userId}/profile.jpg`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Any authenticated uid issues signed/direct read for arbitrary userId
- **Existing mitigation:** auth required; comment marks accepted risk
- **Gap:** No per-owner read scope (storage.rules:19)
- **Residual risk:** All users' profile photos enumerable and correlatable to UIDs
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P3 (defense-in-depth)

### T-AZ-02 — Shared-artifact write into another tenant's workspace path
- **Category / framework:** STRIDE:Tampering / OWASP-API1:BOLA + API3:BOPLA / ASVS-V4
- **Component / evidence:** `workspaces/{workspaceId}/teams/{teamId}/artifacts/{id}`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** mallory writes ownerUserID=mallory doc under workspace-alice/...
- **Existing mitigation:** Read gated on ownerUserID==auth.uid; no active client writer found
- **Gap:** sharedArtifactOwnerWrite (firestore.rules:1073-1080) never binds workspaceId to a uid; zero rules-test coverage
- **Residual risk:** Namespace pollution/quota-grief in another tenant path; latent if future read keys off path
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P3 (defense-in-depth)

### T-AZ-07 — Operator custom-claim (burnbarOperator) trust breadth
- **Category / framework:** STRIDE:ElevationOfPrivilege / OWASP-API5:BFLA
- **Component / evidence:** `isOperator() firestore.rules:38-40 gating ops/* metrics`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Misissued burnbarOperator claim reads ops budget/metrics/events across all tenants
- **Existing mitigation:** Claim server-minted; only ops aggregate collections gated (not user content)
- **Gap:** No code in scope proves claim-issuance custody
- **Residual risk:** Scoped to ops telemetry, not user-private data; issuance path UNKNOWN
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P3 (defense-in-depth)

### T-CRY-03 — Anti-replay high-water-mark stored in a deletable plaintext file
- **Category / framework:** STRIDE:Tampering (anti-replay state)
- **Component / evidence:** `HermesRelayReplayCache`
- **Actor:** Network attacker / malicious or compromised relay | **Asset:** Relay & gateway message payloads | **Data flow:** Phone<->Cloud<->Mac sealed relay/gateway
- **Preconditions:** On-path network position or control of a relay/gateway lane
- **Attack path:** Delete .../HermesRelay/authenticated-request-replay-cache.json (HermesRelaySenderTrustResolver.swift:151-158) -> maxCounter resets to -1 and requestID set clears -> prior authenticated frames (counter <= old max) replay until counter advances.
- **Existing mitigation:** Counter is AAD-bound (frame must be a real prior frame, not forgeable); TTL prunes requestIDs; local-only file requires Mac FS access.
- **Gap:** No tamper-evidence/monotonic anchor outside the file.
- **Residual risk:** Bounded local replay after filesystem compromise (matches CURE53 T-GW-3).
- **Detection:** Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing) | **Owner:** Crypto/Core (OpenBurnBarCore) | **Priority:** P3 (defense-in-depth)

### T-CRY-05 — KCI / static-key compromise reads and forges on the affected link (accepted)
- **Category / framework:** STRIDE:Spoofing/Information disclosure
- **Component / evidence:** `HermesRelayCrypto`
- **Actor:** Network attacker / malicious or compromised relay | **Asset:** Relay & gateway message payloads | **Data flow:** Phone<->Cloud<->Mac sealed relay/gateway
- **Preconditions:** On-path network position or control of a relay/gateway lane
- **Attack path:** Compromise of a recipient static relay key (HPKE Auth shares this bound) decrypts to that recipient and enables peer impersonation toward it.
- **Existing mitigation:** Documented non-goal (HermesRelayCrypto.swift:13-19); keys in Keychain; not exploitable under relay-only model.
- **Gap:** By design no double-ratchet/PQXDH (explicitly banned in header).
- **Residual risk:** Accepted; consistent with stated threat model.
- **Detection:** Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing) | **Owner:** Crypto/Core (OpenBurnBarCore) | **Priority:** P3 (defense-in-depth)

### T-CVS-06 — Legacy v1 AAD/no-AAD open path weakens domain separation
- **Category / framework:** STRIDE:Tampering
- **Component / evidence:** `CloudVaultCrypto open path`
- **Actor:** Compromised unlocked endpoint / curious cloud operator | **Asset:** CloudVault at-rest content; vault & identity private keys | **Data flow:** Client<->Firestore client-sealed sync
- **Preconditions:** Read access to Firestore ciphertext, OR code running as the app on an unlocked device
- **Attack path:** v1-schema envelope opens under no-AAD branch (CloudVaultCrypto.swift:605-606) / legacy v1 AAD accepted (1094-1102), sidestepping path binding
- **Existing mitigation:** Still requires correct vault key (confidentiality intact); v1 is migration legacy
- **Gap:** No enforced cutover removing v1 acceptance
- **Residual risk:** Weakened relocation binding for legacy docs only
- **Detection:** Firestore read audit; at-rest open-failure metrics; key-access logs (endpoint side) | **Owner:** Crypto/Core + Mobile | **Priority:** P3 (defense-in-depth)

### T-DMN-06 — HID root-bridge peer trusted by code-signature alone (no UID anchor)
- **Category / framework:** STRIDE:Spoofing
- **Component / evidence:** `PrivilegedInputExecutionSocketServer.swift:231 validateSocketPeer (uid==0 branch)`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** A root process forging first-party identity could drive locked-screen input; requires root + Apple-anchored first-party signature, which non-first-party root cannot satisfy.
- **Existing mitigation:** Full DR + CD-flag check on the root peer.
- **Gap:** Relies entirely on code-sig for root peers (acceptable; root already wins most games).
- **Residual risk:** Low
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P3 (defense-in-depth)

### T-DMN-07 — Audit token read via private KVC selector on NSXPCConnection (SPI fragility)
- **Category / framework:** STRIDE:Spoofing
- **Component / evidence:** `PrivilegedInputXPCPeerValidator.swift:25 openBurnBarPeerAuditToken`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** Private auditToken selector (Dev-ID only); if Apple removes it, validator returns nil and fails closed (auditTokenUnavailable).
- **Existing mitigation:** Fail-closed on nil; LOCAL_PEERTOKEN socket path is the robust primary.
- **Gap:** SPI dependency in the XPC path only.
- **Residual risk:** Low
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P3 (defense-in-depth)

### T-GW-01 — HTTP gateway edge has no App Check; auth is bearer+PoP only
- **Category / framework:** STRIDE:Spoofing / Agentic:tool-auth
- **Component / evidence:** `burnBarHermesGateway onRequest (callables/hermesGateway.ts:1818)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Stolen bearer token replayed from any client; but every authenticated request also needs a fresh Ed25519 PoP signed by the pinned pairing private key (:845), so token alone is useless.
- **Existing mitigation:** Mandatory PoP :693; per-bearer rate limit :1119
- **Gap:** No device attestation on the HTTP edge (accepted: agents/phones are non-Firebase clients)
- **Residual risk:** Requires theft of BOTH bearer and Ed25519 signing key — acceptable
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P3 (defense-in-depth)

### T-GW-02 — PoP body-hash binding covers only JSON body, not raw/multipart or headers
- **Category / framework:** STRIDE:Tampering
- **Component / evidence:** `gatewayRequestBodyHash (callables/hermesGateway.ts:604)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Non-JSON body hashes to the empty-object string; if a handler consumed raw bytes, PoP would not cover them.
- **Existing mitigation:** All write handlers read requestBody() (JSON) only; attachment bytes go to Storage with sha256 finalize gate :507
- **Gap:** No explicit reject of non-JSON content-type on signed routes
- **Residual risk:** Low; revisit if a raw-body signed route is added
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P3 (defense-in-depth)

### T-GW-03 — Path/body swap under same nonce within 5-min window
- **Category / framework:** STRIDE:Tampering / replay
- **Component / evidence:** `verifyGatewayRequestPoP (callables/hermesGateway.ts:758)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Reuse a captured nonce with a modified method/path/body.
- **Existing mitigation:** Signature covers method/path/bodyHash :755 so a swapped request fails signature before nonce is even consumed; nonce single-use :764
- **Gap:** None material
- **Residual risk:** None material
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P3 (defense-in-depth)

### T-GW-05 — Events list filters targetClientId in app code, not Firestore where-clause
- **Category / framework:** LINDDUN:Disclosure (same-tenant) / availability
- **Component / evidence:** `handleEvents (callables/hermesGateway.ts:1100-1106)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Query is uid-scoped (tenant-safe) but client targeting is filtered post-fetch; a query-shape regression could surface same-user other-client targeted events.
- **Existing mitigation:** Owner-scoped query; nextCursor over scanned docs prevents re-read; targetClientId filter :1105
- **Gap:** Relies on app-layer filter rather than rules/where-constraint
- **Residual risk:** Low — same tenant only, never cross-account
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P3 (defense-in-depth)

### T-IOS-06 — App Group is a confused-deputy surface between app and extensions
- **Category / framework:** Tampering / Spoofing (MASVS-PLATFORM-1 IPC)
- **Component / evidence:** `TextExpansionInbox.swift:42-71, KeyboardViewController.swift:76-95`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Keyboard writes snippets to shared snapshot+inbox; app drains and cloud-syncs; a compromised/replaced extension or App-Group-entitled sibling could plant snippets the app later trusts and uploads; Darwin notification unauthenticated
- **Existing mitigation:** Snippet validation in makeSnippet; dedup by id
- **Gap:** No integrity/authenticity check on App Group payloads
- **Residual risk:** Stored-text injection into outbound agent messages via auto-synced snippets
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P3 (defense-in-depth)

### T-IOS-07 — Deep-link/URL-scheme handler routes attacker-influenced params
- **Category / framework:** Tampering / Spoofing (MASVS-PLATFORM-2 deep links)
- **Component / evidence:** `OpenBurnBarMobileApp.swift:137-208`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** burnbar:// scheme unverified (no Universal-Link verification); any app/page can invoke burnbar://assistants?... to drive navigation/stash thread/trigger ShowAgentWatch; threadId unsanitized into Firestore-scoped view
- **Existing mitigation:** Prompts ignored on public path; pairing-code origin-restricted; host switch allow-listed
- **Gap:** Custom scheme not cryptographically attributable to a caller
- **Residual risk:** Phishing/UI-redress and forced navigation; impact bounded to social engineering
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P3 (defense-in-depth)

### T-IOS-08 — Keyboard Open Access expands attack surface
- **Category / framework:** Information Disclosure / Spoofing (MASVS-PLATFORM-1)
- **Component / evidence:** `OpenBurnBarKeyboard/Info.plist:31-32 (RequestsOpenAccess=true)`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Open Access grants App Group + potential network; no network code today but a poisoned build could exfiltrate keystrokes once Full Access granted (classic iOS keylogger risk)
- **Existing mitigation:** No network egress in current code; no input persistence
- **Gap:** Open Access requested broadly; no App-Group-only justification gating
- **Residual risk:** Latent keylogger surface if a malicious update ships; current build benign
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P3 (defense-in-depth)

### T-IOS-11 — Launch-time protection sweep is bounded and may miss files
- **Category / framework:** Information Disclosure (MASVS-STORAGE-1)
- **Component / evidence:** `MobileDataProtectionBootstrap.swift:4,41-46`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** Recursive sweep stops after 2000 items; large Caches/Documents tree leaves later items at default; third-party SDK caches (Firestore persistence) may land outside the swept intent
- **Existing mitigation:** Entitlement floor applies to app container; chat self-protected
- **Gap:** Sweep best-effort and capped; Firestore local-cache protection class not asserted
- **Residual risk:** Marginal; residual is backup-exclusion gaps and App-Group SDK files
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P3 (defense-in-depth)

### T-PRV-06 — Agent-notification events retain provider identity + thread graph with no TTL
- **Category / framework:** LINDDUN Linking + Disclosure + Non-compliance; data minimization
- **Component / evidence:** `functions/src/agentNotifications.ts:300-321,494-505`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** Each reply writes users/{uid}/agent_notification_events with runtime/providerLabel/title/threadId/messageId/sourcePath revealing which agent answered + reply cadence; FCM data carries runtime+deep_link to Google; covered by account-erase but never expires
- **Existing mitigation:** Generic preview; covered by account-erase tree
- **Gap:** No TTL; provider label in title/FCM is a usage-fingerprint leak
- **Residual risk:** Low/Medium; provider-usage fingerprint + reply timing
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P3 (defense-in-depth)

### T-PRV-07 — Non-repudiation gap / push-token correlation across providers
- **Category / framework:** LINDDUN Non-repudiation + Linking
- **Component / evidence:** `functions/src/voipPush.ts:79-104, agentNotifications.ts:551-562`
- **Actor:** Push/analytics sub-processor (Apple/Google/Sentry) or curious operator | **Asset:** Metadata, push tokens, call graph, logs, crash reports | **Data flow:** Cloud<->APNs/FCM/Sentry/search-index
- **Preconditions:** Access to push payloads / crash SaaS / Firestore metadata / query logs
- **Attack path:** Stable pairedDeviceId/connection_id/push tokens flow to APNs+FCM and stored in queue docs; a processor with cross-service visibility (or BurnBar) links a device across sessions and ties call events to a user; queue timestamps prove a call was attempted
- **Existing mitigation:** Tokens rotate on reinstall; per-user scoping
- **Gap:** Identifiers long-lived; no rotation of connectionId correlator
- **Residual risk:** Low
- **Detection:** DLP on push payloads; Sentry event review; log-field audit; search-index access logs | **Owner:** Backend (Privacy) | **Priority:** P3 (defense-in-depth)

### T-PTR-05 — TOFU first-pairing window on controller key when gate force-disabled
- **Category / framework:** STRIDE:Spoofing; T-TR
- **Component / evidence:** `ControllerKeyPinStore`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** First-ever controller key pinned unconfirmed (ControllerKeyPinStore.swift:199-212). If ControllerKeyPinEnforcementFlag is overridden off via UserDefaults (:94), a relay-supplied key is silently trusted on first contact.
- **Existing mitigation:** Gate default ON requires operator safety-code confirmation before admission (PinResult.admits :139-148); mismatch on an established pin always refused.
- **Gap:** Secure default can be flipped off by a UserDefaults/MDM override.
- **Residual risk:** First-contact key poisoning only when the secure-default gate is overridden off.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P3 (defense-in-depth)

### T-PTR-06 — Client-writable cloud_vault_key_wrappers lacks generation-monotonicity / rotation-job binding in rules
- **Category / framework:** STRIDE:Tampering/Elevation
- **Component / evidence:** `firestore.rules cloud_vault_key_wrappers`
- **Actor:** Malicious cloud/admin or social-engineering pairer | **Asset:** Device trust graph, pairing records, vault wraps | **Data flow:** Device pairing & trusted-device promotion
- **Preconditions:** Firestore write (admin) or victim approving a pending device / first-pairing TOFU window
- **Attack path:** Stolen-session owner writes extra wrappers; rule (firestore.rules:2230-2253) only requires trusted target+source and current vaultKeyID match, not origin from rotateCloudVaultKey nor advancing vaultGeneration.
- **Existing mitigation:** Rotation-path wrappers are Admin-SDK-written out-of-band; wrapper writes bounded by matchesCurrentVaultKey and trusted-device existence.
- **Gap:** No binding to a rotation job / generation advance at the rules layer.
- **Residual risk:** Limited — cannot elevate trust; bounded by current-key match.
- **Detection:** high_risk_action_nonces, escrow approval audit events; pairing-record write audit | **Owner:** Identity/Pairing | **Priority:** P3 (defense-in-depth)

### T-SC-05 — xcframework lacks rebuild-parity gate
- **Category / framework:** STRIDE:Tampering / SSDF PW.4 / SLSA
- **Component / evidence:** `iroh-xcframework.yml:63-79`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** If Vendor/OpenBurnBarIroh.xcframework ever became committed, a tampered binary would not be diff-checked unlike the AAR.
- **Existing mitigation:** Currently gitignored/built-fresh in release (git check-ignore=IGNORED).
- **Gap:** Asymmetric control vs AAR; no guard if vendoring policy changes.
- **Residual risk:** Low
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P3 (defense-in-depth)

### T-SC-07 — firebase.json predeploy runs arbitrary npm build with deploy creds
- **Category / framework:** STRIDE:Tampering / SSDF PW.6
- **Component / evidence:** `firebase.json:5-7,30-32,309`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Malicious build/verify script or compromised devDependency executes in the GCP-authenticated deploy job.
- **Existing mitigation:** Deploy from signed tag only; npm ci from committed lockfile; least-priv token.
- **Gap:** Build runs with deploy credentials present in env.
- **Residual risk:** Low
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P3 (defense-in-depth)

### T-SC-09 — workflow_run runs in trusted context off external workflow success
- **Category / framework:** STRIDE:Elevation / SSDF PO.3
- **Component / evidence:** `supply-chain-provenance.yml:11-14,23-25,48-54`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** workflow_run job gets repo secrets + id-token/attestations:write; gated only on conclusion==success && head_branch starts v.
- **Existing mitigation:** Regenerates SBOM from source, does not execute downloaded artifacts; tag-prefix guard.
- **Gap:** Tag-prefix gate is weak but acceptable given no artifact execution.
- **Residual risk:** Low
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P3 (defense-in-depth)

### T-SC-10 — Agentic droid exec --skip-permissions-unsafe in CI
- **Category / framework:** Agentic:tool-permission-bypass / SSDF PW.6
- **Component / evidence:** `droid-wiki-refresh.yml:34-37`
- **Actor:** Supply-chain attacker, malicious PR, or insider operator | **Asset:** Build/release artifacts, CI secrets, deploy credentials | **Data flow:** Repo<->CI<->prod deploy / artifact registry
- **Preconditions:** Ability to land a PR, compromise an action/dep, or operator access
- **Attack path:** Autonomous agent runs unattended with skipped tool-permission prompts on push-to-main.
- **Existing mitigation:** No write token (default read perms), continue-on-error, refuses installers :24-25.
- **Gap:** No explicit top-level permissions block on this workflow.
- **Residual risk:** Low
- **Detection:** CI run logs; action-pin/diff gates; provenance/SBOM gate; CODEOWNERS review | **Owner:** CI/CD | **Priority:** P3 (defense-in-depth)

### T-TOOL-08 — Path-based deny rules (/admin,/billing) use heuristic window-title regex
- **Category / framework:** STRIDE Tampering / scope bypass
- **Component / evidence:** `ComputerUseDenyRegistry builtInRules`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** Rules at :165-177 rely on the URL path appearing in the window title; SPA routes or titles omitting the path evade them.
- **Existing mitigation:** file://, loopback, metadata, OAuth denies are urlPrefix-based and robust
- **Gap:** Path denies are heuristic
- **Residual risk:** Low
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P3 (defense-in-depth)

### T-TOOL-09 — Local grantDesktopControl bypasses the signed apply() admission path
- **Category / framework:** STRIDE Elevation (local)
- **Component / evidence:** `ChatSessionController.grantDesktopControl`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** grantDesktopControl (:358-380) builds and activates a grant directly, skipping AgentCapabilityGrantStore.apply() checks.
- **Existing mitigation:** Only reachable from local Mac UI (ChatPanelHeader.swift:387) which first calls DesktopGrantLocalAuthenticator.authenticateIfNeeded (fail-closed, throws)
- **Gap:** No defense-in-depth inside grantDesktopControl itself; relies on caller to local-auth
- **Residual risk:** Low — local operator is the trust root
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P3 (defense-in-depth)

### T-TOOL-10 — shell_run sandbox permits general reads outside the curated deny list
- **Category / framework:** STRIDE Information Disclosure
- **Component / evidence:** `OpenAICompatibleChatGatewayClient.restrictedShellSandboxProfile`
- **Actor:** Prompt-injection adversary or malicious CLI agent runtime | **Asset:** Local shell, filesystem, granted agent capabilities | **Data flow:** Agent<->Tools / CLI subprocess
- **Preconditions:** An active grant (esp. workspace_write/shell/YOLO/Trusted) on the session
- **Attack path:** (allow default) (:723) after targeted (deny file-read*) means sensitive files not in the hand-curated list (:672-698) remain readable by a prompt-injected shell_run.
- **Existing mitigation:** (deny network*) limits exfil; secret stores + app state explicitly denied
- **Gap:** Deny-list rather than allow-list for reads
- **Residual risk:** Low
- **Detection:** ComputerUse audit chain; CLI process registry; grant/approval audit events | **Owner:** AgentLens (CLIBridge/ComputerUse) | **Priority:** P3 (defense-in-depth)

### T-TRN-07 — Production E2E transport on iroh 1.0.0-rc.0 release candidate
- **Category / framework:** STRIDE:Tampering/supply-chain
- **Component / evidence:** `openburnbar-iroh Cargo deps`
- **Actor:** Malicious cloud/admin or relay operator | **Asset:** iroh control channel; transport metadata (NodeIds, IPs, timing) | **Data flow:** Device<->Device iroh / relay / Firestore fallback
- **Preconditions:** Control of the Firestore pairing directory / relay, OR network position
- **Attack path:** Pre-GA iroh/iroh-services pinned to =1.0.0-rc.0 (Cargo.toml:20-29) may carry unpatched QUIC/relay/crypto bugs
- **Existing mitigation:** exact-version pins prevent silent drift; dependabot present
- **Gap:** shipping production E2E transport on a release candidate, not a stable line
- **Residual risk:** latent upstream iroh protocol/crypto bug not yet found/fixed
- **Detection:** iroh_fallback_to_wss / fallback-rate audit events; pairing-key change audit | **Owner:** Transport (iroh) | **Priority:** P3 (defense-in-depth)

## Info (8)

### T-ATT-07 — Legacy content-type denylist incomplete and largely dead
- **Category / framework:** STRIDE Tampering; CWE-183/434
- **Component / evidence:** `assertSafeAttachmentContentType:200-215`
- **Actor:** Malicious paired peer or attachment uploader | **Asset:** Attachment/media bytes; receiver disk/quota; parsers | **Data flow:** Attachment upload/download + Mercury media transfer
- **Preconditions:** A paired peer or an authenticated upload session
- **Attack path:** Denylist (not allowlist) misses types; sealed path forces octet-stream so list applies only to disabled legacy write path.
- **Existing mitigation:** Sealed-only writes
- **Gap:** Defense-in-depth uses denylist.
- **Residual risk:** Minimal while legacy writes disabled.
- **Detection:** Storage finalize size/hash mismatch logs; media budget/kill metrics; quarantine xattr (missing on Mercury) | **Owner:** Backend + Media | **Priority:** P4 (doc/assumption)

### T-AZ-08 — Unauthenticated public HTTP endpoints
- **Category / framework:** STRIDE:InformationDisclosure / OWASP-API2
- **Component / evidence:** `routerRundown.ts:1125 latestRouterRundown; health.ts:47 healthLive`
- **Actor:** Malicious authenticated user or rogue admin (Admin SDK) | **Asset:** Firestore/Storage objects across tenants; trust roots | **Data flow:** Client<->Firestore/Storage
- **Preconditions:** Valid Firebase session + App Check, OR Admin/IAM access
- **Attack path:** Anonymous GET
- **Existing mitigation:** Intentional public pricing/health data; maxInstances cap is only throttle
- **Gap:** No per-IP rate limit
- **Residual risk:** Cost/DoS only; no tenant data exposed (payload scope verified public)
- **Detection:** Firestore rules-deny metrics; Cloud Audit Logs; Admin SDK access logs | **Owner:** Backend (Functions/Rules) | **Priority:** P4 (doc/assumption)

### T-CRY-04 — Pinned public-key equality is non-constant-time
- **Category / framework:** STRIDE:Spoofing (key confusion)
- **Component / evidence:** `HermesRelayAuthenticatedRequestOpener`
- **Actor:** Network attacker / malicious or compromised relay | **Asset:** Relay & gateway message payloads | **Data flow:** Phone<->Cloud<->Mac sealed relay/gateway
- **Preconditions:** On-path network position or control of a relay/gateway lane
- **Attack path:** samePublicKey decodes base64 and uses Data == (HermesRelayAuthenticatedRequest.swift:309-315).
- **Existing mitigation:** Compared values are PUBLIC keys, not secrets; AEAD tag is the real auth gate.
- **Gap:** None material.
- **Residual risk:** Negligible; recorded for completeness, not a real finding.
- **Detection:** Relay version telemetry; HPKE open-failure metrics; downgrade-rate alarm (missing) | **Owner:** Crypto/Core (OpenBurnBarCore) | **Priority:** P4 (doc/assumption)

### T-DMN-08 — HPKE AEAD AAD intentionally empty (context binding via HPKE info only)
- **Category / framework:** STRIDE:Tampering
- **Component / evidence:** `RemoteUnlockCredentialEnvelopeCrypto.swift:5`
- **Actor:** Same-user malware or a compromised signed first-party app | **Asset:** Local system control, HID, credentials, daemon RPC | **Data flow:** App<->Daemon unix socket / privileged HID socket
- **Preconditions:** Code execution as the login user OR compromise of a signed first-party binary
- **Attack path:** AEAD associated data fixed empty for Android Tink interop; context relies on HPKE info key-schedule binding + Ed25519 authority hash over ciphertext+info.
- **Existing mitigation:** info mismatch rejected pre-decrypt (:103); authority signature covers both fields.
- **Gap:** None material — info is bound into the HPKE key schedule.
- **Residual risk:** Low
- **Detection:** Daemon peer-auth rejections; ComputerUse audit hash-chain; launchd/binary integrity | **Owner:** Daemon/Core | **Priority:** P4 (doc/assumption)

### T-GW-04 — Entitlement read fired detached before client-doc validation
- **Category / framework:** STRIDE:DoS (wasted read)
- **Component / evidence:** `resolveGatewayGrant (callables/hermesGateway.ts:823)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Token index pointing at a uid triggers an entitlement read even when the client is later found revoked.
- **Existing mitigation:** Revocation still 401s at :829; entitlement result awaited at :857
- **Gap:** Minor wasted Firestore read on revoked tokens
- **Residual risk:** Negligible; no security impact
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P4 (doc/assumption)

### T-GW-06 — Stale-token index deletion is best-effort/racy
- **Category / framework:** STRIDE:Spoofing / availability
- **Component / evidence:** `resolveGatewayGrant (callables/hermesGateway.ts:831-836)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Concurrent rotation could leave a dangling token_index entry briefly.
- **Existing mitigation:** client-doc tokenHash check :831 is authoritative; stale index never authorizes
- **Gap:** None
- **Residual risk:** None
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P4 (doc/assumption)

### T-GW-07 — Non-constant-time tokenHash !== comparison
- **Category / framework:** STRIDE:Information disclosure (timing)
- **Component / evidence:** `resolveGatewayGrant (callables/hermesGateway.ts:831)`
- **Actor:** Compromised relay, token+PoP-key thief, or malicious agent | **Asset:** Gateway messages/events/attachments + routing metadata | **Data flow:** Phone<->Hermes Gateway<->Mac
- **Preconditions:** Stolen bearer AND PoP private key, OR control of the gateway store
- **Attack path:** Plain string !== on sha256 hex; theoretically a timing oracle.
- **Existing mitigation:** Index lookup already keyed on attacker-known hash; both sides are sha256 hex; not a token-recovery vector
- **Gap:** Cosmetic — could use timingSafeEqual
- **Residual risk:** None material
- **Detection:** Gateway PoP-nonce txn writes; replay-ledger; sealed-write rejection logs | **Owner:** Backend (Functions) | **Priority:** P4 (doc/assumption)

### T-IOS-10 — No jailbreak/runtime-integrity assumption stated or enforced
- **Category / framework:** Tampering (MASVS-RESILIENCE-1)
- **Component / evidence:** `(absence) no jailbreak/integrity checks in OpenBurnBarMobile/`
- **Actor:** Thief with unlocked phone, malicious sibling app, or backup extractor | **Asset:** iOS local data, vault/escrow keys, pasteboard, push payloads | **Data flow:** iOS app<->Keychain/AppGroup/APNs
- **Preconditions:** Physical access to an unlocked device, a malicious co-resident app, or a device backup
- **Attack path:** On a jailbroken device Keychain ACLs and file protection can be bypassed; all keys/data become reachable
- **Existing mitigation:** None on-device (App Attest is server-side anti-fraud)
- **Gap:** No jailbreak detection/anti-tamper; assumption undocumented
- **Residual risk:** Determined attacker with jailbroken target gets full local access (accepted-risk class)
- **Detection:** n/a on-device (no jailbreak detection); MDM/backup posture; APNs payload review | **Owner:** Mobile-iOS | **Priority:** P4 (doc/assumption)
