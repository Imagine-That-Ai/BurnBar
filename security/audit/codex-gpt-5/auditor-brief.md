# Auditor Brief

## Scope

This package covers commit `0e0b063b27e39ad8cd1210ee829c2c7de28db620` on `origin/main` and is namespaced as `codex-gpt-5`.

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

## Reviewer Entry Points

- `README.md`
- `AGENTS.md`
- `docs/security/`
- `functions/`
- `firestore.rules`
- `OpenBurnBarDaemon/`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
- `services/hosted-mcp/`
- `.github/workflows/`

## Suggested Commands

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

See `findings.md`. Highest priority: FINDING-001.

