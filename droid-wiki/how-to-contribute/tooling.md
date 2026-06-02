# Tooling

## Build system

- **Xcode project** generated from `project.yml` via XcodeGen. Run `xcodegen generate` after editing.
- **Swift packages** use `Package.swift` in `OpenBurnBarCore/` and `OpenBurnBarDaemon/`.
- **Android** uses Gradle with Java 21. Set `JAVA_HOME` and `ANDROID_HOME` appropriately.

## Key commands

| Command | What it does |
|---------|--------------|
| `make build` | Build Release `.app` |
| `make install` | Build + copy to `/Applications` |
| `make test` | All test suites |
| `make lint` | SwiftLint |
| `make ci` | Lint + tests + full CI parity |
| `make sbom` | Generate SPDX SBOM |
| `xcodegen generate` | Regenerate `OpenBurnBar.xcodeproj` from `project.yml` |

## CI/CD

- **Fast feedback:** `.github/workflows/fast-feedback.yml` — lint + typecheck + unit tests in <5 min.
- **Full build:** separate macOS build workflow.
- **Automated review:** `.github/workflows/pr-review.yml` posts structured review comments on every internal PR.
- **Deploy:** `.github/workflows/deploy-production.yml` runs on tagged releases.

## Lint and quality

- **Swift:** SwiftLint (`.swiftlint.yml`), SwiftFormat (`.swiftformat`).
- **TypeScript:** ESLint + Prettier in `functions/` and `extensions/`.
- **Rust:** `rustfmt` in `crates/`.
- **Supply chain:** `scripts/ci/verify-resilience-wiring.sh` enforces no raw `fetch` in Functions.

## Related pages

- [Development workflow](development-workflow.md) — branch and PR cycle
- [Testing](testing.md) — test frameworks and patterns
- [Debugging](debugging.md) — logs and troubleshooting
