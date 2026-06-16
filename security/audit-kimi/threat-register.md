# Threat Register

| ID | Threat | STRIDE Category | Severity | Likelihood | Risk | Owner | Mitigation | Residual Risk | Finding IDs |
|---|---|---|---|---|---|---|---|---|---|
| THREAT-001 | Attacker with same-user filesystem access reads plaintext local DB. | Information Disclosure | Critical | High | Critical | Platform | SQLCipher (planned), keychain key | High until enabled | FINDING-001, FINDING-002 |
| THREAT-002 | Attacker abuses cloud sync to read another user's metadata or sealed content. | Information Disclosure / Elevation | High | Medium | High | Backend | Firestore owner rules, App Check, sealed envelopes | Medium | FINDING-005, FINDING-006, FINDING-011 |
| THREAT-003 | Attacker writes malformed data to another user's Firestore documents (BOLA). | Tampering / Elevation | High | Medium | High | Backend | Ownership assertions, input validation | Medium | FINDING-005, FINDING-016 |
| THREAT-004 | Malicious agent log content poisons RAG / LLM prompts. | Tampering | High | High | High | AI/Agentic | Delimiter wrappers, provenance, tests | Medium | FINDING-004, FINDING-008 |
| THREAT-005 | Backup or snapshot of Mac exposes plaintext local DB. | Information Disclosure | High | High | High | Platform | SQLCipher, file protection | High until enabled | FINDING-001 |
| THREAT-006 | Compromised local client (extension, MCP, tunnel) abuses daemon RPC. | Elevation | Medium | Medium | Medium | Daemon | Auth token, capability matrix | Medium | FINDING-007, FINDING-009, FINDING-022 |
| THREAT-007 | External MCP client exfiltrates sensitive context via search/resume. | Information Disclosure | Medium | Medium | Medium | AI/Agentic | User approval, scoped tokens | Medium | FINDING-008 |
| THREAT-008 | Computer Use tool performs unauthorized high-impact action. | Elevation | High | Medium | High | Computer Use | Approval UI, kill switches, audit chain | Medium | FINDING-003 |
| THREAT-009 | Phone-control pairing exploited to control wrong Mac/session. | Elevation | High | Low | Medium | Computer Use | Passkey/escrow, capability tokens | Medium | FINDING-020 |
| THREAT-010 | Browser tool used for cross-origin/cross-site attacks. | Elevation | Medium | Medium | Medium | Computer Use | Scope, approval, origin checks | Medium | FINDING-003 |
| THREAT-011 | CI/CD or release infrastructure compromised to ship malicious binary. | Spoofing / Tampering | High | Low | High | Ops | Signed/notarized releases, SBOM, cosign | Medium | FINDING-010 |
| THREAT-012 | Callable abuse causes cost/denial-of-service. | Denial of Service | Medium | Medium | Medium | Backend | Rate limiting, quotas | Medium | FINDING-012 |
| THREAT-013 | User data not fully deleted after account deletion request. | Information Disclosure | Medium | Medium | Medium | Backend | dataDeletion callable | Medium | FINDING-013, FINDING-018 |
| THREAT-014 | Android iroh secret key extracted from device. | Information Disclosure | Medium | Low | Low | Mobile | Keystore storage | Low | FINDING-014 |
| THREAT-015 | Malicious log file crashes parser or exhausts resources. | Denial of Service | Medium | Medium | Medium | Platform | Size limits, streaming | Medium | FINDING-017 |
| THREAT-016 | Sealed cloud payloads malleable due to incomplete AAD. | Tampering | Medium | Low | Low | Backend | Complete AAD binding | Low | FINDING-015 |
| THREAT-017 | Push notifications leak identifiers. | Information Disclosure | Low | Medium | Low | Backend | Scrub notification payload | Low | FINDING-019 |
| THREAT-018 | Free-form crash reports leak user content. | Information Disclosure | Low | Medium | Low | Platform | Scrubbers, audit throws | Low | FINDING-021 |

## Risk Matrix

| Likelihood \ Severity | Critical | High | Medium | Low |
|---|---|---|---|---|
| High | THREAT-001, THREAT-005 | THREAT-004 | — | — |
| Medium | THREAT-008 | THREAT-002, THREAT-003, THREAT-011 | THREAT-006, THREAT-007, THREAT-010, THREAT-012, THREAT-013, THREAT-015 | THREAT-017, THREAT-018 |
| Low | — | — | THREAT-009, THREAT-014, THREAT-016 | — |
