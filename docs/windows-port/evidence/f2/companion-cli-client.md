# F2 evidence: authenticated companion CLI client

**Ledger row:** WPD-0006 row 29, companion CLI / daemon-client surface

**What this proves:** Windows ships a standalone, bounded client for the
production companion protocol instead of exposing only an in-process test
server.

## Production path

- `windows/app/OpenBurnBar.Cli/` is a `net8.0` executable published
  self-contained for `win-x64` and `win-arm64`.
- `CompanionCliClient` connects only to IPv4 loopback, bounds the request,
  response, and timeout, and returns stable transport/protocol error codes.
- Authentication is injected from the same current-user DPAPI secret used by
  the production Model Proxy. Inline `authToken` input is rejected, the token
  is never printed, and the serialized secret-bearing buffer is cleared on
  every exit path.
- Named commands cover health/catalog, durable run lifecycle, approvals and
  leased tools, local missions, planner/policy/fusion, and project-code
  operations. `call <operation>` preserves forward compatibility with new
  bounded protocol operations without accepting inline JSON arguments.
- Request bodies are accepted only through `--input <file|->`; malformed,
  oversized, non-object, or secret-bearing input fails before transport.

## Distribution path

- `windows/OpenBurnBar.sln` includes the CLI and its managed-runtime tests.
- `.github/workflows/openburnbar-release-windows.yml` publishes the matching
  RID, stages the CLI beside the WinUI executable, and includes it in the
  existing Azure Artifact Signing filter.
- MSIX exposes `openburnbar.exe` through a Windows app-execution alias.
- Both MSIX and portable packagers fail closed if `OpenBurnBar.Cli.exe` is
  absent; the portable layout documents the command surface.

## Verification

- `CompanionCliClientTests` exercises an authenticated exchange against the
  real loopback server, protected-token failure, inline-token rejection, and
  the explicit unauthenticated mode.
- `CompanionCliApplicationTests` covers aliases, bounded stdin, future
  operations, stable exits, secret redaction, malformed input, and help without
  transport.
- `CompanionCliPackagingTests` verifies release publishing/signing intent, the
  exact MSIX alias, and fail-closed packagers.
- Local Release tests pass for the managed-runtime and distribution projects;
  self-contained `win-x64` and `win-arm64` CLI publishes both succeed. Exact
  Windows-host compile, signing, package installation, and alias execution are
  release evidence and must come from the corresponding CI candidate.

## Boundary

This closes the standalone companion CLI / daemon-client part of WPD-0009. It
does **not** claim the separate connector secret store, tooling proxy,
workspace bridge broker, or context selector in WPD-0006 row 33.
