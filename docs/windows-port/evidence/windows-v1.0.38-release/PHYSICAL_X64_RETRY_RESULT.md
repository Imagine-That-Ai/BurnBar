# Physical Intel x64 Retry Result

**Date:** 2026-07-19

**Verdict:** `NO-GO` with a validator-clean evidence bundle.

## Passed

- Exact signed artifact hash, source binding, Imagine That AI LLC signature,
  and RFC 3161 timestamp.
- Native HP Intel/AMD64 hardware identity and clean candidate/harness checkouts.
- Cold launch: 20/20 responsive, zero matching crash events.
- Warm relaunch: 20/20 responsive, zero matching crash events.
- Uninstall, exact-package reinstall, and second 20/20 responsive launch.
- Idle capture: 300 samples over 300 seconds; normalized CPU p95 8.084 percent,
  maximum private bytes 101.94 MB, and process write rate 0.200 MB/minute.
- Soak: 1,800 samples over 1,822 seconds, zero unresponsive samples, zero
  matching crashes, 0.616 percent normalized average CPU, 100.34 MB maximum
  private bytes, and negative private-memory growth.
- All 26 route screenshots and route-root UIA anchors, including high contrast,
  reduced transparency, DPI 100, and compact `640x720`.
- `gcloud` authentication, `burnbar-staging` access, staging environment enable
  and restore, and final evidence validation.

## Still blocked

| Gate | Missing proof | Recovery |
| --- | --- | --- |
| Accessibility/display | The semantic probe coupled valid UIA inspection to a scheduled-task desktop bitmap that remained blank. Manual Narrator, keyboard-only, 150/200 percent DPI, and mixed-DPI receipts are also absent. | Rerun with the corrected independent harness, then perform and record every remaining manual assertion. |
| Physical performance x64 | Canonical flyout/dashboard/search/settings/chat/scan latency samples, frame pacing, and sleep/wake are incomplete. | Install PresentMon or an approved equivalent, capture complete sample series, perform physical sleep/wake, and finalize the budget-bound supplemental receipt. |
| Staging cloud | The retry did not run the authorized OAuth/App Check/TPM/CloudVault assertions. | Use the committed staging-only fixture publisher and complete every staging assertion without exposing tokens. |
| Media/Computer Use safety | The iPhone was detected, but trusted pairing, permissions, interruption, quarantine, exact approval, panic/watchdog/kill-switch, audit tamper, and replay receipts are absent. | Run the harmless paired-device protocol and restore the Remote Config baseline in `finally`. |
| Store/update lifecycle | No authorized Partner Center private flight or predecessor package was available. | After the other gates pass, create only the approved internal flight and run the complete install/update/repair/rollback/activation/feed protocol. |
| Physical performance ARM64 | No qualifying physical ARM64 Windows device is available. | Keep the explicit beta limitation; do not relabel CI or VM evidence as physical. |

## Staging fixture recovery

The retry's loose-file handoff failure is removed by
`scripts/windows-port/remote-config-certification-fixtures.json` and
`scripts/windows-port/publish-staging-remote-config-fixture.ps1`. The publisher
derives all four payloads from one committed catalog and refuses every project
except `burnbar-staging`.

For every non-baseline drill, restoration remains mandatory:

```powershell
$Publisher = Join-Path $Harness 'scripts\windows-port\publish-staging-remote-config-fixture.ps1'
try {
    & $Publisher -Fixture ComputerKill -ConfirmStagingMutation
    # Run the harmless signed-app observation and save its sanitized evidence.
}
finally {
    & $Publisher -Fixture Baseline -ConfirmStagingMutation
}
```

The script output is sanitized metadata only. Do not add access tokens, OAuth
codes, App Check tokens, TPM claims, authorization headers, or vault keys to
the protocol evidence.
