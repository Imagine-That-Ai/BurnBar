# Dual untrusted envelopes (W04 optional alignment)

| Surface | Envelope | Oracle |
|---------|----------|--------|
| Chat / RAG / memory snippets | `OpenBurnBarCore.LLMSafeContent.wrapUntrusted` -> `<UNTRUSTED_CONTENT provenance="...">` + `CRITICAL RULE` | `AgentLensTests/.../PromptInjectionHardeningTests.swift` |
| Project code search / context pack | `BurnBarProjectCodeMemoryStore.wrapUntrustedCode` -> `OPENBURNBAR_UNTRUSTED_CODE_V1` JSON block | `OpenBurnBarDaemonTests/BurnBarProjectCodeMemoryStoreTests.swift` |

These are intentionally different transports: prose prompts use XML sentinels; code memory uses a versioned JSON schema with `warning` + `content` fields. Consumers must not treat either envelope as instructions.

Alignment evidence: both paths defang breakout attempts in their respective layers; full unification is a product decision, not a Linux-port blocker.
