# Re-run Instructions — Opus 4.8 1M lane

## How to re-run this audit
1. **Mode:** next run should be `DELTA_REVIEW` against this package (`security/audit/opus-4-8-1m/`). Compare current `git rev-parse HEAD` to `audit-state.json.commit` (`60faa70227`).
2. **Preserve IDs:** keep `OPUS-F-NNN` / `OPUS-U-NNN` stable; never renumber. Cross-reference the authoritative `M-001…M-040` (06-14) lineage and the `LB/P0/NB/CG` (06-11) lineage.
3. **Lane hygiene (important):** multiple audit lanes run this prompt concurrently and the repo's own `HANDOFF_REMAINING_RISKS_2026-06-14.md` documents lanes clobbering each other via `git clean`/`git checkout` sweeps. **Write only under your own model-named subdir** (`security/audit/<model>/`). Do not modify `security/audit/*` top-level files or `security-audit/`. The `Vendor/OpenBurnBarIroh.xcframework` is gitignored — a `git clean -fdx` by another lane will wipe it; rebuild with `scripts/build-iroh-xcframework.sh`.

## Delta checklist for the next run
Re-verify each previously-fixed item still holds (regression guard):
- P0-6 privileged input, LB-2 updater, LB-5 Stripe watermark, M-005 session_logs allowlist, M-025 BOLA execution, CG-1 coverage gate, qa.yml secrets, deploy submodule checkout.

Re-check open findings: OPUS-F-001..014 status; confirm any newly-closed with a regression test.

## Gates to enforce / re-run locally
```
node scripts/ci/check-privacy-invariants.mjs        # I1-I5
node scripts/ci/check-privacy-invariants.test.mjs   # self-test (non-vacuous)
cd firestore-rules-tests && npm run test:ci          # owner-scoping, secret denylist, AAD
npm --prefix functions run test:unit                 # BOLA tier-2 + billing
node scripts/ci/verify-github-action-pins.mjs        # SHA pins
bash scripts/ci/check-no-suppressions.sh             # suppression meta-gate
```

## Resolve the operational unknowns (cap drivers — see open-questions.md)
The score cannot rise above the low-80s until OPUS-U-001..005 are confirmed with live evidence:
```
gcloud firestore fields ttls list --project=burnbar           # OPUS-U-001
# Firebase console → App Check → Firestore enforcement         # OPUS-U-002
dig openburnbar.app; gcloud beta monitoring channels list      # OPUS-U-003
# healthReady version vs HEAD; gcloud functions describe        # OPUS-U-004
# GitHub branch-protection API (required checks/reviews/admins) # OPUS-U-005
```

## Confidence gate (maturity)
Not mature until: 0 unresolved Critical/High; no catastrophic/critical caps; core claims evidence-backed (close OPUS-F-001 or narrow CLAIM-10); sensitive logging reviewed (done); object-authz tested (done); **score stable across ≥2 runs** (this is run 1 — re-run to lift the −2 hold); remaining unknowns owned/closed.
