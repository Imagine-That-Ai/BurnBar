# Phase 1 Security Register

This is the live closure ledger for the debt-free plan's Phase 1 items: the
register debt that can hurt users. Historical reports stay immutable; this file
records current status, proof commands, and the next evidence needed.

## Status Snapshot

| ID | Status | Current proof | Remaining work |
| --- | --- | --- | --- |
| NB-1 | **Closed 2026-06-13** | `node scripts/ops/check-ops-alerts.mjs` exits 0 and now verifies actual notification-channel objects, not just channel counts. Live GCP readback shows channel `projects/burnbar/notificationChannels/5012565067290551244` is enabled, type `email`, display name `OpenBurnBar Ops - operator email (deliverable)`, and address `alberto8793@gmail.com`. The repo gate rejects the historical black-hole address `support@openburnbar.app` by default. | Keep `OPENBURNBAR_DISALLOWED_ALERT_EMAILS` updated if any other dead support addresses are discovered. |
| NB-2 | **Closed 2026-06-13** | `.github/workflows/deploy-production.yml` uses `actions/checkout` with `submodules: recursive`, then re-runs `git submodule update --init --recursive` after checking out the release tag so `Vendor/libsignal` matches the tag gitlink before provenance preflight. `docs/runbooks/functions-break-glass.md` documents the bounded emergency lane. | Next production tag must still prove the deploy lane end-to-end and postdate the LB-5/P0-7 code fixes. |
| SOTA release attestations | **Open** | `release.yml` attests SBOM, VEX, checksums, DMG, ZIP, source archive, appcast, and latest feed with cosign. New verifier: `scripts/ci/verify-release-attestations.sh <tag>`. Current latest release `v0.1.2-beta.12` predates available GitHub attestations for the DMG/ZIP, so this box cannot be checked yet. | Cut the next release through current `release.yml`, then run `scripts/ci/verify-release-attestations.sh <tag>` and attach output before checking the SOTA signoff box. |

## Proof Commands

```bash
# NB-1: required ops policies are enabled, metric-complete, and wired to live channels.
node scripts/ops/check-ops-alerts.mjs

# NB-1: inspect the concrete operator channel.
gcloud alpha monitoring channels describe \
  projects/burnbar/notificationChannels/5012565067290551244 \
  --project burnbar \
  --format=json

# NB-2: deploy lane keeps the release tag's submodule contents available.
rg -n "submodules: recursive|git submodule update --init --recursive" \
  .github/workflows/deploy-production.yml

# SOTA release-attestation box, after the next release.
scripts/ci/verify-release-attestations.sh vX.Y.Z
```

## Closure Rules

- "Has notification channels" is not enough. The gate must prove referenced
  channels exist, are enabled, and do not point at known black-hole addresses.
- Historical diligence reports are evidence, not the current ledger. Close or
  reopen items here with dated proof.
- Operational boxes stay open when the only proof is intent, planned UI review,
  or a release that predates the relevant gate.
