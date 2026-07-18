# Windows Usage Scan Process Boundary

The WinUI app must execute native Swift usage parsing through the packaged
`OpenBurnBar.Cli` worker. It must not compose `CAbiUsageEngine` directly into
the long-lived tray process.

## Why this boundary exists

Physical Intel x64 certification of `windows-v1.0.35` found bounded behavior
for roughly 24 minutes followed by two native-memory high-water steps. The app
remained responsive, but private memory grew from 99.16 MB to 325.13 MB during
the 30-minute soak, exceeding the +10% release budget. The same native parser
completed correctly and with bounded memory in focused tests. The defect was
process lifetime: Swift and its Windows allocator retained scan allocations in
the app's long-lived process.

`OutOfProcessUsageEngine` starts the signed sibling `OpenBurnBar.Cli.exe` for
one scan, streams one JSON request over standard input, reads one JSON response
from standard output, and waits for the worker to exit. Process exit gives the
operating system a deterministic reclamation boundary for the native heap.

## Invariants

- The app composition root uses `OutOfProcessUsageEngine`.
- Only the CLI's hidden `--internal-usage-scan-worker` mode creates
  `CAbiUsageEngine`.
- The worker is resolved beside the installed app by default. The
  `OPENBURNBAR_USAGE_SCAN_WORKER_PATH` override exists for tests and local
  development only.
- Launches use the reviewed `ChildProcessProfile.UsageScanner` policy, never a
  shell. Standard streams are redirected, inherited environment is filtered,
  stderr capture is bounded, scans time out after five minutes, and cancellation
  terminates the worker process tree.
- Missing workers, non-zero exits, timeouts, invalid JSON, and broken pipes fail
  closed as typed `UsageRuntimeException` failures.
- Portable and MSIX layouts must include the CLI executable, its `.deps.json`
  and `.runtimeconfig.json`, the native engine, and both Swift resource bundles.
- The Windows release workflow runs the in-process native parser smoke and the
  real out-of-process worker smoke from the exact published x64 layout before
  signing.

The process protocol is internal and version-coupled to the app package. It is
not a public CLI or compatibility surface.

## Verification

Run the portable tests on any development host:

```bash
dotnet test windows/tests/usage-runtime/OpenBurnBar.App.UsageRuntime.Tests.csproj -c Release
dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj -c Release
dotnet test windows/tests/dist/OpenBurnBar.Dist.Tests.csproj -c Release
```

The real worker/native-engine integration is fail-closed in the Windows release
workflow through `OPENBURNBAR_REQUIRE_USAGE_SCAN_WORKER_INTEGRATION=1`. A new
signed candidate must repeat the physical x64 performance protocol; unit and
hosted-runner success do not promote the failed `windows-v1.0.35` evidence.
