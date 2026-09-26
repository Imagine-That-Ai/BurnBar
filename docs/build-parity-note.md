# Build-parity note: OpenBurnBarCore Package.swift probes + OPENBURNBAR_* env

Date: 2026-09-22. Manifest: [OpenBurnBarCore/Package.swift](../OpenBurnBarCore/Package.swift).
This note documents how the manifest's host-evaluated probes shape the package
graph, which environment flags control them, and where CI and dev can silently
diverge. It proposes no code change: the disable-flag seams already exist where
they are safe (Remote, LibSignal), and adding more is not trivially safe (see
"Why no new flags").

## The probe block (Package.swift L8–L114)

The manifest is host-evaluated Swift: `ProcessInfo` env reads and `FileManager`
existence probes run on the machine resolving the package, and their results
add or prune targets, products, and binary targets from the graph.

| Flag / probe | Lines | Effect when set / present |
|---|---|---|
| `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1` | L8, L281–299 | Prunes `OpenBurnBarData` + `OpenBurnBarMemoryExport` (GRDB) from the graph; the Linux-daemon boundary build |
| `OPENBURNBAR_LINUX_SECURITY_ONLY_BUILD=1` | L9, L354–359 | Collapses the product list to `OpenBurnBarLinuxSecurity` only |
| `OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK=1` | L10–12, L98–103 | Forces `hasBurnBarRemoteXCFramework=false`; prunes `BurnBarRemoteFFI` product + `BurnBarRemoteEngine` dep + `OPENBURNBAR_HAS_BURNBAR_REMOTE_FFI` define (L474–476) |
| `OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1` | L22–24, L92–97 | Forces the LibSignal-Swift-package half of `hasLibSignalSwiftPackage=false`; prunes `LibSignalClient` product dep and `libsignal_ffi.a` (avoids the `_rust_eh_personality` collision with the DomainCore Rust staticlib, L13–21) |
| `OPENBURNBAR_DECLARED_XCFRAMEWORKS=1` | L104–113 | Fail-fast gate: `fatalError` unless `OpenBurnBarIroh.xcframework` **and** `OpenBurnBarSignalFfiMac.xcframework` probe present |
| `OPENBURNBAR_LINUX_IROH_LIBRARY_DIR=<dir>` | L116–139 | Linux only: `<dir>` must contain **both** `libopenburnbar_iroh.so` and `libopenburnbar_iroh.a`, else `fatalError`; feeds `hasIrohFFIBindings` (L139) and the `openburnbar_irohFFI` system target (L394–421) |

Apple-vs-non-Apple split (L42–60): on Linux/Windows hosts every `has*XCFramework`
flag is hardcoded `false` and the `Vendor/*.xcframework` probes are compiled
out. On Apple hosts each flag is a live `FileManager.default.fileExists`
probe against `../Vendor/`:

- `OpenBurnBarIroh.xcframework` (L62–67)
- `OpenBurnBarDomainCore.xcframework` (L68–73)
- `OpenBurnBarSignalFfiIOS.xcframework` (L74–79)
- `OpenBurnBarSignalFfiMac.xcframework` (L80–85)
- `OpenBurnBarSignalFfi.xcframework` legacy (L86–91; only linked when the Mac split framework is absent, L486–488)
- `../Vendor/libsignal/swift/Package.swift` (L92–97, ANDed with the LibSignal disable flag)
- `BurnBarRemote.xcframework` (L98–103, ANDed with the Remote disable flag)

Observed state of this worktree: `Vendor/` contains no `.xcframework` and no
`libsignal/swift/Package.swift` (only `.aar` files, `CHECKSUMS.sha256`,
`GRDB-SQLCipher/`, `libsignal/` without the Swift package), so on an Apple host
with no flags set, all seven probes evaluate `false` here.

## CI-vs-dev parity statement

Same flags + same `Vendor/` contents ⇒ same package graph, because every seam
is host-evaluated from exactly those two inputs. The known divergences are all
cases where CI and dev pass different flags or check out different `Vendor/`
contents:

- **Dev default prunes Remote.** [scripts/test-openburnbar-swift.sh](../scripts/test-openburnbar-swift.sh)
  (L23–24) exports `OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK=1` unless the
  caller already set the variable. A dev `swift test` therefore never links
  `BurnBarRemoteFFI` by default; release/CI jobs that need the remote engine
  must set the variable explicitly (empty counts as set).
- **Focused DomainCore CI prunes LibSignal.**
  [domain-core.yml](../.github/workflows/domain-core.yml) (L1123) sets
  `OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1` for the focused macOS job so
  the prebuilt DomainCore staticlib links without the `_rust_eh_personality`
  collision; SignalCore/SignalSessionTransport compile against their
  `unavailable` stubs there. Full-app CI gates still link real libsignal (manifest
  L20–21). A green focused job does **not** prove the full Signal link.
- **Boundary builds prune GRDB + UI.**
  `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1` (used by the Windows engine lane
  [openburnbar-engine-windows.yml](../.github/workflows/openburnbar-engine-windows.yml) (L119)
  among others) drops `OpenBurnBarData`/`OpenBurnBarMemoryExport`; Linux/Windows
  hosts additionally drop all Apple-only presentation products (L308–328) and
  all XCFramework binary targets (L53–60).
- **Implicit file presence is the residual risk.** Apart from the two
  `DISABLE_*` flags and the `DECLARED_XCFRAMEWORKS` gate, graph shape depends
  on which files happen to sit in `Vendor/` — a stale or partial `Vendor/`
  checkout silently changes what gets built rather than failing. Jobs that
  require the native binaries should set `OPENBURNBAR_DECLARED_XCFRAMEWORKS=1`
  to convert "silently pruned" into a loud `fatalError` naming the missing
  framework.

## Why no new flags (decision, 2026-09-22)

Pinning the Iroh/DomainCore/SignalFfi probes behind `DISABLE_*` flags would
look trivial but is not safe: each flag doubles the graph-shape matrix that
release, domain-core, Windows, and Linux jobs must cover, and a flag defaulting
to "probe" preserves today's implicit behavior while adding a new untested
combination. The existing seams already cover the two cases with a proven need
(Remote link cost, LibSignal Rust-symbol collision). Recommendation: no manifest
change in this packet; instead, CI jobs that depend on Vendor binaries set
`OPENBURNBAR_DECLARED_XCFRAMEWORKS=1`, and any future disable flag ships with
its CI matrix entry in the same PR.
