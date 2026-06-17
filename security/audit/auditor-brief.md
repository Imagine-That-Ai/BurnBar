# Auditor Brief

## Scope

This package covers the repository at commit `0e0b063b27e39ad8cd1210ee829c2c7de28db620` on `origin/main`.

In scope:

- macOS app and local data protection
- local daemon and HTTP gateway
- Computer Use policy, approvals, and audit
- Firebase Functions callables and public HTTP endpoints
- Firestore and Storage rules
- Cloud Vault crypto and export/delete flows
- hosted MCP and remote MCP local shim
- iOS and Android client security-relevant surfaces
- Stripe billing and webhooks
- logging, Sentry, privacy controls
- CI/CD, release integrity, dependency and secret scanning

Out of scope or not fully repo-verifiable:

- live Firebase/GCP IAM membership
- live Firebase App Check enforcement state
- live GitHub branch protection settings
- live Stripe/Sentry dashboard users
- live Cloud Armor or edge rate-limit policy
- third-party processor retention guarantees

## Product Overview

OpenBurnBar is a local-first and cloud-assisted developer productivity product with desktop/mobile clients, local daemon, hosted MCP, encrypted cloud sync, usage/cost tracking, billing, and agentic Computer Use workflows.

## Setup Guidance for Reviewers

Suggested local review entry points:

- `README.md`
- `AGENTS.md`
- `docs/security/`
- `functions/`
- `firestore.rules`
- `OpenBurnBarDaemon/`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
- `services/hosted-mcp/`
- `.github/workflows/`

Useful commands:

```bash
git rev-parse HEAD
bash scripts/ci/verify-resilience-wiring.sh
bash scripts/ci/check-no-suppressions.sh
cd functions && npm test
cd services/hosted-mcp && npm test
cd OpenBurnBarDaemon && swift test
```

Some tests may require local toolchain setup, Firebase emulator setup, Xcode, Android SDK, or project secrets.

## Key Flows for Adversarial Review

1. Daemon Computer Use start/invoke proof and production verifier wiring.
2. Computer Use approval, trust downgrade, deny-region, audit-chain, panic-halt behavior.
3. Hosted MCP grant issuance, refresh rotation, scope enforcement, local-decrypt resource model.
4. Cloud Vault envelope validation, AAD binding, export sanitizer, signed URL refs.
5. Firestore rules for owner, server-only, secret, audit, remote MCP, and Computer Use paths.
6. Stripe checkout/portal redirect validation and webhook idempotency.
7. Data deletion audit behavior.
8. Production deploy workflow, secret fallback, branch protections, and provenance.

## Known Issues

See `findings.md`. The highest priority issue is FINDING-001.

## Areas Where Adversarial Review Is Desired

- Local daemon threat model under compromised first-party app assumptions.
- Computer Use prompt injection and tool-output injection.
- Hosted MCP token and scope model.
- Cloud Vault claim boundaries and metadata leakage.
- Firestore direct client attack surface under App Check drift.
- CI/CD release and deploy credential model.

## Test Accounts Needed

- Standard user account.
- Pro/entitled user account.
- Suspended/inactive entitlement account.
- Account with cloud-vault/session-log data.
- Account with remote MCP grant.
- Stripe test customer/subscription.
- Mobile approval device pair.

## Open Questions for Auditors

- Is the daemon local-auth proof design sufficient once wired?
- Should deletion fail closed on audit append failure, or is pre-delete audit intent the right product/privacy tradeoff?
- Are Cloud Vault AES-GCM/AAD and local-decrypt MCP claims precise enough for enterprise security review?
- Is the residual 15-minute hosted MCP access token replay window acceptable?

