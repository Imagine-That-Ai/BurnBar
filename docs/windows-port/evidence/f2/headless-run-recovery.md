# F2 Headless Run and Recovery Evidence

Ledger row: `f2-headless-run-recovery`

What this proves: The Windows app composes a metadata-only JSONL headless-run
journal, a dependency-aware resumable run service, and the authenticated
companion TCP plane. `App.xaml.cs` creates the journal and service at startup,
registers `run.submit`, `run.resume`, and `run.recover`, and reports interrupted
runs without logging step payloads or credentials. The managed runtime tests
cover dependency ordering, persistence redaction, interruption recovery,
resume-with-completed-step skipping, cycle failure, corrupt journal rejection,
safe built-in steps, and unauthorized requests. The loopback integration test
opens a real ephemeral TCP listener, submits a health step through the same
router used by the desktop composition, verifies a successful terminal result,
and verifies the bearer token is not returned to the client. This is accepted
in-process runtime evidence; physical Windows service hosting and long-lived
hardware lifecycle stress remain separate release gates.

Validation:

- `dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
- `CompanionCliServerTests.Server_ExecutesHeadlessRunOverAuthenticatedLoopback`
- `HeadlessRunServiceTests`
