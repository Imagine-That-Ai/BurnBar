# Cloud, Infrastructure & Operations Review — Opus 4.8 1M lane

Verdict: **The weakest category (scored 48).** Detection is real **in code**, but operational effectiveness of several controls is **unverifiable from the repository** and the prior internal diligence (06-11) found a dead alert path and a wedged deploy plane. This is the primary reason the overall score sits in the low-70s.

## J.1 What is verifiable from code (good)
- **Deploy pipeline:** `deploy-production.yml` checks out submodules recursively (`:46,68` — prior wedge **fixed**), `environment: production`, least-priv `permissions:` (`:3-6`), auto-rollback on failed deploy/health-gate (`:228-247`, `scripts/rollback.sh` previous-SemVer with 30-day freshness guard).
- **Firestore deploy:** `deploy-firestore.yml` runs emulator rules tests → deploy rules+indexes+storage → API-level hash drift check → TTL-state readback (`:109`) → auto-issue on failure.
- **Fail-closed governance:** `ops-plane-verify.yml:115-124` fails closed on scheduled run if `GCP_SA_KEY` absent.

## J.2 Unverifiable operational state (cap drivers)
| Item | Code says | Unknown | ID |
|---|---|---|---|
| Firestore TTL policies | declared + deploy-readback gate present | are they LIVE (ACTIVE/CREATING)? 06-11 found 0 live TTLs | OPUS-U-001 |
| App Check enforcement | code default true + startup fail-closed (callables) | is Firestore **console** enforcement ON for direct traffic? | OPUS-U-002 |
| Alert delivery | 16 GCP policies exist | 06-11: all → `support@openburnbar.app` = NXDOMAIN (undeliverable) | OPUS-U-003 |
| Prod functions currency | fixes merged | is prod running them? 06-11 found prod pinned to 2026.06.03 | OPUS-U-004 |
| Branch protection | required-check wiring present in workflows | is `enforce_admins`/required-reviews actually ON? | OPUS-U-005 |

## J.3 Production access model (from docs + code)
- Single prod GCP project (`burnbar`); `GCP_SA_KEY` long-lived service-account key (06-11 noted laptop Cloud Run deploys). No HSM/multi-party signing — single-signer release model (solo operator, `docs/SOLO_OPERATOR_POLICY.md`).
- `burnbarOperator` claim minted only out-of-band; operator dashboards read aggregate `ops/**` only.

## J.4 Detection & response
- **Detect:** GCP uptime checks (4 surfaces), hosting smoke (200+marker+CSP), nightly Swift matrix, DAST. Real per 06-11.
- **Respond:** auto-rollback wired; auto-issue filing on failures. **But** response *reach* depends on OPUS-U-003 (alert channel). Incident-response runbooks exist (`docs/runbooks/`), but operator-attested IR evidence is not in-repo.

## Recommendations (highest leverage)
1. Confirm + fix the alert notification channel (OPUS-U-003) — minutes of work, converts monitoring from theater to function.
2. Confirm live TTL state (OPUS-U-001) and prod deploy currency (OPUS-U-004) via readback.
3. Confirm App Check console enforcement (OPUS-U-002) and branch-protection ruleset (OPUS-U-005).
4. Move toward short-lived WIF instead of `GCP_SA_KEY`; document a break-glass hotfix lane.
