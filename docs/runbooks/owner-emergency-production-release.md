# Owner-emergency production release

Use this lane only when the release owner explicitly authorizes a public release
whose exact tag is covered by the structured owner-attestation packet, while one
or more product runtime-readiness gates remain intentionally deferred.

This is not a declaration that the deferred runtime is ready. The normal
production lane remains fail-closed and continues to require `status: ready` plus
a cryptographically verified external-counsel packet.

## Preconditions

- The release commit is the current protected `main` tip and has passed the
  required merge/CI gates.
- `launch-evidence/latest-agpl-store-legal-packet.json` has
  `owner_attested_soft_approval`, names the exact release tag, and passes the
  owner-emergency validator.
- The release owner has explicitly authorized both the release and acceptance of
  the recorded runtime hold.
- `python3 scripts/ci/check_burnbar_release_preflight.py
  --allow-owner-emergency-approval --allow-owner-emergency-runtime-hold
  --expected-release-tag <tag>` passes on the exact commit.
- A production dry-run for the exact final `main` SHA succeeds before the tag is
  created.

## Procedure

1. Dispatch `Deploy Production (Cloud Functions)` from `main` with
   `dry_run=true`, `candidate_sha=<exact-main-sha>`, and the future tag.
2. Verify that run succeeds, then create and push the immutable `v*` tag at that
   exact SHA.
3. Dispatch the workflow manually from the tag with:
   - `dry_run=false`
   - `tag=<same-tag>`
   - `owner_emergency_release=true`
   - `domain_core_profile=public-production`
4. The resolver rejects the emergency switch on dry-runs and only observes it on
   `workflow_dispatch`; normal tag-push deploys continue to use strict preflight.
5. Require the deploy and post-deploy health jobs to pass. Verify
   `healthReady.source.commit` equals the tag commit and `healthReady.version`
   equals the tag.
6. Re-run `node scripts/commercial-launch-gate.mjs` and retain its output.

## Audit boundary

The workflow summary records whether `owner_emergency_release` was selected, and
the immutable tag binds the run to the owner-attestation packet's release tag.
The runtime-readiness manifest must remain truthful (`not_ready`) until all of its
required gates have real evidence. Do not edit pending gates to make this lane
pass.

This lane differs from
[`functions-break-glass.md`](functions-break-glass.md): it remains inside the
reviewed tag-bound deployment workflow, uses WIF/OIDC, produces normal deployment
evidence, and runs the post-deploy health gate. Break-glass is reserved for a
live production incident when the normal workflow itself is unavailable.
