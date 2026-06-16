# Remediation Roadmap

## Phase 1 — Ship Blockers (Must Fix Before Release)

| Item | Finding | Owner | Effort | Deliverable |
|---|---|---|---|---|
| Decide local DB encryption posture | FINDING-001 | Platform | Medium | Ship SQLCipher or update marketing/privacy claims |
| Verify App Check enforcement | FINDING-005 | Backend | Small | Console audit + runtime probe + CI drift test |
| Add Computer Use adversarial tests | FINDING-003 | Computer Use | Large | Test suite for all 13 tool kinds |
| Complete prompt/RAG injection wrapping | FINDING-004 | AI/Agentic | Large | Uniform wrappers + adversarial corpus |

## Phase 2 — High Priority (Next Sprint)

| Item | Finding | Owner | Effort | Deliverable |
|---|---|---|---|---|
| Daemon RPC capability matrix | FINDING-007 | Daemon | Medium | Authorization matrix + per-method checks |
| Add callable rate limiting | FINDING-012 | Backend | Medium | Per-UID + global throttling |
| Fix data deletion cascade | FINDING-013 | Backend | Medium | E2E deletion test + fixes |
| Complete Cloud Vault AAD | FINDING-015 | Crypto | Medium | Audit all envelopes + tamper tests |
| Android iroh Keystore | FINDING-014 | Mobile | Small | Move key to Keystore |

## Phase 3 — Medium Priority (30–60 Days)

| Item | Finding | Owner | Effort | Deliverable |
|---|---|---|---|---|
| Local MCP human gate | FINDING-008 | AI/Agentic | Medium | Approval UX + audit log |
| Cursor tunnel hardening | FINDING-009 | Extensions | Small | TTL/token + revocation |
| Phone HID binding | FINDING-020 | Computer Use | Medium | Session-bound capability tokens |
| Parser limits | FINDING-017 | Platform | Small | Size/depth caps |
| session_logs validation | FINDING-016 | Backend | Small | Strict schema + limits |

## Phase 4 — Low Priority / Continuous

| Item | Finding | Owner | Effort | Deliverable |
|---|---|---|---|---|
| Notification payload scan | FINDING-019 | Backend | Small | PII scan test |
| Crash context scrub | FINDING-021 | Platform | Small | Audit throws + before-send test |
| Daemon token rotation | FINDING-022 | Daemon | Small | Policy + rotation logic |
| dataExport audit | FINDING-018 | Backend | Small | Field audit + policy alignment |
| CI two-person rule / OIDC | FINDING-010 | Ops | Medium | Workflow hardening |

## Risk Acceptance

| Finding | Accepted By | Rationale |
|---|---|---|
| FINDING-002 | Product | Required for local log access; mitigated by signing, approval gates, kill switches |
| FINDING-006 | Product / Legal | Metadata visibility is a design choice; requires accurate privacy policy |
| FINDING-010 | Exec / Security | Industry-standard release trust model; mitigated by attestations |
