# Script index — OpenBurnBar doors

This is the map of **door scripts**: the commands an agent or human should
run, not the 1,200-file `scripts/` tree. If a task is not in this index,
search before inventing a parallel helper.

## Cheap PR door (merge)

| Door | Command |
|------|---------|
| Fast feedback / typecheck / unit | `.github/workflows/fast-feedback.yml` (CI) |
| Functions lint + wrap/logging | `npm test --prefix functions` and `bash scripts/ci/verify-callable-logging.sh` |
| Core/Daemon focused tests | `./scripts/test-openburnbar-swift.sh` |
| Migrator parity | `node scripts/check-migrator-parity.mjs` |
| Debt ratchets | `scripts/debt/*.sh` (see below) |

Do **not** put AgentLens XCTest or the Full Harness on the merge ticket.

## Nightly / post-merge proof

| Door | Command / workflow |
|------|--------------------|
| Mac app compile + bounded smoke | `.github/workflows/app-pr-gate.yml` (`./scripts/test-openburnbar-app.sh`) |
| Full XCTest corpus | `.github/workflows/openburnbar-pr-harness.yml` |
| Linux desktop matrix | `.github/workflows/linux-nightly.yml` |
| Production ops plane | `.github/workflows/ops-plane-verify.yml` / `bash scripts/ops/verify-production-ops-plane.sh` |
| Functions deploy | `.github/workflows/deploy-production.yml` (break-glass: `docs/runbooks/functions-break-glass.md`) |

Scheduled reds file a per-lane issue via `.github/actions/ops-failure-issue`.

## Debt ratchets (`scripts/debt/`)

| Script | Budget |
|--------|--------|
| `scripts/debt/check-swift-file-size-budget.sh` | `budgets/swift-file-size-baseline.json` |
| `scripts/debt/check-string-any-boundary-budget.sh` | `budgets/string-any-boundary-baseline.json` |
| `scripts/debt/check-singleton-budget.sh` | `budgets/singleton-baseline.json` |
| `scripts/debt/check-sqlite-writer-ownership.sh` | `budgets/sqlite-dual-writer-baseline.json` |
| `scripts/debt/check-xctskip-budget.sh` | `budgets/xctskip-baseline.json` |
| `scripts/debt/check-privacy-public-budget.sh` | `budgets/privacy-public-baseline.json` |
| `scripts/debt/check-parser-twins.sh` | `budgets/parser-twin-baseline.txt` |
| `scripts/debt/check-domain-core-freeze.sh` | `budgets/domain-core-adapter-baseline.txt` |
| `scripts/debt/check-kernel-sharedmodels-purity.sh` | Kernel SharedModels deny-gate |
| `scripts/debt/check-settings-protocol-split.sh` | SettingsManagerProtocol slices |
| `scripts/debt/check-video-encoder-isolation.sh` | VideoEncoder not `@MainActor` |
| `scripts/debt/check-rpc-method-freeze.sh` | `budgets/rpc-methods-baseline.json` |

## Vendor / Package.swift

| Door | Command |
|------|---------|
| Declared xcframeworks | `OPENBURNBAR_DECLARED_XCFRAMEWORKS=1` in `OpenBurnBarCore/Package.swift` |
| Checksums | `bash scripts/ci/verify-vendor-xcframework-checksums.sh` |

## Mobile

| Door | Command |
|------|---------|
| iOS unit | `./scripts/test-openburnbar-mobile.sh` |
| Android JVM | `./scripts/test-openburnbar-android.sh` |

Keep this file short. New door scripts get a row here; one-off debug scripts do not.
