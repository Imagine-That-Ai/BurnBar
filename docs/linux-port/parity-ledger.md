# Linux parity ledger

The machine-readable ledger is [`parity-ledger.json`](parity-ledger.json).

## Semantics (VAL-000-LEDGER)

As of mission-002 reanchor (2026-07-09):

```json
"semantics": {
  "kind": "historical-infrastructure-plus-product",
  "productParityClaim": false
}
```

| Field | Meaning |
|---|---|
| `scope: historical-infrastructure` | Mission-001 sealed evidence; not a current product parity claim. |
| `scope: product-parity` | Product foundation / surface contracts for full macOS parity. |
| `staleWhenHeadDiffers` | When true on ready product rows, evidence head must match the checkout once `productParityClaim` is true. |
| `evidenceHead` / `validatedAtHead` | Git SHA where the product row was last proven. |

**Do not treat an all-ready historical ledger as full product parity.** Public
prerelease assets may exist while product parity remains incomplete.

## Commands

Strict promotion check:

```bash
node scripts/linux-port/validate-parity-ledger.mjs
```

PR structural check (blocked Tier A/B allowed as warnings):

```bash
node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked
```

Public update feed (HTML must not pass for promotion):

```bash
node scripts/linux-port/check-linux-update-feed.mjs
node scripts/linux-port/check-linux-update-feed.mjs --allow-missing
```

## Historical context

Mission-001 rows were sealed against `64538ed350b1d3bd25ddd1cae1ba67b2a9165c57`
with V24/V23 active-checkout evidence at
`1b62ec42bd752cc8a6af578f034bf776c6ec3b97`. Those rows remain
`historical-infrastructure`. Product foundation work is tracked under
`scope: product-parity` and
[`FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`](FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md).

Release readiness still means: strict release verifier exits 0 from a clean
commit, public JSON feed verifies, and product parity rows are green with
current evidence heads.
