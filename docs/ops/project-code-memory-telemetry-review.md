# Project Code Memory Telemetry Review

Project Code Memory handles source code and durable agent memory. Telemetry for
this surface is allowed only when it is operationally necessary and cannot carry
plaintext source, snippets, memory bodies, raw untrusted content, secrets, or
model prompts.

Project Code Memory telemetry cannot carry plaintext source.

Allowed fields:

- project IDs, audit hashes, blob/content hashes, schema versions, counts, byte
  counts, latency, timeout, and boolean gate states;
- confidence tiers and fallback reason codes;
- local-only readiness flags such as parser availability, SQLCipher state,
  hosted-code disabled state, and semantic availability.

Disallowed fields:

- source text, snippets, context packs, memory bodies, comments, diagnostics
  source lines, or untrusted wrapper payloads;
- raw secret scanner matches;
- raw LSP/helper stdout or stderr;
- cloud telemetry that implies hosted code sync is enabled by default.

Review gate:

- `scripts/ci/verify-project-code-memory-telemetry-policy.sh` must pass before a
  Project Code Memory telemetry change lands.
- New telemetry events must update this document with the field list and the
  reason each field is operationally necessary.
- Hosted telemetry remains blocked until the hosted code threat model and
  sealed-only proofs pass.
