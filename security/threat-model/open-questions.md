> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# Open Questions — decisions & evidence outside the code

These cannot be resolved from the repository alone. They are **deployed/console state**, **product decisions**, or **out-of-repo source**. Several controls that look correct in code are unprovable without these answers; resolve them before relying on the dependent claim. Grouped by owner.

## 1. Deployed-state evidence (operator + Cure53 to confirm)

| # | Question | Why it matters | Dependent claim/threat | How to resolve |
|---|---|---|---|---|
| Q1 | Is **App Check `ENFORCED`** in the production console for Firestore **and** Storage (not just enforced in code)? | Code defaults to enforce + prod boot-refusal, but console state is the real gate. | C11, T-AZ, every callable | `scripts/commercial-launch-gate.mjs` with live gcloud; console readback |
| Q2 | Is **Firestore PITR + scheduled backups + delete-protection** enabled? | Internal package live-verified these *absent* on 2026-06-11. Single region/project. | Availability/recovery (T-CL-1) | `scripts/ops/verify-firestore-disaster-recovery.sh` with creds |
| Q3 | Are the **alert channels** real/verified (not the historical NXDOMAIN domain)? | Detection/response depends on a channel that actually delivers. | Detect/Respond | `ops-alerts-gate.mjs`; console |
| Q4 | Current **Remote Config live values**: `computer_use_kill_switch`, `*_attestation_required`, `computer_use_control_seal_enabled`, `media_frame_aead_enabled`, `signal_at_rest_*_enabled`, `hermes_iroh_hosted_relay_url`, `media_kill_switch`. | Several controls are flag-gated; some RC paths historically fail **open** on fetch failure. | C14, kill-switch behavior | Remote Config console export |
| Q5 | Which **Functions revision is live**? Are the HEAD fixes (PoP, sealed-write, backfill, rotation) actually deployed? | Diligence found prod pinned to an older revision with a wedged deploy lane. | All cloud claims | `gcloud functions describe` / deploy history |
| Q6 | **IAM/KMS**: which service accounts can decrypt provider-credential Secret Manager envelopes / read the buckets? | C10 is “backend-decryptable by design” — IAM is the *actual* confidentiality boundary. | C10, T-AZ | IAM policy + KMS keyring audit |
| Q7 | **Branch protection** live state: required checks, `enforce_admins`, environment-protection on `release`/`production`. | Solo-operator + direct-push can bypass PR gates (T-SC-03/17). | Supply chain | `scripts/ops/verify-github-governance.sh`; GitHub API |
| Q8 | Has the **privacy backfill** converged (legacy plaintext rows + legacy attachment **Storage objects** purged)? | C2/C3 caveats hinge on legacy plaintext that the backfill strips on a 24h lag — and no code purges legacy plaintext Storage *objects*. | C2, C3, T-ATT | Production Firestore + Storage data scan; `privacy_reseal_state/current.resealEpoch` |
| Q9 | Does Firebase Hosting → Cloud Run **forward the `x-obb-pop-*` headers** intact? | If stripped, PoP is unenforceable end-to-end (fails closed, but the control is moot). | C4 | Live request trace / Hosting rewrite config |
| Q10 | Is **bucket `burnbar-hosted-mcp-bodies-*`** Firebase-rules-linked or IAM-only? | `storage.rules` deploys to the default bucket; an override bucket may bypass rules. | T-AZ, attachments | Bucket config / `adminRuntime.ts:20-23` |

## 2. Out-of-repo source (provide to Cure53)

| # | Question | Why |
|---|---|---|
| Q11 | The **Hermes agent runtime** (`~/.hermes/hermes-agent`, vendored, `.pyc` in-repo at pinned `bdb830070`). Does `connect()` refuse to start the `localhost:8642` API server when `API_SERVER_KEY` is unset? The claimed start-guard was not locatable. | The model loop sees plaintext prompts; its source is not fully auditable in-repo. Provide the pinned source. |
| Q12 | The **committed Android iroh AAR** + the normative ratchet spec (`plugins/platforms/burnbar/SECURITY_V4.md`, in the vendored fork). | AAR rebuild-parity and the gateway ratchet are security-critical and not fully in the main tree. |

## 3. Product / design decisions (founder to confirm)

| # | Decision | Recommendation |
|---|---|---|
| Q13 | **SE-P256 vs ed25519 controller custody** in production. If SE-P256 is live, a class of high-risk grants ship with **no explicit single-use proof** (the SE signature substitutes). | Decide whether SE-signature-as-presence is acceptable for shell/desktop classes, or require the explicit per-op proof regardless of key kind (close the cloud/Mac divergence). |
| Q14 | **Trusted/YOLO mode** auto-dispatch of scope-allowed high-impact actions. | Confirm this is documented, opt-in, and that real scope allow-rules are narrow; consider a hard re-approve for high-impact classes even in Trusted (currently unimplemented). |
| Q15 | **Local DB at-rest** (SQLCipher codec status at HEAD). | If the codec still isn’t linked, keep the “plaintext on disk, protected by file permissions; at-rest encryption pending” copy; do not say “encrypted database.” |
| Q16 | **No surviving-trusted-device** revocation case (old key never retired). | Decide the UX: must warn the user that revocation did not re-key. |
| Q17 | **Solo-operator policy** vs `enforce_admins` toggling. | Either codify the exception process or stop the practice; it currently contradicts `SOLO_OPERATOR_POLICY.md`. |

## 4. Verification owed to this package (re-verify on current tree)

- The exact **CU tool-result return path** wrapping (display-mangling limited one grep; confirm a clean read shows every tool result wrapped) — A3.
- **At-rest envelope freshness** (RR-8): confirm no doc-id+revision binding has landed (same-path replay still possible).
- **P0-6 privileged-input socket rework** final state vs the stale `PRIVILEGED_SOCKET_AUTH.md` — re-run the red-team evidence.
- Whether any deployed callable **blocks old-key writes** while a rotation requirement is pending (C5 window bounding).
