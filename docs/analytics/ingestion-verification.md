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
or another collector origin, and allow that origin in `connect-src` (CSP `'self'` is
exact-origin — a `burnbar.web.app` collector is not implied by a `burnbar.ai` page).
Console / native clients still use platform Amplitude SDKs with build-time keys.

Hosting lanes compile that URL from optional GitHub Actions variables
(`vars.PUBLIC_ANALYTICS_COLLECTOR_URL` for production, `vars.STAGING_ANALYTICS_COLLECTOR_URL`
for staging). An unset variable builds `""`, so `Analytics.canSend` stays false until
ops deploys the Worker and sets the variable. Do not bake a URL into the workflow.
`csp:check` compares the committed dark marketing CSP. When the production variable
is set, `deploy-hosting.yml` runs `csp:update` after verify so the deployed
`firebase.json` `connect-src` includes that collector origin. Staging
`build-hosting-candidate` always runs `csp:update` after `build:staging` and
packages the reviewed `firebase.json` in the hosting artifact;
`deploy-staging-trusted.yml` generates `firebase-hosting.json` from that
artifact instead of the committed dark default.

Amplitude **routes by API key**, not by `AMPLITUDE_PROJECT_ID`. The numeric id is a local
allowlist + event stamp (OpenBurnBar `830583` / Dev `830581` only). Bind each deploy's
`wrangler secret` to that project's key. A CubeLove or Hormiga key would still land in
those projects even if `AMPLITUDE_PROJECT_ID=830583`.

## Verification (collector path)

1. **Worker dark without a key** — `AMPLITUDE_API_KEY` unset → `204` and no Amplitude POST.
   Consent false → `204`. Forbidden project ids → `409`.

2. **Consented collector forward** — with the Dev key and `AMPLITUDE_PROJECT_ID=830581`,
   `POST` `{consent:true,events:[{name:"page.viewed",...}]}` from an allowlisted origin.
   The Worker returns `{accepted:true,events_forwarded:N,project_id:830581}` and POSTs
   Amplitude HTTP V2. The browser payload must not contain `api_key`.

3. **Pre-consent darkness** — before opt-in the page does not persist a device id, does
   not POST to the collector, and does not talk to `api2.amplitude.com`.

4. **Raw Amplitude sanity (ops only)** — `POST https://api2.amplitude.com/2/httpapi` with
   the **project-specific** Dev key still returns Amplitude's `{code:200,events_ingested:1}`.
   That is a key check, not the website path.

Unit tests in `website/test/collector.test.ts` cover consent, project routing, Arena
allowlisting, origin rejection, and email stripping. Live ingestion for native surfaces
still needs each runtime with its key injected.
