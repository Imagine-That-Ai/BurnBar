# Evidence Map

This file maps key claims and threats to code evidence. Line numbers may drift; function/module names are included for durable lookup.

| Evidence ID | File path | Function/class/module | Relevant behavior | Tests | Confidence |
| --- | --- | --- | --- | --- | --- |
| E-AUTH-001 | `functions/src/auth.ts` | `assertOwnership`, `assertAuth`, `assertAppCheck`, `enforceAuthAndAppCheck` | Firebase Auth, uid equality, App Check enforcement helper | Functions security tests | High for code, medium for deployed |
| E-AUTH-002 | `functions/src/config.ts` | `getConfig`, production-looking checks | App Check/high-risk nonce defaults fail closed for production-looking projects | config tests unknown | Medium |
| E-AUTH-003 | `functions/src/appCheckAttestation.ts` | high-risk nonce helpers | One-time nonce issue/consume, expiry, staged enforcement | `appCheckAttestationBinding.test.ts` | Medium |
| E-RULES-001 | `firestore.rules` | owner namespace/server-only rules | Owner scoping, server-only Gateway and sensitive collections, plaintext-secret field rejection | `functions/scripts/test-firestore-rules.mjs` | Medium/High |
| E-RULES-002 | `storage.rules` | Storage rules | Session log owner path, avatar path, default deny | Storage tests needed | Medium |
| E-GW-001 | `functions/src/hermesGateway.ts` | relay protocol constants | v2/v3 algorithms, Signal v4 readiness disabled, plaintext grace closed | Gateway tests | High |
| E-GW-002 | `functions/src/callables/hermesGateway.ts` | `/device/start`, `/device/poll`, approval callable | Pairing codes, secret hashes, expiry, relay key requirement, phone relay key on approval | pairing tests partial | Medium |
| E-GW-003 | `functions/src/callables/hermesGateway.ts` | `resolveGatewayGrant`, PoP verifier | bearer token hash, active client, scope, PoP timestamp/nonce/body/query binding | `hermesGatewayPopV2.test.ts` | High |
| E-GW-004 | `functions/src/callables/hermesGateway.ts` | message enqueue/list endpoints | Rejects plaintext `text`, requires relayCapable, create-if-absent | Gateway tests partial | Medium/High |
| E-GW-005 | `functions/src/callables/hermesGateway.ts` | attachment init/finalize | Sealed envelope required, signed upload URL, content-type, size/hash/status validation | `hermesGatewayAttachmentInit.test.ts` | Medium |
| E-GW-006 | `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift` + `storage.rules` | attachment download path | Mobile uses Storage SDK path that appears not allowed by repo Storage rules | Missing | Low/Medium; important uncertainty |
| E-CRYPTO-001 | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift` | `HermesRelayCrypto` | v2/v3 relay sealing, AAD, stated FS/non-goals | HPKE vector/auth request tests | Medium/High |
| E-CRYPTO-002 | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift` | `HermesRatchetCrypto` | P-256 ratchet, HKDF/HMAC chain, AES-GCM, replay/out-of-order logic | `HermesRatchetCryptoTests.swift` | Medium |
| E-CRYPTO-003 | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` | `CloudVaultCrypto` | AES-GCM sealed payload/blob, path-bound AAD, HMAC; RNG status issue in vault key | `CloudVaultCryptoTests.swift` | Medium |
| E-CRYPTO-004 | `OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift` | `SignalAtRestSealer` | Sender-authenticated at-rest envelopes, HPKE wraps, binding checks | `SignalAtRestSealerTests.swift` | Medium |
| E-CRYPTO-005 | `third_party/libsignal/runtime-readiness.json` | runtime readiness | Signal/libsignal Gateway production write readiness not ready | readiness checks | High |
| E-IROH-001 | `OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohRelayPairing.swift` | Iroh pairing signature | Ed25519 canonical payload and freshness | `IrohRelayPairingSignatureTests.swift` | Medium |
| E-KEY-001 | `SignalIdentityKeyStore.swift`, `HermesGatewayRelayKeypair.swift`, Android key stores | Keychain/Keystore stores | OS-backed storage, not hardware/user-presence proof | key tests partial | Medium |
| E-SECRETS-001 | `functions/src/secrets.ts` | `encryptEnvelope`, `storeCredential`, `retrieveCredential` | AES-GCM DEK, KMS-wrapped DEK, Secret Manager versions | backend tests unknown | Medium |
| E-DAEMON-001 | `OpenBurnBarDaemon/Sources/OpenBurnBarDaemonServer.swift` | daemon server | max request size, socket permissions, peer auth before RPC | daemon tests | Medium/High |
| E-DAEMON-002 | `OpenBurnBarDaemon/Sources/BurnBarDaemonPeerAuthenticator.swift` | peer authenticator | production fail-closed first-party code-signature validation | IPC tests partial | Medium |
| E-TOOLS-001 | `OpenBurnBarDaemon/Sources/BurnBarRunService+ToolDispatch.swift` | tool dispatch | Mandatory approval for patch, terminal, browser/computer use where required | run service tests | Medium/High |
| E-TOOLS-002 | `OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarPolicyEngine.swift` | policy engine | Low/medium/high tool risk classification and approval descriptors | run tests | Medium |
| E-TOOLS-003 | `OpenBurnBarDaemon/Sources/ComputerUseRunCoordinator.swift` | computer-use coordinator | capability gate, approval, audit-before-action, URL/action validation | computer-use tests | Medium/High |
| E-TOOLS-004 | `OpenBurnBarCore/Sources/OpenBurnBarCore/AgentCapabilityGrant.swift` | capability grants | workspace/shell/unrestricted/desktop/browser/export capabilities; YOLO risk | grant tests unknown | Medium |
| E-TOOLS-005 | `AgentLens/Services/CLIBridge/CLIArgumentBuilder.swift` | CLI argument builder | backend-specific flags; YOLO dangerous bypasses; prompt wrappers | prompt tests partial | Medium |
| E-MCP-001 | `services/hosted-mcp/src/auth.ts` | hosted MCP auth | bearer header only, Ed25519/HMAC verification, exp checks, legacy controls | `auth.test.ts` | Medium |
| E-MCP-002 | `services/hosted-mcp/src/oauthToken.ts` | token refresh | refresh hash validation, rotation, entitlement/client checks | `oauthToken.test.ts` | Medium |
| E-MCP-003 | `services/hosted-mcp/src/resources.ts` | resources read | owner storage path prefix, body hash, local decrypt mode | hosted MCP tests | Medium |
| E-MCP-004 | `tools/openburnbar-mcp/server.py` | local MCP | local SQLite/history/cloud decrypt/search/memory/resume privileged tools | local MCP tests unknown | Low/Medium |
| E-MEM-001 | `tools/openburnbar-mcp-remote/src/memoryHook.ts` | memory hook | model-mediated memory extraction, redaction, dedup, sealing/queue | `memoryHook.test.ts` | Medium |
| E-MEM-002 | `functions/src/callables/knowledgeMemory.ts` | knowledge memory | sealed/cloaked memory storage and owner scoping | knowledge tests | Medium |
| E-PROVIDER-001 | `functions/src/insightsHostedAnswer.ts` | hosted answer | App Check/Auth/entitlement, digest/user question to OpenRouter, JSON output | hosted answer tests partial | Medium |
| E-PROVIDER-002 | `AgentLens/Services/InsightsMacEnvironment.swift` | insights route/privacy | route selection, privacy mode, hosted fallback, audit metadata | tests unknown | Medium |
| E-LOG-001 | `functions/src/logging.ts` | scrub/log helpers | recursive scrub for obvious secrets, PII-ish values, truncation | logging tests | Medium |
| E-LOG-002 | `functions/src/sentry.ts` | Sentry sanitizer | `sendDefaultPii=false`, beforeSend request/env/header/context scrubbing | `sentry.test.ts` | Medium/High for server |
| E-AUDIT-001 | `OpenBurnBarDaemon/Sources/ComputerUseAuditLogger.swift` | audit logger | parent-hash chain, descriptor hash, append validation | computer-use audit tests | Medium |
| E-CI-001 | `.github/workflows/security-pr.yml` | PR security gate | gitleaks, dependency review, npm audit, OSV, hosted MCP proofs, rules/policy checks | CI | Medium |
| E-CI-002 | `.github/workflows/release.yml` | release | tests, signing/notarization/Sparkle, SBOM/VEX, checksums, cosign | CI | Medium |
| E-CI-003 | `.github/workflows/deploy-production.yml` | prod deploy | production deploy checks and credential use | CI | Medium |
| E-SC-001 | `docs/security/SUPPLY_CHAIN_PROVENANCE.md` | supply-chain docs | provenance goals, SBOM/VEX, caveats on reproducibility | doc only | Low/Medium |
| E-SC-002 | `docs/security/AGENT_RUNTIME_PROVENANCE.md`, `scripts/ci/verify-vendored-agent-source.sh` | vendored runtime provenance | known runtime/source correspondence issue and verifier | verifier not confirmed blocking | Low/Medium |
| E-CLAIMS-001 | `SECURITY_CLAIMS_REGISTER.md` | claims register | safe claims, residuals, banned overclaims | doc review | Medium |
