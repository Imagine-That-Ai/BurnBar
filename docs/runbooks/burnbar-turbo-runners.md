# BurnBar turbo runners

BurnBar's urgent native lane uses owned Apple-silicon hardware without exposing
either physical Mac to code from a public pull request. The fleet target is one
disposable worker on the 24 GB M4 Pro Mac mini and two disposable workers on the
48 GB M5 Max MacBook Pro. Normal CI remains on standard GitHub-hosted runners.

## Trust boundary

- Only `.github/workflows/burnbar-turbo.yml@main` may access the
  `burnbar-turbo-ephemeral` runner group.
- The workflow is manual until the fleet has passed its soak test. A caller must
  have write access and supply an exact lowercase 40-character SHA belonging to
  `main` or an open, non-draft, same-repository PR.
- The group is selected-repository (`Imagine-That-Ai/BurnBar`) and workflow
  allowlisted. Never grant BurnBar access to the shared persistent runner group.
- Workers run inside disposable Tart macOS VMs with softnet isolation, no host
  directory mounts, no host SSH agent, no signing identities, and no repository
  or organization secrets. `GITHUB_TOKEN` is read-only and checkout credentials
  are not persisted.
- Register each worker with GitHub's JIT/ephemeral configuration. One job is the
  entire lifetime of a worker; forward runner diagnostics, then destroy the VM
  even when setup or tests fail.

## Capacity

Start with one 12 GB VM on the M4 and two 18 GB VMs on the M5. Keep at least
6 GB for each host and reduce concurrency if memory pressure or thermal
throttling appears. The three native lanes intentionally fan out as app,
mobile, and daemon/release so a full urgent validation uses both Macs.

The base image must pin the GitHub Actions runner release and checksum and
include Xcode 26, the required iOS simulator, Node, Rust, protobuf, and Tart's
softnet support. Rebuild the image on a schedule rather than allowing each job
to mutate the image. Remote SwiftPM/build cache entries remain lockfile keyed.

## Bring-up order

1. Land the trusted workflow on `main`.
2. Create `burnbar-turbo-ephemeral` with public-repository access enabled only
   for BurnBar and workflow access pinned to
   `Imagine-That-Ai/BurnBar/.github/workflows/burnbar-turbo.yml@main`.
3. Build and attest the disposable image on each host.
4. Start one JIT worker on the M4 and two on the M5, then dispatch the workflow
   against a known-green exact head.
5. Prove VM destruction, runner deregistration, log retention, cache behavior,
   and no host mounts before enabling the `ci-turbo` label integration.

If no matching ephemeral worker is online, do not dispatch: GitHub leaves a
self-hosted job queued for up to 24 hours. Normal hosted CI is always the safe
fallback.
