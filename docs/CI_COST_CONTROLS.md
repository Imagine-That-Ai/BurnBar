# CI cost controls

BurnBar uses one required status context, `BurnBar CI Gate`. On pull requests the
gate polls [`governance/burnbar-ci-gate.fast.json`](../governance/burnbar-ci-gate.fast.json)
(45-minute PR eligibility set without the slow walls). Merge-queue candidates
still fail closed on the full component inventory in
[`governance/burnbar-ci-gate.json`](../governance/burnbar-ci-gate.json). The gate
is always emitted and fails closed until every required component context is
successful, neutral, or intentionally skipped.

Slow walls kept off the fast PR set: Daemon PR Gate, Android PR Gate, PR Windows
Full Gate, and Domain Core PR Gate remain merge-queue / classic-protection
walls where applicable. App build + test (AgentLens) and Mobile build + unit
test are post-merge/nightly macos-26 proofs — they do not run on
`pull_request`, and `merge_group` only emits skipped receipts so a stale
BurnBar CI Gate inventory cannot hang the queue. Headless App Build is
push-to-main + nightly only. Domain Core stays path-scoped evidence when
`rust=true`; its aggregator must not sit in the 45-minute eligibility umbrella
while `swift-consumer-contracts` can still run for tens of minutes.

## Path classification

[`scripts/ci/classify-ci-impact.mjs`](../scripts/ci/classify-ci-impact.mjs)
sorts the exact base-to-head diff and selects the macOS, mobile, Android,
Rust/domain-core, daemon, Functions, website/extension, and console lanes.
The classifier is deterministic and defaults to full CI for an empty or
unresolvable diff, an unknown path, shared build infrastructure, dependency
manifests, security policy, release/deploy code, and its own gate configuration.
Plain Windows test sources are owned by the Windows gates and do not rebuild
Apple products; .NET project/solution manifests still force full validation,
and Windows consumers of domain-core still select the Rust lane.

Workflows use job-level conditions. Do not add workflow-level `paths` filters to
an always-required workflow: GitHub leaves its required context pending when the
workflow does not start. An unselected product job reports `skipped`; its local
aggregate verifies that the classifier explicitly selected that outcome.

## Full validation

Full cross-platform validation remains available through nightly schedules,
release workflows, `workflow_dispatch`, and the `full-ci` pull-request label.
Adding `full-ci` reruns classifier-backed workflows because they subscribe to
the `labeled` activity. Merge-group diffs are classified from the synthetic
candidate SHA and fail closed when that exact diff cannot be resolved.

## Caches

Native jobs cache dependency/build directories with lockfile-keyed entries:
SwiftPM uses `.spm-cache-new` plus the SwiftPM download cache, Gradle uses
`setup-java`'s Gradle cache, and Rust workflows use lockfile-aware Rust caches.
Generated outputs may be cached only when their generator inputs are included
in the key and the workflow still runs its drift check after restore.
The macOS app test driver reuses the exact DerivedData produced by the preceding
real-process CPU build on the same runner, so the test action compiles the test
bundle without rebuilding the entire product and dependency graph from scratch.

Default-branch warming lives in
[`.github/workflows/ci-cache-warm.yml`](../.github/workflows/ci-cache-warm.yml).
GitHub scopes cache writes to the writing ref: PR/merge-queue entries are
invisible to other refs, so cold MQ candidates used to rebuild Signal FFI and
re-resolve SwiftPM every time. The warm workflow writes Signal FFI xcframeworks
and the App PR Gate `app-spm` / `mobile-spm` keys on `main` (hosted `macos-26`,
same image as consumers) so every PR and merge-queue restore can hit. SPM warm
prefers `xcodebuild -resolvePackageDependencies` over a full app compile.

## Runner policy

BurnBar uses standard GitHub-hosted runners by default. The public repository
must not be granted access to the shared persistent self-hosted runner group,
and workflows must not route labels to paid larger-runner pools. Throughput
normally comes from narrow path classification, caching, and concurrent
merge-queue candidate builds.

Urgent native validation may use the owned M4/M5 fleet only through the
manual, main-pinned `BurnBar Turbo Native CI` workflow and the
`burnbar-turbo-ephemeral` group. Those workers are disposable macOS VMs, accept
one exact same-repository commit, receive no secrets, and are destroyed after
one job. The bring-up and isolation contract is documented in
[`runbooks/burnbar-turbo-runners.md`](runbooks/burnbar-turbo-runners.md).

## Changing ownership

Update classifier rules and tests in the same pull request. New or unmatched
paths intentionally trigger every lane until ownership is explicit. Update the
component context inventory only when a workflow's stable check name changes,
then validate the umbrella on both a pull-request head and a merge-group head
before changing live branch protection.
