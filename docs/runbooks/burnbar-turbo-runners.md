# BurnBar turbo runners

BurnBar's urgent native lane uses owned Apple-silicon hardware without exposing
either physical Mac to code from a public pull request. The fleet target is one
disposable worker on the 24 GB M4 Pro Mac mini and two disposable workers on the
48 GB M5 Max MacBook Pro. Normal CI remains on standard GitHub-hosted runners.

## Trust boundary

- Only the pinned `burnbar-turbo.yml`, `app-pr-gate.yml`, and
  `daemon-pr-gate.yml` workflows may access the `burnbar-turbo-ephemeral`
  runner group. All three workflows are explicitly allowlisted in the runner
  group; no other workflow may target it.
- The workflow is manual until the fleet has passed its soak test. A caller must
  have write access and supply an exact lowercase 40-character SHA belonging to
  `main` or an open, non-draft, same-repository PR.
- The group is selected-repository (`Imagine-That-Ai/BurnBar`) and workflow
  allowlisted. Never grant BurnBar access to the shared persistent runner group.
- Workers run inside disposable Tart macOS VMs with Softnet isolation, no host
  directory mounts, no host SSH agent, no signing identities, and no repository
  or organization secrets. `GITHUB_TOKEN` is read-only and checkout credentials
  are not persisted. Tartelet is not used because its persistent host cache
  mount violates this boundary.
- `scripts/ci/burnbar-turbo-runner-host.sh` keeps the GitHub CLI credential on
  the physical host and pipes only a short-lived registration token to the
  guest. `scripts/ci/burnbar-turbo-runner-guest.sh` verifies the pinned Actions
  runner archive before registering it with `--ephemeral`, `--disableupdate`,
  and `--no-default-labels`.
- One job is the entire lifetime of a worker. The controller extracts runner
  diagnostics, gracefully stops the guest, and deletes the exact VM even when
  setup or tests fail. An atomic per-slot lock prevents duplicate controllers.

## Capacity

Start with one 12 GB VM on the M4 and two 18 GB VMs on the M5. Keep at least
6 GB for each host and reduce concurrency if memory pressure or thermal
throttling appears. The three native lanes intentionally fan out as app,
mobile, and daemon/release so a full urgent validation uses both Macs.

The base image is Cirrus Labs Tahoe/Xcode 26.5 pinned at
`sha256:61f6e857a3d65dd2f8daf9c51c7b837fa458bcc9181ae8556e645b534dab6bf6`.
It includes Xcode 26.5, the iOS 26.5 simulator, and Node 24; the attested local
template adds protobuf 35 and Rust 1.97.1. The controller installs Actions
runner 2.336.0 only after verifying SHA-256
`8e8839c49b7060b6b2154f4931f815df330c27f167d53ef2239ee3dfce28b079`.
Rebuild the image on a schedule rather than allowing jobs to mutate it. Remote
SwiftPM/build cache entries remain lockfile keyed.

The M4 keeps Tart storage on the external Samsung NVMe. The M5 uses a sparse
500 GB APFS image stored on the external X31 drive; this preserves APFS
copy-on-write cloning without reformatting the drive or consuming the laptop's
internal SSD.

## Bring-up order

1. Land the trusted workflow and the explicitly allowlisted merge-gate
   workflows on `main`.
   For a pull request, retarget it to `main` before validation and push a
   normal synchronize commit; the trusted deletion guard intentionally refuses
   to evaluate a stacked or stale base.
2. Create `burnbar-turbo-ephemeral` with public-repository access enabled only
   for BurnBar and workflow access pinned to
   `Imagine-That-Ai/BurnBar/.github/workflows/burnbar-turbo.yml@main`.
3. Build and attest the disposable image on each host. Configure Softnet's
   root-owned setuid helper once, then verify the controller rejects a missing
   or incorrectly permissioned helper.
4. Start one continuous controller on the M4 and two on the M5:

   ```bash
   scripts/ci/burnbar-turbo-runner-host.sh --profile m4 --slot 1 --continuous
   scripts/ci/burnbar-turbo-runner-host.sh --profile m5 --slot 1 --continuous
   scripts/ci/burnbar-turbo-runner-host.sh --profile m5 --slot 2 --continuous
   ```

   Then dispatch the workflow against a known-green exact head.
5. Prove VM destruction, runner deregistration, log retention, cache behavior,
   and no host mounts before enabling the `ci-turbo` label integration.

If no matching ephemeral worker is online, do not dispatch: GitHub leaves a
self-hosted job queued for up to 24 hours. Normal hosted CI is always the safe
fallback.
