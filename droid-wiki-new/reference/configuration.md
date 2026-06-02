# Configuration

Reference for environment variables, build settings, runtime configuration, and secrets management across all OpenBurnBar surfaces.

## Build environment variables

### Android

| Variable | Default | Purpose |
|----------|---------|---------|
| `JAVA_HOME` | `~/.homebrew/opt/openjdk@21` | Java 21 (required by Gradle 8.9 + AGP 8.7.3) |
| `ANDROID_HOME` | `~/Library/Android` | Android SDK root |
| `ANDROID_SDK_ROOT` | same as `ANDROID_HOME` | Legacy alias; set both |
| `OPENBURNBAR_ANDROID_KEYSTORE_PATH` | unset | Release keystore file path |
| `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD` | unset | Release keystore password |
| `OPENBURNBAR_ANDROID_KEY_ALIAS` | unset | Release key alias |
| `OPENBURNBAR_ANDROID_KEY_PASSWORD` | unset | Release key password |
| `OPENBURNBAR_ANDROID_SENTRY_DSN` | unset | Injected into `AndroidManifest.xml` at build time; empty disables Sentry |
| `OPENBURNBAR_USE_DEBUG_APP_CHECK` | `false` | When `true`, wires the Firebase App Check debug provider instead of Play Integrity |
| `OPENBURNBAR_APP_CHECK_DEBUG_TOKEN` | `""` | Debug provider token for simulator/CI/physical debug builds |

### macOS / iOS (Xcode / Makefile)

| Variable | Default | Purpose |
|----------|---------|---------|
| `OPENBURNBAR_DEVELOPMENT_TEAM` | `4Y367DF25B` | Code-signing team ID |
| `OPENBURNBAR_ENABLE_COVERAGE` | unset | Set to `1` to enable code-coverage instrumentation |
| `OPENBURNBAR_IOS_DESTINATION` | unset | Override Xcode `-destination` for simulator choice |
| `OPENBURNBAR_SENTRY_DSN` | unset | Injected into the daemon executable at launch; read by `OpenBurnBarDaemonMain.swift` |

### Cloud Functions / Node

| Variable | Purpose |
|----------|---------|
| `SENTRY_DSN` | Sentry ingest DSN for the functions project. Gracefully disabled when unset (local dev). |
| `STRIPE_BURNBAR_PRO_PRICE_ID` | Stripe price ID for BurnBar Pro checkout |
| `STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID` | Stripe price ID for BurnBar Cloud monthly |
| `STRIPE_BURNBAR_CLOUD_ANNUAL_PRICE_ID` | Stripe price ID for BurnBar Cloud annual |
| `STRIPE_SECRET_KEY` | Stripe secret key for checkout and webhook reads |
| `STRIPE_WEBHOOK_SECRET` | Stripe webhook signing secret |
| `FIREBASE_PLIST_BASE64` | iOS CI: base64-encoded `GoogleService-Info.plist` |
| `GOOGLE_SERVICES_JSON_BASE64` | Android CI: base64-encoded `google-services.json` |
| `BURNBAR_EXTENSION_SENTRY_DSN` | VS Code extension Sentry DSN |
| `ANDROID_SENTRY_DSN` | Android Sentry DSN |

## Factory quota overrides

Used by `FactoryQuotaAdapter.swift` to authenticate against the Factory exact-quota API. These are optional; when absent, OpenBurnBar falls back to heuristics.

| Variable | Purpose |
|----------|---------|
| `FACTORY_COOKIE_HEADER` | Explicit session cookie for Factory API calls (e.g. `session=factory-session`) |
| `FACTORY_BEARER_TOKEN` | Explicit bearer token for Factory API calls |

These are read from `ProcessInfo.processInfo.environment` at runtime, not compiled into the binary.

## Firebase config injection patterns

Real Firebase config files contain API keys and must **never** be committed.

| File | Template | Injection script | Secret |
|------|----------|------------------|--------|
| `AgentLens/Resources/GoogleService-Info.plist` | `AgentLens/Resources/GoogleService-Info.plist.example` | `scripts/ci/inject-firebase-config.sh` | `FIREBASE_PLIST_BASE64` |
| `OpenBurnBarMobile/Resources/GoogleService-Info.plist` | same example | same script | `FIREBASE_PLIST_BASE64` |
| `android/app/google-services.json` | `android/app/google-services.json.template` | `scripts/ci/inject-firebase-config-android.sh` | `GOOGLE_SERVICES_JSON_BASE64` |

Local development: download from the Firebase Console and copy into place. CI decodes the base64 secret and writes the real file before the build.

## Remote Config feature flags

`SettingsManager.swift` fetches and activates Firebase Remote Config on app launch. Defaults are hardcoded in `commercialRemoteConfigDefaults` so the app behaves correctly when offline.

### Computer Use phases

