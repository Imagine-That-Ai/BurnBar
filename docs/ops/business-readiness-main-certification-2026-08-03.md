# Main CI certification record (2026-08-03)

This PR exists solely to drive a full merge-group certification of the current
`main` tip after the business-readiness stack landed via admin squash merges.

## Why

`BurnBar CI Gate` on bare `workflow_dispatch` against `main` cannot go green:
most required component checks only fire on `pull_request` / `merge_group`.
The commercial launch gate needs a trusted `BurnBar CI Gate` result bound to
the shipped tree (main tip or exact tree-bound PR head).

## How this PR forces every product lane

A docs-only diff is classified as safe by `scripts/ci/classify-ci-impact.mjs`
(`SAFE_NO_PRODUCT_PATTERNS`), which would let the App, Daemon, and Android
aggregate jobs accept their prerequisites as skipped and pass `BurnBar CI Gate`
without rerunning the product suites. That would not be a real certification.

This record therefore lives under `governance/`, which the classifier treats
as a shared-or-sensitive path (`FULL_PATTERNS`), forcing `full=true` with every
product lane enabled on both the `pull_request` and the `merge_group`
classification runs. The PR additionally carries the `full-ci` label as an
explicit force for the PR-event run. The merge-group `BurnBar CI Gate` result
for this PR is a genuine full-lane certification of the merged tree.

## Post-merge requirements (before any real tag deploy)

1. Re-run both dry-run planes (`deploy-production` and `deploy-cloud-run`)
   against the post-merge `main` commit so fresh attestations are published for
   the exact SHA that will be tagged. The `v1.0.30` dry-run success referenced
   below was bound to the pre-merge SHA;
   `scripts/ci/release-dry-run-attestation.mjs verify` (invoked by
   `.github/workflows/deploy-production.yml` on real tag deploys) rejects
   missing or stale SHA/tag attestations, so tagging the newly certified `main`
   without re-attestation fails before deployment, and tagging the old SHA
   would not ship the tree this PR certifies.
2. Re-run `node scripts/commercial-launch-gate.mjs`.

## Related

- Production Functions dry-run: success for candidate `v1.0.30` plumbing
  (pre-merge SHA; superseded per the re-attestation requirement above)
- Real tag deploy additionally blocked on libsignal runtime readiness +
  counsel approval
