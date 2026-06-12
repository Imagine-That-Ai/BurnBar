# Security Claims Register

This register is the claim boundary for public copy, release notes, app-store copy, and reviewer packets. If product language conflicts with this file, this file wins until code and live evidence prove otherwise.

## Current Accurate Claims

| Surface | Allowed claim | Required caveat / proof |
|---|---|---|
| Local macOS database | SQLCipher-backed builds fail closed when encryption is enabled and an existing plaintext database is present. | Users with legacy plaintext databases need a migration path before encrypted startup; the app must not silently continue plaintext. |
| Cloud Vault sealed payloads | Current high-risk CloudVault writers bind new AES-GCM payloads to the Firestore uid, collection, document id, and field where they are stored. | Legacy global-AAD rows remain readable for migration. Same-path stale-document replay by a malicious storage service is not cryptographically eliminated without a monotonic revision/read-state protocol. |
| Signal at-rest envelopes | Signal at-rest payloads are path-bound and sender-authenticated where enabled. | Do not call this whole-product "Signal-quality privacy"; metadata, search indexes, and legacy fallback surfaces remain outside that claim. |
| Pensieve / semantic search | Pensieve content bodies and snippets are sealed; token and semantic indexes are keyed/opaque rather than plaintext. | Cloaked vectors preserve similarity geometry for search. The server can still observe cluster structure, access patterns, source facets, timestamps, sizes, and result counts. Do not claim "semantic memory is private from us" or "zero-knowledge semantic search." |
| Hosted Remote MCP | Production token verification supports asymmetric Ed25519 bearer tokens, and the local shim uses Keychain by default. | HMAC tokens are a legacy transition path only; plaintext env/file token sources require explicit insecure opt-in. |
| Sentry | Functions Sentry initialization scrubs request bodies, cookies, query strings, secret-like headers, breadcrumbs, contexts, and extras before capture. | Pattern scrubbers are not a license to log secrets. New logging fields still need review. |
| Remote Config kill switches | Computer Use and media gates default to killed/closed when Remote Config is absent or fetch fails. | Operators must explicitly publish remote false values to open these features. |
| Firestore disaster recovery | Production readiness requires live Admin API proof of PITR, delete protection, and at least one backup schedule. | Run `bash scripts/ops/verify-firestore-disaster-recovery.sh`; documentation-only evidence is not accepted. |
| GitHub governance | Production readiness requires live GitHub API proof of main branch protection and release/production environment protection. | Run `bash scripts/ops/verify-github-governance.sh`; screenshots or remembered settings are not accepted. |

## Banned Shortcuts

- "Zero-knowledge" unless the sentence immediately names the remaining metadata/index/vector leakage.
- "Server learns nothing" or "server searches without reading it."
- "Signal-quality privacy" for the whole product.
- "Semantic memory is private from us."
- "Revocation immediately makes old data safe."
- "Encrypted database" when SQLCipher is disabled or when a legacy plaintext database has not been migrated.

## Review Rule

Any new claim about confidentiality, replay resistance, revocation, disaster recovery, governance, or production readiness must cite one of:

- a test or CI gate in this repository,
- a live verifier command under `scripts/ops/`,
- a signed release/provenance artifact,
- or an explicit accepted residual in this register.
