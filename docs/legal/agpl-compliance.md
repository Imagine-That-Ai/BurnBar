# AGPL Compliance

OpenBurnBar future source releases, app binaries, extension packages, hosted
services, and release artifacts are licensed as `AGPL-3.0-only`.

This is an operational compliance runbook, not a substitute for legal advice.
Counsel must approve any public App Store, Mac App Store, direct-download,
extension-marketplace, npm, Docker, or hosted-service release that links
AGPL-covered dependencies such as official Signal libsignal.

## License Posture

- The root `LICENSE` is the AGPLv3 text.
- `NOTICE` identifies the current project copyright and license.
- `LICENSES/MIT-legacy.txt` preserves the MIT notice that governed historical
  OpenBurnBar snapshots released before the AGPL change.
- New contributions are accepted under `AGPL-3.0-only`; prior MIT attribution is
  preserved.
- Package metadata must say `AGPL-3.0-only` for first-party OpenBurnBar
  packages.

## Corresponding Source

Every binary release and hosted network service must provide a corresponding
source offer that includes enough material for a user to rebuild the exact
covered work:

- exact Git commit SHA and tag or build version
- full source tree for the released commit
- root `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, and `LICENSES/`
- build scripts and release scripts used for the artifact
- dependency lockfiles and generated SBOM/license reports
- generated binding steps for libsignal, Swift, Kotlin, Rust, Node, and FFI
  surfaces that are part of the artifact
- deployment notes for hosted services, including environment variables with
  secret values redacted
- checksums for binaries and source archives

Direct-download releases must publish a source tarball next to the DMG/ZIP.
Hosted services must expose source metadata from public health or metadata
endpoints and link to a stable corresponding source page.

## Hosted Service Source Link

Any network-facing BurnBar service must expose the following public metadata in
health or well-known responses:

- `license: "AGPL-3.0-only"`
- `source.repository`
- `source.commit`
- `source.correspondingSource`

Default public source page:

`https://burnbar.ai/legal/source`

Default repository:

`https://github.com/Imagine-That-Ai/BurnBar`

The commit value should come from the deployment environment when available
(`FUNCTION_VERSION`, `GIT_SHA`, `SOURCE_COMMIT`, or equivalent). If the hosting
platform cannot inject the commit, return `"unknown"` rather than fabricating
provenance.

## Release Gates

Before shipping AGPL-covered artifacts:

1. Run `bash scripts/ci/verify-agpl-compliance.sh`.
2. Build the corresponding source tarball with
   `scripts/create-corresponding-source.sh --version <version> --output <path>`.
3. Build the normal artifact and SBOM/license reports.
4. Verify hosted-service health endpoints include source metadata.
5. Complete App Store / Mac App Store legal review for GPL/AGPL compatibility
   before uploading review-bound binaries.
6. Record the exact commit SHA in release metadata and release notes.

## libsignal Adoption Contract

Official Signal libsignal is pinned in `third_party/libsignal/manifest.json` and
listed in `THIRD_PARTY_NOTICES.md`. Runtime migration status is tracked in
`third_party/libsignal/runtime-readiness.json` and can be checked with
`bash scripts/ci/verify-libsignal-runtime-readiness.sh`.

Current status is deliberately fail-closed: the runtime readiness gate must stay
red until official libsignal is the crypto core for new private-domain writes on
all shipping clients and services. Pinning the package is not equivalent to
runtime adoption.

The Node bridge has a protocol harness in `packages/libsignal-bridge` that proves
official libsignal session setup, one-time prekey consumption, Kyber prekey-use
marking, replay rejection, out-of-order Whisper decrypt, and safety-number
identity changes. Treat that as one evidence item toward runtime migration, not
as release approval for platform clients or hosted services.

All Signal-grade private-cloud crypto must route through the shared libsignal
integration layer instead of introducing another home-grown ratchet. Legacy
HPKE/CloudVault envelopes remain readable only for migration. New private-domain
writes may move to Signal-backed envelopes only after the platform bridge,
cross-language vectors, replay rejection, skipped-key limits, safety-number
state, and stale-session repair tests are green.
