# Configuration

## Build environment variables

### Android

| Variable | Default | Purpose |
|----------|---------|---------|
| `JAVA_HOME` | `~/.homebrew/opt/openjdk@21` | Java 21 (required by Gradle) |
| `ANDROID_HOME` | `~/Library/Android` | Android SDK root |
| `ANDROID_SDK_ROOT` | same as `ANDROID_HOME` | Legacy alias, set both |

### macOS / iOS (Xcode / Makefile)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENBURNBAR_DEVELOPMENT_TEAM` | `4Y367DF25B` | Code-signing team ID |
| `OPENBURNBAR_ENABLE_COVERAGE` | unset | Set to `1` to enable code-coverage instrumentation |
| `OPENBURNBAR_IOS_DESTINATION` | unset | Override Xcode `-destination` for simulator choice |

### Firebase CI injection

| Variable | Platform | Script |
|----------|----------|--------|
| `FIREBASE_PLIST_BASE64` | iOS | `scripts/ci/inject-firebase-config.sh` |
| `GOOGLE_SERVICES_JSON_BASE64` | Android | `scripts/ci/inject-firebase-config-android.sh` |

Never commit `GoogleService-Info.plist` or `android/app/google-services.json`. Use the `.template` files in git and inject at build time.

## App settings (SettingsManager.swift)

`SettingsManager` is the composition root for all app configuration. It exposes domain-specific sub-stores as `let` properties:

| Sub-store | Purpose |
|-----------|---------|
| `providerPath` | File paths for agent log directories (Codex, Claude, Grok, etc.) |
| `behavior` | Refresh interval, auto-launch, menu bar icon style |
| `cloudSync` | Cloud sync toggle, Firestore write frequency |
| `summary` | Daily digest delivery time, summary format |
| `appearance` | Theme (follows macOS system appearance by default) |
| `quotas` | Per-provider quota configuration |
| `chatBackend` | Hermes webapi endpoint, CLI bridge fallback |
| `index` | Local retrieval index settings |
| `computerUse` | Computer Use session settings (trust mode, scope rules) |

Settings are persisted via `SettingsPersistenceCoordinator` with coalesced writes after a debounce.

## Remote Config feature flags

Flags are evaluated by Firebase Remote Config and respected by `SettingsManager`.

### Computer Use phases

| Flag | Phase | Description |
|------|-------|-------------|
| `computer_use_watch_enabled` | 8 | Agent Watch — Mac→phone read-only mirror |
| `computer_use_browser_enabled` | 9 | Browser Computer Use via Playwright |
| `computer_use_trust_modes_enabled` | 10 | Trust modes, scope rules, audit chain |
| `computer_use_system_enabled` | 11 | Mac System Computer Use (CGEvent + AX) |
| `computer_use_phone_control_enabled` | 12 | Phone-as-controller (Ed25519-signed intents) |
| `computer_use_polish_enabled` | 13 | Trusted scopes, audit export, OpenTimestamps |
| `computer_use_kill_switch` | any | Hard disable across all phases |

### Budget Remote Config

| Setting | Value | Description |
|---------|-------|-------------|
| Soft cap | $1,500/mo | Per-user daily ceiling $5; `evaluateComputerUseBudget` evaluates hourly |
| Hard cap | $2,500/mo | Remote Config kill-switch; daily ceiling $0 |
| Max actions/run | 25 (soft) | Envelope tightens at soft cap |
| Max actions/day | 100 (soft) | Per-user daily ceiling |

## Daemon configuration

| Setting | Value |
|---------|-------|
| Unix socket | `~/.burnbar.sock` (mode `0o600`) |
| launchd plist | `~/Library/LaunchAgents/com.openburnbar.daemon.plist` |
| Support directory | `~/Library/Application Support/OpenBurnBar/` |
| SQLite database | inside support directory, encrypted with SQLCipher |

The socket is created by the daemon on startup; the macOS app and VS Code extension both connect to it.
