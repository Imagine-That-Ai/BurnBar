# Third-Party Notices

This file records third-party components and notices that must travel with
OpenBurnBar source releases, binary releases, and hosted-service source offers.
It complements `THIRD_PARTY.md`, which covers bundled brand/logo assets and
operational dependency risk notes.

## Nous Hermes / MIT-Origin Code

The Hermes Agent upstream contribution lane remains MIT-compatible. BurnBar
product-only AGPL/libsignal release materials must not be included in Nous/Hermes
MIT PRs.

## Signal / libsignal / Sparse Post-Quantum Ratchet

- Upstream: `https://github.com/signalapp/libsignal`
- Pinned tag: `v0.94.4`
- Pinned tag object: `03c449017b57eccbda715b8b018dce5dff603ac6`
- Pinned source commit: `46d867c986f66201e34e7ae20ce423eec742bf3f`
- License: `AGPL-3.0-only`
- Node artifact: `@signalapp/libsignal-client@0.94.4`
- Node integrity: `sha512-ZkZN3Vy+yK4X+qx13nrW+Ve4ofIvxW9QQ22YS7uL76Cls5y2tcrXWQJc5l8lFVOZ7zctsGHp38ikbcJOMeHwxg==`
- Android artifacts: `org.signal:libsignal-client:0.94.4` and
  `org.signal:libsignal-android:0.94.4` from
  `https://build-artifacts.signal.org/libraries/maven/`

OpenBurnBar uses the official Signal-maintained libsignal distribution for the
Signal Protocol adoption path. The repository-wide AGPL-3.0-only license means
future libsignal-linked BurnBar artifacts do not require a separate scoped
license boundary. Legal approval is still required before shipping public
libsignal-linked binaries or hosted services. Runtime adoption is tracked
separately in `third_party/libsignal/runtime-readiness.json`; do not treat this
notice as proof that all private-domain writes already use libsignal.

## Dependency License Reports

Release builds must include dependency license evidence for the ecosystems they
ship:

- npm packages: package lockfiles plus generated SBOM/license report
- Swift Package Manager packages: `Package.resolved` plus generated SBOM/license
  report
- Cargo crates: `Cargo.lock` plus generated SBOM/license report
- Android Gradle packages: Gradle lock/dependency report where applicable
- Extension packages: package lockfiles plus generated SBOM/license report

Do not remove upstream license files, acknowledgement files, or attribution
comments from vendored artifacts.
