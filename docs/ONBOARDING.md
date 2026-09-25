# Onboarding: subsystem → modules → canonical tests → runbooks

The 30-minute map for a new engineer (or agent) on OpenBurnBar. Every path
below is verified against the tree; start with `AGENTS.md` (agent contract),
`README.md` (product), and `docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md`
(deep onboarding), then use this map to find the subsystem you need.

Standing invariants (all waves): Core vs Lab split, single-writer stores,
`costUSD` canon, freeze-not-delete, opt-in sync. Proved with real binaries
and green ratchets — see `budgets/` + `scripts/debt/` + `scripts/ci/`.

## Subsystem map

### 1. Data spine (SQLite / GRDB, single writer, single migrator)

| | |
|---|---|
| Modules | `OpenBurnBarCore/Sources/OpenBurnBarData` (migrator, stores), `AgentLens/Services/DataStore` (app access) |
| Schema canon | `docs/SCHEMA_SQLITE.sql` (update alongside every GRDB migration) |
| Cost canon | `costUSD` is canonical; rule + cross-client fixture in `functions/src/costRule.ts`, `tests/fixtures/cost-rule/` |
| Perf guard | `AgentLens/Services/DataStore/OpenBurnBarQueryTracer.swift` (`configure` → `resetLog` → `assertMaxQueries`) |
| Canonical tests | `AgentLensTests/Active/OpenBurnBarDatabaseMigrationTests.swift`, `OpenBurnBarDaemonTests/AIInboxSchemaParityTests.swift`, `functions/src/__tests__/costRule.test.ts` |
| Runbooks | `docs/DATABASE_OPERATIONS.md`, `docs/runbooks/firestore-disaster-recovery.md` |

### 2. Daemon (Unix-socket RPC server, MissionControl, providers)

| | |
|---|---|
| Modules | `OpenBurnBarDaemon/Sources` (server, MissionControl, provider executors) |
| RPC catalog | TypeSpec-first: `tools/schema-sync/typespec/domains/daemon-rpc.tsp`; adding a method is a TypeSpec edit, CI rejects hand edits (`tools/ipc/generate-burnbarrpc-canon.mjs --check`) |
| Canonical tests | `swift test` in `OpenBurnBarDaemon/` (`OpenBurnBarDaemonTests`, incl. `BurnBarDaemonServerTests`, `AIInboxCrossPlatformContractTests`); N-1 compat via `AgentLensTests/Active/BurnBarRPCMethodCompatTests.swift` |
| Runbooks | `docs/runbooks/slos.md` (latency/availability/error budgets) |

### 3. Mac app (AgentLens: Core UI + Lab)

| | |
|---|---|
| Modules | `AgentLens/` — Core UI; `AgentLens/Lab/` — experimental, file-level `OPENBURNBAR_LAB` gate, builds nightly (PR door runs Core only) |
| Project | `project.yml` (xcodegen; pinned 2.45.4 — never hand-edit `project.pbxproj`); scheme `OpenBurnBar` |
| Design tokens | `AgentLens/Theme/DesignSystem.swift` + `DesignSystemTokens`; palette documented in `DESIGN.md`, gated by `scripts/ci/check-design-tokens.sh` |
| Canonical tests | `./scripts/test-openburnbar-app.sh` (bundle `OpenBurnBarTests`, sources under `AgentLensTests/`; quarantine rules in `AgentLensTests/README.md`) |

### 4. Cloud Functions (per-codebase deploys, `domains/` layout)

| | |
|---|---|
| Modules | `functions/`, `functions-identity/`, `functions-sync/`, `functions-media/` (independent deploys) + `packages/functions-shared/` (validators, logging, runtime) |
| Conventions | `onCallProduction` for new callables; `providerFetch` for provider HTTP (no raw `fetch` — ESLint `no-restricted-globals` on the PR door); resilience helpers in `functions/src/resilienceHelpers.ts` |
| Canonical tests | `scripts/build-functions-all.sh` (build), `npx vitest run` per codebase; emulator-backed suites where marked |
| Runbooks | `docs/runbooks/functions-break-glass.md`, `docs/runbooks/rollback-automation.md` (`node scripts/rollout.mjs --status`) |

### 5. Mobile (iOS + Android, parity ledger)

