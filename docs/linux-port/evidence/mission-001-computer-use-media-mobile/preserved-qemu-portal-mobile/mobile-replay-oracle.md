# Mobile Replay Oracle Candidate

This artifact documents the replay oracle beside the live mobile transcript imported or produced in this run.

## Contract Fit

VAL-MOBILE-001 evidence allows mobile simulator/device traces or protocol replay traces. This replay is stronger than a schema-only replay because it combines product-generated mobile pairing/auth signatures, product mobile panic audit verification, additive wire-frame diffing, and media/control frame fixtures tied to Linux peer metadata.

## Covered Behaviors

- Pairing/auth signatures valid: true
- Approval, deny, input, media viewer, and panic frame set present: true
- Product mobile panic audit fully verified: true
- Backward-compatible wire diff: true
- Live mobile surface available: true
- Live Linux peer transcript produced: true
- Linux peer replay transcript bound to product artifacts: true

## Boundary

The replay remains compatibility evidence; the pass decision must come from `mobile-live-surface-probe.json` and `linux-peer-mobile-control-transcript.json` raw live transcript fields.

Candidate acceptable for contract text: true

## Source Artifacts

- `mobile-pairing-auth-evidence.json`
- `computer-use-mobile-protocol-replay.json`
- `computer-use-media-codec-trace.json`
- `product-computer-use-evidence.json`
- `mobile-live-surface-probe.json`
- `linux-peer-mobile-control-transcript.json`
