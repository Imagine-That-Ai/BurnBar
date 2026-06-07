# Third-Party Notices

BurnBar's main shipped product is licensed under AGPL-3.0-only. This notice
preserves attribution for third-party and upstream components that BurnBar
includes, adapts, vendors, or builds against.

This file is not a replacement for the referenced license texts. When a
component ships with its own `LICENSE`, `NOTICE`, acknowledgments, or source
offer, keep that material with the distribution.

## BurnBar Product Code

- License: AGPL-3.0-only.
- Scope: the main shipped BurnBar product tree, including Signal/libsignal-backed
  E2EE integrations and BurnBar product packaging.
- License text: [LICENSE](LICENSE).

## Nous Hermes / MIT-Origin Code

- License: MIT.
- Copyright: Copyright (c) 2025 Nous Research, where present in upstream
  Hermes files.
- Scope: Hermes-origin agent, gateway, plugin, CLI, and supporting code that
  BurnBar carries forward or modifies.
- Notice: MIT-origin copyright and permission notices must be preserved in
  source distributions and any generated third-party notice bundle.

## OpenBurnBar MIT-Compatible Helper Packages

- `packages/e2ee-backend-policy/`: first-party MIT-compatible backend selection
  policy. It names the gateway v5 and BurnBar Signal backend IDs and enforces
  fail-closed selection rules, but it does not import, link, or depend on
  libsignal. This package is safe to reuse in the MIT upstream seam.

## Signal / libsignal / Sparse Post-Quantum Ratchet

- License: AGPL-3.0-only.
- Copyright: Signal Messenger LLC and contributors, as recorded by upstream
  Signal source files and acknowledgments.
- Vendored source: `Vendor/libsignal/`.
- Upstream project: https://github.com/signalapp/libsignal
- SPQR dependency: `SparsePostQuantumRatchet`, referenced by Signal's
  `Vendor/libsignal/Cargo.toml`.
- Product role: official Signal/libsignal-backed E2EE and post-quantum ratchet
  implementation path for BurnBar product builds.

## OpenBurnBar Signal Facades

- `packages/libsignal-bridge/`: AGPL-backed wrapper around
  `@signalapp/libsignal-client`.
- `packages/libsignal-protocol/`: BurnBar Signal-protocol facade and tests.
- `packages/signal-envelope-contracts/`: BurnBar Signal-envelope schemas and
  canonicalization helpers used by product services.

These packages are part of the BurnBar AGPL product lane and must not be copied
into the MIT-only Nous/Hermes upstream PR path.

The machine-readable runtime readiness gate lives at
`third_party/libsignal/runtime-readiness.json`. Keep it fail-closed until every
native/runtime, hosted write-path, source-provenance, and legal-release gate has
current evidence.

Generate the release provenance record with
`python scripts/ci/write_burnbar_source_provenance.py --output <release-artifact>.json`
when preparing a Signal-enabled build or hosted-gateway release.

## Apache / MIT / BSD Dependencies

BurnBar also depends on permissively licensed dependencies across Python, Node,
Swift, Kotlin/Android, and Rust build surfaces. Preserve their upstream notices,
license files, and acknowledgments in generated distribution bundles.

Known examples in this tree include:

- `plugins/security-guidance/`: Apache-2.0, with its own `LICENSE` and `NOTICE`.
- `plugins/hermes-achievements/`: MIT, with its own `LICENSE`.
- Swift Package Manager, Gradle, npm, and Python dependencies resolved during
  platform builds.

## Compliance Rule For Upstream Contributions

The Nous/Hermes upstream PR lane is MIT-only. It must not include:

- `Vendor/libsignal/`
- `@signalapp/libsignal-client`
- `org.signal:libsignal-client` or `org.signal:libsignal-android`
- `SparsePostQuantumRatchet`
- first-party BurnBar libsignal bridge packages

Use `scripts/verify_burnbar_mit_pr_clean.py` before preparing a Nous/Hermes PR.
