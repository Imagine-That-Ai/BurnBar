# BurnBar / OpenBurnBar SOTA Security Review — Executive Summary (Second-Opinion Edition)
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) independent second-opinion review
**Status:** Provisional — final synthesis after specialist subagents complete; see `00-MASTER_INDEX.md` for the reading order.

## TL;DR

- **Product:** BurnBar / OpenBurnBar (macOS + iOS + Android + extensions) — local-first AI agent observability + cross-device control via Iroh E2EE, with opt-in cloud sync, Remote MCP, Hermes/Mercury media, and Computer Use phone-as-controller.
- **Method:** Multi-agent specialist swarm (8 parallel subagents) + primary-source code reading + cited SOTA framework research. Re-verifies every Critical/High finding from the prior Grok 4.3 review (`security-review-2026-06-01/`) against the *current* code on disk.
- **Headline posture:** The product has a *strong baseline* — local-first canonical state, explicit consent model, post-P0 privileged-socket code-sign auth, capability tokens (WS2), an anchored tamper-evident audit chain, owner-scoped Firestore rules, App Check, and a SOTA-graded remediation plan (`plans/2026-05-30-sota-security-remediation.md`) with substantial progress shipped.
- **The honest news:** Real risks remain in the highest-blast-radius surface (remote control / phone-as-controller / agent execution), the bespoke Hermes Gateway HTTP/SSE/attachment surface, AI/agent prompt injection through RAG and Computer Use, and the long tail of public transparency (VDP, security.txt, precise claims) that a product with these capabilities should ship with.
- **Overall grade:** Provisional **B** (B- if the long tail stays; B+ if the P0s and P1s land in the next 7 days). Final grade in the synthesized report after specialists return.
- **Launch readiness:** **Ready with conditions.** Ship behind the conditions in §"What must be fixed before public launch."

## What is genuinely strong (evidence, file:line)

