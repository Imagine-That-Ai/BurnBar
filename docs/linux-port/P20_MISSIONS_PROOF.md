# P-20 Installed Missions Proof

P-20 closes only when the exact signed Linux candidate proves the complete
Missions lifecycle through the installed desktop, installed daemon, and native
AT-SPI surface. Source tests and fixture-mode UI are not accepted as product
evidence.

## Required lifecycle

The native runner `scripts/linux-port/run-p20-native-missions-probes.mjs` uses
an isolated owner-only home, daemon support directory, Unix socket, auth token,
and index database. It must prove, in order:

1. A real project is registered and a mission is created in
   `awaiting_approval`.
2. The installed Missions UI exposes the pending approval and approves it via
   AT-SPI. Canonical `daemon.mission.get` must read back `approved`.
3. A typed mission packet is dispatched and a typed result is recorded with a
   positive burn delta, evidence reference, and merged PR linkage.
4. `daemon.mission.health` returns health and controller history.
5. A daemon-backed pending question with a suggested answer is selected and
   submitted through AT-SPI. `daemon.question.list` must read back the exact
   answer and selected option.
6. The isolated daemon is restarted. Mission packet, result, PR linkage,
   health, and history must remain present.
7. The installed UI opens mission detail and exposes packets, results,
   evidence, and controller history, then cancels through the two-step UI.
   Canonical daemon readback must return `cancelled`.

The session contains five distinct nonblank screenshots and a candidate-bound
AT-SPI transcript. Replayed screenshots, reordered daemon calls, substituted
mission/question identifiers, missing restart state, fixture evidence, and
unsigned or mismatched installed candidates fail closed.

## Live execution

Run the native probe inside a supported Linux desktop session after installing
the exact signed candidate. Materialize its raw output with
`materialize-p20-missions-session.mjs`, then capture the registered proof with
`capture-p20-missions-proof.mjs`. The product validator is
`scripts/linux-port/product-validators/P-20.mjs`.

The runner temporarily stops the normal user daemon only when it was active,
launches the installed daemon against isolated state, and restores the original
service state in `finally`. Raw evidence must remain inside the named parity
worktree. A live VM pass is not claimed until these scripts execute against the
signed candidate and the resulting receipt passes the shared closure.

## Focused verification

```bash
node --test \
  scripts/linux-port/p20-native-missions-probes.test.mjs \
  scripts/linux-port/p20-missions-proof.test.mjs
```
