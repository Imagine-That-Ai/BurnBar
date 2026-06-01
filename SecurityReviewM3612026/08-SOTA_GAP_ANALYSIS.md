# BurnBar / OpenBurnBar SOTA Security Review — Gap Analysis vs. Frameworks
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) second-opinion edition
**Status:** Provisional — specialist subagents in flight. The matrix below is seeded with primary-source-cited expectations; per-requirement depth arrives after specialists return.
**Cross-reference:** See `security-review-2026-06-01/SOTA_GAP_ANALYSIS.md` (Grok 4.3 edition) for the prior version.

## Sources (primary, cited inline)

- **NIST SSDF v1.1** — SP 800-218 (Feb 2022). [csrc.nist.gov](https://csrc.nist.gov/publications/detail/sp/800-218/final)
- **OWASP ASVS 5.0.0** — May 2025, ~350 requirements, 17 chapters. [asvs.dev](https://asvs.dev/v5.0.0/) · [GitHub](https://github.com/OWASP/ASVS)
- **OWASP API Security Top 10 2023.** [owasp.org](https://owasp.org/API-Security/editions/2023/en/0x11-t10/)
- **OWASP LLM Top 10 2025** — released Nov 2024; next major version expected 2026. [owasp.org](https://owasp.org/www-project-top-10-for-large-language-model-applications/) · [PDF](https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf) · [GenAI Security Project](https://genai.owasp.org/)
- **MITRE ATLAS** — Adversarial Threat Landscape for AI Systems. [atlas.mitre.org](https://atlas.mitre.org/)
- **CISA Secure by Design (2023)** + **Secure by Demand: Choosing a Secure by Design Product**. [cisa.gov SbD](https://www.cisa.gov/resources-tools/resources/secure-demand-choosing-secure-design-product)
- **SLSA v1.1** — current; v1.2 in draft. [slsa.dev v1.1](https://slsa.dev/spec/v1.1/) · [levels](https://slsa.dev/spec/v1.1/levels) · [requirements](https://slsa.dev/spec/v1.1/requirements)
- **NIST SP 800-53 r5.1** — federal control catalog. [OSCAL](https://csrc.nist.gov/CSRC/media/Projects/risk-management/800-53%20Downloads/800-53r5/SP_800-53_v5_1-derived-OSCAL.pdf)
- **Iroh official docs** (n0 project). [iroh.computer](https://iroh.computer/) · [docs.rs/iroh](https://docs.rs/iroh)
- **SentinelOne 2026 remote access best practices.** [sentinelone.com](https://www.sentinelone.com/cybersecurity-101/identity-security/remote-access-security-best-practices/)
- **ScreenMeet 2026 Zero Trust help desk guide** (ConnectWise CVE-2024-1709, BeyondTrust Treasury, TeamViewer APT29 incidents). [screenmeet.com](https://www.screenmeet.com/blog/ciso-guide-building-a-zero-trust-framework)

## 1. NIST SSDF v1.1 (SP 800-218)

| Practice | BurnBar status | Gap | Source of evidence |
|---|---|---|---|
| **PO.1** Define security requirements for software development | Strong | None material | `docs/THREAT_MODEL.md` + `docs/security/*` + `plans/2026-05-30-sota-security-remediation.md` |
| **PO.2** Define roles and responsibilities | Medium | No RACI for security review / red-team cadence | Internal org chart, not in repo |
| **PO.3** Implement supporting toolchains | Strong | None material | `scripts/ci/verify-*.sh`, fast-feedback workflow, Sentry, OpenTimestamps |
| **PO.4** Define and use security metrics | Medium | Vulnerability aging / SLA not formalized | `docs/TECH_DEBT_METRICS.md` exists; security metrics partial |
| **PO.5** Implement and maintain secure environments | Strong | None material | Hardened runtime, library validation, signing identities |
| **PS.1** Protect all forms of code from unauthorized access | Strong | None material | Branch protection, code owners, OIDC signing |
| **PS.2** Provide a mechanism for verifying software release integrity | Strong (release lane) | Not uniform across all artifacts (extensions, crates, MCP shims) | `.github/workflows/release.yml`, `supply-chain-provenance.yml` |
| **PS.3** Archive and protect each software release | Strong | Bit-reproducible notarized builds **explicitly de-scoped** (with rationale) | `docs/security/SUPPLY_CHAIN_PROVENANCE.md:52-69` |
| **PW.1** Design software to meet security requirements | Strong | None material | Threat models + formal invariants in Computer Use |
| **PW.2** Review the software design | Strong | None material | `plans/2026-05-30-sota-security-remediation.md` + arch review |
| **PW.3** Reuse existing, well-secured software | Strong | None material | Firebase, Iroh, GRDB, Playwright (pinned) |
| **PW.4** Write secure code | Medium | 68 empty `catch {}` + 745 `try?` debt (V2-1 in May plan) | `docs/TECH_DEBT_METRICS.md` |
| **PW.5** Configure compilation and build | Strong | None material | Hardened runtime, library validation, code-sign |
| **PW.6** Configure compilation, interpreter, or build process | Strong | None material | Same as PW.5 |
| **PW.7** Review and analyze human-written code | Strong | None material | PR review workflow, CodeQL, Sentry auto-capture |
| **PW.8** Test executable code | Strong | None material | `scripts/test-*.sh`, invariant harness, kill drills |
| **RV.1** Identify and confirm vulnerabilities | Strong | Public VDP missing | Internal remediation plan excellent; external channel missing |
| **RV.2** Assess, prioritize, and remediate vulnerabilities | Strong | None material | Severity-normalized register + fix roadmap |
| **RV.3** Analyze root cause of vulnerabilities | Strong | None material | Subagent traces + primary source evidence |

**Material gaps vs. SSDF:** PO.2 (RACI), PO.4 (security metrics), RV.1 (public VDP).

## 2. OWASP ASVS 5.0 (May 2025) — 17 chapters, ~350 requirements

### V1 Encoding & Sanitization / V2 Validation & Business Logic
- **Status:** Strong on input validation (bounded trim, hex/sealed parsers throwing `HttpsError` everywhere). Bounded parsers and `assertUserStoragePath` ownership checks.
- **Gap:** Business-logic race conditions on pairing/escrow/grant flows (V11 = "Business Logic" coverage in the standard; we map pairing completeness into this chapter).
- **Evidence:** `functions/src/shared.ts`, `guards.ts`, all callable files.

### V3 Web Frontend Security
- **Status:** N/A — this is a desktop/mobile product with a separate website. Website (`website/`) needs separate review.
- **Gap:** Cookies/headers/SRI/CSP on the public website not in this review's scope; flag for follow-up.

### V4 API & Web Service
- **Status:** Strong on callable authz (Web/API subagent matrix in prior review). Bespoke Hermes Gateway is the outlier.
- **Gap:** REST/GraphQL/WebSocket authz for the gateway subpaths (custom bearer, scopes, SSE, attachments).

### V5 File Handling
- **Status:** Strong — signed uploads with post-verify, `assertUserStoragePath` ownership, size limits.
- **Gap:** None material.

### V6 Authentication
- **Status:** Firebase Auth (Google + Apple Sign-In), App Check, high-risk wrappers.
- **Gap:** **V6.5 MFA** — no passkeys / no MFA found. CISA SbDemand explicitly calls out phishing-resistant MFA as a default expectation. (Prior review Finding M-?; flagged in `auth-authz.md`.)
- **Gap:** V6.4 recovery — account recovery / escrow device bootstrap "first device" path. (`docs/THREAT_MODEL.md:233-238` documents the bootstrap; verify it is gated by strong proof, not just a UI checkbox.)
- **Gap:** V6.7 cryptographic — Apple/Google Sign-In nonce handling. Re-verify.

### V7 Session Management
- **Status:** Firebase sessions (managed by SDK). Refresh tokens handled by SDK.
- **Gap:** V7.4 explicit session termination on critical actions. Verify in callable layer.
- **Gap:** V7.5 session abuse defenses on long-lived Hermes Gateway bearer tokens. (Prior review Finding H3.)

### V8 Authorization
- **Status:** Strong — owner-scoped Firestore rules, escrow trusted-state checks on every grant/controller path, no client-controlled elevation.
- **Gap:** V8 function-level negative testing is sparse (the 10 specific neg cases from the prior Auth subagent must be implemented and gated in CI). (Prior review Finding.)

### V9 Self-Contained Tokens
- **Status:** CapabilityToken is COSE/CBOR-style with Ed25519 signature. (Verify in `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/CapabilityToken*.swift`.)
- **Gap:** None material, assuming single-use nonce ledger is implemented.

### V10 OAuth & OIDC
- **Status:** Uses Firebase SDK. Remote MCP uses OAuth.
- **Gap:** Verify PKCE on Remote MCP OAuth flow. (See `functions/src/remoteMcpOAuth.ts` — flag in auth-authz.md.)

### V11 Cryptography
- **Status:** Ed25519 (phone control), P-256 + AES-GCM (escrow envelopes), BLAKE3 (audit chain), SHA-256 (digests).
- **Gap:** Verify key rotation cadence for escrow public keys. (`docs/THREAT_MODEL.md:248-250` — key versioning supports rotation; verify rotation is actually exercised.)
- **Gap:** Verify no deprecated algorithms (MD5, SHA-1) in any code path. Spot-check.

### V12 Secure Communication
- **Status:** Firebase TLS by default. Hermes Gateway uses HTTPS. Iroh uses QUIC + E2EE.
- **Gap:** Verify certificate pinning on mobile clients where appropriate. (See clients.md for details.)

### V13 Configuration
- **Status:** `verify-resilience-wiring.sh`, `verify-ops-readiness.sh`, hardened runtime.
- **Gap:** OpenAPI drift (prior review Finding).

### V14 Data Protection
- **Status:** Strong — opt-in cloud, opt-in SQLCipher, opt-in sealed hosted search, opt-in Hermes Gateway. (`docs/THREAT_MODEL.md`)
- **Gap:** Verify deletion/export flow actually purges orphan docs in cloud search index and escrow envelopes. (See privacy-data.md.)

### V15 Secure Coding & Architecture
- **Status:** Strong architecture. (See 02-ARCHITECTURE_THREAT_MODEL.md.)
- **Gap:** 68 empty `catch {}` + 745 `try?` debt (PW.4 / V15).

### V16 Security Logging & Error Handling
- **Status:** Sentry auto-capture on callables, structured audit chain.
- **Gap:** Log redaction — verify Sentry `beforeSend` and Cloud Logging filters never emit tickets/tokens/secrets/screenshots/full prompts. (See blue-team.md.)

### V17 WebRTC
- **Status:** Iroh uses QUIC; not strictly WebRTC. SSE is used in Hermes Gateway.
- **Gap:** Auth on SSE cursors / pagination. (Prior review Finding H3.)

## 3. OWASP API Security Top 10 (2023)

| ID | Risk | BurnBar status | Evidence |
|---|---|---|---|
| API1 | Broken Object Level Authorization | Strong | Owner-scoped rules; no BOLA found in Web/API subagent. Verify Hermes Gateway. |
| API2 | Broken Authentication | Strong | Firebase Auth + App Check + high-risk wrappers. |
| API3 | Broken Object Property Level Authorization | Strong | Plaintext secret denylist + no client-elevation. |
| API4 | Unrestricted Resource Consumption | **Weak** | Sparse rate limiting (prior Finding H2). |
| API5 | Broken Function Level Authorization | **Medium** | `approveHermesGatewayDeviceGrant` uses weaker auth tier than peer high-risk paths. (Prior Finding C2.) |
| API6 | Unrestricted Access to Sensitive Business Flows | **Medium** | Pairing, escrow, grant flows are gated; verify race conditions. |
| API7 | Server Side Request Forgery | Strong | Resilience wiring + bounded URL allowlist. |
| API8 | Security Misconfiguration | **Medium** | OpenAPI drift (prior Finding H1), possible tier-inconsistency on Hermes Gateway. |
| API9 | Improper Inventory Management | **Medium** | OpenAPI incomplete vs. actual callables + gateway subpaths. |
| API10 | Unsafe Consumption of APIs | Strong | Bounded parsers + resilience wiring. |

## 4. OWASP LLM Top 10 2025 (per [owasp.org](https://owasp.org/www-project-top-10-for-large-language-model-applications/))

| ID | Risk | BurnBar status | Notes |
|---|---|---|---|
| LLM01 | Prompt Injection | **High risk surface** | Log parsers, webpages, screenshots, MCP responses, RAG chunks, hosted JSON. Mitigations in-flight (LLMSafeContent wrappers, PromptInjectionHardeningTests.swift) — verify universal coverage. (Prior Finding C4.) |
| LLM02 | Sensitive Information Disclosure | Strong | Local-first canonical state; opt-in cloud; PII scrubbing in logging/Sentry. |
| LLM03 | Supply Chain (models + tools) | **Medium** | Playwright bridge pinned; verify any hosted LLM fallback model IDs. |
| LLM04 | Data and Model Poisoning | **Medium** | Memory/RAG poisoning risk; verify isolation. |
| LLM05 | Improper Output Handling | **Medium** | Tool broker should not auto-execute model output. Verify. |
| LLM06 | Excessive Agency | **High risk surface** | Mandatory confirmation for high-impact `BurnBarToolKind.computerUse*`; verify universal. (Prior Finding C4 follow-up.) |
| LLM07 | System Prompt Leakage | Strong | System prompt not exposed to user; verify no debug endpoint. |
| LLM08 | Vector and Embedding Weaknesses | **Medium** | Local HNSW index + persistent vector index. Verify cross-user isolation. |
| LLM09 | Misinformation | Strong | Audit chain + grounding in ContextBuilder. |
| LLM10 | Unbounded Consumption | **Medium** | Budget cap, Remote Config kill switch, hourly eval. Verify exhaustion path. |

**Cross-reference:** [MITRE ATLAS](https://atlas.mitre.org/) techniques (50+ as of 2026) — map any concrete exploit chains in the red-team report to ATLAS IDs.

## 5. CISA Secure by Design (2023) + Secure by Demand (2024)

| Principle | BurnBar status | Gap |
|---|---|---|
| Take ownership of customer security outcomes | Strong | Post-P0 sockets, WS2 tokens, audit chain, multiple kills. |
| Embrace radical transparency | **Medium** | Missing public VDP / security.txt / trust center. |
| Lead from the top | Strong | May 2026 remediation plan is leadership-level. |
| Phishing-resistant auth by default (SbDemand) | **Gap** | No passkeys / no MFA. |
| Default secure (SbDemand) | Strong | Local-first defaults; opt-in for cloud. |
| Secure by design (SbD) | Strong | Threat models, formal invariants, defense-in-depth. |

## 6. SLSA v1.1 (current; v1.2 in draft)

| Track | Level | BurnBar status | Gap |
|---|---|---|---|
| Source | L3 | Strong (two-party review, branch protection). | — |
| Build | L3 target; current ~L1-2 for DMG/ZIP, partial for others | `.github/workflows/release.yml` uses GitHub-hosted runners with `id-token: write` + `attestations: write` for cosign. Hardened build platform (L3) is GitHub-hosted, which qualifies if ephemeral isolation is confirmed. | Confirm ephemeral environment + secret-material isolation (no user-defined step accesses signing keys). SLSA L3 needs explicit confirmation. |
| Provenance | L2 (signed) | cosign keyless via OIDC. | Verify completeness of `externalParameters` + dependency resolution. |
| Artifacts | L2-3 | DMG/ZIP attested; AAR/APK partial; extensions/crates/MCP shims unverified. | Uniform coverage across all platforms. |
| Reproducible builds | De-scoped for notarized | Documented in `docs/security/SUPPLY_CHAIN_PROVENANCE.md:52-69`. | Apple-specific; acceptable per industry practice. |

**Cross-reference:** [SLSA v1.1 levels](https://slsa.dev/spec/v1.1/levels) — Build L3 requires: (a) builds on a hosted build platform that meets L3, (b) secrets used to sign provenance not accessible to user-defined build steps, (c) builds cannot influence one another, (d) ephemeral environment, (e) no cache poisoning. GitHub-hosted runners with `permissions: id-token: write` + OIDC cosign satisfy most of (a)-(c) by design; verify (d) and (e) on the actual workflow.

## 7. OpenSSF Scorecard

| Check | BurnBar status | Gap |
|---|---|---|
| Binary-Artifacts | Partial | Extensions and MCP shims not scored. |
| Branch-Protection | Strong | Main + release branches protected. |
| CI-Tests | Strong | fast-feedback + full build + ops confidence. |
| CII-Best-Practices | Unknown | Not in repo as badge. |
| Code-Review | Strong | PR review workflow. |
| Contributors | Strong | Multi-contributor, multi-org. |
| Dangerous-Workflow | **Medium** | Verify unpinned Actions / broad `permissions`. (See supply-chain.md.) |
| Dependency-Update-Tool | Strong | Dependabot / similar. |
| Fuzzing | **Medium** | Some harnesses; verify Computer Use fuzzing corpus. |
| License | Strong | Apache 2.0 (verify in LICENSE). |
| Pinned-Dependencies | **Medium** | Verify lockfile pin + GitHub Actions SHA pin. |
| SAST | Strong | CodeQL. |
| Security-Policy | **Gap** | No top-level `SECURITY.md`. |
| Signed-Releases | Strong | cosign. |
| Token-Permissions | **Medium** | Verify least privilege on all workflows. |
| Vulnerabilities | Strong | OSV/CodeQL/Sentry auto-capture. |

**OpenSSF Scorecard target:** ≥7.0 across the public repo for credibility with security-conscious enterprise buyers.

## 8. Iroh-specific secure implementation expectations (per Iroh official docs)

| Expectation | BurnBar status | Gap |
|---|---|---|
| E2EE between endpoints | Strong | HermesRelayCrypto. |
| Relays cannot decrypt payloads | Strong | Per Iroh design. |
| Relays see metadata (NodeIds, connection patterns, timing, volumes) | Acknowledged in docs | Public claims must reflect this honestly. (See 06-SECURITY_CLAIMS_REWRITE.md.) |
| Tickets are versioned, scoped, and not used as long-lived auth | Strong | Short pairing codes + signed records. |
| App-layer authorization on top of NodeId | **Gap** | Verify post-pairing authz contracts. (See 09-BURNBAR_SPECIFIC_REQUIREMENTS.md §"Post-pairing app-layer authz".) |
| Browser/WASM relay behavior is different (metadata + cost) | Acknowledged | Public copy must reflect this. |
| Production relay configuration | Strong | Hermes/Mercury use first-party relay configuration. |
| BLAKE3 for blobs; Bao for streaming; do not assume BLAKE3 covers all live streams | Verify | Confirm Bao is used for live streams. |

## 9. Remote desktop / control safety (2026 SOTA)

| Expectation | BurnBar status | Gap |
|---|---|---|
| Explicit consent before access (NIST AC-8, PT-4) | Strong | Incoming call sheet + trust mode picker + per-action approval. |
| View-only vs control clearly distinguished | Strong | Pre-P0 spec; verify regression test exists. |
| Phishing-resistant MFA | **Gap** | No passkeys / no MFA. (CISA SbDemand + V6.5.) |
| Session isolation, idle timeouts | Strong | Per-session trust, deny wins, budgets, kill. |
| Immutable audit (NIST AU-14) | Strong | BLAKE3 hash chain + signed head + OTS. |
| Re-authentication for sensitive actions (NIST IA-11) | **Medium** | Verify step-up for high-tier phone grants. |
| Per-action approval for privileged actions | Strong | Scope/deny + per-action approval. |
| Documented incident response (NIST IR family) | **Medium** | Internal runbooks; no public IR summary. |
| Zero Trust model (NIST SP 800-207) | **Medium** | Persistent agent model conflicts with strict ZT; verify compensating controls. (See [ScreenMeet 2026](https://www.screenmeet.com/blog/ciso-guide-building-a-zero-trust-framework) for context.) |
| Detection of anomalous activity (volume, duration) | **Medium** | irohMonitoring + mediaMonitoring exist; verify alert thresholds wired. (See blue-team.md.) |

## Overall maturity assessment

- **Above average / SOTA for consumer/pro tool with remote privileged execution:** Internal threat modeling, privileged input remediation, pairing design, cloud authz layers, audit proofs, post-P0 socket hardening, capability tokens, anchored audit chain.
- **Below SOTA / material gaps:**
  - Supply-chain provenance uniformity + OpenSSF Scorecard
  - Public transparency (VDP, security.txt, trust center, precise claims)
  - Negative test coverage (especially authz + revocation)
  - AI/LLM prompt injection defenses for RAG/agent flows
  - Rate limiting breadth
  - Daemon local socket hardening (still token-only, not code-signed)
  - Revocation propagation to transport sessions
  - Passkeys / phishing-resistant MFA
  - Full Iroh post-pairing app-layer authz proofs
- **Recommended immediate lift (P0/P1):** Public transparency package, rate limiting facade, AI confirmation gates, post-pairing Iroh authz contracts, negative test matrix, OTS completeness proofs wired, OpenSSF Scorecard ≥7.0.

## Citation policy reminder

Every claim in this gap analysis cites a primary source (file:line for code, URL for external standards). Where a claim depends on operational practice not visible in code (e.g., "GitHub-hosted runners qualify for SLSA L3 isolation"), the assumption is explicitly flagged for verification.