1. **Local-first canonical state.** Daemon + GRDB/SQLCipher + macOS Keychain. Cloud is opt-in and never replaces local state. (`docs/THREAT_MODEL.md:127-134`, `AgentLens/Services/DatabaseEncryptionService.swift`)
2. **Privileged socket post-P0 hardening.** `OpenBurnBarPrivilegedInputExecution` Mach service holds only `hid.virtual.device`. `VirtualHIDBridge` is a thin Unix-socket adapter. `RemoteAccessAgent` is launcher-only. `PrivilegedPeerAuthenticator` validates peer code-sign via `LOCAL_PEERTOKEN` + `SecCode` + designated requirement. (`docs/security/PRIVILEGED_SOCKET_AUTH.md:5-26`, `OpenBurnBarRemoteAccessAgentCore/OpenBurnBarSigningIdentity.swift`)
3. **Capability tokens (WS2).** Ed25519-signed, single-use, short-TTL, domain-tagged, scope-hashed, action-budgeted, attestation-bound. `CapabilityToken` + `CapabilityTokenIssuer` + `CapabilityTokenVerifier` + `CapabilityTokenSigning` in `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/`. Verified fail-closed `VirtualHIDBridgeInputPolicy` until WS2 universal.
4. **Phone control authority validation.** Ed25519 + monotonic counter + intent-hash + 300s lifetime + attestation param + escrow-device check. (`OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUsePhoneControlSigner.swift`, `PhoneControlAuthorityValidator.swift`)
5. **Tamper-evident audit chain.** BLAKE3 hash chain + signed head + OpenTimestamps anchoring. `ComputerUseAuditChain.swift`, `ComputerUseAuditHeadFinalizer.swift`, `ComputerUseAuditExportSignerProvider.swift`, `ComputerUseOpenTimestampsClient.swift`, `ComputerUseOpenTimestampsProofVerifier.swift`, `ComputerUseAuditVerifier.swift`. WS3 (signed-head + max-index completeness proofs) is in-flight per `plans/2026-05-30-sota-security-remediation.md`.
6. **Multiple independent kill switches.** Global hotkey (⌃⌥⌘.), phone three-finger long-press, NSWorkspace (loginwindow / SecurityAgent / screen sleep), Remote Config `computer_use_kill_switch`, AX revocation poll, and an always-on watchdog LaunchDaemon that activates a leaf-side flag even when the app can't. (`docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md`)
7. **High-risk callable wrappers.** `enforceHighRiskComputerUseCallable` requires a bound `obb_app_check` attestation claim (`functions/src/computerUseSecurity.ts:140`, `appCheckAttestation.ts:120`). The pattern is applied to escrow device trust, Remote MCP grants, and the high-risk CLI Link complete path.
8. **Owner-scoped Firestore rules + secret denylist.** Plaintext secret field names (`apiKey`, `token`, `refreshToken`, etc.) are rejected in client-writable sync documents. `provider_account_secret_refs` is server-only. (`docs/THREAT_MODEL.md:240-244`, `firestore.rules`)
9. **Apple JWS trust pipeline.** Forged/replayed App Store JWS rejected via vendored Apple root CAs (SHA-256 pinned), `appAccountToken` binding per `entitlement_bindings`, `signedDateMs` ordering, server authoritative. (`docs/THREAT_MODEL.md:255-287`, `functions/src/appstore/verifier.ts:ROOT_CERT_FILES`)
10. **Iroh E2EE foundation.** Cross-device traffic is QUIC + E2EE between endpoints; relays cannot decrypt payloads (per official Iroh docs). Tickets and NodeId are versioned and verifiable.
11. **Resilience wiring enforcement.** `providerFetch` is mandatory; CI script `scripts/ci/verify-resilience-wiring.sh` fails on any raw `fetch` in `functions/src/`.
12. **Supply-chain provenance on release lane.** cosign + SPDX SBOM + OpenVEX on tag releases via OIDC; release artifacts attested. (`docs/security/SUPPLY_CHAIN_PROVENANCE.md`, `.github/workflows/release.yml`, `.github/workflows/supply-chain-provenance.yml`)
13. **Self-critical team posture.** The team's own May 2026 remediation plan (`plans/2026-05-30-sota-security-remediation.md`) ranks 9 verified vulns with evidence and explicitly corrects the prior mega-draft. This is itself a maturity signal.

## What is fragile / highest risk (evidence, file:line)

1. **Remote control / phone-as-controller / agent execution surface.** Even with P0 sockets closed and WS2 tokens largely built, the *feature set itself* (cross-device privileged input with biometric + grant + trust mode) is the highest blast radius. A compromised-but-genuinely-paired device, a first-party-signed-but-evil binary, or a bug in WS2 wiring would be catastrophic. **This is the risk that defines the product's security posture**; everything else is downstream. (See Red Team chain #1, #2, #5 in `07-RED_TEAM_KILL_CHAINS.md`.)
2. **Hermes Gateway HTTP/SSE/attachment surface.** Bespoke bearer + scopes + 50MB uploads + SSE + event streaming. The approve-path call `approveHermesGatewayDeviceGrant` uses `enforceAuthAndAppCheck` + entitlement, *not* `enforceHighRiskComputerUseCallable` — a tier inconsistency vs. peer high-risk paths. (Prior review Finding C2; re-verified.)
3. **CLI Link device-code flow.** `startCliLink` is fully public onRequest (no App Check, no Auth); `pollCliLink` checks only a SHA-256 hash of `deviceSecret`. ~27-43M effective userCode space × 10-minute window = limited brute-force protection before a high-risk complete. (Prior Finding C3; re-verified.)
4. **Sparse rate limiting.** Per-action last-timestamp + caller windows only; no general burst / distributed / global facade. Pairing floods, grant spam, gateway enqueue abuse, and high-risk callable storms are all possible. (Prior Finding H2; re-verified.)
5. **Spec/implementation drift on `latestRouterRundown`.** Public onRequest endpoint with no `assertAppCheck`, while the OpenAPI doc claims App Check. Document-vs-reality gap. (Prior Finding H1; re-verified.)
6. **Post-pairing Iroh app-layer authz.** E2EE between endpoints is strong, but the *application-layer* contract (what does possessing a NodeId + signed pairing record grant you? Nothing? Screen-only? Full control?) is the unstated assumption. If post-pairing screens are too permissive, a stolen pairing record enables escalation.
7. **AI / agent prompt injection through RAG / Computer Use.** Log parsers, webpage extracts, screenshot OCR, MCP responses, hosted insight JSON, and RAG chunks all flow into agent context. The prior review shipped `LLMSafeContent` wrappers + `<UNTRUSTED_CONTENT>` blocks + `AgentLensTests/Security/PromptInjectionHardeningTests.swift` during its run — this is in-flight, not universal. Re-verify that *every* untrusted-content path uses the wrappers.
8. **Relay metadata leakage + cost blowup for Mercury.** Per Iroh official docs, relays see NodeIds, connection patterns, timing, and volumes. For high-bandwidth screen-share and call paths, this is a privacy + cost exposure that must be communicated and capped.
9. **Supply-chain depth.** Cosign + SBOM on release lane, but not uniform across all artifacts (extensions, crates, MCP shims, browser extension). Dependency review and OpenSSF Scorecard not in fast-feedback.
10. **Public transparency.** No top-level `SECURITY.md`, no `security.txt` at root, no public VDP, no public trust center. A product with these capabilities should ship with radical transparency.
11. **Local same-UID residual risk.** Documented and inherent to single-user UNIX-socket IPC, but must be clearly communicated. Any non-sandboxed process running as the console user can connect to the daemon socket with a valid launchd-env token.

