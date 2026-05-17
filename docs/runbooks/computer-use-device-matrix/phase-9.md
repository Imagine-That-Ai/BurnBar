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
