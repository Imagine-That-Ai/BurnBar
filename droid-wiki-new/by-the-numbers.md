# By the numbers

*Data collected on 2026-06-01.*

## Codebase size

| Language | Lines | Files (approx) |
|----------|-------|----------------|
| Swift | ~1,332,000 | ~4,959 |
| Kotlin | ~109,787 | — |
| Rust | ~56,887 | — |
| TypeScript | ~23,820 | — |

The Swift figure covers the macOS app (`AgentLens/`), iOS app (`OpenBurnBarMobile/`), daemon (`OpenBurnBarDaemon/`), and shared core (`OpenBurnBarCore/`).

## Test coverage

- **208 Swift test files** in `AgentLensTests/`
- Quarantined / archived suites live under `AgentLensTests/Archive/` and are not compiled by default
- Android JVM unit suite covers ~253 tests across relay, media, missions, and atom parser modules
- iOS mobile unit tests (`OpenBurnBarMobileTests`) run on-device or Simulator

## Commit activity

- **855 total commits** in the repository
- **~16 commits/day** over the last 30 days
- **~27%** of all commits are co-authored by `factory-droid[bot]`

## Top churn files (all-time edit frequency)

| File | Commits touching it |
|------|---------------------|
| `project.pbxproj` | 144 |
| `CHANGELOG.md` | 87 |
| `project.yml` | 61 |
| `firestore.rules` | 43 |
| `HermesService.swift` | 42 |

## Largest production file

`AgentLens/Services/HermesService.swift` at **~4,589 lines**. It owns Hermes relay connection management, iroh transport, mission dispatch, and media session state.

## Surface counts

| Category | Count |
|----------|-------|
| Log parsers | 17 |
| Quota adapters | 22+ |
| Firebase Cloud Functions | 49 |
