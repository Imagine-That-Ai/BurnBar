# Windows memory-extraction HTTP client evidence

**Date:** 2026-07-13  
**Lane:** F2 memory extraction

Ledger row: nav-memory

## What this proves

Windows now composes the stateless network boundary behind
`IMemoryExtractionLlmClient`. The OpenAI-compatible client posts the macOS
message contract, JSON response-format hint, optional OpenRouter title, and
GPT-5.5 reasoning hint, then accepts string or structured text content. The
Ollama client posts the non-streaming JSON-generation contract and exposes the
same transport/status cooldown semantics as macOS. Prompt/model/output/timeout
and response-size limits are enforced before data enters the parser; malformed
responses, invalid endpoints, status failures, cancellation, and transport
errors return null/fail-closed results without exposing credentials.

## Validation

```text
dotnet test windows/tests/memory-search/OpenBurnBar.App.MemorySearch.Tests/OpenBurnBar.App.MemorySearch.Tests.csproj --no-restore
```

Result: **157 tests passed**. The HTTP tests use an in-memory handler to verify
OpenAI request headers/body/content variants, Ollama request shape and response,
status-based cooldowns, cancellation, invalid input, and fail-closed behavior.

## Boundary

This closes the network transport seam. It does not claim a configured Windows
account, provider billing/quota parity, production memory-consent composition,
or physical release certification.
