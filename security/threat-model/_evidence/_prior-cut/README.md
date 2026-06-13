# BurnBar Security Assurance Package

Date: 2026-06-13

This package is a codebase-grounded security and privacy threat model for BurnBar/OpenBurnBar in preparation for an external Cure53 review. The local repository is the evidence source. Deployed Firebase state, live IAM, live branch protection, App Store/Play release settings, and current production feature flags were not verified by this package unless explicitly stated.

## What BurnBar Does

BurnBar lets users control AI agents running on their own computers from other devices. The codebase includes macOS/iOS Swift apps, an Android app, a local daemon/runtime, Firebase Functions, Firestore/Storage rules, hosted MCP services, local/remote MCP tooling, Hermes Gateway relay flows, CloudVault sealing, Iroh relay pairing, provider integrations, computer-use automation, and CI/release workflows.

The product is best described as local-first remote agent control with selective cloud relay, encrypted/sealed subflows, and optional hosted provider/MCP paths. It is not, based on this repository, a universal Signal-equivalent secure messenger.

## Definition Of Secure

Secure for BurnBar means:

- Users can control which trusted devices and agents act on their behalf.
- BurnBar infrastructure cannot read current sealed Hermes Gateway message and attachment contents without endpoint keys.
- High-impact local actions are gated by deterministic policy and user approval, with auditability.
- Cross-user data access is denied by authentication, object ownership checks, and Firestore/Storage rules.
- Endpoint, cloud, provider, and agent compromise limits are explicit and not hidden behind marketing claims.
- Security claims are only made when code, tests, and operational evidence support them.

See [security-definition.md](security-definition.md).

## Evidence Grades

| Grade | Meaning |
| --- | --- |
| High | Code and tests both support the claim. |
| Medium | Code supports the claim, but tests or deployed proof are missing. |
| Low | Code is partial, ambiguous, or has unresolved operational dependencies. |
| Unknown | The repository does not prove the claim. |

## Top Security Goals

1. Keep current sealed message and attachment contents opaque to the cloud relay.
2. Prevent unpaired or revoked devices from creating trusted relay traffic.
3. Prevent cross-user access to messages, devices, attachments, provider secrets, and MCP resources.
4. Require explicit approval for high-impact local actions such as shell, patching, browser control, and desktop input.
5. Keep model output and untrusted content from directly bypassing deterministic tool policy.
6. Protect device, relay, Signal, CloudVault, and provider keys with appropriate local or cloud secret storage.
7. Preserve enough audit evidence for incident response without logging unnecessary plaintext.
8. Make provider/model egress visible and bounded.
9. Detect supply-chain and release-integrity regressions before release.
10. Tell users what BurnBar does not protect, especially compromised endpoints and intentionally shared provider data.

## Top Risks

1. **Local agent privilege and MCP exposure:** local MCP and YOLO/shell grants are highly privileged and can expose or mutate local/cloud history when granted.
2. **Endpoint compromise:** malware on a paired phone or desktop can read plaintext, steal local keys after unlock, approve actions, or tamper with tool outputs.
3. **Prompt-to-tool escalation:** malicious documents, webpages, emails, model output, or tool output can influence agent behavior; deterministic approval helps but does not make untrusted content safe.
4. **Attachment download authorization uncertainty:** iOS code appears to read Hermes attachment bodies via Firebase Storage SDK while `storage.rules` deny unlisted paths.
5. **Revocation is partial:** server credentials can be revoked, but already-downloaded plaintext, cached ciphertext, local keys, and best-effort Signal cleanup remain residual risks.
6. **Legacy/plaintext migration uncertainty:** current Gateway writes are sealed-only, but historical plaintext/backfill and deployed migration state are not fully proven.
7. **Cloud/admin metadata and secret access:** cloud sees metadata and may access hosted provider credentials through Secret Manager/KMS/IAM paths; live IAM least privilege was not proven.
8. **Memory poisoning:** model-mediated memory extraction and RAG/context retrieval can persist malicious or sensitive content without a formal provenance and quarantine model.
9. **Supply-chain gaps:** some workflows use tag-pinned rather than SHA-pinned actions, vendored agent provenance remains a known issue, and some dependency surfaces have weaker scanning.
10. **Local storage and crash/log privacy gaps:** SQLCipher is not proven for all local stores, Android/native crash payload sanitization is not fully evidenced, and endpoint logs may still hold sensitive local context.

