# macOS gate runner policy

## Default: free

The nine required macOS gates (`app-pr-gate`, `daemon-pr-gate`, `domain-core`,
`headless-app-build`, `pr-native-fast`) run on the in-house Apple Silicon fleet by
default. Those runners cost nothing per job.

```yaml
runs-on: ${{ vars.MACOS_GATE_POOL == 'paid'
  && fromJSON('{"group":"burnbar-ci-paid"}')
  || fromJSON('["self-hosted","macOS","ARM64","m5max"]') }}
```

## Opting into the paid pool

Set the repository variable `MACOS_GATE_POOL` to `paid` when a run needs the speed
and parallelism of the hosted pool — for example when draining a deep merge queue:

```sh
gh variable set MACOS_GATE_POOL --repo Imagine-That-Ai/BurnBar --body paid   # billed
gh variable delete MACOS_GATE_POOL --repo Imagine-That-Ai/BurnBar            # back to free
```

The paid branch remains the **isolated capped** `burnbar-ci-paid` group. Ephemeral and
uncapped workers (`burnbar-turbo-ephemeral`, `BurnBar-macos-26-xlarge`) stay banned for
these gates; `scripts/ci/verify-pr-harness-aggregate-gates.test.mjs` enforces all of this.

## Why `m5max` and not the whole fleet

The free lane pins the `m5max` label rather than the broader `burnbar-turbo` label
because it is the only fleet Mac that satisfies both requirements:

| Machine | Toolchain | Xcode | Eligible |
| --- | --- | --- | --- |
| M5 Max | node, cargo, protoc, gradle, cmake, swiftlint | 26.6 (pinned via runner `.env`) | yes |
| M1 Pro | none (no brew/node/cargo/protoc) | 26.6 | no |
| Mac mini | partial | 27.0 only — breaks BurnBar Swift builds | no |

Widening the free lane means equipping those machines first, then adding their labels here.

## Known trade-off

Free capacity is two concurrent macOS runners. That is ample for ordinary PR traffic and
deliberately slow for a deep queue drain — which is exactly when `MACOS_GATE_POOL=paid`
is worth setting. A spending cap on the paid pool fails **closed**: GitHub reports
"the job was not started because recent account payments have failed or your spending
limit needs to be increased", which looks like an outage rather than a billing state.
Check `gh api /repos/:owner/:repo/check-runs/<job_id>/annotations` when a gate dies with
no code change.
