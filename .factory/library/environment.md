# Environment

Environment variables, external dependencies, and setup notes for this mission.

**What belongs here:** required tools, dependency assumptions, sync/API caveats.  
**What does NOT belong here:** service ports/commands (use `.factory/services.yaml`).

---

## Required Local Tooling
- Xcode + `xcodebuild`
- Swift toolchain (`swift`, `swift test`)
- `swiftlint`
- Node + npm (for extension lint/tests where needed)
- `sqlite3` (for datastore evidence queries)

## Mission-Specific Assumptions
- Core mission work is local and does not require new external credentials.
- Provider API reconciliation behavior may be tested conditionally based on existing local environment support.
- Optional tokenizer-assisted fallback path must remain feature-flagged and default-off.

## Data and Sync Notes
- Token accounting uses mixed local and API-derived sources; source identity must remain explicit.
- Remote sync watermark behavior is safety-critical; failures must not advance progress markers.