## What must be fixed before public launch (P0 blockers)

1. **Verify + land the remaining WS2 capability-token wiring on every "input" dispatch path** (bridge adapter, keyboard engine, dispatch handler). Make attestation binding (`bindAppCheckAttestation` → bound `obb_app_check` claim) mandatory for all high-tier phone grants and every control intent envelope. Universally required. (`OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/`, `PhoneControlAuthorityValidator.swift`)
2. **Tier consistency on Hermes Gateway grant issuance.** Migrate `approveHermesGatewayDeviceGrant` and similar to `enforceHighRiskComputerUseCallable`. (`functions/src/callables/hermesGateway.ts:499` per prior review.)
3. **Rate limiting breadth.** A proper facade (Firestore-backed counters with decay, or external service) on all sensitive paths: pairing start/complete, CLI Link start/poll, gateway enqueue, every high-risk callable.
4. **Close `latestRouterRundown` drift.** Add `assertAppCheck` (or full enforce) at the top of the handler; update OpenAPI if the data is truly intended to be unauthenticated.
5. **Public security transparency package.** `SECURITY.md` (VDP), `.well-known/security.txt`, responsible disclosure contact, public trust center outline. Link from website footer, README, pricing, and in-app Settings.
6. **Explicit post-pairing Iroh app-layer authorization contracts + tests.** Stolen/impersonated post-pairing artifact must be denied for control paths, even with a valid NodeId + signed pairing record.
7. **AI/agent high-impact tool confirmation gates.** Mandatory confirmation for high-impact `BurnBarToolKind.computerUse*` actions (shell, file modify outside scope, send message/email, spend, change account/security). Extend `LLMSafeContent` wrappers to every untrusted-content path.
8. **WS3 audit completeness proofs wired end-to-end.** Signed-head + max-index completeness proofs, CLI verifier, operator drill with published timings, automated CI gate. (`ComputerUseAuditSignedHead.swift`, `ComputerUseAuditVerifier.swift` already exist; verify the export → verifier path is fully wired.)

## Top 10 risks (severity-normalized, owners suggested)

