# Calendar Analytics View (all five platforms)

A month-grid calendar where the grid itself is the data visualization: each day
cell paints a heat wash scaled to that month's busiest day, and selecting days
drives a customizable panel of analytics cards computed from the usage rows on
exactly those days.

macOS is the **oracle**. iOS, Android, Windows, and Linux are ports that must
agree with it number-for-number; the "Shared semantics" contract below is the
thing to check first when a port looks wrong.

## Surfaces

| Platform | Route / entry | Implementation | Tests |
|---|---|---|---|
| macOS | `DashboardMainRoute.calendar` | `AgentLens/Views/Calendar/*.swift`, `AgentLens/Services/Charts/CalendarDataService.swift` | `AgentLensTests/Active/Calendar*Tests.swift` |
| iOS | `AuroraNavDestination.calendar`, `burnbar://calendar` | `OpenBurnBarMobile/Views/Calendar/*.swift`, `OpenBurnBarMobile/Models/CalendarStore.swift` | `OpenBurnBarMobileTests/Calendar*Tests.swift` |
| Android | `BurnBarTab.CALENDAR`, `burnbar://calendar` | `android/.../ui/calendar/*.kt`, `android/.../data/stores/CalendarStore.kt` | `android/app/src/test/java/com/openburnbar/Calendar*Test.kt` |
| Windows | `calendar` → `CalendarPage` | `windows/app/OpenBurnBar.App.Presentation/Calendar/*.cs`, `windows/app/OpenBurnBar.App/Calendar/` | `windows/tests/presentation/Calendar/` |
| Linux | `ShellRoute 'calendar'` | `apps/linux-desktop/src/surfaces/calendar/`, `src/state/calendarStore.ts` | `src/surfaces/calendar/calendarMath.test.ts` |

## Shared semantics (the parity contract)

These are the behaviours that decide whether the numbers on screen are right.
A port that diverges here is a bug, not a platform idiom.

1. **Day attribution is local-timezone `startOfDay` of the row's start time.**
   Never the UTC `DATE(startTime)` SQL path, never the end time, and rows are
   never split across midnight — a session that runs 23:50→00:20 belongs
   entirely to the day it started.
2. **Heat is scaled to the month peak, with a sqrt ramp.** Day cells use
   `0.10 + 0.55 * sqrt(cost / peak)`; the hour heatmap uses
   `0.14 + 0.78 * sqrt(value / peak)`. The sqrt is load-bearing: without it one
   monster day washes the rest of the month out. The denominator spans the
   whole grid — leading/trailing overflow cells paint too and can claim the
   peak — while the header's month total counts the visible month alone.
   The metric is **cost**, never tokens.
3. **Selection is Finder/Photos multi-select.** Plain click replaces the
   selection and moves the anchor; ⇧-click extends inclusively from the anchor;
   ⌘/Ctrl-click toggles one day; drag paints a contiguous range. Ranges include
   both endpoints, use calendar arithmetic (DST-safe), and carry a 372-day
   guard. Changing month **preserves** the selection.
4. **Per-day burn is gap-filled.** Silent days inside the selection span emit
   zero-value points so the series stays continuous instead of collapsing.
5. **Sessions are counted distinct.** Rows with no session id collapse into one
   synthetic bucket rather than disappearing.
6. **Unattributed spend stays visible.** Rows with no project name bucket as
   `"Unattributed"` in project focus — that bucket is frequently the largest,
   so dropping it would understate the card.
7. **Model keys are normalized before grouping** — `custom:` / `vibeproxy:`
   prefixes (Cursor conventions) stripped, then trimmed and lowercased, so one
   model never splits into two rows. Ported from
   `TokenExtractionUtility.normalizeModelKey`.
8. **Layout is persisted JSON**: an ordered
   `[{kind, isVisible, span: 1...3}]`. Decoding is forward-compatible —
   unknown kinds dropped, missing kinds appended with defaults, duplicates
   deduplicated. Card raw values are identical on all five platforms.

## Cards

Eight cards, same set and same raw values everywhere: `kpis`,
`burnOverSelection`, `providerMix`, `modelMix`, `hourOfDayHeatmap`,
`projectFocus`, `cacheROI`, `reasoningShare`. Each can be hidden, reordered by
drag, and resized across a 3-column grid (S/M/L spans).

Cache and reasoning math is byte-identical across platforms:
`cacheHitRate = cacheRead / (input + cacheCreation + cacheRead)`,
`cacheSavings = 0.9 × cacheRead × (totalCost / totalTokens)`,
`reasoningShare = reasoning / totalTokens`.

## Layout storage keys

