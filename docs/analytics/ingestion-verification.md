# Amplitude Ingestion — Projects, Key Wiring, Verification

Opt-in usage analytics ship to **Amplitude** (org `imaginethatai`, US data center →
`https://api2.amplitude.com`). Two projects keep dev and prod data separate, per the security
contract.

| Project | Amplitude project ID | Used by |
|---------|:--------------------:|---------|
| **OpenBurnBar Dev** | `830581` | local builds, staging, CI instrumentation tests |
| **OpenBurnBar** (prod) | `830583` | production builds of every platform |

> **Zero keys are committed.** Each platform reads its ingestion key from the env/secret below at
> build time; an absent key leaves the wrapper **dark by construction** (the recorder's key check).
> The key *values* live only in the Amplitude console + CI secrets — never in the repo. (Ingestion
> keys are client-side write keys, not secrets like the Data API *secret* key, but we keep them out
> of git regardless.)

## Per-platform key wiring (set to the **prod** key for release builds, **dev** key otherwise)

| Platform | Env var / secret | How it reaches the wrapper |
|----------|------------------|----------------------------|
| macOS (`AgentLens`) | `BURNBAR_AMPLITUDE_API_KEY` | `scripts/ci/inject-amplitude-config.sh` replaces the `__AMPLITUDE_API_KEY__` placeholder in `AnalyticsConfig.swift` |
| Website (`website`) | `PUBLIC_ANALYTICS_COLLECTOR_URL` (browser) + `AMPLITUDE_API_KEY` (collector Worker secret) | Browser POSTs to the first-party collector; the Worker stamps the Amplitude key. `PUBLIC_AMPLITUDE_API_KEY` is retired for the marketing site. |
| Console (`apps/console`) | `NEXT_PUBLIC_AMPLITUDE_API_KEY` | Next build env → `process.env` |
| VS Code ext (`extensions/openburnbar`) | `BURNBAR_EXTENSION_AMPLITUDE_API_KEY` | injected at package/CI time |
| Backend (`functions`) | `AMPLITUDE_API_KEY` | functions runtime config/env |
| Android (`android/app`) | `OPENBURNBAR_AMPLITUDE_API_KEY` (or `amplitude.apiKey` in gitignored `local.properties`) | Gradle → `BuildConfig.AMPLITUDE_API_KEY` |
| iOS / widget / keyboard | xcconfig/Info.plist placeholder injected at build | shared App Group → host wrapper |

The marketing site no longer talks to `api2.amplitude.com` from the browser. Point
`PUBLIC_ANALYTICS_COLLECTOR_URL` at the first-party Worker (`workers/analytics-collector/`)
or another same-origin collector path, and allow that origin in `connect-src`.
Console / native clients still use platform Amplitude SDKs with build-time keys.

## Verification (2026-06-18)

1. **Raw ingestion** — `POST https://api2.amplitude.com/2/httpapi` with the Dev key →
   `{"code":200,"events_ingested":1}`. The event appears on the OpenBurnBar Dev project
   (Events This Month = 1).

2. **Live end-to-end through the real website wrapper** — built the site with the Dev key, served
   it, clicked **Enable analytics** in the consent banner. The wrapper dynamically imported the SDK
   and `POST /2/httpapi` returned **200** carrying exactly:
   - `consent.analytics.granted` · `app.session.started` · `screen.viewed`
   - props: `platform=web`, `surface=home`, `app_version`, `event_category` (lifecycle / screen_view)
   - `device_id` = random UUID, **no `user_id`**, no IP in payload, **zero PII**.

3. **Pre-consent darkness** — before opt-in, the served HTML loads **no** Amplitude script and makes
   **no** request to `api2.amplitude.com` (the SDK is a dynamic chunk fetched only on opt-in).

**Pipeline proven** (key → SDK → Amplitude, and the website wrapper end-to-end). Per-platform *live*
ingestion for the other surfaces is gated only on running each runtime (Xcode 16 for Apple, an
emulator/device for Android, a deploy for backend) with its key set — the wrappers themselves are
unit-tested to emit the same taxonomy events, and the key + endpoint are confirmed working.
