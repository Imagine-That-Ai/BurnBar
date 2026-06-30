# Public macOS Emergency Release

Use this runbook when the public macOS download is hurting users and the normal
signed legal packet is not yet available.

## Normal path

1. Land the release change on `main`.
2. Commit a signed counsel approval packet that passes:
   `python3 scripts/ci/check_agpl_legal_release_review.py <packet>.json --repo-root .`
3. Tag the release with `scripts/tag-release.sh <version>`.
4. Approve the GitHub `release` environment.
5. Wait for the signed, notarized DMG to publish.
6. Update the website download metadata only after the DMG exists.
7. Run `bash scripts/ci/verify-public-macos-download-trust.sh` against the live
   website.

## Emergency owner lane

Only the release owner may use this lane.

1. Record a structured owner attestation in
   `launch-evidence/latest-agpl-store-legal-packet.json`.
2. The packet must name the owner, GitHub owner account, counsel name, approval
   type, release boundary, emergency reason, and follow-up requirement.
3. The release workflow may run:
   `python3 scripts/ci/check_burnbar_release_preflight.py --allow-owner-emergency-approval`
4. Do not add a generic bypass input. Do not conditionally skip the product
   release preflight.
5. Keep production deploy on the strict preflight unless a separate owner
   decision explicitly scopes that deploy.
6. Replace the emergency packet with signed counsel evidence when available.

This lane exists to publish a signed/notarized artifact when users are blocked
by a stale or broken public download. It is not a replacement for the signed
counsel approval process.
