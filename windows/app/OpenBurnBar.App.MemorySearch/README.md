# OpenBurnBar.App.MemorySearch

Portable (net8.0) Windows peer of the macOS **semantic-search + memory-extraction** engine. Zero
Windows TFM, zero P/Invoke, zero UI framework — the SAME managed assembly the WinUI shell links
is unit-tested on the macOS authoring host today (`dotnet test`). Mirrors the
proven `OpenBurnBar.App.TextExpansion` / `OpenBurnBar.App.Settings` portable-core pattern.

Tests: `windows/tests/memory-search/` (net10.0 xUnit, 157 tests).

## What is ported (deterministic, faithful to the Swift oracles)

### Search (`Search/`)
| File | macOS oracle | What |
| --- | --- | --- |
| `VectorMath.cs` | `VectorSearch/VectorIndexTypes.swift` | cosine / dot / negative-euclidean / L2, blob codec — bit-for-bit float32/double discipline |
| `VectorCandidateBackend.cs` | `VectorSearch/VectorCandidateBackend.swift` | the one canonical top-k rule (score desc, chunkID asc, drop non-finite) + `ExactVectorCandidateBackend` |
| `EmbeddingTypes.cs` | `Embedding/EmbeddingProviderProtocol.swift`, `EmbeddingTypes.swift` | descriptor + identity (sha256) + the injectable provider seams |
| `DeterministicEmbeddingProvider.cs` | `Embedding/DeterministicEmbeddingProviders.swift` | the seeded hash embedding — **bit-for-bit** vs an independent numpy-float32 reference |
| `OpenAIEmbeddingProvider.cs` | `Embedding/OpenAIEmbeddingProvider.swift` | bounded OpenAI-compatible `/embeddings` transport with model/vector validation |
| `SearchRankingMath.cs` | `SearchService+Ranking.swift`, `+Retrieval.swift` | RRF, normalized RRF/lexical, recency (injectable clock), exact-token coverage, snippet, sensitive-lookup, the two hybrid blends, final sort/dedup |
| `CrossEncoderReranker.cs` | `CrossEncoderReranker.swift` | prompt build → parse `[{chunk_id, relevance}]` → reorder, over an injectable completion-client seam |
| `RetrievalHealth.cs` | `RetrievalHealthService.swift`, `SearchService+Health.swift` | per-query status/error mapping, degraded-mode classification, monotonic latency timer |

### Memory (`Memory/`)
| File | macOS oracle | What |
| --- | --- | --- |
| `MemoryExtractionPromptBuilder.cs` | `Memory/MemoryExtractionPromptBuilder.swift` | exact prompt/contract literals + recent-first char-budgeted transcript render |
| `MemoryExtractionPolicy.cs` | `Memory/MemoryExtractionPolicy.swift` | ceilings + clamps + kill switch + settings box |
| `MemoryRecallBudget.cs` | `Memory/MemoryRecallBudget.swift` | high-recall limit/budget + prose token estimation + pinned wrapper overhead (202) |
| `MemoryExtractionParser.cs` | `Memory/MemoryExtractionParser.swift` | clean-JSON-first + brace-slice fallback, field-level leniency, kind fallback, confidence clamp |
| `MemoryExtractionSettingsSnapshot.cs` | `Memory/MemoryExtractionSettingsSnapshot.swift` | local-first provider filter + clamp derivations |
| `MemoryExtractionDeadline.cs` | `Memory/MemoryExtractionDeadline.swift` | the throwing wall-clock deadline race |
| `MemoryExtractionLlmClient.cs` | `Memory/MemoryExtractionLLMClient.swift` | bounded OpenAI-compatible/Ollama transport seam |
| `MemorySecretPIIGate*.cs` | `OpenBurnBarCore/.../Memory/MemorySecretPIIGate.swift` | the fail-closed secret/PII gate over the committed corpus (linked, single source of truth) |

## The injectable seams

The OpenAI embedding and memory-extraction network calls are implemented behind fakeable
`HttpClient` boundaries. Everything here rides fakeable seams:

- `IEmbeddingProvider` (chunk + query) — text → `float[]`; deterministic fallback and bounded OpenAI provider ship here.
- `ICrossEncoderCompletionClient` — (system, user) → completion text; fake returns canned JSON.
- `IMemoryExtractionLlmClient` — OpenAI-compatible / Ollama completion; bounded HTTP implementation ships here.
- `Func<DateTimeOffset>` clock for recency; `Stopwatch` for latency.
- `MemoryGateCorpus` is injectable so the fail-closed and custom-corpus branches are testable.

## Faithful-behavior notes

- **Cross-encoder inertness (flagged, not silently changed):** in the macOS pipeline the reranker
  reorders candidates but never writes their relevance into `rerankScore`, and `SearchService`
  then re-sorts unconditionally by the hybrid `rerankScore` — so the cross-encoder is inert on
  final ordering at the pipeline level. This port reproduces the reranker COMPONENT exactly
  (scoring/ordering over a fake scorer); a future pipeline integration should preserve or
  deliberately fix that behavior.
- **ASCII parity:** grapheme/UTF-16/byte offsets coincide for ASCII, which the deterministic
  embedding tokenizer, the snippet truncation, and the secret/PII corpus all target. Non-ASCII
  edge cases follow .NET Unicode semantics (documented in each file header).
- **ANN backend** (`ann_signpost_v1`) is out of these sources and approximate; deterministic parity
  is preserved by the exact path, so only the exact/deterministic search core is ported.
