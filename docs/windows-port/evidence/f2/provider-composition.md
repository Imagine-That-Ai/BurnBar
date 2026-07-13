# Windows provider composition evidence

**Date:** 2026-07-13  
**Lane:** F2 semantic search / project-code memory

Ledger row: f2-project-code-memory-store

## What this proves

The durable Windows project-code store now accepts an explicit embedding
provider identity (version plus dimensions) and uses it for both chunk writes
and semantic queries. The app composition reads the persisted
`indexEmbeddingProvider` and `indexOpenAIModel` settings. `openai` is opt-in;
its API key is read only from the protected provider secret
`openburnbar.windows.provider.openai.project-code.api-key`. Missing keys,
unsupported models, invalid endpoints, or provider construction failures log a
non-secret diagnostic and keep the deterministic 96-dimensional offline path.

This prevents a configured provider from being silently ignored while keeping
existing databases and offline startup deterministic. Vector rows are tagged
with the provider-derived embedding version, so changing models cannot mix
incompatible dimensions in one query.

## Validation

```text
dotnet test windows/tests/presentation/OpenBurnBar.App.Presentation.Tests.csproj --no-restore --filter FullyQualifiedName~ProjectCodeMemoryServiceTests
dotnet test windows/tests/memory-search/OpenBurnBar.App.MemorySearch.Tests/OpenBurnBar.App.MemorySearch.Tests.csproj --no-restore
```

Results: **8 project-store tests passed** and **157 memory/search tests passed**.
The app managed build reaches the expected macOS boundary at the Windows-only
WinUI XAML compiler (`XamlCompiler.exe`); all managed dependencies, including
the new provider composition, compile before that boundary.

## Boundary

This closes the local production-selection seam. It does not claim a live
OpenAI account, billing/quota acceptance, NaturalLanguage/BGE quality parity,
physical Windows certification, or staging cloud approval.
