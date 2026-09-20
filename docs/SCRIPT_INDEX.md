# scripts/ index (Phase 4)

Do not add a new `scripts/ci/*.sh` without listing it here.

| Script | Door |
|---|---|
| `scripts/ci/verify-callable-logging.sh` | onCall + onRequest wrap |
| `scripts/ci/check-feature-flag-registry.sh` | `config/feature-flags.json` |
| `scripts/ci/check-twin-typenames.sh` | Mac/iOS twin type names |
| `scripts/ci/verify-dependabot-config.mjs` | Dependabot coverage |
| `scripts/debt/check-string-any-boundary-budget.sh` | `[String: Any]` including Core/Daemon |
| `scripts/debt/check-swift-file-size-budget.sh` | Swift 1500-line target |
| `scripts/debt/check-rpc-method-freeze.sh` | RPC method table + v2 in supported |
| `scripts/debt/check-domain-core-freeze.sh` | Rust domain-core adapter freeze |
| `scripts/debt/check-parser-twins.sh` | AgentLens/Core parser twins |
| `scripts/debt/check-singleton-budget.sh` | Settings/Account + `static let shared` |
| `scripts/debt/check-xctskip-budget.sh` | XCTSkip second quarantine |
| `scripts/debt/check-privacy-public-budget.sh` | `privacy: .public` interpolations |
| `scripts/debt/check-kernel-sharedmodels-purity.sh` | Kernel SharedModels UI-import deny-gate |
| `scripts/debt/check-sqlite-writer-ownership.sh` | Dual-writer sqlite freeze |
| `scripts/debt/check-video-encoder-isolation.sh` | VideoEncoder off MainActor |
| `scripts/debt/check-settings-protocol-split.sh` | SettingsManagerProtocol domain slices |
| `scripts/ci/verify-vendor-xcframework-checksums.sh` | Vendor xcframework SHA-256 |
