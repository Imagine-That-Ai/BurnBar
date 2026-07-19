# Windows Remote Safety Config

**Status:** implemented in source with portable tests. A signed Windows build
and live staging toggle receipt are still required before release certification.

## Contract

Windows reads the same Firebase Remote Config safety keys as macOS through the
`getWindowsRuntimeSafetyConfig` callable. The relay is required because the
Windows desktop client does not embed the Firebase Remote Config SDK. It accepts
no tenant or object identifiers and returns only a fixed set of booleans.

The callable requires Firebase Auth and App Check. It reads only Remote Config
default values, applies the macOS secure defaults, and returns a server timestamp
with a 90-second lease. Missing or malformed values resolve as follows:

- every Computer Use feature flag: `false`;
- `computer_use_kill_switch`: `true`;
- `media_kill_switch`: `true`;
- `computer_use_phone_control_respects_deny_regions`: `true`.

Conditional Remote Config targeting is not evaluated by this relay. Windows
safety keys must therefore be published as fleet-wide default values. A future
conditional rollout needs a server-side, testable evaluation contract before it
may replace this global posture.

## Client behavior

`WindowsRuntimeSafetyConfigMonitor` fetches immediately and every 60 seconds.
The client accepts only the exact schema, every required boolean, a maximum age
between 30 and 300 seconds, and a fresh server timestamp. Transport errors,
timeouts, malformed responses, stale responses, sign-out, and missing App Check
all publish the secure closed snapshot.

The privileged input broker uses two independent layers:

1. `privileged-input-kill.flag` is the operator/watchdog panic latch. Remote
   recovery never clears it.
2. `privileged-input-remote-safety.flag` is an expiring authorization lease.
   Missing, malformed, blocked, or expired content denies every dispatch.

The broker checks both layers before target inspection and again immediately
before synthesis. Broker pipe `v2` prevents an upgraded app from reconnecting to
a still-running pre-lease broker. App startup also creates the local panic latch
if none exists, so a user must explicitly start a System session after the first
valid remote lease.

Browser, Agent Watch, System, elevated trust modes, and Mercury media settings
consume the live snapshot. Any kill-switch activation, fetch failure after an
allowed state, or feature revocation converges on the existing Computer Use
panic path. App exit blocks the remote lease immediately; an app crash is bounded
by the lease expiry.

## Staging certification

Deploy only the bootstrap and proof surface needed for the test:

```bash
gh workflow run deploy-staging.yml --ref main \
  -f dry_run=false \
  -f deploy_functions=true \
  -f function_targets='functions:issueWindowsAppCheckChallenge,functions:mintWindowsAppCheckToken,functions:getWindowsRuntimeSafetyConfig,functions:submitDomainCoreShadowSamples'
```

Use the exact signed candidate and capture redacted receipts for:

1. unauthenticated and missing-App-Check calls denied;
2. signed-in TPM App Check call returning the exact schema;
3. `computer_use_system_enabled=true` plus both kill switches off authorizing a
   lease for no longer than 90 seconds;
4. `computer_use_kill_switch=true` halting an active run within 60 seconds;
5. callable outage or malformed response halting and leaving the operator panic
   latch intact;
6. `media_kill_switch=true` denying Mercury admission;
7. app termination followed by broker denial after lease expiry;
8. restoring the staging template to its reviewed baseline.

Never print ID tokens, App Check tokens, TPM claims, OAuth codes, Remote Config
API credentials, or callable authorization headers into the evidence bundle.

## Deterministic checks

```bash
cd functions
npx vitest run src/__tests__/windowsRuntimeSafetyConfig.test.ts \
  src/__tests__/endpointAuthorizationMatrix.test.ts \
  src/__tests__/bola/authOnly.bola.test.ts

cd ..
dotnet test windows/tests/cloudsync-app/OpenBurnBar.App.CloudSync.Tests.csproj
dotnet test windows/tests/computeruse/OpenBurnBar.ComputerUse.Tests.csproj
dotnet test windows/tests/settings/OpenBurnBar.App.Settings.ViewModels.Tests/OpenBurnBar.App.Settings.ViewModels.Tests.csproj
dotnet build windows/computeruse/OpenBurnBar.PrivilegedInput/OpenBurnBar.PrivilegedInput.csproj \
  -p:EnableWindowsTargeting=true
```
