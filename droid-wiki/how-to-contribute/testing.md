# Testing

## Test organisation

**Active tests** live in `AgentLensTests/Active/` and are compiled by the `OpenBurnBarTests` Xcode target. These are gated by CI and must stay green.

**Quarantined tests** live in `AgentLensTests/Quarantine/` and are excluded from all CI targets. Move a test there when it is long-lived but temporarily broken; delete it if it is permanently irrelevant. See `AgentLensTests/README.md` for the full policy.

## Running tests by surface

### macOS app

```bash
./scripts/test-openburnbar-app.sh
```

### Daemon (Swift package)

```bash
swift test --package-path OpenBurnBarDaemon
```

### Core package

```bash
swift test --package-path OpenBurnBarCore
```

### iOS / mobile

```bash
./scripts/test-openburnbar-mobile.sh
```

Runs `OpenBurnBarMobileTests` on a connected physical iPhone locally. CI uses a Simulator fallback.

### Android JVM unit tests (~253 tests)

```bash
./scripts/test-openburnbar-android.sh
# or directly:
cd android && ./gradlew :app:testDebugUnitTest --no-daemon
```

Covers relay, media, missions, and atom parser.

### iroh relay library tests

```bash
cd android && ./gradlew :openburnbar-iroh-relay:testDebugUnitTest --no-daemon
```

Codec, pairing, and loopback transport.

### Firebase Functions and Firestore rules

```bash
cd firestore-rules-tests && npm test
```

Requires the Firebase emulator (`firebase emulators:start`).

### Full CI

```bash
make ci
```

Runs all of the above plus lint, evals, and supply-chain checks.

## Diff coverage

To check coverage on lines you changed:

```bash
OPENBURNBAR_ENABLE_COVERAGE=YES ./scripts/diff-coverage-all.sh origin/main
```

## GRDB in-memory databases

Every test that touches GRDB must create a **fresh in-memory database** for that test case:

```swift
let db = try DatabaseQueue()
try db.write { try YourSchema.create(in: $0) }
```

Never share a database instance between tests. Shared state causes ordering-dependent failures.
