# WPD-0005: Windows storage architecture — the Engine computes, the shell persists

- **Status:** Accepted (Wave 1, R2 retirement)
- **Date:** 2026-07-06
- **Contract:** `VAL-P0-DB-010` (byte-compat proof carried over from WPD-0004);
  retires master-plan risk **R2** by architecture.
- **Scope:** *Who owns storage on Windows, permanently.* WPD-0004 decided **how**
  Windows opens the shared SQLCipher database (C# `Microsoft.Data.Sqlite.Core` +
  `SQLitePCLRaw.bundle_e_sqlcipher`, the sanctioned raw-SQLCipher-C fallback).
  This WPD extends it with the architectural ruling that seam was implicitly
  building toward: on Windows, the **Swift Engine is compute-only** and the
  **C# storage seam (`windows/storage/`) is the permanent owner of persistence**.
  The storage prune in the Windows Engine CI lane is therefore **architecture,
  not a waived parity gap**, and the storage-prune waiver is retired.
- **Supersedes:** `docs/windows-port/STORAGE_PRUNE_WAIVER.md` (deleted with this
  WPD) and the waiver semantics of the old
  `scripts/ci/verify-windows-storage-prune-waiver.sh` gate (now
  `scripts/ci/verify-windows-storage-architecture.sh`).

## Context

The macOS app persists to a GRDB + SQLCipher store (53 migrations, ~50 tables,
heavy FTS5) via the `OpenBurnBarData` target, which depends on the vendored
`GRDB-SQLCipher` package. **GRDB-SQLCipher does not resolve or build off-Apple
at all** — leaving it in the graph fails SwiftPM package resolution before Core
ever compiles. That is master-plan risk **R2** (GRDB-no-Windows, Critical), the
crown-jewel DB kill-risk.

To get the Windows Engine compiling, the SwiftPM manifests read
`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD` and prune exactly the
GRDB-SQLCipher package + the `OpenBurnBarData` target from the off-Apple graph
(`OpenBurnBarCore/Package.swift`; the Windows Engine CI lane
`.github/workflows/openburnbar-engine-windows.yml` sets the flag to `"1"`).
While the Windows storage story was undecided, that prune was treated as a
**dated, expiring parity waiver** (`STORAGE_PRUNE_WAIVER.md`), enforced by a
fail-closed Fast Feedback gate, so "storage is pruned" could never silently
masquerade as parity.

Since then, the story stopped being undecided:

- **WPD-0004** landed the C# storage seam (`windows/storage/OpenBurnBar.Storage`,
  `Microsoft.Data.Sqlite.Core` + `SQLitePCLRaw.bundle_e_sqlcipher`) — the master
  plan's pre-authorized "raw SQLCipher-C + a thin data layer" fallback — behind a
  DataStore-shaped read seam.
- Byte-compat was **proven, not asserted** (`VAL-P0-DB-010`, commit
  `5c4fd006f8`): the seam opens the committed Mac-produced fixture and
  reproduces the Mac oracle exactly (details under *Evidence*).
- `PARITY_100_REMEDIATION_PLAN.md` Wave 1 item 2 put the fork on the table:
  **(a)** port GRDB-SQLCipher to MSVC so the Swift engine owns storage on
  Windows, or **(b)** formalize the C# seam as the permanent Windows storage
  architecture. Alberto deferred the call to the goal driver; **option (b) is
  chosen and executed by this WPD.**

## Decision

**On Windows, the Swift Engine is compute-only. Storage is owned by the C#
seam (`windows/storage/`). "The Engine computes, the shell persists."**

Concretely:

- The Swift Engine subset that compiles on Windows (parsers, crypto, state
  machines, protocol codecs, the walking skeleton) never links GRDB and never
  opens the database. Data it needs at parse time reaches it through explicit
  seams (e.g. the read-only SQLite reader seam the Codex + Hermes G2 parsers
  ride, `67de06b5c7`).
