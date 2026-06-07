# Dependency License Manifest

This manifest separates the BurnBar shipped product from the Nous/Hermes MIT PR
lane.

## BurnBar shipped product

The BurnBar shipped product is AGPL-3.0-only and includes Signal libsignal
materials only when the Runtime readiness manifest, AGPL release review packet,
and Gateway Signal-required rollout runbook all show the relevant gates are
complete.

## Nous/Hermes MIT PR

The Nous/Hermes MIT PR lane must remain MIT-compatible and must not include
BurnBar product-only AGPL/libsignal release artifacts.

## Review artifacts

- Signal libsignal license and pin evidence: `Vendor/libsignal/LICENSE`
- Runtime readiness manifest: `third_party/libsignal/runtime-readiness.json`
- AGPL release review packet: `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md`
- Gateway Signal-required rollout runbook:
  `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md`
