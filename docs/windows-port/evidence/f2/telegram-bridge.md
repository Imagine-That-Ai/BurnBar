# F2 evidence: Telegram Mission Control bridge

Date: 2026-07-14
WPD-0006 row: 16
Disposition: SUB-DONE (protected live command bridge)

## Production composition

The Windows app now starts one lifecycle-owned `TelegramPollingService` beside
the authenticated companion and headless-run services. It reloads the persisted
notification settings each cycle, so enabling/disabling Telegram or rotating the
bot token does not require an app restart. The bot token remains in the existing
current-user protected settings store; Mission Control followup/question state is
also stored as a bounded DPAPI-protected payload. The non-secret Telegram update
offset is atomically persisted under the app's local-data directory.

The runtime performs all four live duties from the macOS bridge/evaluator:

- sends due followups and advances their next-nudge timestamp;
- long-polls `getUpdates` with a durable offset;
- filters every update to the configured chat before command dispatch;
- sends command results back through `sendMessage`.

Daily and weekly commands launch real durable `HeadlessAgentRunService` reviews
against the highest-priority healthy configured route. Authenticated companion
operations (`notification.followup.record`, `notification.question.record`, and
`notification.command`) let local Mission Control/agent workflows feed and test
the same protected command state instead of maintaining a disconnected UI stub.

## Contract and safety

- The API origin is fixed to `https://api.telegram.org`; tokens are validated
  before URI construction, redirects are disabled, and provider failures never
  echo the token, request URI, or provider response body.
- Request cancellation propagates. Response headers and streaming bodies are
  bounded to 1 MiB, inbound/outbound text is bounded to Telegram's 4,096
  characters, and each poll accepts at most 100 updates.
- `sendMessage` correctly accepts Telegram's message-object result (rather than
  incorrectly decoding it as a Boolean).
- Updates are processed in update-ID order. The next offset is persisted before
  chat filtering/command execution, matching macOS replay behavior and avoiding
  duplicate side effects after a reply failure.
- The parser supports `help`, `pending`, `followups`, `done`, `snooze`,
  `calendar`, `answer`, `latest`, `status`, `run_daily`, and `run_weekly`, plus
  the macOS `daily`/`weekly` aliases. EventKit-backed calendar mutation remains
  the explicit Windows structural N/A in WPD-0006 row 17.
- Polling is single-flight, intervals are bounded to 1 second through 5 minutes,
  loop errors are isolated, and shutdown cancels and awaits the poller before
  the gateway and headless runtime are disposed.

## Verification

Focused tests cover fixed-origin HTTP request shape, response decoding, token
redaction, streaming size limits, cancellation, all command aliases, ordered
offset handling, wrong-chat isolation, disabled configuration, atomic offset
recovery, followup list/snooze/done, question answers, due-message rescheduling,
real review/status delegates, state bounds, and authenticated companion routing.

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj -c Release --no-restore
Passed: 277, Failed: 0, Skipped: 0

dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj -c Release --no-restore
Passed: 189, Failed: 0, Skipped: 0
```

The macOS authoring host compiles all portable dependencies but cannot execute
the Windows App SDK `XamlCompiler.exe`; the exact-head Windows x64/ARM64 workflow
is therefore the authoritative app-composition build proof.
