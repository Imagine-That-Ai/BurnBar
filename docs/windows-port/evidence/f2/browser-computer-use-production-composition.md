# Browser Computer Use production composition

Ledger row: `f2-browser-computer-use`

## What this proves

The Windows app no longer carries Browser Computer Use as an exercised core
that production never reaches. The app packages the reviewed JavaScript bridge,
discovers an explicit or pinned Playwright 1.49/Chromium runtime, and launches it
through `ChildProcessLaunchPolicy` without a shell. The Computer Use settings
surface reports runtime availability, persists a non-secret check target, and
runs an explicit user-initiated launch/navigate/evaluate/close lifecycle using a
fixed `document.title` evaluation. It does not expose arbitrary script entry in
settings.

The lifecycle rejects oversized URLs, script counts, script bytes, process
arguments, malformed argument JSON, credential-bearing URLs, and known literal
loopback/private/metadata targets before launch. The reviewed bridge remains the
network chokepoint: it re-resolves named targets for every request and fails
closed on private/link-local/metadata answers, DNS-rebinding, resolution errors,
redirects, and subresources. Process input/output is serialized, responses are
bounded, stderr is drained, close is time-bounded, and final disposal kills the
process tree when necessary.

## Production paths

- `windows/app/OpenBurnBar.App.Configuration/WindowsBrowserComputerUseService.cs`
- `windows/app/OpenBurnBar.App/Settings/WindowsSettingsPersistence.cs`
- `windows/app/OpenBurnBar.App/OpenBurnBar.App.csproj`
- `windows/computeruse/OpenBurnBar.ComputerUse.Core/Browser/BrowserComputerUseLifecycle.cs`
- `windows/computeruse/OpenBurnBar.ComputerUse.Core/Browser/BrowserProcessLaunchOptions.cs`
- `OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js`

## Validation

Local validation on 2026-07-13:

- Computer Use: 114 passed, 1 live-host test skipped when its explicit runtime
  environment is absent.
- Live process driver -> JavaScript bridge -> Playwright 1.49 -> Chromium:
  1 passed, 0 skipped; launch, data-page navigation, title evaluation, and clean
  close completed in about two seconds.
- Settings view models: 175 passed, including unavailable runtime, unsafe URL,
  persistence, success, and daemon-matrix truthfulness cases.
- Configuration: 39 passed, including explicit direct-process configuration,
  malformed JSON rejection, and reviewed launch inventory.
- Distribution: 98 passed, including structured verification that the bridge is
  copied to both build and publish layouts.
- `node scripts/test-playwright-bridge-guard.mjs`: passed all literal-IP,
  metadata, DNS-rebinding, resolution-failure, redirect-chokepoint, and direct
  Windows protocol cases.

Hosted Windows Full run
[29304837991](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29304837991)
at exact implementation commit `e7f43649c36c13df9ea5a565d728e86d1feab520`
passed the full x64 suite, the full native-hosted ARM64 suite, and the focused
Windows x64 process-driver -> JavaScript bridge -> Playwright 1.49 -> Chromium
lifecycle with **1 passed, 0 failed, 0 skipped**. The focused browser test took
807 ms after the isolated pinned runtime was installed. Physical ARM64 browser
and safety certification remains an explicit beta limitation rather than an
automated-host claim.

## Boundary

This evidence proves production composition and a real managed-browser
lifecycle. It does not replace the independent physical Windows approval,
panic-kill, accessibility, media/file-safety, or public release protocols.
