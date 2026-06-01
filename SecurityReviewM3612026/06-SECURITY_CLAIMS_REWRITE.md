# BurnBar / OpenBurnBar Security Claims — Precise, Non-Misleading Language (Second-Opinion Edition)
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) second-opinion edition
**Cross-reference:** Prior Grok 4.3 review at `security-review-2026-06-01/SECURITY_CLAIMS_REWRITE.md`. This version adds Iroh-specific and AI-agent-specific guidance and aligns with the SOTA framework citations in `08-SOTA_GAP_ANALYSIS.md`.
**Principle:** Never use absolute language ("impossible," "unhackable," "fully secure," "end-to-end encrypted for everything," "we can't see anything"). Prefer precise, scoped claims that match the actual architecture, evidence, and residual risks. Every claim must be traceable to code/docs.

## Specific overclaim patterns to eliminate

| Overclaim pattern | Why it's wrong | Replace with |
|---|---|---|
| "End-to-end encrypted, we can't read it" | True for payload content; **false for relay metadata** (NodeIds, connection patterns, timing, volumes per Iroh official docs). | "Payload content is end-to-end encrypted between your devices. Relays (including our hosted fallbacks) cannot decrypt content but do observe metadata as documented at iroh.computer." |
| "Only your own paired devices can see your data" | True **if** the paired device itself is uncompromised + post-pairing app-layer authz is enforced + revocation propagates promptly. | "Data access is gated by paired-device status, device-trust state, and application-layer permissions (escrow trust + scope + grant). Compromised paired devices remain a residual risk; revocation propagates within [N] seconds." |
| "Tamper-proof record of every action" | Strong (BLAKE3 hash chain + signed head + OTS) **but** completeness requires exported artifacts + verifier + max-index; not automatic. | "Every Computer Use action is recorded in a tamper-evident hash chain with a signed session head and optional OpenTimestamps anchor. Completeness can be independently verified using the exported artifacts and a verifier." |
| "Quantum-safe" or "military-grade" | No product is "quantum-safe" today; no industry-grade definition of "military-grade." | Avoid entirely. |
| "Self-hosted = private" | Self-hosted reduces OpenBurnBar's visibility but you still trust the OS, your own network, and your own operational hygiene. | "Self-hosted / CLI-only deployments have a reduced OpenBurnBar-surface attack profile. You still need to maintain OS permissions, network security, and software updates." |
| "AI agent is safe" | LLMs follow instructions; prompt injection is a known class of attack. | "We apply [LLMSafeContent / untrusted-content wrappers / explicit confirmation gates / OWASP LLM 2025 mitigations] to reduce the impact of indirect prompt injection. Residual risk remains and we operate a continuous red-team program." |
| "Passkeys / FIDO2" | Not currently used. (See auth-authz.md.) | Do not claim passkey support until implemented. |
| "Hermes Gateway is encrypted" | True at the QUIC/E2EE layer between endpoints; the gateway HTTP/SSE/attachment surface has its own bespoke auth that is **separate from** end-to-end encryption. | "The Hermes Gateway uses a custom bearer-token model with scope checks, rate limits, and short TTLs. It is not the same as the Iroh end-to-end encryption path." |

## Recommended precise wording (use or adapt directly)

### Core product / local-first
- "OpenBurnBar is local-first. Usage data, session logs, and control state are canonical in local SQLite (GRDB, optional SQLCipher) and the daemon-owned support directory on your Mac. Cloud features (Firestore replication, hosted search, remote MCP, quota refresh) are strictly opt-in and never replace local state."
- "The macOS app reads AI agent session logs from your disk. It does not read your provider API keys for local tracking. Provider credentials for optional hosted features are stored in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) or Google Cloud Secret Manager and are used only when you explicitly enable the feature."
- "Remote control and screen sharing require explicit user consent on the Mac, per-session trust modes (default Manual), scope and deny rules with built-in protections, and multiple independent kill switches (global hotkey ⌃⌥⌘., phone gesture, lock screen, Remote Config)."

