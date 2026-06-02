# Development workflow

## Branch strategy

- `main` is the default branch. Feature branches branch from `main`.
- The current working branch is `chore/land-remaining-safe-work-20260601`.
- Rebase on `main` before merging; the automated review workflow runs on every PR.

## Code → test → PR → merge

1. **Code** — make focused changes. Every line should serve the request.
2. **Test** — add or update tests in active test trees (`AgentLensTests/Active/`, `OpenBurnBarDaemon/Tests/`). Quarantined tests under `AgentLensTests/Quarantine/` are not compiled by default.
3. **Lint** — `make lint` runs SwiftLint. `npm run lint --prefix functions` for TypeScript.
4. **Full CI** — `make ci` runs all test surfaces: Swift packages, app tests, mobile tests, Android tests, Functions tests, Firestore rules, extension evals, supply chain audit.
5. **PR** — open a PR against `main`. The automated review workflow (`pr-review.yml`) posts a structured comment. Read it before merging.
6. **Merge** — squash or rebase as appropriate.

## Adding a new provider parser

1. Add a case to `AgentProvider` in `AgentLens/Models/AgentProvider.swift`.
2. Set `iconName` (SF Symbol), `displayName`, `logDirectory`, and `filePattern`.
3. Implement `LogParser` protocol in `AgentLens/Services/LogParser/`.
4. Register the parser in `UsageAggregator`.
5. Add tests in `AgentLensTests/Active/`.

## Clearing stale caches

After large `OpenBurnBarCore` migrations, Xcode may hold stale binary artifacts. Run:

```bash
./scripts/clear-xcode-caches.sh
```

## Related pages

- [Testing](testing.md) — test frameworks and patterns
- [Debugging](debugging.md) — logs and troubleshooting
- [Patterns and conventions](patterns-and-conventions.md) — coding style
- [Tooling](tooling.md) — build system and CI
