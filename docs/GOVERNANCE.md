# Governance and Maintainer Expectations

> **Canonical location:** this file. The repo root [`GOVERNANCE.md`](../GOVERNANCE.md) redirects here.

## Current Maintainer

OpenBurnBar is maintained by [@Ajnunezg](https://github.com/Ajnunezg).

## Support tiers

| Tier | Surfaces | Support posture |
|------|----------|-----------------|
| **Core** | macOS app, `OpenBurnBarCore`, daemon, CLI, VS Code extension | Best-effort OSS; tagged releases; security fixes prioritized |
| **Commercial** | iOS 1.0, hosted quota sync, Remote MCP, App Store billing | Launch-gate enforced (`scripts/commercial-launch-gate.mjs`); App Check ENFORCED required |
| **Experimental** | Connectors, mission control, optional cloud sync planes, Computer Use rollout flags | Explicit no-SLA; feature-flagged; may change without deprecation |

macOS remains **beta** (`0.1.3-beta.1`) while commercial mobile/hosted paths finish approval. This is not an “experimental source-only” project — it is a **tiered product** with different readiness bars per surface.

Live branch/environment governance is verified with `bash scripts/ops/verify-github-governance.sh` and is part of production ops-plane verification.

## Decision-making

Single-maintainer project. Design decisions, roadmap priorities, and merge authority rest with the maintainer. Contributions welcome via pull requests; no formal RFC process.

## Releases

- Semantic versioning for tagged macOS releases
- iOS/Android store versions tracked in `project.yml` / Gradle independently
- Release notes extracted per tag via `scripts/tag-release.sh` (not the full `CHANGELOG.md`)

## Security

Security reports handled per [`SECURITY.md`](../SECURITY.md). Computer Use kill switch and budget envelopes are operator-automated — see [`docs/runbooks/computer-use-budget.md`](runbooks/computer-use-budget.md).

## How to help

- Bug reports with reproduction steps
- Tests in active suites (`AgentLensTests/Active/`, mobile/Android CI-gated tests)
- Schema changes via `tools/schema-sync/` (TypeSpec → emit → `check-drift.sh`)
- Documentation fixes with cross-links in [`README.md`](../README.md)

## Future governance

If single-maintainer governance becomes a bottleneck, this document will be revised. Until then, keep it simple.
