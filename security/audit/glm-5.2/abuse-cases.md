# Abuse Cases and Attack Trees

## ABUSE-001: Kill Switch Disarm + HID Compromise Chain

### Narrative
An attacker obtains root on the Mac through a separate vulnerability (e.g., a kernel exploit or a compromised sudo). They connect to the kill-switch watchdog socket and send `{"action":"clear"}` to disarm the panic-halt safety layer. If they also have a path to inject HID commands (e.g., through a compromised first-party signed process), they can continue driving the Mac even after the user triggers a panic on their phone.

### Attack Tree
```
Goal: Continue agent actions after user panic
├── Obtain root on Mac [HARD]
│   ├── Kernel exploit
│   ├── Compromised sudo/helper
│   └── Physical access + single-user mode
├── Disarm kill switch [EASY once root]
│   └── Connect to /var/run/openburnbar-killswitch-watch.sock
│       └── Send {"action":"clear"} [NO AUTH REQUIRED]
└── Inject HID commands [HARD]
    ├── Compromise first-party signed process
    ├── Forge capability token [VERY HARD - Ed25519]
    └── Bypass peer codesig gate [VERY HARD]
```

### Controls
- File permissions 0600 root (limits to root-only)
- Three other independent panic paths (hotkey, auth gate, remote kill switch, AX revocation)
- HID dispatch requires capability token + peer codesig

### Gaps
- FINDING-001: No peer auth on watchdog socket
- FINDING-002: Local-auth-proof dormant (weakened defense-in-depth)

### Detection
- Watchdog stderr log on socket accept (not centralized)
- Audit chain records all HID actions (but kill switch disarm is not audited)

## ABUSE-002: Phone Trust Mode Elevation

### Narrative
A user's phone is stolen or compromised. The attacker opens the Computer Use control sheet on the phone and taps "Trusted" mode. The UI presents all three modes without filtering. `downgradeTrustMode(.trusted)` is called, elevating the session from Manual/Step to Trusted. The attacker's agent can now auto-dispatch scope-matched actions without per-action approval.

### Attack Tree
```
Goal: Elevate trust mode from phone
├── Obtain phone access [MEDIUM]
│   ├── Physical theft
│   └── Remote compromise
├── Open PhoneControlOptionSheet [EASY]
├── Tap "Trusted" [EASY - no filter]
│   └── onTrustMode(.trusted) called [NO DIRECTION CHECK]
└── Agent auto-dispatches scope-matched actions
    └── Still limited by scope rules + budget caps
```

### Controls
- Capability gate still enforces scope rules in Trusted mode
- Budget caps (50 actions/run, $5/day, hard cap $2500/mo)
- Audit chain records all actions

### Gaps
- FINDING-003: UI does not filter to downgrade-only

## ABUSE-003: Cross-Tenant Data Access

### Narrative
Authenticated user Alice tries to read user Bob's session data. She calls `searchEncryptedConversationIndex` with Bob's uid as the target.

### Attack Tree
```
Goal: Read Bob's data
├── Call callable with Bob's uid [BLOCKED]
│   └── assertOwnership(request, "bob-uid") throws PERMISSION_DENIED
├── Query Firestore directly [BLOCKED]
│   └── ownsUserNamespace("bob-uid") returns false in rules
└── Forge Auth token [VERY HARD]
    └── Firebase Auth token signing key compromise
```

### Controls
- `assertOwnership` on every callable
- Firestore `ownsUserNamespace` rules
- 21 BOLA test files with victim-tenant seeding

### Gaps
- None identified

## ABUSE-004: CloudVault Ciphertext Relocation

### Narrative
User writes a sealed payload to `chat_threads/{threadA}`, then copies the exact same `sealedPayload` to `chat_threads/{threadB}`. Because `chat_threads` uses global AAD (not path-bound), the ciphertext opens under both document paths. This could enable a confusion attack where content intended for one thread is presented in another context.

### Attack Tree
```
Goal: Relocate ciphertext across documents
├── Write sealed payload to chat_threads/{A} [ALLOWED]
├── Copy sealedPayload to chat_threads/{B} [ALLOWED - global AAD]
│   └── validSealedPayloadForUser passes (same vault key)
└── Open under different context
    └── Limited: same-user, same-vault-key boundary
```

### Controls
- Same vault key required
- Same-user boundary

### Gaps
- FINDING-008: `chat_threads` and `cli_sessions` use global AAD

## ABUSE-005: Payment Webhook Forgery

### Narrative
Attacker tries to forge a Stripe webhook to grant themselves Pro entitlement.

### Attack Tree
```
Goal: Forge payment webhook
├── Send POST to webhook endpoint [BLOCKED]
│   └── constructEvent fails: missing/invalid signature
├── Replay old webhook [BLOCKED]
│   └── reserveStripeWebhookEvent: already processed (10-min lease)
├── Compromise Stripe signing secret [VERY HARD]
│   └── Stored in GitHub Actions secret / Secret Manager
└── Forge entitlement directly [BLOCKED]
    └── Firestore rules require server-side write or callable auth
```

### Controls
- Stripe webhook signature verification
- Idempotent processing with Firestore transaction lease
- Entitlement docs callable-gated

### Gaps
- None identified

## ABUSE-006: Prompt Injection via Indexed Content

### Narrative
Malicious content is ingested into the local search index (e.g., a crafted agent session log). When the user asks the local oracle a question, the malicious content is retrieved and injected into the prompt, attempting to override the oracle's instructions.

### Attack Tree
```
Goal: Inject instructions via indexed content
├── Poison local index [REQUIRES LOCAL ACCESS]
│   └── Write malicious content to session log
├── Oracle retrieves poisoned chunk [POSSIBLE]
├── Inject instructions into prompt [PARTIALLY MITIGATED]
│   ├── Snippets framed as "untrusted evidence" [M-015 fix]
│   └── Instruction-looking lines redacted [denylist - bypassable]
└── Oracle follows injected instructions [LOW IMPACT]
    └── Oracle has no tool execution; read-only
```

### Controls
- M-015 framing change (snippets as untrusted evidence)
- Instruction-line denylist (defense-in-depth, bypassable)
- Oracle is read-only (no tool execution)

### Gaps
- Denylist is trivially bypassable (leetspeak, paraphrase, `<<SYS>>`)
- No systematic adversarial test suite
