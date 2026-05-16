# Media Device Matrix Results

Per-phase soak-test results for the Mercury media rollout. Format mirrors `docs/runbooks/iroh-rollout-status.md` and the device matrix specified in `plans/2026-05-15-mercury-media-master-plan.md` § J.3.

Each phase appends a `phase-N.md` file. Each file records, per device per scenario:

- Scenario (10-min soak call · 100 MB file transfer · 5-min screen share · etc).
- p50 / p95 / p99 RTT (ms).
- Freeze count (visual stalls > 100 ms).
- Encoder failures (count + recovered).
- Outcome (passed / failed / partial — with note).

## Devices in scope

| Device | Phase 3 (share) | Phase 4 (audio) | Phase 5 (video) | Phase 6 (multicam) |
|---|---|---|---|---|
| iPhone 13 mini (A15) | receive | both | H.264 outbound | n/a |
| iPhone 15 Pro (A17 Pro) | both | both | HEVC | n/a |
| iPhone 17 Pro Max | both | both | HEVC | n/a |
| iPad mini 6 | both | both | H.264 | n/a |
| iPad Pro M4 | both + PiP | both | HEVC | multicam |
| Mac Intel Core i7 (Skylake+) | encode | both | HEVC | host-only |
| Mac M1 | both | both | both | host-only |
| Mac M3 / M4 | both | both | both | host-only |

## Pre-Phase-3 (Phase 1 + 2)

File transfer is the only Phase 1 + 2 capability and rides reliable QUIC streams without a per-device codec path, so no formal device matrix is required. A Phase 1 spot-check: 5 MB PNG send Mac M3 → iPhone 17 Pro across LAN + LTE topologies, BLAKE3 round-trip verified, wall-clock under 15 s on 50 Mbps.

## Phase results

`phase-3.md`, `phase-4.md`, `phase-5.md`, `phase-6.md` will be created as each phase reaches the soak-test gate.
