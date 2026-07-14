# Codex and Factory CLI provider executors

Ledger row: `f2-model-proxy-router`

## What this proves

Windows now production-composes the two remaining macOS provider executors for
explicit `cli://codex` and `cli://factory` routes:

- Codex runs `exec --json --ephemeral` with a read-only sandbox, user config and
  repository rules disabled, the selected model, and the guarded request on
  standard input rather than the command line;
- Factory Droid runs in a random per-request directory with a UTF-8 prompt file,
  JSON output, `ApplyPatch` and `execute-cli` disabled, and strict Standard-tier
  enforcement;
- both adapters preserve OpenAI buffered or SSE response shapes, produce bounded
  usage estimates when the CLI does not report tokens, and reject malformed,
  empty, timed-out, unauthenticated, quota-exhausted, or downgraded responses;
- Factory Standard routes fail closed if output indicates an unrequested Droid
  Core fallback, while the six explicit Droid Core model ids remain eligible;
- raw stdout, stderr, prompts, provider keys, and temporary paths are never
  returned in an error body or persisted as route metadata; and
- every temporary request directory is removed after success or failure.

The production runner resolves `codex` or `droid` through the existing protected
approved-executable inventory, reverifies the executable SHA-256 before every
launch, uses `ProcessStartInfo.ArgumentList` without a shell, captures at most
16 MiB from each output stream, and kills the full process tree on cancellation,
timeout, or an output-policy failure. Ambient provider credentials remain
scrubbed. Only explicitly supplied `OPENAI_API_KEY` or `FACTORY_API_KEY` values
may cross the central child-process policy, and only under the Gateway profile.

## Production paths

- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/ProviderCliModelCompletionExecutor.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayRouteConfiguration.cs`
- `windows/app/OpenBurnBar.App.ManagedAgentRuntime/Gateway/GatewayCompositionFactory.cs`
- `windows/app/OpenBurnBar.App/Gateway/WindowsProviderCliProcessRunner.cs`
- `windows/app/OpenBurnBar.App.Configuration/ChildProcessEnvironment.cs`
- `windows/app/OpenBurnBar.App.Configuration/ChildProcessLaunchPolicy.cs`
- `windows/app/OpenBurnBar.App/Settings/WindowsSettingsPersistence.cs`
- `windows/tests/managed-runtime/ProviderCliModelCompletionExecutorTests.cs`
- `windows/tests/configuration/ChildProcessLaunchPolicyTests.cs`

## Validation

`dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --no-restore`
passes **195/195** locally. Seventeen focused cases cover endpoint/vendor binding,
HTTP-versus-CLI dispatch, the exact guarded Codex and Factory launch contracts,
standard input and temporary prompt isolation, JSONL and nested JSON extraction,
OpenAI JSON/SSE normalization, terminal usage, cleanup, missing credentials,
Standard-tier downgrade rejection, explicit Droid Core acceptance, quota
classification, and secret-safe failures.

`dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj --no-restore`
also passes locally and covers the narrow required-secret exception, continued
ambient-secret scrubbing, rejection under every other process profile, reviewed
launch inventory, and ownership of all product process primitives.

## Boundary

This closes the configured-transport portion of WPD-0006 row 7. It does not
claim proactive local-provider/model discovery, an approved executable that is
not present in the protected inventory, live Codex/Factory account acceptance,
or WPD-0006 row 8's long-lived agent/tool execution loop.
