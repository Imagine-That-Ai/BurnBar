# BurnBar AGPL Release Review Packet

This packet is the counsel-facing release checklist for a Signal-enabled
BurnBar release. It is not an approval record and must not be used to mark the
`legal_release_review` readiness gate complete. The gate is complete only when
external counsel returns an approved JSON evidence record that validates with:

```bash
python scripts/ci/check_agpl_legal_release_review.py <review-artifact>.json --repo-root .
```

Do not market a Signal-enabled BurnBar release as fully cleared until that
approved record exists and the runtime-readiness manifest is `ready`.

## Current Release Boundary

- BurnBar shipped product: AGPL-3.0-only product lane with
  Signal/libsignal/SPQR-backed E2EE.
- Nous/Hermes upstream PR: MIT-compatible encrypted gateway hardening only. It
  must not include Signal/libsignal/SPQR implementation code or AGPL backend
  imports.
- Current readiness is intentionally fail-closed while
  `hermes_gateway_write_path` or `legal_release_review` remains `not_ready`.

## Required Review Scope

Counsel approval must cover each item exactly enough for the validator to prove
the release scope was reviewed:

- AGPL-3.0-only product license
- Signal/libsignal/SPQR product dependency
- corresponding source for shipped apps
- hosted gateway network source obligations
- app store and commercial distribution terms
- MIT-compatible Nous/Hermes upstream boundary

## Required Distribution Channels

The approval record must cover every distribution channel used by the release:

- Apple App Store and TestFlight
- Google Play
- direct download
- hosted gateway network service
- commercial distribution

## Required Artifacts For Counsel

Counsel should review the exact files listed below for the release revision and
then include the same repo-relative paths in `reviewedArtifacts`:

- `.github/workflows/license-posture.yml`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`
- `docs/legal/SOURCE_AVAILABILITY.md`
- `docs/legal/DEPENDENCY_LICENSE_MANIFEST.md`
- `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md`
- `docs/legal/agpl-release-review.evidence.template.json`
- `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md`
- `package.json`
- `pyproject.toml`
- `scripts/ci/check_burnbar_license_posture.py`
- `scripts/ci/check_libsignal_runtime_readiness.py`
- `scripts/ci/write_burnbar_source_provenance.py`
- `scripts/verify_burnbar_mit_pr_clean.py`
- `third_party/libsignal/runtime-readiness.json`

The reviewer should also inspect the release-specific runtime evidence named by
`third_party/libsignal/runtime-readiness.json`, including gateway migration-drain
evidence and the Signal-required rollout runbook for hosted gateway releases. If
the live gateway evidence still shows Signal-required mode disabled, legacy
relay-envelope records, unreadable records, or only a dry-run drain plan, the
release remains operationally not ready even if this packet has been reviewed.

## Approval Record Requirements

The approval record must be a JSON object matching
`docs/legal/agpl-release-review.evidence.template.json` with:

- `reviewStatus` set to `approved`;
- `reviewerRole` set to `external_counsel`;
- a non-empty `reviewedAt` timestamp and counsel identifier;
- the full required scope, distribution channels, and reviewed artifacts above;
- release-decision notes that record the approval boundary.

Placeholder disclaimers such as "not legal advice" are rejected by the
validator. Internal engineering review is not enough for this gate.