| | |
|---|---|
| Modules | `OpenBurnBarMobile/` (SwiftUI), `android/app/src/main` (Compose) |
| Parity bar | `docs/mobile-parity/mobile-parity-ledger.md` (live; `productParityClaim` is false until the ledger says otherwise) |
| Schema | Canonical Firestore contracts in `tools/schema-sync/` (TypeSpec → TS/Swift/Kotlin); `./tools/schema-sync/check-drift.sh` before changing shared models; legacy canon in `functions/src/types.ts` during migration |
| Canonical tests | `./scripts/test-openburnbar-mobile.sh` (physical iPhone locally, simulator in CI), `./scripts/test-openburnbar-android.sh` (`:app` + `:openburnbar-iroh-relay` JVM suites) |

### 6. Shared Rust domain core + crypto

| | |
|---|---|
| Modules | `crates/` (domain core, parsers), `OpenBurnBarCore/Sources/OpenBurnBarDomainCore*` (FFI) |
| Decision 4 | Legacy never loads Wasm; pricing runs through Rust with the legacy twin deleted where cut over |
| Canonical tests | `cargo test` in `crates/`; `HermesDomainCoreMigrationTests` (native-gated: `OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE=1`) |
| Threat models | `docs/security/BurnBar-threat-model.md`, `docs/security/SHARED_RUST_CRYPTO_ADVERSARIAL_REVIEW_2026-07-13.md` |

### 7. Hermes relay / realtime transport

| | |
|---|---|
| Modules | `OpenBurnBarCore/Sources/OpenBurnBarHermes*`, `OpenBurnBarIroh*`, relay clients per platform |
| Canonical tests | Daemon `Hermes*` suites, `OpenBurnBarDaemonLinuxGatewayTests` (Docker toolchain), Android iroh instrumented suites (`scripts/e2e/android-iroh-chat.sh`) |
| Runbooks | `docs/runbooks/hermes-gateway-3features.md`, `docs/runbooks/android-iroh-transport.md`, `docs/HERMES_COMPUTER_USE.md` (wire reference) |

### 8. Computer Use (phases 8–13)

| | |
|---|---|
| Plan | `plans/2026-05-16-computer-use-master-plan.md` |
| Invariants | Approval is the only ground truth; trust downgrade-only from the phone; content-addressed audit chain; three panic-kill paths + Remote Config kill switch; Path C ships direct-download only (compiled out for MAS) |
| Canonical tests | Phase suites under the daemon + app tests; rollout log in `docs/runbooks/computer-use-rollout-status.md` |

### 9. Quota / providers / parsers

| | |
|---|---|
| Modules | Quota adapters (`OpenBurnBarCore/.../ProviderQuota/`), log parsers (`OpenBurnBarLogParsers/`), provider executors (daemon) |
| Session paths | Codex `~/.codex/sessions/`, Claude Code `~/.claude/projects/`, Grok `~/.grok/sessions/` (see `docs/PROVIDERS.md`) |
| Canonical tests | Parser golden suites (`AgentLensTests/Active/Parsers/`), quota adapter matters tests, `functions` rollup vitest suites |

### 10. CI, ratchets, debt governance

| | |
|---|---|
| PR door | `.github/workflows/fast-feedback.yml` (lint + typecheck + unit tests, <5 min); `pr-native-fast.yml` (xcodegen drift, app smoke + impacted tests <20 min) |
| Ratchets | `budgets/*.json` + `scripts/debt/check-*.sh` / `scripts/ci/check-*.sh` — all shrink-only or assert-zero; never add a suppression without an inline `reason:` (`scripts/ci/check-no-suppressions.sh`) |
| Debt review | `docs/TECH_DEBT_STRATEGY.md` + `docs/TECH_DEBT_METRICS.md` (regen: `./scripts/ci/update-tech-debt-metrics.sh`); ADRs in `docs/ARCHITECTURE/` |
| Full local parity | `make ci` |

### 11. Security & diligence

| | |
|---|---|
| Registers | `docs/governance/RISK_REGISTER.md`, `docs/governance/PHASE1_SECURITY_REGISTER.md` (AR-007: human SOTA signoff pending; signoff record is local-only by audit-evidence policy) |
| Runbooks | `docs/runbooks/slos.md`, `docs/security/` (threat models, privacy invariants, supply-chain provenance) |
| Gates | `scripts/ci/verify-ops-readiness.sh` before release; `verify-phase1-security-gates.sh`; confidentiality guard (`node scripts/security/scan-internal-content.mjs`) |

## First-day checklist

1. Read `AGENTS.md`, then the subsystem row above for your task.
2. Run the cheapest relevant check for the touched area (table above).
3. Smallest reviewable coherent unit → commit → PR with what/why/validation/risks (see `AGENTS.md` factory loop; `CHEAP_FAST` applies).
4. If you add a type, parser, or store: extend what exists, mirror the canonical schema, and add the test + doc in the same change.
