# Windows live language-server client evidence

**Date:** 2026-07-13  
**Lane:** F2 project-code symbols and references

Ledger row: project-code-static-parser

## What this proves

Windows now has a shell-free JSON-RPC language-server adapter alongside the
Tree-sitter process client. Configured executable-plus-argument vectors are
started without command-line interpolation; the client performs bounded
`initialize`, `initialized`, `textDocument/didOpen`,
`textDocument/documentSymbol` or `textDocument/references`, `shutdown`, and
`exit` protocol exchange. Responses are framed by byte-accurate
`Content-Length`, bounded, correlated by request id, and converted to
`exact_lsp` symbols/references with current-source Git-blob evidence. Paths are
confined to the project root, Location and LocationLink forms are supported,
and timeout/cancellation/crash paths kill the child process.
Both the language-server adapter and Tree-sitter process client now use the
reviewed `ProjectTool` child-process policy, which preserves the explicit
argument vector and redirected UTF-8 streams while replacing inherited process
environment state with the secret-scrubbed profile allowlist.

## Validation

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~LanguageServerProjectCodeParserClientTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore
```

Results: **3 protocol/composition tests passed**, the full presentation suite
passed (774 tests), and the full configuration suite passed (37 tests). The
tests launch the checked-in fake language-server executable,
verify symbol and reference responses, validate `exact_lsp` and SHA evidence,
prove missing-language/path-traversal fail-closed behavior, and prove LSP
failure falls back to the bundled parser. Configuration tests prove the two
parser launches are present in the reviewed inventory and that no raw process
launch bypass remains under `windows/app`. App startup now composes the same
selection from `OPENBURNBAR_CODE_LSP_COMMANDS` when configured.

The project root itself is no longer environment-only: the Projects page owns a
persisted Windows folder-picker selection and shares the resulting long-lived
service with the companion plane. `OPENBURNBAR_CODE_LSP_COMMANDS` remains an
explicit language-server deployment map, not the workspace-selection path.

## Boundary

This closes the Windows JSON-RPC LSP adapter and app-selection seam. It does
not claim a specific production language server is installed on a user's
machine, compiler-quality coverage for every language, or physical Windows
release certification.
