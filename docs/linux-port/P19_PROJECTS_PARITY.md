# Linux Projects Parity Slice (P-19)

This slice closes the safe portion of the Linux Projects gap against the
macOS controller-project contract. It is intentionally bounded by the daemon
RPC surface that exists today.

## Implemented

- `daemon.controller.project.list` is decoded as
  `BurnBarControllerProjectsListResponse` rather than as filesystem rows.
- `daemon.controller.project.get` is exposed through a typed Linux bridge
  method and rendered as a project detail view.
- `daemon.controller.project.upsert` is exposed through a typed Linux bridge
  method and powers project registration/editing.
- `daemon.controller.project.delete` and
  `daemon.controller.project.reassign` are exposed through typed Linux bridge
  methods. Deleted identities become durable tombstones, and reassignment
  migrates daemon-owned references without using display names or paths as
  identity.
- Checkpoint plus journal-tail replay preserves deletion and reassignment after
  daemon restart without resurrecting a deleted project.
- Project identity is the daemon-owned `projectSlug`/`id`. Display names,
  paths, and session titles are never used as identity or association keys.
- Controller activity metadata (`session_count_last_7d`,
  `total_cost_last_7d`, and `total_tokens_last_7d`) is shown only when emitted
  by the daemon. Missing metadata is rendered as unavailable.
- Detail/edit states include loading, daemon errors, empty fields, and a
  disabled management state when the packaged bridge does not expose the
  canonical methods.

## Remaining certification boundary

Linux still does not invent a project filesystem-root field or infer one from a
slug. Final parity requires the signed installed-candidate proof described in
[`P19_PROJECTS_PROOF.md`](P19_PROJECTS_PROOF.md), including a real associated
mission migrating to the target project, restart persistence, tombstone
rejection, and installed AT-SPI UI evidence. Source behavior alone does not
close the parity row.

## QA evidence

From `apps/linux-desktop`:

```text
npx vitest run src/bridgeRpcBehavior.test.ts src/surfaces/projects/ProjectsSurface.test.tsx src/tauriBridge.test.ts
53 tests passed
npx tsc --noEmit --pretty false
pass
npm run build
Vite production build and verify-linux-production-bundle passed
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
pass
cargo test --manifest-path src-tauri/Cargo.toml --lib
48 tests passed
git diff --check
pass
```

Installed Linux verification still needs a packaged candidate, a running
daemon with registered projects, and the full seven-environment matrix. Those
receipts are release-gate work, not claimed by this source slice.
