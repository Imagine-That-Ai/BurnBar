# Mission 002 — Reanchor (product parity)

Date: 2026-07-09

## Purpose

Archive the active checkout state, keep sealed mission-001 evidence immutable,
and claim product parity only when Tier A/B product-parity rows are ready with
evidence heads matching `git rev-parse HEAD`.

## VAL contracts (product-parity)

Per-row evidence under `row-evidence/VAL-*.md` (each file names its row id):

- **VAL-000-BASELINE** — checkout baseline + frontend + guest plane
- **VAL-000-CSS** — Vite/CSS + design-tokens
- **VAL-000-LEDGER** — `productParityClaim: true` with head-matched product rows
- **VAL-PATH-001** — XDG path single ownership
- **VAL-PARSER-001** — provider path registry parity
- **VAL-TOKENS-001** — design-tokens consumption
- **VAL-DASHBOARD-001** — six-layout dashboard contract
- **VAL-RPC-001** — contract-first bridge/gateway (no invented methods)
- **VAL-DASHBOARD-004** — layout contract ready in code

## Live guest proof

- `vm-e2e/branch-daemon/` — branch daemon catalog/health/CU/pensieve

## Release assembly

- `release/` — package-closure, sidecars, smoke logs (OPENBURNBAR_LINUX_RELEASE_OUT)

## Claims

- Product parity is claimable when `validate-parity-ledger.mjs` (strict) exits 0
  with `productParityClaim: true`.
- Strict `verify-linux-release.mjs` is green when release assembly + smoke +
  Ed25519 signatures are present under `release/`.