## Top Recommendations

1. Fix and test Hermes attachment download authorization before audit.
2. Check `SecRandomCopyBytes` return status for CloudVault vault key generation.
3. Produce deployed evidence for Firebase rules, Functions flags, App Check enforcement, KMS/IAM, Storage rules, and CI branch/environment protection.
4. Publish a strict security claims register that bans Signal-level, full forward secrecy, hardware-backed key, and anonymity claims until implemented and tested.
5. Build a complete endpoint authorization matrix for all callables, hosted MCP tools, daemon RPCs, and device revocation paths.
6. Add adversarial tests for prompt injection, memory poisoning, malicious tool output, and high-impact approval bypass.
7. Harden local MCP privilege separation and document it as a high-risk privileged interface.
8. Add malicious attachment preview/parser hardening and size/decompression protections.
9. SHA-pin third-party CI actions or document compensating controls.
10. Make incident-response playbooks actionable for relay compromise, provider compromise, endpoint compromise, credential/key compromise, rogue agent behavior, and supply-chain compromise.

## Ready For Cure53

Ready:

- Source review of current sealed Hermes Gateway code paths.
- Firestore/Storage rules review.
- CloudVault, Hermes relay, ratchet, Signal-at-rest, and Iroh protocol review.
- Hosted MCP and local MCP authorization review.
- Local daemon IPC, tool execution, and computer-use policy review.
- CI/release workflow and supply-chain posture review.

Not ready:

- Any claim that production exactly matches repository configuration.
- Any Signal-level or full-forward-secrecy claim for Gateway messaging.
- Any claim that attachments are safely downloadable end to end until the Storage-rule/path inconsistency is resolved.
- Any claim that malicious content cannot manipulate agents.
- Any claim that local storage is uniformly encrypted.
- Any claim that all logs, analytics, and crash reports are free of sensitive data.

## Framework Baselines

The package maps findings to OWASP Threat Modeling, STRIDE, PASTA-style impact, OWASP ASVS, OWASP API Top 10 2023, OWASP LLM Top 10 2025, OWASP Agentic Applications Top 10 2026, OWASP MASVS/MASTG, NIST CSF 2.0, NIST SSDF, OWASP SCVS, SLSA-style provenance, LINDDUN, MITRE CWE/ATLAS, and the 2026 CISA/NSA/Five Eyes agentic AI guidance. Reference pages checked on 2026-06-13:

- OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/
- OWASP LLM Top 10: https://owasp.org/www-project-top-10-for-large-language-model-applications/
- OWASP Agentic Applications Top 10 2026: https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/
- CISA agentic AI guidance: https://www.cisa.gov/resources-tools/resources/careful-adoption-agentic-ai-services

## Deliverables

- [security-definition.md](security-definition.md)
- [architecture.md](architecture.md)
- [assets.md](assets.md)
- [trust-boundaries.md](trust-boundaries.md)
- [security-claims.md](security-claims.md)
- [crypto-review.md](crypto-review.md)
- [agentic-ai-threat-model.md](agentic-ai-threat-model.md)
- [privacy-threat-model.md](privacy-threat-model.md)
- [cloud-and-ops-threat-model.md](cloud-and-ops-threat-model.md)
- [supply-chain-threat-model.md](supply-chain-threat-model.md)
- [threat-register.csv](threat-register.csv)
- [threat-register.md](threat-register.md)
- [abuse-cases.md](abuse-cases.md)
- [mitigation-roadmap.md](mitigation-roadmap.md)
- [security-test-plan.md](security-test-plan.md)
- [cure53-audit-brief.md](cure53-audit-brief.md)
- [open-questions.md](open-questions.md)
- [evidence-map.md](evidence-map.md)