- `windows/storage/OpenBurnBar.Storage` (+ `OpenBurnBar.Storage.SessionLogs`,
  tested by `OpenBurnBar.Storage.Tests`) is the **permanent** Windows owner of
  the SQLCipher database: open path, pinned cipher profile
  (`cipher_compatibility=4`, `cipher_page_size=4096`, `kdf_iter=256000`,
  PBKDF2/HMAC-SHA512, `porter unicode61` FTS5, per WPD-0004), and the typed
  DataStore-shaped API the app shell consumes. The write/migration seam grows
  here too (WPD-0004's follow-up), not in a resurrected Swift storage target.
- `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD` in the Windows Engine lane is
  **permanent architecture, not a waived gap**: it prunes a storage target that
  *by design* has no Windows implementation, because the Windows storage
  implementation lives in C#.

### Parity claim — stated precisely

- **File-format parity IS claimed** (drift **D6** in
  `PARITY_CERTIFICATION_BUNDLE.md`): the Windows stack opens the byte-identical
  SQLCipher file the Mac writes and reproduces the Mac oracle's schema hash and
  FTS5 behavior.
- **API parity is explicitly NOT claimed:** Windows has no GRDB API, no
  `OpenBurnBarData` Swift target, and no plan to grow them. Any doc that reads
  "storage parity" means the file and its contents, never the Swift API surface.

## Evidence (byte-compat, `VAL-P0-DB-010`)

Carried from WPD-0004 and commit `5c4fd006f8`
(`dotnet test windows/storage/OpenBurnBar.Storage.Tests`, 10/10):

- Opens the committed Mac-produced fixture
  `AgentLensTests/Fixtures/DBByteCompat/openburnbar-db-compat-v53.sqlcipher`
  with the pinned profile.
- Reproduces the committed `DatabaseByteCompatVector` exactly: schema hash
  `8f8f0eba…943992c` over 220 `sqlite_master` objects, plus the frozen FTS5
  `bm25()`/`snippet()` row set for all four `MATCH` probes (KAT-style frozen
  expectations, diffed byte-for-byte).
- The headline: the seam linked **SQLCipher 4.5.2 / libtomcrypt** against a file
  the Mac wrote with **4.16.0 / commoncrypto** and still matched — byte-compat is
  anchored to the pinned compatibility-4 parameters, not to a matching build.

## Alternatives considered

- **Port GRDB-SQLCipher to MSVC (option a).** Rejected. GRDB is Swift with deep
  Apple/Foundation SQLite integration and no supported Windows target; forcing
  one is months of bespoke, unmaintained fork work that buys *purity* (the same
  code path on both OSes) but no *product* (the file already opens, byte-proven,
  through the C# seam). It would also duplicate a storage owner the Windows app
  shell already has.
- **Keep the waiver.** Rejected. The waiver existed to stop an undecided gap
  from rotting into silent permanence — its own text demands deletion once the
  storage story lands. The story has landed; keeping an "expiring" waiver for a
  decision that will never expire would invert the honesty mechanism. **Waivers
  must not rot into permanence; decisions must.** The enforcement moves from a
  waiver gate to an architecture gate (below) so the honesty is preserved, not
  dropped.

## Consequences

- `docs/windows-port/STORAGE_PRUNE_WAIVER.md` is **deleted**. R2 is
  **retired-by-architecture** (its open half was already retired empirically by
  WPD-0004; this WPD closes the ownership question).
- The Fast Feedback gate is rewritten as
  `scripts/ci/verify-windows-storage-architecture.sh` (job
  `windows-storage-architecture`). It stays **fail-closed** with new semantics:
  - Every workflow that sets `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD` to a
    truthy value **must be named in this WPD's machine-read block** below. A new
    pruned lane cannot hide behind the architecture decision without being
    written into it.
  - The C# seam's test project (`windows/storage/OpenBurnBar.Storage.Tests`)
    **must exist and contain tests** — an architecture claim with no tests
    behind it fails the gate.
  - A missing WPD file, a malformed machine-read block, or a non-`accepted`
    status fails the gate.
- `.github/workflows/openburnbar-engine-windows.yml` documents the flag as
  permanent architecture citing this WPD (no more "later-phase work" phrasing).
- Docs keyed off the waiver (`PARITY_CERTIFICATION_BUNDLE.md`,
  `PARITY_100_REMEDIATION_PLAN.md`, `HANDOFF.md` §0,
  `runbooks/WINDOWS_ENGINE_REQUIRED_CHECK.md` §5) now point here.

## Revisit triggers

Reopen this decision (new WPD, do not silently edit this one) if:

- **The Windows Swift Engine ever needs direct DB access** — e.g. parser
  checkpoint stores, engine-side caches, or a parser that must write. First
  choice: a UniFFI/C-ABI callback from the Engine into the C# seam (keeps one
  storage owner). Second choice: revive the GRDB-to-MSVC port with real sizing.
- SQLCipher major-version or pinned-parameter drift breaks file-format parity
  (that is a **PIVOT** per the certification bundle §8, not a quiet fix).
- The daemon strategy decision (remediation plan Wave 4 §3) lands a Windows
  daemon that needs its own store — decide then whether it rides this seam.

## Machine-read block

The block below is machine-read by
`scripts/ci/verify-windows-storage-architecture.sh`. Keep it well-formed:

- `status:` must be `accepted` for the architecture to hold.
- `storage-tests:` names the C# test project directory that must exist and
  contain tests.
- `workflows:` must list **every** workflow that sets the boundary flag to a
  truthy value. A pruning workflow not named here fails the gate.

<!-- BEGIN:windows-storage-architecture -->
status: accepted
flag: OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD
storage-tests: windows/storage/OpenBurnBar.Storage.Tests
workflows:
  - .github/workflows/openburnbar-engine-windows.yml
<!-- END:windows-storage-architecture -->
