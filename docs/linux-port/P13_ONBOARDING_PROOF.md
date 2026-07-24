# P-13 installed onboarding proof

P-13 closes only from an exact installed, signed Linux candidate in a live desktop session. Source tests, fixture mode, screenshots without daemon readback, and an OAuth browser opening are not substitutes.

## What the proof establishes

`run-p13-native-onboarding-probes.mjs` starts the installed daemon through `/usr/libexec/openburnbar-daemon-launch` with an isolated owner-only support directory, token, home, and index database. It temporarily stops and later restores the user's `openburnbar-daemon.service`. The installed `/usr/bin/openburnbar-linux-desktop` is observed and controlled through AT-SPI in a real X11 and D-Bus session.

The probe proves:

- daemon-owned reset, ordered required gates, premature-completion rejection, completion, and byte-identical restart readback;
- production Secret Service and provider-data probes from the installed daemon;
- a catalog-backed disabled credential-slot create, config readback, and removal round trip without writing credential material to evidence;
- explicit blocked and repair states for unavailable cloud identity, portal input, and update integration, plus native retry and skip controls;
- explicit tray and update deferral, privacy choices committed through the daemon, and config readback;
- distinct nonblank installed UI captures for provider setup, unavailable cloud recovery, privacy, and completed setup.

All raw artifacts, the installed manifest and signature, the materialized session, and the derived proof are bound to the exact target HEAD, candidate workflow run, artifact digest, package version, architecture, format, desktop environment, and manifest hashes.

## Production authentication boundary

This workflow deliberately exercises the **unavailable** cloud-auth path and records `productionOAuthSuccess: false`. It does not fabricate an identity, device approval, portal grant, or OAuth callback. A candidate where cloud identity is already configured fails this probe instead of cancelling or modifying a live authorization operation.

A separate production-auth proof requires a release OAuth configuration, a disposable test identity, browser authorization, trusted-device approval when requested, callback/poll completion, explicit cancellation and retry runs, and cleanup verified by the account service. Portal success likewise requires user-granted consent in the target compositor. Until those preconditions are present, P-13 proves honest unavailable recovery, not production OAuth or portal success.

## Capture order

1. Run `run-p13-native-onboarding-probes.mjs` with unique P-13 raw/support/home paths and the candidate bindings.
2. Run `materialize-p13-onboarding-session.mjs` in the same environment. It re-verifies the installed candidate and copies only regular non-symlink artifacts.
3. Run `capture-p13-onboarding-proof.mjs` against the materialized session.
4. Register `feature.onboarding-installed` only after the standalone scripts and tests are present in the candidate workflow.

The runner's `finally` path removes a temporary credential slot even after failure and always attempts to restore the prior user-daemon state. A cleanup failure is fatal.

## Focused verification

```bash
node --test \
  scripts/linux-port/p13-native-onboarding-probes.test.mjs \
  scripts/linux-port/p13-onboarding-proof.test.mjs
node --check scripts/linux-port/run-p13-native-onboarding-probes.mjs
python3 -m py_compile scripts/linux-port/p13-atspi-control.py
```

Mutation coverage rejects forged completion, missing restart persistence, retained credential slots, production OAuth overclaims, substituted AT-SPI actions, and replayed screenshots.
