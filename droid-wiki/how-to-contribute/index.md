# Contributing

## Before you start

Read `AGENTS.md`. The completion bar there is not optional: do the whole thing, right, with tests. No workarounds when the real fix exists. No dangling threads.

## Work pickup

1. Pull `main`, create a branch with a descriptive name.
2. Scope discipline: every line in your change must serve the request. No drive-by refactors, no unrelated file edits.
3. Search the codebase before adding new types, parsers, or UI — extend what exists.

## Before submitting a PR

Run `make ci` locally. All tests and lint must pass. The PR is blocked if CI is red.

Key commands:

| Command | Purpose |
|---|---|
| `make ci` | Full CI parity: tests, lint, Firestore rules, evals |
| `make test` | All test suites |
| `make lint` | SwiftLint + workflow lint |
| `./scripts/diff-coverage-all.sh origin/main` | Coverage delta for changed files (set `OPENBURNBAR_ENABLE_COVERAGE=YES`) |

## Review expectations

- Describe what changed and why in the PR body. Include test evidence.
- Squash merge to main.
- Reviewers will reject changes that touch files outside the stated scope.

## Adding a parser

Follow the 5-step process in `how-to-contribute/patterns-and-conventions.md`:

1. Create a parser struct conforming to `LogParser` in `AgentLens/Services/LogParser/`.
2. Register it in `LogParserRegistry`.
3. Add a unit test with representative sample logs.
4. Add a snapshot fixture if the parser emits UI-affecting data.
5. Update `docs/PROVIDERS.md` with the new provider entry.

## File naming

| Platform | Convention | Example |
|---|---|---|
| Swift | `UpperCamelCase.swift` | `ClaudeParser.swift` |
| Kotlin | `UpperCamelCase.kt` | `TokenUsage.kt` |
| TypeScript | `lowerCamelCase.ts` | `quotaRefresh.ts` |

## Tests

Add or update tests in:
- `AgentLensTests/Active/` — compiled by `OpenBurnBarTests` target, gated by CI
- `OpenBurnBarDaemon/Tests/` — Swift package tests for the daemon
- `android/app/src/test/` — JVM unit tests

Long-lived stale suites go in `AgentLensTests/Quarantine/` (excluded from CI). See `AgentLensTests/README.md`.
