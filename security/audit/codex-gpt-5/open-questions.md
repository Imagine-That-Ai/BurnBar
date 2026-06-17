# Open Questions

| ID | Question | Why it matters | How to resolve | Owner |
|---|---|---|---|---|
| UNKNOWN-001 | Is Firebase App Check enforcement enabled in production for Firestore? | repository rules cannot prove console state | add Firebase/GCP verifier | Cloud/Ops |
| UNKNOWN-002 | What Cloud Armor or edge rate limits are active for public HTTP endpoints? | public endpoint cost and availability | inventory edge config or add product limiter | Cloud/Ops |
| UNKNOWN-003 | Which security claims are published outside this repository? | claims must match implementation | review website, app store, sales docs, onboarding, in-app copy | Product/Security |
| UNKNOWN-004 | Who can access production Firestore, Storage, Firebase, Stripe, Sentry, and GitHub environments? | admin/service access is an enterprise review topic | export IAM/access list and review logs | Engineering leadership |
| UNKNOWN-005 | Are production deploy fallback secrets currently configured? | workflow still supports them | audit GitHub environment secrets and remove fallbacks | Platform |
| UNKNOWN-006 | What retention and deletion SLA covers backups, Sentry, Firebase logs, Stripe records, and audit logs? | privacy claims need processor evidence | publish retention matrix | Privacy |
| UNKNOWN-007 | Has independent review occurred after latest Computer Use and Remote MCP changes? | high score requires independent evidence | attach report or schedule review | Security |
| UNKNOWN-008 | Which distribution build variants include or compile out Mac System Computer Use paths? | distribution-specific local privilege risk | map build flags and artifacts to release channels | Release |
| UNKNOWN-009 | What is the formal break-glass process for production data/secrets? | incident response requires it | write and exercise runbook | Ops/Security |
| UNKNOWN-010 | What is the maximum signed URL lifetime for export object refs in production? | export privacy and replay risk | test and document signed URL TTL | Backend/Privacy |