| Flag | Phase | Default | Description |
|------|-------|---------|-------------|
| `computer_use_watch_enabled` | 8 | `false` | Agent Watch — Mac→phone read-only mirror |
| `computer_use_browser_enabled` | 9 | `false` | Browser Computer Use via Playwright |
| `computer_use_trust_modes_enabled` | 10 | `false` | Trust modes, scope rules, audit chain |
| `computer_use_system_enabled` | 11 | `false` | Mac System Computer Use (CGEvent + AX) |
| `computer_use_phone_control_enabled` | 12 | `false` | Phone-as-controller (Ed25519-signed intents) |
| `computer_use_phone_control_attestation_required` | 12 | `false` | Require attestation for phone control |
| `computer_use_polish_enabled` | 13 | `false` | Trusted scopes, audit export, OpenTimestamps |
| `computer_use_kill_switch` | any | `false` | Hard disable across all phases |
| `computer_use_phone_control_respects_deny_regions` | 12 | `false` | Geo-deny region enforcement |

### Budget and media guardrails

| Flag | Default | Description |
|------|---------|-------------|
| `media_kill_switch` | `false` | Hard-disable Mercury Media |
| `media_budget_soft_usd` | `600` | Soft cap for Mercury relay bandwidth |
| `media_budget_hard_usd` | `1_000` | Hard cap for Mercury relay bandwidth |
| `media_normal_file_gb_per_day` | `5` | Normal file-transfer daily GB limit |
| `media_soft_file_gb_per_day` | `2` | Soft-cap file-transfer daily GB limit |
| `computer_use_budget_soft_usd` | `1_500` | Computer Use soft monthly cap |
| `computer_use_budget_hard_usd` | `2_500` | Computer Use hard monthly cap (kill-switch) |
| `computer_use_actions_per_run_normal` | `50` | Max actions per run at normal budget |
| `computer_use_actions_per_day_normal` | `200` | Max actions per day at normal budget |
| `computer_use_usd_per_user_day_normal` | `5` | Per-user daily spend ceiling at normal budget |
| `computer_use_actions_per_run_soft` | `25` | Max actions per run at soft cap |
| `computer_use_actions_per_day_soft` | `100` | Max actions per day at soft cap |

### Cloud Pro SKUs

| Flag | Default | Description |
|------|---------|-------------|
| `hosted_quota_daily_refresh_limit` | `30` | Daily hosted-runner refresh attempts per account |
| `hosted_quota_monthly_refresh_limit` | `300` | Monthly hosted-runner refresh attempts per account |
| `cloud_pro_included_hosted_actions_monthly` | `500` | Included hosted actions in Cloud Pro |
| `cloud_pro_action_topup_unit` | `100` | Action top-up unit size |
| `cloud_pro_monthly_hosted_action_cap` | `2_000` | Absolute monthly hosted-action cap |
| `cloud_pro_included_relay_gb_monthly` | `50` | Included relay GB in Cloud Pro |
| `cloud_pro_relay_topup_unit_gb` | `50` | Relay GB top-up unit size |
| `cloud_pro_monthly_relay_gb_cap` | `300` | Absolute monthly relay GB cap |

## App settings (SettingsManager.swift)

`SettingsManager` is the composition root for all app configuration. It exposes domain-specific sub-stores:

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

## Keychain-backed secrets

Sensitive data is stored in the macOS Keychain, never in UserDefaults or plaintext files.

| Service | Purpose | Accessibility |
|---------|---------|---------------|
| `com.openburnbar.controller.runtime` | Controller Telegram bot token, routed provider API keys | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `com.openburnbar.chat.gateway` | Hermes / OpenClaw bearer tokens | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| `com.openburnbar.daemon.token` | Short-lived daemon socket auth token | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| SQLCipher encryption key | Database encryption key | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Iroh pairing private key | Ed25519 pairing key for iroh transport | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Iroh blob store key | Blob store encryption key | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |

There is no automatic plaintext recovery file for the SQLCipher key. If the Keychain entry is lost, the encrypted database is unrecoverable unless the user previously exported an explicit passphrase-protected recovery bundle (`DatabaseEncryptionService.exportRecoveryBundle(password:)`).

## Daemon runtime configuration

| Setting | Value |
|---------|-------|
| Unix socket | `~/.burnbar.sock` (mode `0o600`) |
| launchd plist | `~/Library/LaunchAgents/com.openburnbar.daemon.plist` |
| Support directory | `~/Library/Application Support/OpenBurnBar/` |
| SQLite database | Inside support directory, encrypted with SQLCipher |
| HTTP gateway | `BurnBarHTTPGatewayServer` actor, loopback-only by default, raw HTTP/1.1 on `Network.framework` |

The socket is created by the daemon on startup; the macOS app, CLI, and VS Code extension all connect to it.

## Related pages

- [Data models](data-models.md) — schema definitions that consume these configuration values
- [RPC surface](rpc-surface.md) — runtime methods that read config and return settings
- [Dependencies](dependencies.md) — libraries that parse and store configuration
