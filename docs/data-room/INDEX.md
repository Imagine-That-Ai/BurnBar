# Diligence data room

This index is the compact map for an independent diligence pass. Each row names
one claim, the committed evidence or deterministic check that supports it, the
last verification date, and the accountable owner. A claim is not a release
approval: store, signing, and live-infrastructure facts remain operator-owned.

## Clone / layout

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| The tracked root surface is inventoried and guarded by a shrink-only ratchet. | `governance/root-inventory.json` | 2026-09-01 | W0-11 / Alberto |
| Repository operating conventions and architecture entry points are committed with the source. | `AGENTS.md` | 2026-09-01 | Repository maintainers |

## Claims vs ledgers

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| The mobile parity ledger keeps the product parity claim explicitly false until its evidence floor is complete. | `docs/mobile-parity/mobile-parity-ledger.json` | 2026-09-01 | Mobile parity |
| Windows parity progress is recorded in a dedicated ledger rather than inferred from the macOS release line. | `docs/windows-port/WINDOWS_PARITY_LEDGER.yml` | 2026-09-01 | Windows parity |

## CI health

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| Version surfaces are checked against the first macOS marketing version in `project.yml`. | `--check bash scripts/verify-version-consistency.sh` | 2026-09-01 | Release engineering |
| New lint and type-suppression debt is rejected without an explicit reviewed reason. | `--check bash scripts/ci/check-no-suppressions.sh` | 2026-09-01 | CI maintainers |

## Deploy proof

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| Production and staging deployment boundaries, authentication, and artifact checks are documented. | `docs/runbooks/production-deploy-boundaries.md` | 2026-09-01 | Operations |
| Rollback automation is documented as a bounded operator action rather than an implicit CI fallback. | `docs/runbooks/rollback-automation.md` | 2026-09-01 | Operations |

## Security harness

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| The public tree has a deterministic confidentiality scan that distinguishes sensitive content from secrets. | `--check node scripts/security/scan-internal-content.mjs` | 2026-09-01 | Security |
| The committed product declares AGPL-3.0-only while documenting the MIT-compatible upstream boundary. | `README.md` | 2026-09-01 | Security / legal |

## Supply chain

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| Third-party license and attribution notices are committed for the shipped dependency surface. | `THIRD_PARTY_NOTICES.md` | 2026-09-01 | Release engineering |
| Public supply-chain provenance expectations are documented separately from private credentials. | `docs/security/SUPPLY_CHAIN_PROVENANCE.md` | 2026-09-01 | Security |

## Bus factor

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| Contribution, review, and ownership expectations are available to a new maintainer. | `CONTRIBUTING.md` | 2026-09-01 | Repository maintainers |
| Incident response and escalation duties have a committed operational runbook. | `docs/runbooks/oncall.md` | 2026-09-01 | Operations |

## Depth

| Claim | Evidence path or --check command | Last-verified | Owner |
| --- | --- | --- | --- |
| Historical diligence, security, handover, and technical-debt reports have a stable archive index. | `docs/audits/INDEX.md` | 2026-09-01 | W0-11 / Alberto |
| Technical-debt trend measurements remain a separate, reviewable artifact. | `docs/TECH_DEBT_METRICS.md` | 2026-09-01 | CI maintainers |
