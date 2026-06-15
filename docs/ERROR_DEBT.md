# Error debt budget

OpenBurnBar tracks silent error swallowing with `tools/error-debt/count-error-debt.py`.
The Python counter is the CI source of truth — **not** SwiftLint's `empty_catch_block`
rule, which matches only a subset of empty catches.

## What is counted

| Metric | Scope | Gate |
|--------|-------|------|
| Empty `catch {}` | `AgentLens/` + `OpenBurnBarDaemon/` | assert-zero; no baseline |
<<<<<<< HEAD
| Untagged `try?` | `AgentLens/Services/` | assert-zero; no baseline |
=======
| `try?` | `AgentLens/` + `OpenBurnBarCore/Sources/` + `OpenBurnBarMobile/` + `OpenBurnBarDaemon/Sources/` (production Swift) | `budgets/try-optional-baseline.json` |
>>>>>>> origin/pr-410

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

<<<<<<< HEAD
Empty catches and untagged `try?` sites are now zero-locked: CI fails on any new
empty `catch {}` or untagged `try?`. Keep a `try?` only when optionality is
genuinely correct, and mark it with a reviewed `// try?-ok(<reason>)` token on
the same line or directly above it.
=======
Regenerate ratcheted baselines only after intentional burn-down:

```bash
./scripts/debt/update-try-optional-baseline.sh
```

Empty catches are now zero-locked: CI fails on any new empty `catch {}`. For
ratcheted metrics, CI fails on **increase**; lowering a baseline belongs in the
same PR as the fixes.
>>>>>>> origin/pr-410

See also [`docs/TYPE_DEBT.md`](TYPE_DEBT.md) for unsafe cast tracking.
