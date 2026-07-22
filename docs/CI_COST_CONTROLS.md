# CI cost controls

BurnBar uses one required status context, `BurnBar CI Gate`. The gate is always
emitted for pull requests and native merge-queue candidates and fails closed
until every component context in
[`governance/burnbar-ci-gate.json`](../governance/burnbar-ci-gate.json) is
successful, neutral, or intentionally skipped.

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

## Runner policy

BurnBar uses standard GitHub-hosted runners. The public repository must not be
granted access to the shared persistent self-hosted runner group, and workflows
must not route labels to paid larger-runner pools. Throughput comes from narrow
path classification, caching, and concurrent merge-queue candidate builds.

## Changing ownership

Update classifier rules and tests in the same pull request. New or unmatched
paths intentionally trigger every lane until ownership is explicit. Update the
component context inventory only when a workflow's stable check name changes,
then validate the umbrella on both a pull-request head and a merge-group head
before changing live branch protection.
