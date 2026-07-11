# Linux performance and reliability validation

Linux performance parity is measured in two complementary layers. Neither
layer may be replaced by fixture-only timings or a single synthetic sample.

## Packaged-shell measurements

`scripts/linux-port/linux-desktop-session.sh` installs and launches the actual
`.deb` and records repeated user-visible timings:

| Metric | Measurement boundary | Minimum samples | PR p95 budget |
| --- | --- | ---: | ---: |
| `app.start` | New packaged process to visible X11 window | 10 | 2500 ms |
| `route.navigation` | Route command to two animation frames after React commit | 19 | 120 ms |
| `ipc.health.roundtrip` | Tray reconnect to AF_UNIX daemon activity | 10 | 800 ms |
| `tray.click.open` | AppIndicator menu action to visible X11 window | 10 | 400 ms |

The first app-start sample is cold. The remaining samples fully terminate and
relaunch the installed process. Route samples must use an
`*-route-after-paint:<route>` source; pre-paint state-loop sources fail the
budget contract.

## Matched macOS/Linux workloads

`tools/matched-performance` is a standalone Swift package that links the same
production implementations on both operating systems:

- GRDB/SQLCipher-backed SQLite range queries
- GRDB/SQLCipher-backed FTS memory search
- deterministic incremental JSONL session decoding
- `HermesOpenAICompatibleStreamParser` first-visible SSE delta decoding

The database and stream probes are separate executables. This avoids symbol
interposition between the vendored SQLite linked by `OpenBurnBarCore` and the
SQLCipher-linked GRDB process while keeping both probes production-linked.

Every run validates the protocol version, platform, architecture, profile,
seed, configuration, workload inventory, sample count, percentile ordering,
absolute p95/p99 limits, Linux-relative p95/p99 limits, deterministic
checksums, soak duration, iteration count, RSS, RSS growth, and CPU use. A
missing workload, mismatched checksum, stale implicit input, or malformed
percentile fails closed.

Profiles are defined in `budgets/linux-desktop.perf.json`:

| Profile | Rows | Samples | Warmups | Soak |
| --- | ---: | ---: | ---: | ---: |
| smoke | 100 | 5 | 1 | 1 second |
| PR | 10,000 | 15 | 3 | 5 seconds |
| nightly | 100,000 | 30 | 5 | 30 minutes |

## Reliability supervisor

The renderer health supervisor keeps exactly one daemon probe in flight. It
uses a 30-second active cadence, a 120-second background cadence, exponential
failure backoff from one to 30 seconds, and immediate wake-up on focus,
visibility, or network restoration. Unmount stops all timers and listeners.
Boot no longer executes synthetic database, parser, memory, media, or control
frame diagnostics on the critical path.

## Commands

```bash
# Contract mutation tests
node --test scripts/linux-port/matched-performance-contract.test.mjs
node --test scripts/linux-port/perf-budget-contract.test.mjs

# Fresh local smoke on both platforms
node scripts/linux-port/run-matched-performance.mjs --profile smoke

# Installed package, matched workloads, and full shell evidence
node scripts/linux-port/run-shell-smoke.mjs

# Verify an existing evidence directory
OB_EVIDENCE_OUT=/path/to/evidence \
  node scripts/linux-port/run-perf-budget.mjs
OB_EVIDENCE_OUT=/path/to/evidence \
  node scripts/linux-port/verify-shell-evidence.mjs /path/to/evidence full
```

CI creates the macOS reference independently, uploads it, runs the Linux probe,
and compares both artifacts. The nightly workflow uses the same contract with
the 30-minute profile. Raw platform reports and the comparison report are
retained so a green summary cannot hide missing source evidence.

## QA checklist

- [ ] Ten process launches, tray reopens, and daemon reconnects are present.
- [ ] Every required route has an after-paint sample.
- [ ] All four matched workloads exist once and have matching checksums.
- [ ] macOS and Linux report the same protocol, seed, row count, and profile.
- [ ] p95/p99 absolute and relative limits pass.
- [ ] Soak duration, iterations, RSS, RSS growth, and CPU checks pass.
- [ ] Killing the daemon produces bounded backoff and recovery after restart.
- [ ] Offline/online, focus, and visibility transitions trigger one probe only.
- [ ] Single-sample, pre-paint, checksum-mismatch, and missing-workload
  mutations fail.