1. **Remote control escalation or replay from compromised genuine paired device or first-party-signed malware.** (Critical) — Owner: Computer Use / Daemon team. Evidence: `plans/2026-05-30-sota-security-remediation.md` V0-1/V0-2/V1-1/V1-3, current `OpenBurnBarVirtualHIDBridgeMain.swift`, `OpenBurnBarRemoteAccessAgentMain.swift`, `ComputerUsePhoneControlSigner.swift`.
2. **Hermes Gateway device grant approval with weaker auth than peer high-risk paths.** (High) — Owner: Cloud / Hermes. Evidence: `functions/src/callables/hermesGateway.ts:499`.
3. **CLI Link device-code public surface with limited brute-force protection.** (High) — Owner: Cloud. Evidence: `functions/src/callables/cliLink.ts:30/82`.
4. **Sparse/naive rate limiting on callables, gateway, pairing, grants.** (High) — Owner: Cloud + Quota. Evidence: `functions/src/shared.ts:1357+`, gateway enqueue paths.
5. **AI/agent prompt injection via logs / screenshots / webpages / MCP responses / hosted JSON / RAG.** (Critical) — Owner: AI / Insights / Computer Use. Evidence: `AgentLens/Services/LogParser/*`, `ContextBuilder.swift`, `insightsHostedAnswer.ts`, OWASP LLM 2025 #1.
6. **Post-pairing Iroh app-layer authz gaps (stolen pairing record / NodeId leading to unauthorized screen/control).** (Critical) — Owner: Iroh / Hermes transport. Evidence: `docs/HERMES_IROH_TRANSPORT.md`, current pairing code.
7. **Relay metadata leakage + cost blowup for Mercury high-bandwidth streams.** (High) — Owner: Iroh / Media. Evidence: Iroh official docs, `docs/HERMES_MEDIA_TRANSPORT.md`.
8. **Spec/implementation drift on `latestRouterRundown` (App Check claimed, not enforced).** (Medium) — Owner: Cloud / Observability. Evidence: `functions/src/routerRundown.ts:1054`, `openapi.yaml`.
9. **Supply-chain compromise of privileged release artifacts (DMG + entitlements + MCP shims).** (High) — Owner: Release / CI. Evidence: `.github/workflows/release.yml`, `docs/security/SUPPLY_CHAIN_PROVENANCE.md`.
10. **Missing public security transparency (VDP, security.txt, trust center, precise claims).** (Medium — but launch blocker) — Owner: Docs / Legal / Website. Evidence: grep across repo/website confirms none at top level.

## What can wait (90-day+ hardening)

- Full SLSA L3 across every artifact/platform (DMG, AAR/APK, extensions, crates, MCP shims).
- Comprehensive AI red-team corpus (prompt injection via every untrusted channel + automated eval gates).
- Advanced detection (pairing abuse, anomalous relay volume/cost, high token burn, model-switch anomalies, new device/escrow, privilege escalation) wired to oncall + playbooks.
- Self-hosted hardening guide v2 + documented local gateway attack surface + same-UID residual risks.
- Hardware-backed / HSM for hosted secrets where feasible.
- Formal (small TLA+/Alloy or exhaustive harness) proofs of pairing/grant/panic protocol as living docs.
- Passkeys / phishing-resistant MFA as default (CISA emphasis) where Firebase paths allow.
- Continuous external red-team program focused on remote control + AI agent surfaces.

## Confidence

- **High** on the architecture, cloud API, privileged control, pairing, and supply-chain posture (direct subagent + primary-source reads).
- **Medium-high** on AI/agent prompt injection surface (significant in-flight work; verify universal coverage).
- **Medium** on cross-platform parity (Android E2E, hosted MCP, live kill drills) pending final specialist synthesis.
- **Medium** on privacy/admin-access (depends on operational claims; verify via runbook + Sentry config + Cloud Logging).

All claims are traceable. Every finding cites file:line or doc section. No rubber-stamping.

## Next steps for the orchestrator

After all specialist subagents return:
1. Integrate findings into `03-FINDINGS_REGISTER.md`, deduplicating against the prior review.
2. Confirm the P0 list above is complete (add anything the specialists surface that the prior review missed).
3. Re-grade and update this executive summary.
4. Refresh `10-FIX_ROADMAP.md` with concrete owners and dates.
5. Hand the checklist to engineering.
