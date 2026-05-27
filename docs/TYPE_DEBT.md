# Type Debt Budget

OpenBurnBar tracks unsafe type shortcuts with `tools/type-debt/audit-unsafe-casts.mjs`.
The scanner is a ratchet: current debt is allowed while remediation is underway, but new
unsafe casts must not raise `budgets/unsafe-cast-baseline.json`.

## What Is Counted

The budget covers hand-written TypeScript, Swift, and Kotlin:

| Kind | Meaning |
|---|---|
| `ts_type_assertion` | TypeScript `as Type` and angle-bracket assertions, excluding `as const` |
| `ts_as_any` | TypeScript `as any` |
| `ts_non_null_assertion` | TypeScript non-null assertions |
| `swift_force_cast` | Swift `as!` |
| `swift_force_try` | Swift `try!` |
| `kotlin_unsafe_cast` | Kotlin `as Type`, excluding import aliases and `as?` |
| `kotlin_force_unwrap` | Kotlin `!!` |

For TypeScript, the scanner prefers `@typescript-eslint/parser` from the Functions or
extension dependency trees. If dependencies are not installed, it falls back to a
conservative token scanner that strips comments and strings, skips import aliases, and
ignores `as const`. The fallback intentionally favors avoiding false positives over
finding every complex syntax edge case.

## Excluded Paths

Generated and vendor code stays generated; app code must touch FFI and generated
surfaces through typed facades instead of editing generated files directly.

The scanner excludes generated/vendor/build paths such as:

| Exclusion | Rationale |
|---|---|
| `**/Generated/**`, `*.generated.*` | Generated Swift/TS/Kotlin should not be hand-edited |
| `**/uniffi/**` | UniFFI output is wrapped at hand-written boundaries |
| `node_modules`, `Vendor`, `Pods`, `Carthage` | Third-party dependencies are outside the repo budget |
| `dist`, `build`, `lib`, `.build`, `.derived-data`, `.firebase` | Build outputs and compiled artifacts |
| `artifacts` | Generated release/test artifacts |

## Local Workflow

Run the scanner:

```bash
node tools/type-debt/audit-unsafe-casts.mjs --format text
```

Run the budget gate:

```bash
./scripts/debt/check-unsafe-cast-budget.sh
```

Regenerate the baseline only after an intentional burn-down:

```bash
./scripts/debt/update-unsafe-cast-baseline.sh
```

The CI gate passes when `live.total <= budgets/unsafe-cast-baseline.json.total`.
If a cleanup lowers the live total, update the baseline in the same change so the
lower number becomes the new ceiling.
