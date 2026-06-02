# Debugging

## Logs

- macOS app: check Console.app for `com.openburnbar.app` logs.
- Daemon: `swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI -- health` for quick status.
- Functions: structured logging via `logging.ts`; set `SENTRY_DSN` for production exception capture.

## Common errors

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "value of type 'X' has no member 'Y'" after core migration | Stale Xcode/SwiftPM cache | `./scripts/clear-xcode-caches.sh` |
| Daemon unreachable in extension | Daemon not running or socket missing | Launch OpenBurnBar app, or repair daemon from Settings |
| Build failures after `project.yml` changes | Xcode project out of sync | `xcodegen generate` |
| Firestore schema mismatch | Android/Swift types drifted from `functions/src/types.ts` | Run `./tools/schema-sync/check-drift.sh` |

## Troubleshooting runbook

- `make preflight` — verify Xcode, Swift, and tooling presence.
- `make ci` — full local CI parity; catches most issues before PR.
- `scripts/ci/verify-ops-readiness.sh` — pre-release ops checklist.
- `scripts/ops/verify-production-ops-plane.sh` — production plane verification.

## Related pages

- [Development workflow](development-workflow.md) — branch and PR cycle
- [Testing](testing.md) — test frameworks and patterns
- [Tooling](tooling.md) — build system and CI
