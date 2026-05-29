# VibeProxy vs. OpenBurnBar Gateway — Token-Waste Comparison

**Status:** Research + comparison (no code changed).
**Date:** 2026-05-28.
**Scope:** How VibeProxy forwards LLM traffic vs. how OpenBurnBar's daemon gateway
(`127.0.0.1:8317`) does, focused on places where OpenBurnBar can spend more
tokens / billed upstream calls than VibeProxy.

---

## 1. How VibeProxy works (evidence)

VibeProxy is `unco3/vibeproxy`, a small Go localhost proxy. Its headline purpose
is **API-key hygiene** (swap a deterministic dummy token `vp-local-<service>` for
the real key from the OS keychain), *not* usage metering. Sources:

- Repo / README: <https://github.com/unco3/vibeproxy> ·
  <https://github.com/unco3/vibeproxy/blob/master/README.md>
- Proxy path: <https://github.com/unco3/vibeproxy/blob/master/internal/proxy/proxy.go>
- Request rewriter: <https://github.com/unco3/vibeproxy/blob/master/internal/proxy/rewriter.go>
- Router: <https://github.com/unco3/vibeproxy/blob/master/internal/proxy/router.go>
- Optional gateway: <https://github.com/unco3/vibeproxy/blob/master/internal/gateway/handler.go>,
  `openai.go`, `anthropic.go`, `sse.go`, `translator.go`, `types.go`

### 1a. Two forwarding paths

1. **Proxy path (default & primary).** A Go `httputil.ReverseProxy` per request.
   - `FlushInterval: -1` → flush on **every write** = true SSE/streaming
     passthrough, byte-for-byte (`internal/proxy/proxy.go`,
     `reverseProxyHandler`).
   - The `Rewrite` hook *only* sets the target URL/Host, injects the real key,
     and strips the agent header. **The request body is never parsed or
     modified** — `max_tokens`, `reasoning_effort`, `thinking`, `tools`, etc.
     pass through exactly as the client sent them. (`rewriter.go` is just token
     extraction; there is no body rewriter.)
   - `ModifyResponse` detects a streaming response (`text/event-stream` or
     chunked) and **clears the write deadline** (`rc.SetWriteDeadline(time.Time{})`)
     so a long generation is never killed by the server's `write_seconds`
     timeout.
   - `ResponseHeaderTimeout = upstream_seconds` (default 90s) bounds only the
     wait for upstream **headers**, not the body/stream.
   - **No retry, no failover.** One upstream attempt. On a connection/timeout
     error the `ErrorHandler` writes a single `502` and logs once; on client
     disconnect it logs `499` and stops. There is exactly one upstream request
     per client request.

2. **Gateway path (optional, `gateway.enabled: false` by default).** Routes by
   model prefix (`gpt-` → openai, `claude-` → anthropic) and translates.
   - OpenAI translator is **near-passthrough**: it re-marshals the request to
     `/v1/chat/completions` unchanged (`internal/gateway/openai.go`).
   - Anthropic translator sets `max_tokens` to the caller's value, or
     `defaultAnthropicMaxTokens = 4096` **only when the caller omitted it**
     (Anthropic requires the field). It injects **no** `thinking`/reasoning
     budget and never raises a caller's `max_tokens`
     (`internal/gateway/anthropic.go`).
   - Streaming is real: `handleStream` reads upstream SSE and `flusher.Flush()`es
     each event immediately (`internal/gateway/handler.go`).
   - **No retry, no failover** — a single `client.Do(upReq)`
     (`http.Client{Timeout: 120s}`). On `>= 400` it copies the upstream error
     body straight back to the client.

### 1b. Token counting

VibeProxy does **not** count or attribute tokens. Its audit log
(`~/.vibeproxy/audit.log`) records timestamps, method, path, status code, and
duration — explicitly "no secrets," and no usage. It therefore performs no
usage-parsing work and makes no estimation calls.

### 1c. Net behavior

VibeProxy is a thin, verbatim, single-shot, true-streaming pipe. Its
**token-waste surface is essentially zero**: it forwards exactly what the client
asked for, streams it back live, and never issues a second upstream call for the
same client request. The trade-off is that it has no usage tracking, no quota
awareness, no multi-account capacity, and a narrow optional translator.

---

## 2. How OpenBurnBar's gateway works (evidence)

The daemon gateway is a `Network.framework` HTTP server that fully buffers each
request, runs a router, then issues **buffered** (`URLSession.data(for:)`)
upstream calls through provider executors, and writes the whole response back in
one shot.

