# CSQLite — vendored SQLite amalgamation (public domain)

Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).

This is the **read-only SQLite reader seam's off-Apple backend**. The Swift Windows
SDK ships no system SQLite, so the Foundation-only Engine subset vendors the
official SQLite **amalgamation** here and compiles it as a first-party C target
(`CSQLite`). The `OpenBurnBarCore` Swift code imports it as `import CSQLite` and
uses the raw `sqlite3_*` C API (the same API `AgentLens/Services/LogParser/WindsurfParser.swift`
already uses on Apple via the system `SQLite3` module).

- **Source:** <https://www.sqlite.org/2024/sqlite-amalgamation-3470000.zip>
- **Version:** SQLite `3.47.0` (2024-10-21), `sqlite3.h` `SQLITE_VERSION "3.47.0"`.
- **Files:** `sqlite3.c` (~8.8 MB, the amalgamation) + `include/sqlite3.h` (~636 KB,
  the public API) + `include/module.modulemap`. `shell.c` and `sqlite3ext.h` are
  intentionally NOT vendored (no CLI shell, no run-time extension loading — see
  `SQLITE_OMIT_LOAD_EXTENSION` in `OpenBurnBarCore/Package.swift`).
- **License:** SQLite is released into the **public domain** — "The author disclaims
  copyright to this source code" (see the header of `sqlite3.h` / `sqlite3.c`). No
  attribution or license file is required; this note records provenance.

## Platform gating

`CSQLite` is compiled **off-Apple only** (`#if os(Linux) || os(Windows)` in the
host-evaluated `OpenBurnBarCore/Package.swift`). On Apple the reader links the
system `SQLite3` module instead (`#if canImport(SQLite3)`), so this 8.8 MB
amalgamation is never compiled on macOS/iOS builds.

## Updating

Re-download the amalgamation zip for the desired version, replace `sqlite3.c` and
`include/sqlite3.h`, and update the version line above. Do not hand-edit the
amalgamation.
