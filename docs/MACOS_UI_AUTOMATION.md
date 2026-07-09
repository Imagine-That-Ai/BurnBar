# macOS UI Automation

This runbook defines the Mac mini bridge for real macOS UI automation. The
controller builds test products; the mini runs them inside the logged-in Aqua
session through a LaunchAgent.

```text
MacBook/controller
  xcodebuild build-for-testing
  rsync Build/Products or OpenBurnBar.app
  write queue/<job-id>.job over SSH
        |
        v
Mac mini gui/<uid> LaunchAgent
  scripts/macmini/runner-daemon.sh
  xcodebuild test-without-building or CUClickSmoke
  writes results/<job-id>/status.json last
        |
        v
MacBook/controller
  rsync results to .artifacts/macmini/<job-id>/
```

## Coverage Layers

| Layer | Catches | Cannot catch |
| --- | --- | --- |
| Unit and snapshot tests | View model behavior, render regressions, deterministic UI states | Real AppKit focus, TCC, status items, testmanagerd attachment |
| XCUITest on the mini | Real app launch, XCTest runner attachment, keyboard/click flows, accessibility identifiers | Non-XCTest AX/CGEvent failures, screen-lock effects outside XCTest |
| AX real-app smoke | Launching `OpenBurnBar.app`, AX tree availability, status item or dashboard root presence, screenshot evidence | Deep product assertions owned by XCUITest |
| Pixel evidence | What was actually visible on the mini desktop at failure time | Semantic correctness without paired logs |

## One-Time Mini Setup

Run these on the Mac mini:

1. Enable SSH:
   System Settings -> General -> Sharing -> Remote Login -> On.

2. Optional operator access:
   System Settings -> General -> Sharing -> Screen Sharing -> On.

3. Keep a GUI user logged in. XCUITest, AXUIElement, and CGEvent automation
   must run in the logged-in Aqua session. A bare SSH process cannot attach to
   testmanagerd or post UI events.

4. For a controlled lab runner, consider:
   System Settings -> Users & Groups -> Automatically log in as the runner user,
   and System Settings -> Lock Screen -> disable short display sleep and lock
   timers. This improves automation reliability but weakens physical-security
   posture; use it only for a controlled runner.

Then run from the controller:

```bash
cp scripts/macmini/config.env.example scripts/macmini/config.env
$EDITOR scripts/macmini/config.env
scripts/macmini/bootstrap-mini.sh
scripts/macmini/mini-doctor.sh
```

The bootstrap script installs `com.openburnbar.uitest-runner` in `gui/<uid>`,
copies `runner-daemon.sh`, builds and pushes `CUClickSmoke`, disables sleep
best-effort, enables developer tools best-effort, and checks Xcode first-launch
state.

## TCC Grants

TCC grants must be made on the mini in the logged-in user session. Grants do not
inherit from `/usr/bin/ssh` into a LaunchAgent. Grant the actual runner binaries.

Accessibility:

```text
System Settings -> Privacy & Security -> Accessibility
```

Enable:

- `/bin/bash` as the LaunchAgent host shell when macOS prompts for it.
- `$MACMINI_RUNNER_ROOT/bin/CUClickSmoke`.
- `OpenBurnBarUITests-Runner.app` when it appears after the first XCUITest run.

Screen Recording:

```text
System Settings -> Privacy & Security -> Screen Recording
```

Enable:

- `/bin/bash`.
- `$MACMINI_RUNNER_ROOT/bin/CUClickSmoke`.
- `OpenBurnBarUITests-Runner.app` when macOS prompts for it.

`mini-doctor.sh` runs `CUClickSmoke --probe-permissions`, which prints:

```json
{"axTrusted":true,"screenCapture":true}
```

## Running

Remote XCUITest:

```bash
scripts/test-openburnbar-ui.sh --remote
```

Remote AX smoke against a built app:

```bash
scripts/test-openburnbar-ui.sh --remote --ax-smoke /path/to/OpenBurnBar.app
```

Dry run without SSH:

```bash
scripts/macmini/run-remote-ui-tests.sh --dry-run
```

Local runner mode, intended for use on the mini or future self-hosted CI:

```bash
scripts/test-openburnbar-ui.sh --local
```

Filters:

```bash
OPENBURNBAR_UI_TEST_FILTER=OpenBurnBarUITests/SomeTest \
  scripts/test-openburnbar-ui.sh --remote
```

Artifacts land under `.artifacts/macmini/<job-id>/`. PR-grade durable evidence
belongs under `docs/macos-ui-automation/evidence/`, following the compact
README/JSON/transcript style used by `docs/linux-port/evidence/`.

## Failure Modes

| Failure | Detection | Remedy |
| --- | --- | --- |
| Mini asleep | SSH timeout, no LaunchAgent log growth | Wake the mini, keep power connected, rerun `bootstrap-mini.sh` for `pmset -a sleep 0` |
| Screen locked | XCUITest attach failures, AX tree empty, screenshots show lock screen | Log into the mini desktop; adjust Lock Screen settings for the lab runner |
| TCC revoked after macOS update | `mini-doctor.sh` probe shows `axTrusted:false` or `screenCapture:false` | Re-grant Accessibility and Screen Recording to the listed binaries |
| Xcode skew between controller and mini | `test-without-building` rejects the `.xctestrun` or build products | Install matching Xcode major/minor on both machines, then rebuild |
| Stale LaunchAgent | `mini-doctor.sh` LaunchAgent row fails or old logs keep repeating | Run `scripts/macmini/bootstrap-mini.sh` to bootout/bootstrap/kickstart |
| Rsync partial payload | Runner log says `.xctestrun` or app missing | Re-run; the controller deletes and recreates `payloads/<job-id>/` before copy |
| Hung test | Controller warns `runner.log` stopped growing and exits on poll timeout | Inspect `.artifacts/macmini/<job-id>/runner.log` and screenshots; terminate stale app/test runner on the mini if needed |
| Missing Xcode first launch | Bootstrap warns `xcodebuild -checkFirstLaunchStatus` failed | Run `sudo xcodebuild -runFirstLaunch` on the mini |

## Files

| File | Purpose |
| --- | --- |
| `scripts/macmini/config.env.example` | Local mini connection template |
| `scripts/macmini/lib.sh` | Shared SSH, rsync, config, and logging helpers |
| `scripts/macmini/bootstrap-mini.sh` | Idempotent mini installation and LaunchAgent setup |
| `scripts/macmini/mini-doctor.sh` | Controller preflight table |
| `scripts/macmini/runner-daemon.sh` | LaunchAgent-owned job consumer |
| `scripts/macmini/run-remote-ui-tests.sh` | Controller build/copy/queue/poll/pull entrypoint |
| `scripts/test-openburnbar-ui.sh` | Canonical local/remote UI test wrapper |
| `tools/CUClickSmoke` | AX/CGEvent permission probe and real-app smoke CLI |