Key files:
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarProviderExecutor.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarAnthropicProviderExecutor.swift`

The server reads the entire request body before routing, **rejects inbound
`Transfer-Encoding: chunked`** (`OpenBurnBarHTTPGatewayServer.swift:1485-1487`),
and writes the response as a single buffered `send` with a fixed
`Content-Length` and `Connection: close`
(`OpenBurnBarHTTPGatewayServer.swift:1408-1426`). There is no incremental flush
in either direction.

---

## 3. Side-by-side comparison

| Dimension | VibeProxy | OpenBurnBar gateway |
|---|---|---|
| **Upstream call** | `httputil.ReverseProxy`, body streamed both ways | `URLSession.data(for:)` — full request sent, full response **buffered** in memory (`OpenBurnBarProviderExecutor.swift:190, 264, 305, 386`; `OpenBurnBarAnthropicProviderExecutor.swift:146`) |
| **Streaming to client** | True passthrough; flush every write (`FlushInterval:-1`), write deadline disabled for SSE | **No live streaming.** Even for `stream:true`, the whole upstream SSE is buffered, then re-emitted as one blob; synthetic SSE built fully in memory before a single `send` (`OpenBurnBarHTTPGatewayServer.swift:1408-1426`). `/v1/models` still advertises `native_streaming:true` (`:1664`). |
| **Client cancellation** | Client disconnect cancels upstream request (Go request context) → `ErrorHandler` 499, upstream aborted | Daemon does not observe client disconnect during upstream work; upstream call runs to completion and bills regardless |
| **Failover / retry** | None — exactly 1 upstream call per request | Multi-account, in-pool failover loop that **re-sends the full prompt** to each next route (`:839-879` chat, `:980-1020` responses, `:1127-1166` messages); trigger = `shouldFailOverProviderError` (`:1336-1357`: 429/401/403/402 or body contains quota/rate/insufficient/exhaust) |
| **Responses→Chat fallback** | Proxy path forwards `/v1/responses` verbatim (1 call) | On upstream `404/405`, makes a **second** upstream call to `/chat/completions` (`OpenBurnBarProviderExecutor.swift:311-314`, `329-357`) |
| **Request rewriting** | None (proxy path); Anthropic gateway only defaults `max_tokens=4096` when omitted | Variant injection **overwrites** caller fields: OpenAI `reasoning_effort` + `max_completion_tokens`/`max_tokens` (`OpenBurnBarProviderExecutor.swift:445-470`); Anthropic forces `thinking{enabled,budget}` and raises `max_tokens` floor to `budget+4096` (`OpenBurnBarAnthropicProviderExecutor.swift:279-300`) |
| **Token counting** | None (status/duration audit only) | Exact usage parsed from upstream + cost, recorded to ledger (`recordUsageIfAvailable`, `:1262-1300`) |
| **Usage idempotency** | n/a | Random per-call key `gateway:<UUID>` (`:1288`) — does **not** dedup duplicate billings (contrast the stable key in `tools/openburnbar-mcp/hermes_proxy.py:392-399`) |
| **Quota / route gating** | None — forwards any path/model | Refuses upstream when no eligible route / unprovable exact model → `503` before any upstream call (`:794-797, 827-828`); model-health store blocks known-bad routes (`:370-394`) |
| **Max upstream calls per client request** | **1** | **≥1, up to N(routes) + 1** (failover × responses-fallback × any client retry) |

---

## 4. Ranked token-waste differences (OpenBurnBar worse than VibeProxy)

### #1 — Buffered upstream instead of streaming → client timeouts → full-request retries (double/triple billing). **Severity: HIGH**

**What:** Every executor uses `URLSession.data(for:)` and only returns after the
*entire* upstream generation completes:
`OpenBurnBarProviderExecutor.swift:190` (structured), `:264`
(`proxyChatCompletions`), `:305` (`proxyResponses`), `:386` (Ollama native);
`OpenBurnBarAnthropicProviderExecutor.swift:146` (`proxyMessages`). The gateway
then writes the whole body in one `send` with `Content-Length` +
`Connection: close` (`OpenBurnBarHTTPGatewayServer.swift:1408-1426`). For
`stream:true`, the upstream SSE is buffered and the synthetic SSE
(`chatCompletionsStreamFromAnthropicStream`, `responsesStreamFromChatCompletionStream`,
`openAIStreamResponseFromOllama`) is fully assembled before that single write.

**Why it wastes tokens:** A long reasoning/coding completion can take 30–120s+.
The client receives **zero bytes** until it finishes. Agent clients (Codex,
Droid/Factory, Cursor, OpenCode) enforce first-byte/idle/stream timeouts; when
they fire the client typically **retries the whole request**. The original
upstream call has already generated (and been billed for) the full completion,
so the retry is a second full input+output bill — and if the daemon can't see
the disconnect, the abandoned call still bills in full. This is the single
largest divergence from VibeProxy, which streams every chunk live and disables
the write deadline for SSE so the client's idle timer never trips.

**Recommended fix:** Make the gateway a real streaming proxy. Open the upstream
with `URLSession.bytes(for:)` (or a streaming `URLSessionDataDelegate`) and write
SSE chunks to the `NWConnection` as they arrive (chunked transfer / incremental
`send`), while tallying usage from the final chunk. At minimum, propagate client
disconnect to cancel the upstream `URLSessionTask` so abandoned generations stop
billing. Until then, the advertised `native_streaming:true`
(`OpenBurnBarHTTPGatewayServer.swift:1664`) overstates real behavior.

### #2 — Multi-account failover re-sends the full prompt → duplicate billing. **Severity: MEDIUM–HIGH**

**What:** On a retryable upstream status the gateway loops to the next route with
the same `bodyData`: `:839-879` (chat), `:980-1020` (responses), `:1127-1166`
(messages); classifier `shouldFailOverProviderError` at `:1336-1357` returns true
for 429/401/403/402 and any body containing `quota`/`rate`/`insufficient`/`exhaust`.

**Why it wastes tokens:** A pure pre-generation 429 usually bills nothing, but
the prompt is re-sent in full to each subsequent account, so:
- providers that bill **input tokens** on accepted-then-throttled requests get
  billed once per attempt;
- a **mid-generation** rate-limit (partial output already produced and billed)
  followed by a successful retry double-bills input and pays for the partial
  output too;
- substring matching on `rate`/`quota`/`insufficient` can misclassify a
  *completed-and-billed* response whose body happens to contain those words,
  triggering an unnecessary second full call.

VibeProxy never fails over, so it structurally cannot double-bill this way.

**Recommended fix:** Only fail over on statuses that are provably
pre-generation/no-charge (e.g. 401/403 auth, 402 hard-exhaustion, 429 with a
`retry-after` and zero usage), and **never** on heuristic body-substring matches
for 2xx-adjacent or ambiguous cases. Tighten `shouldFailOverProviderError`
(`:1336-1357`) to require a structured rate-limit/quota error rather than a
`.contains()` scan, and skip failover entirely once any usage has been observed.

### #3 — Variant injection inflates reasoning/output beyond the caller's request. **Severity: MEDIUM (opt-in)**

**What:** When the client's wire id resolves to a thinking-level variant:
- OpenAI: `applyOpenAIVariant` (`OpenBurnBarProviderExecutor.swift:445-470`)
  **overwrites** `reasoning_effort`/`reasoning.effort` and
  `max_completion_tokens`/`max_tokens`/`max_output_tokens` with the variant's
  values (comment: "Caller-supplied values … are deliberately overwritten").
- Anthropic: `applyAnthropicVariant`
  (`OpenBurnBarAnthropicProviderExecutor.swift:279-300`) forces
  `thinking={type:enabled, budget_tokens:budget}` and sets `max_tokens` to at
  least `budget + 4096`, overriding a smaller caller `max_tokens`.

**Why it wastes tokens:** Forcing extended thinking generates reasoning tokens
the caller may not have asked for, and raising the `max_tokens` floor permits
(and bills) larger completions than the client's own cap. VibeProxy never
rewrites these fields. Note this is **gated on the user explicitly selecting a
variant id** — it is a deliberate product feature ("lock in xhigh"), not silent
on the base model — so it ranks below #1/#2, but it remains a real place where
OpenBurnBar can spend more than the literal request.

**Recommended fix:** Keep the effort override (that is the feature) but treat
`max_tokens` as a ceiling, not a forced floor: when the caller's `max_tokens` is
smaller than `budget+4096`, raise only the minimum Anthropic requires
(`budget+1`) instead of `budget+4096`, and never *increase* a caller's
`max_completion_tokens` on the OpenAI path. Make the thinking budget per-variant
configurable, and document that variants intentionally change spend.

### #4 — Responses→ChatCompletions fallback issues a second upstream call. **Severity: LOW (rarely billed) / latency**

**What:** `proxyResponses` calls `/responses`, and on `404`/`405` makes a second
upstream call to `/chat/completions`
(`OpenBurnBarProviderExecutor.swift:311-314`, `329-357`).

**Why it (barely) wastes:** A 404/405 is a pre-generation routing/method error,
so the first call almost never bills tokens — the cost is a wasted round trip and
latency, repeated on *every* request to a provider that lacks `/responses`.

**Recommended fix:** Cache the per-provider/account "no `/responses` endpoint"
capability (alongside the existing model-health store) so subsequent requests go
straight to the chat-completions bridge without the throwaway `/responses`
probe.

### #5 — Usage idempotency key cannot dedup duplicate billings. **Severity: LOW (reporting accuracy, not tokens)**

**What:** `recordUsageIfAvailable` records with
`idempotencyKey: "gateway:\(UUID().uuidString)"`
(`OpenBurnBarHTTPGatewayServer.swift:1288`) — a fresh random key each call. The
sibling `tools/openburnbar-mcp/hermes_proxy.py` instead derives a **stable** key
from provider+model+session+timestamp+upstream-request-id
(`hermes_proxy.py:392-399`).

**Why it matters:** When vector #1 causes a client to retry and produce two
successful gateway requests for one logical turn, the random key guarantees two
ledger rows; a stable key keyed on the upstream `id`/request-id could collapse
duplicates. This is attribution accuracy rather than token spend, but it means
the product that exists to *measure* waste can itself double-count it.

**Recommended fix:** Derive the gateway idempotency key from the upstream
response `id`/`x-request-id` (fall back to a content hash) so genuine duplicates
merge.

---

## 5. Where OpenBurnBar is BETTER than VibeProxy

1. **Real token/cost accounting.** Exact input/output/cache/reasoning tokens +
   cost recorded per request (`recordUsageIfAvailable`,
   `OpenBurnBarHTTPGatewayServer.swift:1262-1300`). VibeProxy records none — it is
   the entire reason BurnBar exists as a replacement.
2. **Pre-flight route gating saves tokens.** BurnBar returns `503` *before* any
   upstream call when there is no eligible route or it cannot prove exact-model
   identity (`:794-797`, `:827-828`, `noEligibleRouteResponse`/
   `exactModelIdentityUnavailableResponse`). VibeProxy blindly forwards whatever
   model/path the client sends, so a typo or wrong-model request still bills.
3. **Model-health memory.** A route that just proved it cannot serve a model is
   removed from advertising and skipped (`canAdvertiseModel` `:370-394`,
   `modelHealthStore.recordFailure`), preventing repeated wasted attempts.
   VibeProxy has no such memory.
4. **Multi-account capacity + quota awareness.** Skips disabled/missing-secret/
   cooling-down/exhausted slots and rotates healthy ones — a real capability
   VibeProxy lacks (the failover, used carefully, is a feature; see #2 for the
   billing caveat).
5. **Empty-/length-capped completion guard.** Detects reasoning-only or
   length-truncated empty answers and returns an actionable `502` instead of an
   empty body (`validateOpenAICompatibleChatResponse` `:1553-1585`,
   `validateOllamaNativeChatResponse`), helping users fix `max_tokens` instead of
   silently retrying.
6. **Format bridging.** Anthropic↔OpenAI and Responses↔Chat translation lets one
   account serve many client shapes; VibeProxy's optional gateway is a much
   narrower translator and its proxy path does none.
7. **Claude Code OAuth identity handling** to unlock Opus on Max subscriptions
   (`OpenBurnBarAnthropicProviderExecutor.swift:96-165`) — VibeProxy only swaps a
   key.
8. **Per-client rate limiting + structured, idempotent usage ledger** (despite
   the key caveat in #5).

---

## 6. Bottom line

VibeProxy minimizes wasted tokens by doing almost nothing: verbatim body,
live streaming, exactly one upstream call, no rewriting. OpenBurnBar trades that
minimalism for metering, routing, quota-awareness, and format bridging — all
genuinely valuable — but its **buffered, non-streaming hot path (#1)** is the
real regression: it converts long generations into client-side timeouts that
trigger full-request retries, and a retry of an already-billed completion is the
most expensive kind of double-bill. Fixing the streaming hot path (and tightening
failover in #2) would let OpenBurnBar keep all of its advantages while matching
VibeProxy's token efficiency.
