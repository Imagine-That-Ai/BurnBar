# Open Questions

| ID | Question | Why it matters | Likely risk if unresolved | How to resolve | Owner suggestion |
|---|---|---|---|---|---|
| UNKNOWN-001 | Is Firebase App Check enforcement enabled in production for Firestore? | Repository rules cannot prove console state. | Direct Firestore clients may bypass app attestation. | Add Firebase/GCP App Check enforcement verifier to ops readiness. | Cloud/Ops |
| UNKNOWN-002 | What Cloud Armor or edge rate limits are active for public HTTP endpoints? | Public endpoints need availability and cost controls. | Denial-of-wallet or noisy logs. | Inventory edge config or add product-layer limiter. | Cloud/Ops |
| UNKNOWN-003 | Which security claims are published outside this repository? | Claims must match implementation. | Audit/procurement failure and user trust risk. | Review website, app store, sales docs, onboarding, in-app copy. | Product/Security |
| UNKNOWN-004 | Who or what can access production Firestore, Storage, Firebase, Stripe, Sentry, and GitHub environments? | Admin/service access is a key enterprise review topic. | Silent broad data access or weak accountability. | Export IAM/access list and review logs. | Engineering leadership |
| UNKNOWN-005 | Are production deploy fallback secrets currently configured? | Workflow still supports them. | Long-lived deploy secret compromise path. | Audit GitHub environment secrets and remove fallbacks. | Platform |
| UNKNOWN-006 | What retention and deletion SLA covers backups, Sentry, Firebase logs, Stripe records, and audit logs? | Privacy claims require processor and backup evidence. | Non-compliance or incorrect deletion promises. | Publish retention matrix and processor subprocessors. | Privacy |
| UNKNOWN-007 | Has an independent security review occurred after latest Computer Use and Remote MCP changes? | High score requires independent evidence. | Overstated audit readiness. | Attach report or schedule external review. | Security |
| UNKNOWN-008 | Which distribution build variants include or compile out Mac System Computer Use paths? | Distribution-specific local privilege risk. | Wrong app-store/public claim or attack surface misunderstanding. | Map build flags and artifacts to release channels. | Release |
| UNKNOWN-009 | What is the formal break-glass process for production data/secrets? | Incident response and enterprise reviews require it. | Slow or unaudited emergency access. | Write and exercise break-glass runbook. | Ops/Security |
| UNKNOWN-010 | What is the maximum signed URL lifetime for export object refs in production? | Export privacy and replay risk. | Long-lived access to ciphertext objects. | Test and document signed URL TTL. | Backend/Privacy |

