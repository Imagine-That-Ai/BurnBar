# Source Availability

This page is the source-availability contract for every Signal-enabled BurnBar
build and hosted service. It records how BurnBar provides corresponding source
for AGPL-covered releases.

## Signal-enabled BurnBar build

A Signal-enabled BurnBar build must publish the exact repository commit, build
scripts, dependency lockfiles, notices, and generated runtime evidence needed to
rebuild the covered work. The libsignal runtime-readiness manifest at
`third_party/libsignal/runtime-readiness.json` is part of the release packet, but
it is not legal approval and it is not launch authorization by itself.

## MIT Upstream Boundary

The Nous/Hermes MIT PR path remains separate from the BurnBar shipped product.
The MIT upstream boundary checker prevents AGPL-only Signal/libsignal product
materials from leaking into upstream Hermes Agent contributions.

## Release documents

The source packet must include:

- `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md`
- `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md`
- `THIRD_PARTY_NOTICES.md`
- `Vendor/libsignal/LICENSE`
- `third_party/libsignal/runtime-readiness.json`

Generate release provenance with:

```bash
python scripts/ci/write_burnbar_source_provenance.py --output artifacts/source-provenance/burnbar-source-provenance.json
```

Run the final product release gate with:

```bash
python scripts/ci/check_burnbar_release_preflight.py
```

That gate must pass before publishing a Signal-enabled BurnBar release. It fails
closed while runtime readiness is incomplete, source provenance is dirty or
invalid, or external-counsel approval is missing.
