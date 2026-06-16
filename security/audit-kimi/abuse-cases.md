# Abuse Cases and Attack Trees

## AC-001 — Malicious Log File Injection

**Attacker:** Any process that can write to watched agent log directories.
**Goal:** Crash parser, exfiltrate data via RAG, or trigger harmful LLM/tool output.
**Steps:**

1. Write a malformed JSON/XML log with deeply nested objects or huge strings.
2. BurnBar daemon/parser ingests it.
3. If no size limits: memory exhaustion (DoS).
4. If parser succeeds: content enters `ContextBuilder` / chat / search.
5. If prompt wrapping missing: LLM is instructed to leak data or call tools.

**Controls:** Parser limits, delimiter wrappers, provenance, human approval for tools.
**Gaps:** FINDING-004, FINDING-017.

## AC-002 — Stolen Firebase Auth Token

**Attacker:** Phishes user's Firebase Auth token or extracts from backup.
**Goal:** Read/write user's Firestore data.
**Steps:**

1. Obtain token.
2. Call Firestore REST API with `Authorization: Bearer <token>`.
3. If App Check not enforced: rules allow owner-scoped reads/writes.
4. Read usage metadata, sealed blobs (useless without keys), device IDs.
5. Write malicious `session_logs` or delete data.

**Controls:** App Check, owner-scoped rules, input validation.
**Gaps:** FINDING-005, FINDING-011.

## AC-003 — Malicious VS Code Extension / MCP Client

**Attacker:** User installs a rogue MCP client or extension.
**Goal:** Exfiltrate local agent context or trigger Computer Use.
**Steps:**

1. Rogue client connects to daemon via UNIX socket (has token if same user).
2. Calls search or Computer Use methods.
3. If daemon lacks per-method auth: obtains sensitive snippets or executes input.
4. If local MCP has no human gate: silently exfiltrates context.

**Controls:** Daemon capability matrix, user approval, audit log.
**Gaps:** FINDING-007, FINDING-008.

## AC-004 — Computer Use Approval Bypass

**Attacker:** Malicious prompt or injected tool result tricks approval UI.
**Goal:** Perform unauthorized high-impact action (send email, transfer funds, install malware).
**Steps:**

1. Build prompt that frames harmful action as benign (e.g., "Click OK to dismiss system dialog").
2. Tool result or UI description hides true intent.
3. User approves in "Step" mode or "Trusted" mode auto-approves.
4. Daemon executes privileged input.

**Controls:** Clear action preview, kill switches, audit chain, per-tool tests.
**Gaps:** FINDING-003.

## AC-005 — Supply-Chain Trojan Update

**Attacker:** Compromises GitHub maintainer account or workflow.
**Goal:** Ship malicious update to all users.
**Steps:**

1. Modify workflow or commit malicious code.
2. CI signs and notarizes malicious binary.
3. Sparkle appcast serves update.
4. Users auto-install due to trusted signature.

**Controls:** Two-person rule, OIDC, reproducible builds, cosign.
**Gaps:** FINDING-010.

## AC-006 — Phone Cross-Pairing

**Attacker:** Obtains escrow QR/token or intercepts pairing flow.
**Goal:** Pair attacker's phone to user's Mac and control it.
**Steps:**

1. Scan or replay escrow token.
2. Establish iroh session.
3. If capability token not bound to session: send HID events.
4. User may not notice until harm occurs.

**Controls:** Short-lived tokens, passkey/escrow, session-bound capability tokens.
**Gaps:** FINDING-020.

## AC-007 — Cursor Connector Public URL Abuse

**Attacker:** Discovers or brute-forces Cloudflare quick tunnel URL/token.
**Goal:** Access local daemon from the internet.
**Steps:**

1. Find active tunnel URL (short TTL helps).
2. Present valid token if leaked.
3. Call daemon RPC methods remotely.

**Controls:** Short TTL, random token, origin checks, revocation.
**Gaps:** FINDING-009.

## AC-008 — Cloud Backup Metadata Profiling

**Attacker:** Gains access to Firestore backups or internal logs.
**Goal:** Build profile of user behavior without reading content.
**Steps:**

1. Access `usage_rollups` or `quota_snapshots`.
2. Correlate provider IDs, costs, timestamps, device IDs.
3. Infer projects, clients, work patterns.

**Controls:** Encrypt metadata with user key, minimize retention.
**Gaps:** FINDING-006.
