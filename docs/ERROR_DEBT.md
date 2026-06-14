# Error debt budget

OpenBurnBar tracks silent error swallowing with `tools/error-debt/count-error-debt.py`.
The Python counter is the CI source of truth — **not** SwiftLint's `empty_catch_block`
rule, which matches only a subset of empty catches.

## What is counted

| Metric | Scope | Gate |
|--------|-------|------|
| Empty `catch {}` | `AgentLens/` + `OpenBurnBarDaemon/` | assert-zero; no baseline |
| `try?` | `AgentLens/Services/` | `budgets/try-optional-baseline.json` |

## Local workflow

Run counters:

```bash
python3 tools/error-debt/count-error-debt.py --format text
```

Run budget gates:

```bash
./scripts/debt/check-empty-catch-budget.sh
./scripts/debt/check-try-optional-budget.sh
```

Regenerate ratcheted baselines only after intentional burn-down:

```bash
./scripts/debt/update-try-optional-baseline.sh
```

Empty catches are now zero-locked: CI fails on any new empty `catch {}`. For
ratcheted metrics, CI fails on **increase**; lowering a baseline belongs in the
same PR as the fixes.

See also [`docs/TYPE_DEBT.md`](TYPE_DEBT.md) for unsafe cast tracking.