### Iroh / networking / cross-device (cite Iroh docs)
- "Cross-device features (Mercury screen sharing, Floo file/clipboard, Hermes realtime relay, Computer Use) use Iroh for peer-to-peer connectivity with QUIC and end-to-end encryption between endpoints. Relays assist NAT traversal and provide an encrypted transport fallback when direct connections are not possible. **Relays cannot decrypt payload contents but do observe metadata such as endpoint identities (NodeIds), connection patterns, timing, and data volumes** — see iroh.computer for the official model."
- "Device pairing uses short-lived codes verified server-side with App Check, authentication, and entitlement checks, followed by signed Iroh pairing records. **Possession of a post-pairing Iroh NodeId or connection does not by itself grant application-layer permissions**; explicit grants, escrow trust, and scope rules still apply for screen sharing and control actions."
- "Browser clients may use relayed Iroh traffic. The payload remains encrypted end-to-end between your devices, but relay metadata exposure and associated bandwidth costs differ from direct P2P connections."

### Remote control / Computer Use / privileged input (highest-risk surface)
- "Remote control and agent-driven computer use require explicit per-session or per-action approval on the Mac (or via trusted paired phone with biometric confirmation for higher tiers). Trust modes are per-session and default to Manual. Scope rules and built-in deny lists (login prompts, password fields, keychain access, etc.) take precedence."
- "All privileged input synthesis (keyboard, mouse, accessibility) on macOS is gated by macOS TCC permissions (Accessibility, Screen Recording), code-signature validation on privileged sockets, capability tokens (signed, single-use, short-TTL, domain-tagged, scope-hashed), per-action or burst approval, scope and deny rules, budgets, and multiple independent kill switches. **A compromised but genuinely paired phone, or a first-party-signed malicious binary on the same Mac, remains a residual high-impact risk** — the same risks documented by NIST and CISA for the broader remote-desktop category."
- "Every privileged action in Computer Use sessions is recorded in a tamper-evident hash chain with parent linking. Signed session heads and optional OpenTimestamps proofs allow offline verification of integrity and completeness (given the exported artifacts and the max entry index)."

### Cloud / API / auth
- "Cloud synchronization and paid features require explicit sign-in (Google or Apple via Firebase) and are protected by App Check (enforced for Firestore in production console configuration and on callables), owner-scoped Firestore rules that reject plaintext secret field names, and server-side authorization on every sensitive action."
- "High-privilege operations (escrow device trust elevation, Remote MCP grants, certain computer-use proofs) require additional device attestation binding and active paid entitlements."
- "Signed upload URLs for encrypted session backups are short-lived and issued only after entitlement and path ownership checks. Post-upload verification enforces size, content type, and integrity before indexing."

### AI / agents / prompt injection (cite OWASP LLM 2025)
- "We treat log parsers, RAG retrievals, webpage extracts, screenshot OCR, MCP responses, and prior AI output as **untrusted content**. That content is wrapped with provenance tags and structurally separated from system and developer instructions, per OWASP LLM Top 10 2025 guidance. We do not claim prompt injection is impossible; we operate a red-team program to identify and remediate new vectors."
- "High-impact tool actions (shell, file modify outside scope, send message/email, spend, change account/security) require explicit confirmation or stronger policy, regardless of model output. The model is advisory, not authoritative, for these actions."

### Privacy / data
- "Chat message bodies and full session log content are never uploaded to OpenBurnBar servers unless you explicitly enable the relevant backup setting. When enabled, bodies are encrypted on-device before upload (AES-GCM); server-side indexes use only sealed metadata and keyed hashes. OpenBurnBar servers cannot decrypt the content without your device-held keys."
- "Relays and OpenBurnBar-operated infrastructure cannot read the contents of Iroh-protected streams or encrypted backups. They can observe metadata and incur bandwidth costs for relayed traffic."
- "Local database encryption (SQLCipher), when enabled, uses a key stored exclusively in the macOS Keychain with `WhenUnlockedThisDeviceOnly` protection. Loss of the Keychain item (device migration, reset, etc.) renders the encrypted database unrecoverable without an explicit user-created recovery bundle."

### Supply chain / release
- "Release artifacts for direct download are Developer ID signed and notarized. A subset of release artifacts include SLSA-style provenance attestations (cosign), SBOMs (SPDX), and OpenVEX sidecars generated in the release workflow. **Full coverage across all platforms and artifacts is targeted but not yet uniform** — see our public supply-chain status for the current matrix."
- "The macOS app runs without App Sandbox by design (to read agent logs from arbitrary locations and access Keychain/iCloud/daemon management). It is distributed via the Mac App Store (sandboxed build) and direct notarized downloads."

