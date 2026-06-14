# Mitigation Roadmap

## Must Fix Before External Audit

| Item | Risk addressed | Severity | Component | Mitigation | Acceptance criteria | Tests | Owner | Effort | Dependencies |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Fix Gateway attachment download authorization | BB-T007, BB-T025 | High | Storage/Mobile/Backend | Add signed download callable or explicit owner-scoped Storage rule for Gateway attachment bodies | iOS/Android download succeeds only for owner/intended recipient; cross-user denied | Storage rules tests, mobile integration test | Backend/Mobile | M | path design |
| Check Swift CloudVault RNG status | BB-T018 | High | Crypto | Throw on `SecRandomCopyBytes` failure in vault key generation | failure cannot produce key | mocked RNG failure unit test | Crypto | S | test injection |
| Produce live cloud evidence | BB-T016, BB-T006, BB-T020 | High | Ops | Export deployed rules, Functions config, App Check, IAM/KMS/Secret Manager bindings | audit folder contains dated readbacks | scripts/manual verification | Ops | M | GCP access |
| Complete endpoint authorization matrix | BB-T006 | High | Backend/Hosted MCP/Daemon | Enumerate all callables/HTTP endpoints/MCP tools/daemon RPCs and expected authz | every endpoint has owner/scope tests or accepted exception | BOLA/IDOR tests | Backend/Sec | L | endpoint inventory |
| Lock security claims | BB-T019 | Medium | Product/Sec | Add claim review checklist and banned wording to release docs | no Signal/full-E2EE/hardware/no-logs claims without evidence | doc lint/manual review | Product/Sec | S | claims owner |
| Add prompt-to-tool red-team suite | BB-T009, BB-T013, BB-T028 | Critical | AI/Desktop | Test malicious docs/web/tool outputs/approvals | high-risk tools never execute without approval; low-risk exfil cases tracked | regression suite | AI/Desktop | M/L | fixtures |
| Local MCP privilege boundary decision | BB-T011 | High | Tools/Desktop | Either restrict local MCP to trusted agents or add capability/token model | untrusted agents cannot read/decrypt history by default | local MCP authz tests | Tools | M | product decision |
| Vendored runtime verifier in release | BB-T022 | High | Supply chain | Make source/runtime verifier blocking in release CI | release fails on mismatch | CI negative test | DevInfra | M | runtime source |

## Should Fix Before Launch

| Item | Risk addressed | Severity | Component | Mitigation | Acceptance criteria | Tests | Owner | Effort |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pairing safety-code UX proof | BB-T004 | High | Mobile/Desktop | Require visible safety code/device identity comparison where appropriate | phishing/MITM tests fail to pair silently | pairing UX/security tests | Mobile/Desktop | M |
| Revocation local purge and rotation plan | BB-T005 | High | Mobile/Desktop/Crypto | On revoke, purge local tokens/cache and rotate CloudVault where survivor exists | post-revoke future cloud access denied; local residual documented | revocation integration tests | Crypto/Mobile | L |
| Attachment preview hardening | BB-T008 | High | Mobile/Desktop | safe preview sandbox, file size/type/decompression limits, untrusted labels | malicious corpus cannot crash/hang or auto-execute | parser fuzz/malware corpus | Mobile/Desktop | M/L |
| Provider egress UX and DLP | BB-T014 | High | AI/Product | Show provider route and data categories; redact obvious secrets | provider request fixtures match expected fields | egress tests | AI/Product | M |
| Native/mobile crash redaction | BB-T017 | Medium | Mobile/Desktop/Ops | Crash fixture tests for prompts/secrets/tool args/screenshots | crash payloads scrubbed or not captured | Crashlytics/Sentry fixture tests | Mobile/Ops | M |
| SHA-pin third-party CI actions | BB-T021 | High | DevInfra | Pin or justify all actions | policy blocks unpinned actions | workflow lint | DevInfra | S/M |

## Important Hardening

| Item | Risk addressed | Mitigation | Acceptance criteria |
| --- | --- | --- | --- |
| At-rest replay protection | BB-T003 | monotonic message/device counters and stale detection | old stored envelope replay rejected |
| Memory provenance/quarantine | BB-T012 | provenance schema, secret scan, canary memory, user review/delete | poisoned memory fixture quarantined |
| Tamper-evident cloud audit | BB-T016, BB-T027 | append-only audit for admin/key/data access | admin data reads detectable |
| Agent egress controls | BB-T010, BB-T014 | per-tool network allowlists and cost limits | unauthorized domains blocked |
| YOLO guardrails | BB-T010 | explicit time-limited grants, workspace snapshots, stronger warnings | YOLO cannot persist silently |
| Extension webview review | BB-T023 | CSP/postMessage hardening and tests | forged postMessage rejected |

## Documentation Needed

| Document | Purpose |
| --- | --- |
| Endpoint compromise statement | Explain what BurnBar cannot protect on stolen/compromised devices. |
| Provider data flow disclosure | Explain what goes to local, user-selected, and hosted providers. |
| Metadata disclosure | Explain what BurnBar Cloud can see. |
| Revocation semantics | Distinguish future server access from local data/key cleanup. |
| Incident response runbooks | Relay, provider, KMS/IAM, CI, rogue agent, memory poisoning. |
| Production access model | Who can access prod data/secrets and how it is logged/reviewed. |

## Future Architecture Work

- Stronger local agent sandbox with filesystem and network isolation.
- Hardware-backed/user-presence keys for high-risk approvals.
- Signal/libsignal Gateway write cutover only after readiness, tests, and migration proof.
- Privacy-preserving metadata reduction or relay architecture changes.
- Formal agent identity and per-action authorization across local/cloud/MCP.
- Reproducible builds or stronger SLSA provenance for all release artifacts.
