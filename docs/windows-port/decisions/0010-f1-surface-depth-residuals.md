# WPD-0010: F1 surface depth residuals (production-honest, not full Mac peer)

- **Status:** Accepted (goal driver, 2026-07-09)
- **Date:** 2026-07-09
- **Scope:** F1 nav/settings/integration rows that ship production-honest empty
  or partial peers but lack host-proven full Mac depth. Prevents silent
  Substituted gaps while forbidding false Real promotions.

## Decision

Rows listed as **DeferredApproved** under this WPD are production-safe
(empty/deferred disclosure, sample only under `OPENBURNBAR_SAMPLE_MODE`) but
are **not** full Mac peers. Revive to `Real` only with live Windows evidence +
tests and zero forbidden-token defaults on blocking paths.

| Area | Revive trigger |
|---|---|
| Dashboard layouts / live usage default | Win11 proof of live SQLCipher usage composition as default |
| Insights engine rollups (non-KPI) | Live Insights engine path for rankings/series on Windows |
| Quota live watch + cloud snapshots | Windows path watcher + OAuth cloud snapshots |
| Session Logs host SQLCipher open of Mac DB | Host evidence of Mac-produced DB open/read |
| Memory cloud review inbox live | OAuth + App Check + live Firestore memory |
| Mission Control Firestore dispatch live | Authenticated dispatch proof on Windows |
| Budget cloud rules + toast | Live cloud budget + WinRT toast proof |
| DCC high-risk envelopes | Live authenticated export/revoke envelopes |
| Switcher encrypted profile host | Host proof of encrypted profile store |
| Onboarding first-run host | First-run proof on Win11 |
| Settings S1–S2 full tab pages | No SettingsPlaceholderPage for S0–S2; render smoke |
| Elder Wand presets-only → deeper peer | Beyond presets when product requires |
| Flyout tray metrics live | Live quota/health cards not sample |
| Theme liquid-glass polish | Does not gate data Real; residual visual only |
| Pet companion live overlay | Live WebView2 glTF host proof |
| Native FFI MSVC loopback host | MSVC build + loopback on Windows |

## Chat

`nav-chat` is DeferredApproved until a **configured Windows host** streams live
assistant tokens through `ChatSurfaceViewModel` via `CliJsonLineChatStreamDriver`
+ process/ConPTY adapter. Portable parser + factory are shipped; host process
attachment is the revive gate (see master plan H3 exit criteria).
