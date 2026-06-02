# How to contribute

## Work pickup

Before starting work, read [AGENTS.md](https://github.com/Imagine-That-Ai/BurnBar/blob/main/AGENTS.md) for the completion bar and scope discipline. Search the codebase before adding new types, parsers, or UI; extend what exists unless the task explicitly requires greenfield work.

## PR process

1. Branch from `main`.
2. Make focused changes — every line should serve the request.
3. Add or update tests in the active `AgentLensTests` or `OpenBurnBarDaemon` test targets.
4. Run `make ci` before opening a PR.
5. Update `CHANGELOG.md` and relevant docs in `docs/` for user-facing changes.
6. Open a PR; the automated review workflow posts a structured comment — read it before merging.

## Definition of done

- Code compiles and tests pass (`make ci`).
- Fast CI (`fast-feedback.yml`) is green — lint + typecheck + unit tests in <5 min.
- New behavior has test coverage in the active test tree (not Quarantine).
- User-facing changes have docs updates.
- Architecture changes have ADR entries in `docs/ARCHITECTURE/`.

## Related pages

- [Development workflow](development-workflow.md) — branch, code, test, PR, merge
- [Testing](testing.md) — frameworks, patterns, how to run
- [Debugging](debugging.md) — logs, common errors, troubleshooting
- [Patterns and conventions](patterns-and-conventions.md) — coding style, error handling, cross-cutting concerns
- [Tooling](tooling.md) — build system, linters, CI
