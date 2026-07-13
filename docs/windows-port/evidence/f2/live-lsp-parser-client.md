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

## Validation

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~LanguageServerProjectCodeParserClientTests
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore
```

Results: **2 protocol tests passed** and the full presentation suite passed
(763 tests). The tests launch the checked-in fake language-server executable,
verify symbol and reference responses, validate `exact_lsp` and SHA evidence,
and prove missing-language/path-traversal fail-closed behavior.

## Boundary

This closes the Windows JSON-RPC LSP adapter seam. It does not claim a specific
production language server is installed on a user's machine, compiler-quality
coverage for every language, or physical Windows release certification.
