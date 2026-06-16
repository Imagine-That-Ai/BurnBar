# Open Questions (require human / deployment evidence) — Opus 4.8 1M lane

These are **deployment/runtime facts** not verifiable from the repository. They are the primary reason several high-value controls are scored conservatively and the overall score is held in the low-70s. Resolving them is mostly minutes-to-hours of operator confirmation.

| ID | Question | Why it matters | How to resolve | Owner |
|---|---|---|---|---|
| OPUS-U-001 | Are the declared Firestore TTL policies (`voip_outbound`, `fcm_outbound`, `agent_notification_events`) LIVE (ACTIVE/CREATING) in prod? | I6 invariant; 06-11 found 0 live TTLs → ephemeral PII could persist | `deploy-firestore.yml` TTL readback run, or `gcloud firestore fields ttls list --project=burnbar` | ops |
| OPUS-U-002 | Is App Check **enforced for Cloud Firestore** in the production console (not just code default)? | Direct Firestore traffic needs console enforcement; Auth alone is insufficient | Firebase console → App Check → Firestore enforcement state | ops |
| OPUS-U-003 | Is the alert notification channel deliverable to a human? | 06-11: all 16 GCP policies → `support@openburnbar.app` = NXDOMAIN; same address is public support contact | `dig openburnbar.app`; `gcloud beta monitoring channels list`; send a test page | ops |
| OPUS-U-004 | Are production Cloud Functions current (Stripe/rollup/entitlement fixes live)? | 06-11 found prod pinned to 2026.06.03 → merged fixes not live | `healthReady` version vs HEAD; `gcloud functions describe ... updateTime` | ops |
| OPUS-U-005 | Is branch protection on `main` actually enforcing required checks + reviews + `enforce_admins`? | 06-11 found zero-review merges + `enforce_admins` toggling; controls must govern | GitHub branch-protection API; `ops-plane-verify` | eng lead |
| OPUS-U-006 | Does the shipped client carry the Sentry DSN, and are org-level PII settings off? | F-RR09-003 crash-telemetry privacy | inspect built macOS/iOS Info.plist; Sentry org/project settings | eng |
| OPUS-U-007 | Do public-website / App Store security claims match the carefully-scoped internal register? | Avoid blanket "encrypted"/"E2EE" claims contradicted by local-DB + collaboration plaintext (CLAIM-09/10/11) | review `website/src/data/*` + ASC listing vs `docs/security/SECURITY_CLAIMS_REGISTER.md` | founder |

## Product-decision items (carried from 06-14 M-lineage, not re-litigated this lane)
- **M-008** — Should CloudVault first-vault creation + rotation quorum be server-mediated?
- **M-018** — Should iroh first-contact safety-number compare be default-on before T-TRN-01 closure?
- **M-030** — What trust UX governs user-installed CLI binaries (OPUS-F-009)?
- **M-031** — What App Check attestation max-age is acceptable for high-impact callables?
- **M-021** — Are stable push routing IDs acceptable metadata, or must they rotate (OPUS-F-006)?
