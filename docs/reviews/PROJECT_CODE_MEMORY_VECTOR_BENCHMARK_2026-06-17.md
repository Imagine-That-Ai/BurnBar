# Project Code Memory Vector Benchmark — 2026-06-17

Command:

```bash
scripts/ci/project-code-memory-vector-benchmark.py
```

Result:

- Status: `ok`
- Fixture: 120 Python files, 600 chunks
- Indexed files: 120
- Storage byte count: 307800
- Cold index time: 0.642 s
- Search latency: p50 13.35 ms, p95 14.82 ms, p99 16.79 ms, max 16.79 ms
- Dense retrieval: disabled
- Selected provider/model: `ollama` / `nomic-embed-text`
- Dense gate reason: `OPENBURNBAR_CODE_EMBEDDING_PROVIDER` must be set to `ollama`

Decision:

The current production path remains sparse-only. Dense/vector retrieval is not
enabled until a real local embedding provider is configured and every current
chunk has vectors for the active non-fingerprint embedding version.