| Platform | Key |
|---|---|
| macOS | `calendarPageLayout.v1` (UserDefaults) |
| iOS | `calendarPageLayout.v1` (UserDefaults) |
| Android | `calendar_page_layout_json_v1` (DataStore preferences) |
| Windows | `calendarPageLayout.v1` |
| Linux | `openburnbar.linux.calendarLayout.v1` (localStorage) |

macOS, iOS, and Windows share the exact `calendarPageLayout.v1` key. Android
and Linux use their platform-idiomatic conventions (DataStore preferences are
snake_case; Linux localStorage keys are namespaced `openburnbar.linux.*.v1`),
which is deliberate — those two storage backends are unrelated and layouts do
not sync across devices. The JSON schema is identical everywhere.

## Data sources

- **macOS** — `DataStore.fetchUsage(in:limit:)` for the visible month ±
  selection, bucketed with `ChartBucketing.dateBuckets(component: .day)`;
  breakdowns reuse `UsageStore.make*Summaries`; distinct session counts follow
  `UsageStore+OrgRollup.swift`'s SQL.
- **iOS** — `DashboardStore` rollups for context, raw events via
  `FirestoreRepository.fetchUsageSince(_:)` for the selection breakdowns.
- **Android** — `listenToUsageSince(startDate)`, aggregated client-side in the
  device timezone. The window is the visible month padded by
  `GRID_OVERFLOW_PAD_DAYS`. Server `dailyPoints` deliberately does **not** seed
  the heatmap: that series is UTC-keyed **tokens**
  (`functions/src/rollupCompute.ts`), so mixing it into a USD map renders token
  counts as dollars. A month outside the live window reads empty — an honest
  gap instead of a wrong number.
- **Windows** — `CalendarUsageProvider` walks the honest ladder: live local
  runtime → cloud Firestore REST → labeled sample → empty.
- **Linux** — `daemon.usage.recent` over JSON-RPC, with the fixture →
  `OfflineNotice` degraded ladder.

## Start-time attribution on Linux

Linux reads usage from the daemon, whose `recordedAt` is stamped when a
*completed* call is logged — effectively an end time. Bucketing by it put a
call running 23:50→00:20 on the wrong day.

`BurnBarUsageEvent` now carries an optional `startTime`
(`OpenBurnBarKernel/Contracts/BurnBarProviderContracts.swift`), populated at
the gateway and run-service sites where a real start instant exists, and read
through `attributionInstant()` in `calendarMath.ts` as `startTime ?? recordedAt`.

Three properties make this safe:

- **Optional by necessity.** The daemon ledger is an append-only JSONL file
  (`usage-events.jsonl`) with no migrator, and its loader is strict — one
  undecodable line would take down both reads and writes. `decodeIfPresent`
  keeps every historical row loading, and follows the same additive pattern
  `parentRequestID`, `confidence`, and `reasoningTokens` already established.
- **Never invented.** `startTime` is set only where the start is genuinely
  known (the gateway's `attemptStartedAt`, the run service's pre-call stamp).
  Paths with no honest start — notably Elder Wand fusion sub-calls, whose
  records carry no time field — leave it `nil` and fall back to `recordedAt`
  rather than stamping `Date()` at record time, which would look precise while
  restating the end time.
- **Sorting and identity untouched.** Recency sorts and idempotency-key
  fallbacks still use `recordedAt`; switching those would rewrite dedup keys
  and re-import history as duplicates.

macOS gets a second fix for free: `OpenBurnBarDaemonUsageSyncService` used to
map `startTime: event.recordedAt, endTime: event.recordedAt`, so every
daemon-imported row had zero duration. It now maps the real start when present.

No Rust change was needed — the Tauri bridge passes daemon JSON through
opaquely. No GRDB migration was needed either: the app-side `token_usage` table
already has `startTime`/`endTime` columns.

## Validation

| Platform | Command |
|---|---|
| macOS | `./scripts/test-openburnbar-app.sh -only-testing:OpenBurnBarTests/Calendar...` |
| iOS | `./scripts/test-openburnbar-mobile.sh` (`OPENBURNBAR_MOBILE_TEST_FILTER=OpenBurnBarMobileTests/Calendar...`) |
| Android | `cd android && ./gradlew :app:testDebugUnitTest` |
| Windows | `cd windows && dotnet test tests/presentation --filter "FullyQualifiedName~Calendar"` |
| Linux | `npx tsc --noEmit && npm test && npm run build` |

The Linux packaged-session smoke script
(`scripts/linux-port/linux-desktop-session.sh`) enumerates every route by name;
`calendar` / `"Calendar"` must stay in both `route_names` and `route_labels`,
in `routes.ts` order.
