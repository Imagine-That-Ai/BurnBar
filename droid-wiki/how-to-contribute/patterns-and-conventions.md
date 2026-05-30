# Patterns and conventions

This page documents the coding conventions, error-handling patterns, and cross-cutting standards followed across the OpenBurnBar codebase.

## Swift conventions (macOS / iOS)

### State management

Use `@Observable` (iOS 17+ / macOS 14+), never `ObservableObject` + `@Published`. The codebase migrated to the new Observation framework; mixing the two produces subtle update bugs.

```swift
// Correct
@Observable final class UsageStore {
    var dailyCost: Double = 0
}

// Wrong
class UsageStore: ObservableObject {
    @Published var dailyCost: Double = 0
}
```

### Persistence

All local persistence uses **GRDB** (not Core Data, not UserDefaults for structured data). The canonical schema lives in `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift`. Migrations are append-only and numbered. Do not alter existing migration bodies.

### Design tokens

Every view must use `DesignSystem` tokens. Raw colors, font sizes, and spacing values are a SwiftLint violation.

```swift
// Correct
Text("$12.34")
    .font(DesignSystem.Typography.mono)
    .foregroundStyle(DesignSystem.Colors.textPrimary)

// Wrong
Text("$12.34")
    .font(.system(size: 14, weight: .medium, design: .monospaced))
    .foregroundColor(.white)
```

### Animations

Always use `animation(_:value:)`. Never use `animation(_:)` without a value parameter.

### Parsers

All parsers must:
1. Conform to `LogParser` (defined in `AgentLens/Services/LogParser/LogParserProtocol.swift`).
2. Be `Sendable` (parsers run in async contexts).
3. Return `[]` for missing directories — never throw for missing data.
4. Return `[]` for malformed lines — log and continue, never crash.

### Async/await and actors

Prefer `async`/`await` over callbacks or Combine. Use `@MainActor` on UI-bound store classes. Avoid `Task.detached` unless truly necessary; prefer structured concurrency.

## Kotlin conventions (Android)

### Architecture

Each screen has a `*Store` (ViewModel subclass):
- `suspend` methods for one-shot fetch (`load()`, `refresh()`).
- `callbackFlow + addSnapshotListener` for real-time Firestore listeners.
- Listener lifecycle managed by `viewModelScope`.

### Firestore models

Every Firestore data class must:
- Be annotated `@IgnoreExtraProperties` to tolerate server additions.
- Use `@PropertyName` for keys that differ from Kotlin camelCase (e.g., `providerID` → `providerId`).
- Keep computed properties (`get()`) in the class body, not the primary constructor.

### Schema alignment

The canonical schema is `functions/src/types/`. Every Android model and parser must match it. Run `./tools/schema-sync/check-drift.sh` before changing shared models.

## TypeScript conventions (Firebase Functions)

- Runtime: Node.js 18, TypeScript strict mode.
- Every callable uses Firebase App Check enforcement (`appCheck()` guard in `functions/src/guards.ts`).
- Secrets are fetched from Secret Manager at call time, never stored in environment variables or Firestore documents.

## Error handling

### Swift

Use `Result` or `throws` for recoverable errors. Use `assertionFailure` or `fatalError` only for programmer errors (invariant violations), never for runtime conditions.

Parser errors follow the "log and continue" pattern:

```swift
do {
    let events = try parseJSONL(line: line)
    results.append(contentsOf: events)
} catch {
    AppLogger.parser.warning("Skipped malformed line: \(error)")
}
```

### Daemon RPC

Daemon JSON-RPC errors follow the standard JSON-RPC error object shape: `{ code, message, data? }`. Client-side, `RoutedClientWiringSentry` validates wiring before a session starts to surface misconfigurations early.

## Testing

- **Active tests** live in `AgentLensTests/Active/` and are compiled by the `OpenBurnBarTests` target.
- **Quarantined tests** live in `AgentLensTests/Quarantine/` and are excluded from CI until fixed and moved back.
- New behavior changes require tests in `AgentLensTests/Active/` or the relevant Swift package test target.
- Avoid test interdependence — each test should create its own in-memory GRDB database.

See [Testing](testing.md) for the full test runbook.

## File naming

- Swift files use `UpperCamelCase.swift`, matching the primary type they define.
- Kotlin files use `UpperCamelCase.kt`.
- TypeScript files use `lowerCamelCase.ts`.
- XcodeGen config: `project.yml` at the repo root.

## Documentation

- User-facing or architectural changes belong in `docs/`.
- Architecture decisions go in `docs/architecture/` (ADR format).
- Runbooks go in `docs/runbooks/`.
- Update `CHANGELOG.md` for user-visible changes.

## Scope discipline

Every line in a change should serve the request. Avoid drive-by refactors and unrelated file touches. The AGENTS.md completion bar applies: ship the whole thing correctly, but only the thing that was asked for.
