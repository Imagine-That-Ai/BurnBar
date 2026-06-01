# BurnBar / OpenBurnBar SOTA Security Review — Security Claims Rewrite (Precise, Non-Misleading Language)

**Date:** 2026-06-01
**Principle:** Never use absolute language ("impossible," "unhackable," "fully secure," "end-to-end encrypted for everything," "we can't see anything"). Prefer precise, scoped claims that match the actual architecture, evidence, and residual risks. All claims must be traceable to code/docs.

**Current examples of over- or imprecise claims (from website/CLAIMS.md + public copy reviewed):**
- "End-to-end encrypted, we can't read it" (for Floo/Mercury) — partially accurate for payload but omits relay metadata (nodeIDs, connection patterns, volumes, timing) and cost implications for browser-relayed traffic.
- "Only your own paired devices" — true post-escrow + grant, but the strength depends on phone compromise model, attestation binding, TTL, and revocation speed.
- "Nothing without your grant; grants are per task and expire" — directionally correct for most paths but requires qualification on in-process CGEvent path residuals and WS2 wiring status.
- "Tamper-proof record of every action" — strong (hash chain + signed head + OTS) but completeness proof requires the exported artifacts + verifier + max-index (offline, not automatic server proof).

## Recommended Precise Wording (use or adapt directly)

### Core Product / Local-First
- "OpenBurnBar is local-first. Usage data, session logs, and control state are canonical in local SQLite (GRDB, optional SQLCipher) and the daemon-owned support directory on your Mac. Cloud features (Firestore replication, hosted search, remote MCP, quota refresh) are strictly opt-in and never replace local state."
- "The macOS app and daemon read AI agent session logs from your disk. They do not read your provider API keys for local tracking. Provider credentials for optional hosted features are stored in the macOS Keychain (WhenUnlockedThisDeviceOnly) or Google Cloud Secret Manager and are only used when you explicitly enable the feature."
- "Remote control and screen sharing require explicit user consent on the Mac, per-session trust modes (default Manual), scope/deny rules with built-in protections, and multiple independent kill switches (global hotkey, phone gesture, lock screen, Remote Config). No silent activation is possible in the reviewed flows."

### Iroh / Networking / Cross-Device
- "Cross-device features (screen sharing, remote control, file transfer, calls) use Iroh for peer-to-peer connectivity with QUIC and end-to-end encryption between endpoints. Relays (including public or hosted fallbacks) assist NAT traversal and provide an encrypted transport fallback when direct connections are not possible. Relays cannot decrypt payload contents but can observe metadata such as endpoint identities (NodeIds), connection patterns, timing, and data volumes."
- "Device pairing uses short-lived codes verified server-side with App Check, authentication, and entitlement checks, followed by signed Iroh pairing records. Possession of a post-pairing Iroh NodeId or connection does not by itself grant application-layer permissions; explicit grants, escrow trust, and scope rules still apply for screen sharing and control actions."
- "Browser clients may use relayed Iroh traffic. The payload remains encrypted end-to-end between your devices, but relay metadata exposure and associated costs differ from direct P2P connections."

### Remote Control / Computer Use / Privileged Input (Highest-Risk Surface)
- "Remote control and agent-driven computer use require explicit per-session or per-action approval on the Mac (or via trusted paired phone with biometric confirmation for higher tiers). Trust modes are per-session and default to Manual. Scope rules and built-in deny lists (login prompts, password fields, keychain access, etc.) take precedence."
- "All privileged input synthesis (keyboard, mouse, accessibility) on macOS is gated by macOS TCC permissions (Accessibility, Screen Recording), code-signature validation on privileged sockets (post-2026-05-30 remediation), capability tokens, per-action or burst approval, scope/deny rules, budgets, and multiple independent kill switches. A compromised but genuinely paired phone or a signed malicious binary on the same Mac remains a residual high-impact risk."
- "Every privileged action in Computer Use sessions is recorded in a tamper-evident hash chain with parent linking. Signed session heads and optional OpenTimestamps proofs allow offline verification of integrity and completeness (given the exported artifacts and max entry index)."

### Cloud / API / Auth
- "Cloud synchronization and paid features require explicit sign-in (Google or Apple via Firebase) and are protected by App Check (enforced for Firestore in production console configuration and on callables), owner-scoped Firestore rules that reject plaintext secrets, and server-side authorization on every sensitive action."
- "High-privilege operations (escrow device trust elevation, Remote MCP grants, certain computer-use proofs) require additional device attestation binding and active paid entitlements."
- "Signed upload URLs for encrypted session backups are short-lived and issued only after entitlement and path ownership checks. Post-upload verification enforces size, content type, and integrity before indexing."

### Privacy / Data
- "Chat message bodies and full session log content are never uploaded to OpenBurnBar servers unless you explicitly enable the relevant backup setting. When enabled, bodies are encrypted on-device before upload (AES-GCM); server-side indexes use only sealed metadata and keyed hashes. OpenBurnBar servers cannot decrypt the content without your device-held keys."
- "Relays and OpenBurnBar-operated infrastructure cannot read the contents of Iroh-protected streams or encrypted backups. They can observe metadata and incur bandwidth costs for relayed traffic."
- "Local database encryption (SQLCipher), when enabled, uses a key stored exclusively in the macOS Keychain with WhenUnlockedThisDeviceOnly protection. Loss of the Keychain item (device migration, reset, etc.) renders the encrypted database unrecoverable without an explicit user-created recovery bundle."

### Supply Chain / Release
- "Release artifacts for direct download are Developer ID signed and notarized. A subset of release artifacts include SLSA-style provenance attestations (cosign), SBOMs (SPDX), and OpenVEX sidecars generated in the release workflow. Full coverage across all platforms and artifacts is targeted but not yet uniform."
- "The macOS app runs without App Sandbox by design (to read agent logs from arbitrary locations and access Keychain/iCloud/daemon management). It is distributed via the Mac App Store (sandboxed build) and direct notarized downloads."

### General / Limitations
- "Security is a product property, not a single feature. OpenBurnBar follows defense-in-depth (local-first state, explicit grants, code-sign on privileged paths, App Check + server-side authz, multiple kill switches, tamper-evident audit) but no system is immune to all attacks. Residual risks include same-user local malware, compromised paired devices, supply-chain compromise of signed binaries, and relay metadata exposure."
- "Self-hosted or CLI-only deployments have a reduced attack surface (no cloud callables or relays) but still require the user to maintain OS permissions, local network security, and software updates."

## Process Recommendation
- Map every public sentence on burnbar.ai, pricing, README, docs, and in-app copy to a specific source (as website/CLAIMS.md already begins to do).
- Replace any absolute or overly broad claim with one of the scoped versions above (or equivalent reviewed by the security owner).
- Add a "Security & Privacy" or "Trust" page that links to the VDP, this review's artifacts (once sanitized), current threat model summary, audit export/verifier tools, and known residual risks.
- Update the claims matrix (website/CLAIMS.md) after every security-relevant change.

**This rewrite avoids misleading users while still highlighting genuine strengths** (local-first, explicit consent model, Iroh E2EE, strong cloud authz layers, active remediation of the highest-risk surface, anchored audit proofs).

Use this language (or reviewed equivalents) in all future public materials. Re-audit before any major launch or marketing push.
