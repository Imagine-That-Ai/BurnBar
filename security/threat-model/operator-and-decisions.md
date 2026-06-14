> **CONFIDENTIAL — BurnBar security package.** Companion to the remediation work on branch `remediation/tech-debt-fable-2026-06-12`. Share with Cure53 out-of-band; do not publish.

# Operator Runbook & Decision Memo — findings that are NOT code-fixable

The remediation waves close every *code*-fixable finding. The findings below are deliberately **not** changed in code because they require either (a) **deployed/console/IAM state** the repository cannot set (and which, per standing policy, must not be altered without explicit operator action), or (b) a **product/crypto-architecture decision** the founder owns. Each is given a concrete action so nothing is left dangling.

## A. Operator-only (deployed state — run these; do not infer them as "done" from code)

| ID | What to verify/set | How | Done-when |
|---|---|---|---|
| **T-AZ-06** | Firebase **App Check enforcement = ENFORCED** for Firestore **and** Storage in production (code defaults to enforce + prod boot-refusal, but the console toggle is the real gate). | `node scripts/commercial-launch-gate.mjs` with live gcloud creds; or Firebase console → App Check → APIs. | Both Firestore and Storage show **Enforced**; the gate prints green. |
| **T-AZ-07** | Custody of the **`burnbarOperator`** custom claim: who can mint it, where minting is audited, and proof it is never set on end-user accounts. | Review the claim-issuance path (out-of-repo / Admin SDK runbook); add an audit log entry on every mint; spot-check production user records for the claim. | Documented minting authority + audit; zero end-user accounts carry the claim. |
| (cross-ref) | **PITR + scheduled Firestore backups + delete-protection**; **alert channels verified** (not NXDOMAIN); **Remote Config** kill-switch values; **branch/environment protection** on `release`/`production`. | `scripts/ops/verify-firestore-disaster-recovery.sh`, `ops-alerts-gate.mjs`, `scripts/ops/verify-github-governance.sh` with creds. | Each fail-closed verifier prints green; see [`open-questions.md`](open-questions.md) §1. |

> **Standing constraint:** these are live GCP/GitHub/Apple/Google console actions. They are intentionally left to the operator and were **not** changed by the remediation (no cloud resource was created, deleted, or reconfigured).

## B. Product / crypto-architecture decisions (founder owns the call)

| ID | Decision | Options | Recommendation |
|---|---|---|---|
| **T-CRY-05** | KCI / static-leg compromise on the homegrown relay is a **documented accepted non-goal**. | (1) Accept as-is (current). (2) Add a Double-Ratchet/PQXDH lane (large, explicitly out of scope today). | **Accept & keep documented** for now; revisit if a forward-secrecy product claim is ever desired. The crypto ADR already scopes this. |
| **T-CVS-05** | At-rest envelopes are not ephemeral/ratcheted, so a future identity/vault-key compromise can retroactively decrypt captured history. | (1) Accept (endpoint-trust model). (2) Introduce key-epoching / periodic vault re-key. | **Roadmap key-epoching** (pairs well with the existing rotation machinery); accept the residual until then. Do **not** claim forward secrecy at rest. |
| **T-AZ-03** | Cleartext control-plane/usage **metadata** enables traffic-analysis inference (not an auth bypass). | (1) Accept & disclose (current honest-claims posture). (2) Seal/minimize more facets (cost vs. product features like cross-device resume). | **Accept & disclose** per the claims matrix; selectively minimize the cheapest facets (the encrypted-search padding from T-PRV-05 already helps). |
| **T-IOS-08** | The keyboard requests **Open Access**. | (1) Keep (justify). (2) Narrow to App-Group-only if Full Access is not strictly required for shared-container reads. | **Test the App-Group-only path**; if snippets read with Full Access denied, narrow the request and document. Otherwise keep + justify in the privacy policy. |
| **T-IOS-10** | No on-device **jailbreak/runtime-integrity** assumption is stated. | (1) Document as accepted-risk (local-first app). (2) Implement detection. | **Document the accepted-risk assumption** (consistent with the same-user-trust model); detection is low-value for a local-first app and easily bypassed. |

## C. Where these are reflected

- The claims matrix ([`security-claims.md`](security-claims.md)) already states the *safe* wording for the residuals above (no forward secrecy at rest, metadata visible, App Check is the boundary).
- The threat register ([`threat-register.csv`](threat-register.csv)) carries these IDs; this memo is their disposition of record.
- The accepted-risk items belong in the repo's `SECURITY.md` "Accepted Risks" section and `SECURITY_CLAIMS_REGISTER.md` (the team's canonical claim boundary) — add T-CRY-05, T-CVS-05, T-AZ-03, T-IOS-08, T-IOS-10 there with their triggers-to-revisit.
