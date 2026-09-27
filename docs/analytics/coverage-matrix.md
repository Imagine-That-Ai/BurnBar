# OpenBurnBar Analytics — Coverage Matrix

Tracks, per platform, whether each **surface** emits each **event category** through the
consent-gated wrapper. Driven by [`event-taxonomy.md`](event-taxonomy.md). A platform is "done"
when its grid is fully green **and** its opt-in/revoke tests pass.

**Legend:** ✅ instrumented + tested · 🟡 instrumented, test pending · ⬜ planned · — N/A for this surface

> Every platform always emits the Tier 1 spine (`app.session.*`, `screen.viewed`,
> `auth.*`, `settings.changed`, `error.handled`, `consent.analytics.granted`). The grid below
> tracks **surface-level** coverage of the five categories.

---

## macOS desktop (`AgentLens/`, `platform: macos`) — reference platform

| Surface              | lifecycle | screen_view | primary_action | conversion_auth | error |
|----------------------|:---------:|:-----------:|:--------------:|:---------------:|:-----:|
| app / lifecycle      | 🟡 | 🟡 | — | — | 🟡 |
| onboarding           | 🟡 | 🟡 | 🟡 | 🟡 | — |
| account / auth       | — | 🟡 | — | 🟡 | 🟡 |
| dashboard (overview + lanes) | — | 🟡 | 🟡 | — | 🟡 |
| model / provider detail | — | 🟡 | 🟡 | — | 🟡 |
| chat                 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| insights             | 🟡 | 🟡 | 🟡 | — | 🟡 |
| settings             | — | 🟡 | 🟡 | — | — |
| quota                | 🟡 | 🟡 | 🟡 | — | 🟡 |
| budget               | — | 🟡 | 🟡 | — | 🟡 |
| cloud sync           | 🟡 | — | 🟡 | 🟡 | 🟡 |
| menubar / windows / wallpaper | 🟡 | 🟡 | 🟡 | — | — |
| **consent gate**     | ✅ | — | — | — | — |

> `consent gate` lifecycle ✅ = `AnalyticsConsentStore` tri-state + opt-in/revoke contract is
> implemented and unit-tested (the spine that makes every other cell safe to fill).

---

## Other platforms (fan-out)

> 🟡 here = wrapper + consent + instrumentation are implemented and the platform-agnostic core is
> unit-tested, but the **full** app build is gated on Xcode 16 (absent from this dev box; the project
> hard-requires the 16.x line). Android is now fully built — its SDK installs without credentials.

| Platform | Wrapper | Consent gate | First-run opt-in | Instrumented | Tests | Disclosures |
|----------|:-------:|:------------:|:----------------:|:------------:|:-----:|:-----------:|
| iOS / iPadOS (`OpenBurnBarMobile/`) | ✅ | ✅ | ✅ | 🟡 (Xcode 16) | ✅ core | ✅ |
| Widget (`OpenBurnBarWidget/`)       | ✅ | ✅ (reads host) | — | 🟡 (Xcode 16) | ✅ core | ✅ |
| Keyboard (`OpenBurnBarKeyboard/`)   | ✅ | ✅ (reads host) | — | 🟡 (Xcode 16) | ✅ core | ✅ |
| Android (`android/app/`)            | ✅ | ✅ | ✅ | ✅ | ✅ (1159) | ✅ |
| Website (`website/`)                | ✅ | ✅ (banner) | ✅ | ✅ | ✅ | ✅ |
| Console (`apps/console/`)           | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| VS Code extension (`extensions/openburnbar/`) | ✅ | ✅ (telemetry + opt-in) | ✅ | ✅ | ✅ | ✅ |
| Backend (`functions/`, optional)    | ✅ | ✅ (consent flag) | — | 🟡 (1 conversion wired) | ✅ | ✅ |

---

## Verification log

| Platform | Pre-consent dark (proof) | Event received after opt-in (proof) | Revoke silences (proof) |
|----------|--------------------------|-------------------------------------|-------------------------|
| macOS    | ✅ unit test + instrumentation **compiles clean** under Swift 6.2 (Xcode 26.3) | ⬜ app-hosted run + live ingestion gated on a **pre-existing** Swift-6 strict-concurrency cascade in non-analytics code (Chat*/ComputerUse/Search…) — repo migration debt, not analytics | ✅ unit test |

> macOS note: the full app build surfaced **10 real type bugs in the analytics instrumentation**
> (raw `String` where `AnalyticsValue` is required, in `BudgetSettings`/`BudgetNotificationCenter`) —
> all fixed; the instrumentation then compiled cleanly. The app build is then blocked by pre-existing
> `sending '…' risks data races` errors across many non-analytics files (the repo isn't Swift-6 strict-
> concurrency-clean). That migration is out of scope for analytics and is flagged for a separate pass.
> The analytics module + consent-contract tests pass standalone (Swift 6.2). Toolchain reality: the code
> targets **Xcode 26** (`glassEffect`, `extendLifetime`), so `project.yml`'s `16.0` pin is stale.
| iOS / widget / keyboard | ✅ core unit test (Swift 6 strict) | ⬜ needs prod key + Xcode 16 | ✅ core unit test |
| Android  | ✅ full debug build + 1159 unit tests green | ⬜ needs prod key | ✅ unit test |
| Website  | ✅ build-proven: no Amplitude key in the browser; collector URL empty → dark | ✅ unit + collector contract: consented POST to first-party collector only; Worker returns `events_forwarded`; anon device_id created at start-after-consent | ✅ unit test: revoke stops + silences |
| Console  | ✅ build-proven: SDK in a lazy chunk, 0 refs in first-load JS / prerendered HTML | ⬜ needs prod key | ✅ unit test |
| Extension| ✅ SDK client never constructed until opt-in **and** VS Code telemetry on | ⬜ needs prod key | ✅ unit test |
| Backend  | ✅ no emit without a propagated granted-consent flag + key (unit tests) | ⬜ needs prod key | — (per-request; no persistent client) |
