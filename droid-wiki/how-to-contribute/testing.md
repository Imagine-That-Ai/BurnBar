# Testing

## Test frameworks

| Surface | Framework | Entry point |
|---------|-----------|-------------|
| Swift packages | XCTest | `swift test --package-path OpenBurnBarCore` / `OpenBurnBarDaemon` |
| macOS app | XCTest (`OpenBurnBarTests`) | `./scripts/test-openburnbar-app.sh` |
| iOS mobile | XCTest (`OpenBurnBarMobileTests`) | `./scripts/test-openburnbar-mobile.sh` |
| Android | JVM + Compose UI tests | `./scripts/test-openburnbar-android.sh` |
| Firebase Functions | Jest | `npm test --prefix functions` |
| Firestore rules | `@firebase/rules-unit-testing` | `npm test --prefix firestore-rules-tests` |
| Extension | `npm test` in `extensions/openburnbar/` | `npm test` |
| Retrieval evals | Custom golden-suite runner | `./scripts/test-openburnbar-retrieval-evals.sh` |

## Active vs quarantined tests

- **Active:** `AgentLensTests/Active/**` + `AgentLensTests/Support/**` — compiled into `OpenBurnBarTests`.
- **Quarantine:** `AgentLensTests/Quarantine/**` — archival, not compiled by default. Move back to `Active/` after fixing.

## N+1 query detection

Configure `OpenBurnBarQueryTracer` before opening a database, then assert query counts in tests:

```swift
// In setUp
OpenBurnBarQueryTracer.configure(in: &configuration)
OpenBurnBarQueryTracer.resetLog()

// After the operation under test
OpenBurnBarQueryTracer.assertMaxQueries(count: 3)
```

## Test patterns

- Prefer deterministic tests; avoid time-dependent assertions.
- Use `make ci` before any PR to catch cross-surface failures.
- Diff coverage: run `./scripts/diff-coverage-all.sh origin/main` after tests with `OPENBURNBAR_ENABLE_COVERAGE=YES`.

## Related pages

- [Development workflow](development-workflow.md) — branch and PR cycle
- [Debugging](debugging.md) — logs and troubleshooting
- [Patterns and conventions](patterns-and-conventions.md) — coding style
