# Type Debt Budget

OpenBurnBar tracks unsafe type shortcuts with `tools/type-debt/audit-unsafe-casts.mjs`.
The scanner is now an assert-zero gate: unsafe casts, force unwraps, force casts, and
force tries are not budgeted debt anymore. Any reintroduction fails CI.

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

Run the assert-zero gate:

```bash
./scripts/debt/check-unsafe-cast-budget.sh
```

The CI gate passes only when `live.total == 0`. If it fails, remove the reported
violation or replace it with a typed boundary before merging.