### General / limitations
- "Security is a product property, not a single feature. OpenBurnBar follows defense-in-depth (local-first state, explicit grants, code-sign on privileged paths, App Check + server-side authz, multiple kill switches, tamper-evident audit) but no system is immune to all attacks. Residual risks include same-user local malware, compromised paired devices, supply-chain compromise of signed binaries, and relay metadata exposure."
- "Self-hosted or CLI-only deployments have a reduced attack surface (no cloud callables or relays) but still require the user to maintain OS permissions, local network security, and software updates."

## Vulnerability disclosure / trust center drafts

### `SECURITY.md` draft (top-level)
```markdown
# Security at OpenBurnBar

We take the security of OpenBurnBar seriously. This page describes how to report
a vulnerability, what we commit to, and where to find the latest security and
privacy information.

## Supported versions
| Version | Supported |
|---|---|
| Latest 1.x release | Yes (full) |
| Previous 1.x minor | Critical fixes only, 90 days |
| Older | No |

## Reporting a vulnerability
- Email: security@openburnbar.com (PGP key below)
- We prefer coordinated disclosure. Please give us a reasonable window (90 days
  standard, faster for active exploitation) before public disclosure.
- We commit to acknowledging within 3 business days and providing a status
  update within 10 business days.

## What we commit to
- No legal action against good-faith research that follows this policy.
- Credit on the security acknowledgements page (unless you request otherwise).
- A dedicated security advisory and patch for confirmed issues.

## Out-of-scope
- Denial-of-service attacks against our hosted infrastructure.
- Social engineering of OpenBurnBar staff.
- Same-user local malware scenarios (inherent to single-user UNIX-socket IPC
  and documented in our threat model).

## See also
- [Threat model](docs/THREAT_MODEL.md)
- [Privileged input threat model](docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md)
- [LLM/GenAI threat model](docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md)
- [Supply chain provenance](docs/security/SUPPLY_CHAIN_PROVENANCE.md)
- [Prior security review (June 2026)](security-review-2026-06-01/) (provenance
  and methodology)
```

### `.well-known/security.txt` draft
```
Contact: mailto:security@openburnbar.com
Expires: 2027-06-01T00:00:00.000Z
Preferred-Languages: en
Canonical: https://openburnbar.com/.well-known/security.txt
Policy: https://github.com/openburnbar/openburnbar/blob/main/SECURITY.md
Acknowledgments: https://openburnbar.com/security/acknowledgements
```

### Trust center page outline

- **Overview** — security model summary (local-first, E2EE between devices, opt-in cloud)
- **Current posture** — grade + launch readiness (from `01-EXECUTIVE_SUMMARY.md`)
- **Threat models** — links to `docs/THREAT_MODEL.md` + `docs/security/*`
- **Pen test & red team** — most recent (with date, scope, vendor), public summary
- **Audit tools** — links to the Computer Use audit verifier + OTS proof verifier
- **SBOM & provenance** — links to release artifacts, cosign verification commands
- **Compliance** — current and in-progress (e.g., SOC 2 Type II roadmap, ISO 27001 roadmap)
- **Vulnerability disclosure** — link to SECURITY.md
- **Acknowledgements** — researcher credits
- **Changelog** — security-relevant changes per release

### Claim-tracking matrix (process)

For every public sentence on `burnbar.ai`, `README.md`, pricing, in-app onboarding, and docs:
1. Record the claim in `website/CLAIMS.md` with: surface, claim text, evidence pointer, owner, last verified date.
2. Re-verify before any major launch.
3. Update after every security-relevant change.

This matrix is the single source of truth for "what we said vs. what we built."

## What to do with this file

- Apply these wordings (or reviewed equivalents) to all public materials before any public launch.
- Replace any absolute or overly broad claim with a scoped version from this file.
- Add the public security transparency package (`SECURITY.md`, `.well-known/security.txt`, VDP, trust center) and link from website footer, README, pricing, and in-app Settings.
- Update `website/CLAIMS.md` after every security-relevant change.
- Re-audit before any major launch or marketing push.
