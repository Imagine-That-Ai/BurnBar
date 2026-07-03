# Windows Engine storage-prune waiver

## Why this file exists

The Windows Engine CI lane (`.github/workflows/openburnbar-engine-windows.yml`)
compiles a **pruned Engine subset**. It sets
`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1`, which the SwiftPM manifests
(`OpenBurnBarCore/Package.swift`, `OpenBurnBarDaemon/Package.swift`) read to
**drop the GRDB-SQLCipher package + the `OpenBurnBarData` storage target** from
the Windows package graph.

That prune is a **real parity GAP, not parity.** The macOS app persists to a
GRDB + SQLCipher store (53 migrations, ~50 tables, heavy FTS5); the Windows
Engine lane currently proves the Foundation compute subset *without* that store.
"Storage is pruned" must therefore **never silently masquerade as parity.**

`scripts/ci/verify-windows-storage-prune-waiver.sh` enforces exactly that: while
any workflow prunes storage, this waiver must exist, be `active`, be unexpired,
and **name every pruning workflow**. When the un-pruning lane lands the real
Windows storage story (removes the boundary flag, or sets it to `0`), the gate
passes with **no waiver required** — and this file should be deleted so the
amnesty cannot rot into permanence.

## Un-prune tracking

- Master plan scope note: `docs/windows-port/HANDOFF.md` §0 ("IMPORTANT SCOPE")
  and §2 — un-pruning storage needs the real-Mac-DB-open dev-host spike, then a
  first-class Windows storage target (`Microsoft.Data.Sqlite` +
  `SQLitePCLRaw.bundle_e_sqlcipher` proved on the dev host, HANDOFF.md §1).
- Risk register: `docs/WINDOWS_PORT_MASTER_PLAN.md` R2 (GRDB-no-Windows,
  Critical) is the un-prune blocker being retired by the sibling lane.
- Progress board: Phase-2 engine parity → G2 (task #10) owns landing the real
  storage layer; this waiver is retired as part of that work.

## The waiver

The block below is machine-read by the gate. Keep it well-formed:

- `status:` must be `active` for the waiver to hold.
- `expires:` is an ISO `YYYY-MM-DD` date; once it passes, the gate fails until an
  owner re-acknowledges the gap (bump the date) or the un-prune lane removes it.
  This forces the parity gap back onto the table every quarter — it cannot be
  set-and-forgotten.
- `workflows:` must list **every** workflow that sets the boundary flag to a
  truthy value. A pruning workflow that is not named here fails the gate.

<!-- BEGIN:windows-storage-prune-waiver -->
status: active
expires: 2026-10-01
flag: OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD
tracking: docs/windows-port/HANDOFF.md#0-tldr ; WINDOWS_PORT_MASTER_PLAN.md R2 ; Phase-2 engine parity (G2)
workflows:
  - .github/workflows/openburnbar-engine-windows.yml
<!-- END:windows-storage-prune-waiver -->
