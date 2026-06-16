# Security Definition

## B.1 What the Product Does

OpenBurnBar is a cross-platform AI agent observability and control platform with five core subsystems:

### Token/Cost Tracking
The app parses local session logs from AI coding agents (Claude Code at `~/.claude/projects/`, Codex at `~/.codex/sessions/`, Factory Droid, Grok at `~/.grok/sessions/`, etc.) on macOS/iOS/Android. It computes token usage and cost using public pricing lists. The daemon maintains a SQLCipher-encrypted local search index. Users see real-time spend in a menu bar popover.

### CloudVault (E2E Encrypted Sync)
When enabled, session content is encrypted on-device with AES-256-GCM using a vault key stored in macOS Keychain (`WhenUnlockedThisDeviceOnly`). The vault key never leaves trusted devices. Firestore stores only ciphertext manifests; Cloud Storage stores encrypted blobs. Search is enabled via keyed HMAC hashes (server cannot reverse). Key rotation is client-driven with server-enforced monotonic generation; revocation requires survivor-side rotation and rewrap.

### Computer Use (Phases 8-13)
AI agents can control a Mac through Virtual HID injection. The system has:
- Three trust modes: Manual (every action gated), Step (burst approval <=10 actions/30s), Trusted (scope-matched actions auto-dispatch)
- A SHA-256-linked audit chain with Ed25519-signed terminal head
- Three+ independent panic-kill paths (hotkey, auth gate, remote kill switch, AX revocation, phone gesture)
- Budget caps (normal: 50 actions/run, $5/day; hard cap: $2500/mo triggers halt)
- Capability tokens (Ed25519-signed, escrow-bound, single-use nonce)
- Phone-side control with replay-protected authority envelopes

### Hermes Communication
Real-time messaging, media transfer, screen-share, and 1:1 calls via iroh P2P (QUIC) with Firestore fallback. Devices pair via escrow trust chain (Ed25519 signatures). Key-change pinning prevents MITM after first contact. First-contact safety-number confirmation exists but is not default-on.

### Payments
Pro/Pro Max/Ultra subscriptions via Stripe (checkout sessions + webhook), Apple App Store (StoreKit 2 + server notifications), and Google Play Billing. Webhook signatures verified; entitlement binding is callable-gated.

## B.2 Definition of Secure

### For Users
- Their session content is never readable by the server or third parties (CloudVault E2E encryption)
- Only their authenticated devices can access their data (Firebase Auth + ownership checks + Firestore rules)
- Agent actions require explicit approval in manual mode (Computer Use capability gate)
- The audit chain provides tamper-evident accountability for agent actions
- Account deletion removes all their data (Firestore subtree + root queues + Storage + Auth + KMS secrets)
- Security-sensitive claims are backed by implementation and tests

### For the Product
- Every callable endpoint verifies authentication and ownership (BOLA tested, CI-enforced)
- High-risk operations require nonce + device proof (App Check attestation binding)
- Crypto uses AEAD with path-bound AAD (conversations, mobile_assistant_chats, session_logs)
- Audit chain is tamper-evident with signed terminal head
- Three+ independent panic-kill paths reach the HID boundary
- Supply chain uses SHA-pinned Actions with SBOM + SLSA attestations + cosign signing
- No secrets committed; triple secret scanning at pre-commit and release

### For the Business
- Enterprise claims are defensible (object-level authorization is tested with runtime cross-user proofs)
- Audit scope is clear (Firestore rules + callable endpoints + crypto + Computer Use + supply chain)
- Incident response is documented (runbooks, telemetry, panic-halt, kill switch)
- Supply-chain risk is managed (SHA-pinned Actions, SBOM, SLSA, dependency review, triple scanning)
- Payment integrity is enforced (webhook signatures, entitlement binding, idempotent processing)

## B.3 Security Goals

1. Protect confidentiality of user session content (CloudVault E2E encryption with path-bound AAD)
2. Protect integrity of Computer Use actions (audit chain, capability tokens, kill switch)
3. Prevent cross-tenant data access (ownership checks on every callable, BOLA tested)
4. Prevent unauthorized agent actions (trust modes, approval gates, budget caps, kill switch)
5. Prevent unauthorized device elevation (escrow trust chain, App Check attestation, nonce proofs)
6. Minimize sensitive data in logs/analytics (Sentry scrubbers, UID redaction, push payload minimization)
7. Secure release pipeline (code signing, notarization, SBOM, SLSA attestations, live feed verification)
8. Support incident response (audit logs, telemetry, panic-halt, Remote Config kill switch)

## B.4 Non-Goals

- Does not protect plaintext on a fully compromised endpoint
- Does not provide anonymity (Firebase Auth UID used for routing)
- Does not prevent screenshots or shoulder surfing
- Does not provide formal cryptographic verification (no mathematical proof)
- Does not guarantee E2EE for iroh first-contact (safety-number compare not default-on)
- Does not guarantee protection from malicious model behavior
- Does not prevent same-user local attacks (filesystem compromise assumed out of scope for most flows)
- Does not verify CLI executable signatures by default (design tradeoff for npm/bun agent CLIs)
- Does not enforce Firestore rule-level App Check (console-only App Check on Firestore product)
- Does not provide multi-region availability (single us-central1 accepted risk pre-launch)
