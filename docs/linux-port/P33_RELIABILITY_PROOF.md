# P-33 Reliability installed proof

P-33 is credited only when the exact signed, installed Linux candidate completes the full reliability campaign in a supported live desktop environment. Unit tests, fixture transports, source-level soak results, an unsigned package, or screenshots without the native transcript do not count.

The production runner performs this fail-closed sequence:

1. Verify the signed candidate and package ownership of `/usr/bin/openburnbar-cli`, `/usr/bin/openburnbar-daemon`, and `/usr/bin/openburnbar-linux-desktop`.
2. Start a real daemon health subscription, record its identifier and cursor, stop the user daemon, expose the accessible **Daemon unavailable** state, restart it, and resume the same subscription. The resumed cursor must advance, report disconnect and restart recovery, preserve bounded backpressure, and deliver no duplicate or terminal event.
3. `SIGSTOP` the daemon long enough to force a bounded socket timeout, prove a non-overlapping monotonic retry schedule, then `SIGCONT` it and require recovery.
4. Disable and restore the target's actual network, require zero subscription attempts while offline, and prove automatic online recovery within 30 seconds.
5. Suspend and resume the target, then require installed-shell health and subscription recovery within 60 seconds.
6. Move the system clock by at least 60 seconds and restore it, lock and unlock the active Secret Service/KWallet, exclusively lock and release the daemon database, and restart the desktop portal. Each fault must be observed before its bounded recovery can pass.
7. Exercise installed queries against genuine 10,000-row and 100,000-row data sets plus a transcript of at least 1 MB. Run low-memory and software-rendering recovery cases.
8. Run a 30-minute alternating idle/use soak with at least 30 cycles of each, zero health failures, and no more than 64 MiB RSS growth.
9. Relaunch the installed desktop and restore the exact original daemon, desktop process, network, portal, clock, keyring, and isolated-state topology.

Four distinct nonblank screenshots and live AT-SPI summaries bind healthy, degraded, recovered, and relaunched Support states. Every copied byte is re-hashed. The marker derives a one-use challenge from the target HEAD, candidate run, artifact digest, random marker, and nonce. Materialization rejects extra, missing, unsafe, or replayed raw artifacts; capture refuses replacement and binds the result into the product closure.

The disruptive operations intentionally fail closed when the target lacks noninteractive PolicyKit authorization or the required seeded scale corpus. Run this only in the dedicated parity VM, never on a developer workstation.

Focused verification:

```bash
node --test scripts/linux-port/p33-reliability-proof.test.mjs scripts/linux-port/ownership-tests/P-33.test.mjs
node --check scripts/linux-port/run-p33-native-reliability-probes.mjs
node --check scripts/linux-port/lib/p33-reliability-proof.mjs
```
