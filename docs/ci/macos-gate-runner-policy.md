# macOS gate runner policy

All macOS product lanes (`app-pr-gate` and `headless-app-build` post-merge/nightly;
`daemon-pr-gate`, `domain-core`, and `pr-native-fast` on the PR/merge path) run
only on free GitHub-hosted `macos-26` runners:

```yaml
runs-on: macos-26
```

There is no pool toggle. The former `MACOS_GATE_POOL` variable (fleet/paid
branches), the `burnbar-ci-paid` group, and the `burnbar-turbo-ephemeral` local
fleet are retired: the turbo dispatcher workflow is deleted, and
`scripts/ci/verify-github-hosted-runners-only.mjs` (wired into workflow-lint)
fails closed on any reintroduction.

## Deliberate exception

`linux-product-parity.yml` keeps two self-hosted jobs that cannot run on
GitHub hardware: the paired-physical-iPad producer and the per-distro signed
package install validator. Both are manual-dispatch-only and additionally
require explicit `confirm_local_runners: true` consent (default off); the
runners-only gate pins both the allowlist and the consent input.

## Known trade-off

Free capacity is two concurrent macOS runners. That is ample for ordinary PR
traffic and deliberately slow for a deep queue drain. If queue latency ever
forces a rethink, add a new policy here first — do not reintroduce runner
labels or pool toggles without updating the gate and its tests.
