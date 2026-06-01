# Privileged socket red-team (release candidate)

Validates post-P0 behavior: an unsigned console probe must be **rejected** on the VirtualHID privileged socket.

## Prerequisites

- RC Mac build with P0+ privileged daemons installed (direct download / not MAS-stripped Computer Use daemons).
- Xcode command-line tools.
- Socket present: `/var/run/openburnbar-virtual-hid.sock`

## Steps

```bash
cd /path/to/BurnBar
bash scripts/ops/run-privileged-socket-redteam.sh
```

## Pass criteria

- `OpenBurnBarPrivilegedSocketRedTeamProbe` exits **1** (rejected).
- `PrivilegedSocketRedTeamIntegrationTests` runs (not skipped) and passes.
- Evidence file written: `launch-evidence/privileged-redteam-rc-<timestamp>.txt`

## Failures

| Symptom | Likely cause |
|---------|----------------|
| XCTSkip: socket absent | Daemons not running or RC build without privileged services |
| XCTSkip: probe missing | Run script (builds probe) or `swift build --product OpenBurnBarPrivilegedSocketRedTeamProbe` |
| Probe exit 0 | Pre-P0 regression — do not ship |
| XCTest failure | Policy/auth regression in VirtualHID bridge |

Attach the evidence file to the security signoff PR or internal ops bucket before checking the Phase 2 ops box in [`SOTA_10_10_SIGNOFF.md`](../security/SOTA_10_10_SIGNOFF.md).