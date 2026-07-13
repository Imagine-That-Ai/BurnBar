# Windows OpenAI embedding-provider evidence

**Date:** 2026-07-13  
**Lane:** F2 semantic search / memory

Ledger row: f2-project-code-memory-store

## What this proves

Windows now has a real OpenAI-compatible `/embeddings` provider matching the
macOS model contract for `text-embedding-3-small`, `text-embedding-3-large`,
and `text-embedding-ada-002`. It sends bearer-authenticated JSON through an
injectable `HttpClient`, preserves indexed batch order, and validates response
count, item indexes, vector dimensions, finite values, status errors, and a
32 MiB response ceiling. Empty input is a no-op. Unknown models, invalid
endpoints, missing keys, oversized text/batches, malformed responses, and
transport failures produce typed errors without logging or embedding the key
in exception text.

The deterministic 96-dimensional provider remains the offline fallback used by
the source-free project-code store and CI. This adapter is deliberately
provider-backed and ready for the Windows protected-secret/settings composition
to select it without changing the portable search contracts.

## Validation

```text
dotnet test windows/tests/memory-search/OpenBurnBar.App.MemorySearch.Tests/OpenBurnBar.App.MemorySearch.Tests.csproj
```

Result: **147 tests passed**. The provider tests use an in-memory HTTP handler
to verify request shape/authentication, indexed ordering, empty input, typed
model/URL/key failures, malformed vector rejection, bounded error handling, and
oversized-input rejection without contacting a real provider.

## Boundary

This closes the OpenAI transport and validation seam. It does not claim live
account credentials, production settings selection, provider billing/quotas,
NaturalLanguage/BGE parity, or physical release certification.
