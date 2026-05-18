# Phase 9 Device Matrix - Browser Computer Use

## Scope

Browser Computer Use lets the agent drive a managed Playwright Chromium session through the daemon bridge.

## Required Checks

| Check | Command / Evidence | Expected |
|---|---|---|
| Playwright installed | `scripts/install-playwright.sh` | `playwright@1.49.1`, Chromium installed |
| Bridge loopback | `scripts/test-computer-use-loopback.sh` | `playwright bridge loopback smoke: OK` |
| Daemon build | `cd OpenBurnBarDaemon && swift build --target OpenBurnBarDaemon` | exit `0` |
| Mac app build | `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -quiet build` | exit `0` |

## Result Log

| Timestamp | Device / Host | Build | Install / Setup | Scenario Result | Evidence |
|---|---|---|---|---|---|
| 2026-05-18T04:55:28Z | Mac local Playwright coordinator, headless Chromium | PASS: `RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1 swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorPlaywrightScenarioTests` exited `0`; normal opt-in Step + Trusted scenario tests passed | PASS: `scripts/install-playwright.sh` restored pinned Playwright 1.49.1 browser cache after the headless shell was missing | PASS: `RUN_COMPUTER_USE_PLAYWRIGHT_50_RUN_GATE=1 swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorPlaywrightScenarioTests/testFiftyLocalBrowserScenariosValidateAuditChainEveryRun` ran 50 real Playwright coordinator sessions, alternating Step and Trusted trust modes. Each session executed 7 browser actions (`goto`, `fill`, `click`, `select`, `key`, `extract`, `screenshot`) and validated `chain.jsonl` with `ComputerUseAuditChain.validate(... expectedHeadHashHex:)`. Total: 50/50 sessions, 350/350 executed responses, 350/350 audit entries, 0 audit-chain validation failures. | Test output: `phase9_50_run_gate runs=50 responses=350 auditEntries=350 elapsedMs=23900` |

## Manual Smoke

1. Start a browser Computer Use session from the Mac.
2. Approve `browser_goto` to `about:blank`.
3. Approve a navigation to a non-authenticated public page.
4. Run `browser_extract` on a visible heading.
5. Reject the next click and confirm the audit timeline records `user_rejected`.

## Failure Rules

- Any missing Chromium binary blocks Phase 9.
- Any bridge process that does not exit after `shutdown` blocks Phase 9.
- Any browser action that bypasses approval blocks Phase 9.
