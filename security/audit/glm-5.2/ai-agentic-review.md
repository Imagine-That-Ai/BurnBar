# AI, LLM, and Agentic Security Review

## L.1 AI Component Inventory

### Component: Local Index Oracle (ChatSessionController)
- **Purpose:** User asks questions about their local indexed data; system retrieves relevant chunks and sends to CLI agent
- **Model/Provider:** User-selected CLI agent (codex, claude) or Hermes webapi (localhost:8642)
- **Data sent:** System prompt with retrieved context (session snippets, token usage), user question
- **Tools available:** None directly (CLI agent has its own tools)
- **Memory:** Per-conversation (Hermes mode), stateless per-turn (CLI mode)
- **External content sources:** User's local index (session logs, skill docs)
- **Autonomy level:** Level 0 (read/display) + Level 1 (suggest action, no execution)
- **Evidence:** `ChatSessionController.swift`, `ContextBuilder.buildDatabaseAnalystSystemPrompt`

### Component: Computer Use Agent Controller
- **Purpose:** AI agent drives the Mac via Virtual HID (keystrokes, mouse, shortcuts)
- **Model/Provider:** External AI agent (Claude, Codex, etc.) via Hermes relay
- **Data sent:** Screen content, action requests
- **Tools available:** Virtual HID (keyboard, mouse, shortcuts), credential input, clipboard
- **Autonomy level:** Variable (Manual=Level 2, Step=Level 3, Trusted=Level 4 for scoped actions)
- **Evidence:** `ComputerUseCapabilityGate.swift`, `ComputerUseSessionCoordinator.swift`

## L.2 Autonomy Classification

| Trust Mode | Classification | Description |
|------------|---------------|-------------|
| Manual | Level 2 | Every action requires explicit approval before execution |
| Step | Level 3 | Burst approval covers <=10 actions in <=30s window |
| Trusted | Level 4 | Scope-matched actions auto-dispatch; out-of-scope falls back to manual |
| Level 5 | NOT USED | No autonomous high-impact action without per-action approval |

**Key invariant:** Level 5 (autonomous high-impact) does not exist in this system. The highest autonomy is Level 4, which requires pre-defined scope rules.

## L.3 Tool Capability Matrix

| Tool | Side Effects | Data Access | Approval Required | Policy Check | Reversibility | Evidence |
|------|-------------|-------------|-------------------|-------------|---------------|----------|
| Virtual HID (keyboard) | Keystrokes | Screen content | Manual: every action; Trusted: scope-matched only | `ComputerUseCapabilityGate.check()` | Low (keystrokes are hard to undo) | `VirtualHIDKeyboardEngine.swift` |
| Virtual HID (mouse) | Mouse events | Screen position | Same as keyboard | Same gate | Low | `MacActionDispatcher.swift` |
| Credential input | Password entry | Keychain credential | Always (even in Trusted mode) | `typeCredential` requires explicit capability token | N/A | `PrivilegedInputDispatchHandler.swift` |
| Clipboard | Clipboard read/write | Clipboard content | Manual mode only | Capability gate | Low | `RemoteClipboardController.swift` |

## L.4 Agentic Threats Evaluation

### Prompt Injection
- **Local index oracle (M-015 fix):** Retrieved snippets are now framed as "untrusted evidence" in the system prompt. Instruction-looking lines are redacted. The prompt framing change is the real protection; the denylist is defense-in-depth only (trivially bypassable via leetspeak/paraphrase).
- **Computer Use:** Agent receives screen content and action requests through the Hermes relay (encrypted). Screen content could contain injected instructions, but the capability gate is deterministic and does not parse natural language.
- **Residual:** Indirect prompt injection via indexed content could influence the local oracle's responses, but cannot trigger Computer Use actions.

### Tool Misuse / Excessive Agency
- **Mitigated:** The capability gate is a deterministic decision tree (kill switch -> entitlement -> concurrency -> caps -> budget -> deny regions -> scope rules). No LLM is in the enforcement path.
- **Budget caps:** Hard cap at $2500/mo triggers session halt + kill switch activation.
- **Action cap:** 50 actions/run (normal), 200/day.

### Agent Identity
- **Phone control authority:** Ed25519-signed envelopes with monotonic counter + freshness window + canonical-JSON re-hash. Controller key pinned to account, refuses relay/Firestore key swaps.
- **Capability tokens:** Ed25519-signed, bound to escrow device + attestation hash + scope hash + action allowlist + budget.
- **Gap (FINDING-002):** Local-auth-proof verifier is nil in production. If a first-party signed process is compromised, fabricated computer-use grants could reach the daemon without independent phone-proof re-verification.

### Memory Poisoning / Context Poisoning
- **Session log search:** Keyed HMAC hashes prevent server-side poisoning. Client-side index could be poisoned by malicious content in agent logs, but this is same-user same-boundary.
- **RAG poisoning:** The local oracle treats indexed snippets as untrusted evidence (M-015 fix).

### Kill Switch
- **Three+ independent paths** (hotkey, auth gate, remote kill switch, AX revocation, phone gesture)
- **Gap (FINDING-001):** Watchdog socket can be disarmed by root attacker
- **Gap (FINDING-002):** Local-auth-proof dormant means the phone-proof layer is not enforcing

### Data Leakage to Model Providers
- **Local CLI mode:** User's data is sent to their own configured AI provider via their own API key. This is intentional and user-controlled.
- **Hermes mode:** Data sent to localhost:8642 (user's own Hermes instance). No data leaves the device to a third-party model provider through this path.

## L.5 Required Agentic Controls Checklist

| Control | Status | Evidence |
|---------|--------|----------|
| Deterministic policy engine for tool calls | **YES** | `ComputerUseCapabilityGate.check()` — pure decision tree, no LLM |
| Least-privilege tool permissions | **YES** | Action allowlist per scope; deny regions beat everything |
| Explicit approval for high-impact actions | **YES** (with caveat) | Manual mode gates every action; FINDING-002: local-auth-proof dormant |
| Structured tool schemas | **YES** | `ComputerUseActionKind` enum, `CapabilityToken` structured fields |
| Input validation | **YES** | `VirtualHIDBridgeCapabilityGate.validate()` multi-factor gate |
| Output validation | **YES** | Audit entry reserved before action; result recorded |
| Memory write controls | **N/A** | Agent does not write to persistent memory through this system |
| Memory provenance | **N/A** | Session logs have device/timestamp provenance |
| Context isolation | **YES** | Snippets framed as untrusted evidence (M-015) |
| Source attribution for retrieved content | **YES** | Citation chips in editorial UI |
| Short-lived credentials | **YES** | Capability tokens have TTL; nonce single-use |
| Per-action authorization | **YES** | Every HID dispatch checks kill switch + capability token |
| Network/file sandboxing | **PARTIAL** | Agent CLI runs as user process (not sandboxed); HID is root-privileged but gated |
| Tamper-evident audit logs | **YES** | SHA-256 chain + Ed25519-signed head |
| User-visible action history | **YES** | Audit chain panel in session UI |
| Kill switch | **YES** (with FINDING-001 caveat) | File-existence flag checked at two layers |
| Rate limits | **YES** | Action caps + budget caps |
| Adversarial prompt-injection tests | **PARTIAL** | M-015 framing test; no systematic adversarial test suite |
