# BurnBar Dependency License Manifest

This manifest records the load-bearing license posture for BurnBar's E2EE
strategy. It is intentionally small and auditable; generated SBOMs may add more
detail, but they should not contradict this file.

| Component                          | Location                                       | License                             | BurnBar Lane                     |
| ---------------------------------- | ---------------------------------------------- | ----------------------------------- | -------------------------------- |
| BurnBar shipped product            | Root product tree                              | AGPL-3.0-only                       | Product                          |
| Nous Hermes-origin code            | Gateway/agent/plugin code copied from Hermes   | MIT                                 | Product, attribution preserved   |
| Signal libsignal                   | `Vendor/libsignal/`                            | AGPL-3.0-only                       | Product only                     |
| Signal SPQR dependency             | `Vendor/libsignal/Cargo.toml`                  | AGPL-3.0-only via Signal dependency | Product only                     |
| OpenBurnBar Signal bridge          | `packages/libsignal-bridge/`                   | AGPL product lane                   | Product only                     |
| OpenBurnBar Signal protocol facade | `packages/libsignal-protocol/`                 | AGPL product lane                   | Product only                     |
| Signal envelope contracts          | `packages/signal-envelope-contracts/`          | AGPL product lane                   | Product only                     |
| E2EE backend policy seam           | `packages/e2ee-backend-policy/`                | MIT                                 | Product and Nous PR allowed      |
| Runtime readiness manifest         | `third_party/libsignal/runtime-readiness.json` | Product gate metadata               | Product only                     |
| Gateway drain evidence validator   | `scripts/ci/check_hermes_gateway_migration_drain.py` | Product release gate metadata       | Product only                     |
| Gateway drain evidence collector   | `scripts/ci/write_hermes_gateway_migration_drain_evidence.js` | Product release gate metadata       | Product only             |
| Gateway legacy drain operation     | `scripts/ci/drain_hermes_gateway_legacy_records.js` | Product release gate operation      | Product only                     |
| Gateway Signal-required rollout runbook | `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md` | Product release gate operation      | Product only       |
| AGPL release review packet         | `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md` | Product release gate metadata       | Product only                     |
| AGPL release review template       | `docs/legal/agpl-release-review.evidence.template.json` | Product release gate metadata       | Product only               |
| Legal release review validator     | `scripts/ci/check_agpl_legal_release_review.py` | Product release gate metadata       | Product only                     |
| CloudVault at-rest evidence validator | `scripts/ci/check_cloudvault_at_rest_runtime.py` | Product release gate metadata       | Product only                  |
| Native Signal runtime evidence validator | `scripts/ci/check_native_signal_runtime_evidence.py` | Product release gate metadata       | Product only                |
| MIT v5 gateway framework           | `gateway/crypto`, `plugins/platforms/burnbar`  | MIT-compatible upstream lane        | Nous PR allowed when Signal-free |

## Claims Matrix

| Lane                 | Allowed Claim                                                                   | Forbidden Claim                                             |
| -------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| BurnBar AGPL product | Signal/libsignal-backed E2EE and post-quantum recovery lane                     | Absolute quantum security                                   |
| Nous/Hermes MIT PR   | MIT-compatible encrypted gateway hardening with replay and downgrade resistance | Signal-backed, Signal-class, post-quantum recovery, PQ3-equivalent, or absolute quantum security |

## Verification

- Product posture: `python scripts/ci/check_burnbar_license_posture.py`
- Runtime readiness: `python scripts/ci/check_libsignal_runtime_readiness.py`
- Gateway drain evidence generation: `node scripts/ci/write_hermes_gateway_migration_drain_evidence.js --project-id <project> --deployed-commit <sha> --source-location <https-url> --runtime-mode-from-gcloud --output <artifact>.json`
- Gateway Signal-required rollout: `docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md`
- Gateway legacy drain dry-run: `node scripts/ci/drain_hermes_gateway_legacy_records.js --project-id <project> --output <artifact>.json`
- Gateway drain evidence validation: `python scripts/ci/check_hermes_gateway_migration_drain.py <artifact>.json --repo-root .`
- Legal release review packet: `docs/legal/AGPL_RELEASE_REVIEW_PACKET.md`
- Legal release review: `python scripts/ci/check_agpl_legal_release_review.py <review-artifact>.json --repo-root .`
- CloudVault at-rest evidence: `python scripts/ci/check_cloudvault_at_rest_runtime.py <artifact>.json`
- Native Signal runtime evidence: `python scripts/ci/check_native_signal_runtime_evidence.py <artifact>.json --platform <swift|kotlin_android>`
- Source provenance inputs: `python scripts/ci/write_burnbar_source_provenance.py --check`
- Source provenance release preflight: `python scripts/ci/write_burnbar_source_provenance.py --release-check`
- MIT upstream boundary: `python scripts/verify_burnbar_mit_pr_clean.py --base <nous-base-ref>`
