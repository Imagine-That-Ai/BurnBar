# F2 evidence: Elder Wand parallel fusion pipeline

**Ledger row:** WPD-0006 row 32, `Elder Wand orchestration`
**Disposition:** `SUB-DONE (parallel fusion pipeline)`
**Integration:** PR #1654 Elder Wand implementation slice

## Production composition

The Windows app now runs the same three-stage product contract as macOS:

1. A bounded panel of one to eight configured analysis models answers in
   parallel. A failed or unroutable member is recorded and dropped; the run
   fails closed only when every panel member fails.
2. The configured judge compares the surviving answers into the five-field
   consensus/contradiction/coverage/insight/blind-spot verdict. Judge failure
   degrades to a clearly marked raw-panel verdict rather than discarding the
   usable analysis.
3. The originating model receives the bounded original conversation and judge
   verdict and produces the final answer. Buffered and streamed provider bodies
   retain their original content type.

`LocalHttpGatewayHost` intercepts only an active
`plugins:[{"id":"fusion"}]` request. Inner panel, judge, tool-loop, and
synthesis calls omit that plugin, so they cannot recursively re-enter fusion.
The standalone authenticated companion command uses the same orchestrator and
loads the saved default preset when an explicit panel is absent.

## Safety and accounting

- Exact-model route selection fails closed; cross-vendor substitution is not
  silently enabled for a panel, judge, or synthesis model.
- Panel fan-out is capped at eight models and tool execution at 1...16 calls.
- `web_fetch` accepts only credential-free HTTP(S) URLs, resolves every address
  at connection time, rejects mixed/private/loopback/link-local/multicast
  answers, pins the connection to the validated public address, denies
  redirects, and bounds response bytes and visible text.
- `web_search` is present but fails closed until an authenticated hosted-search
  delegate is composed. Live Firebase/App Check acceptance remains a staging
  certification gate; no provider search key is placed in the app process.
- The journal persists run/stage state and SHA-256 output digests only. It does
  not persist prompts, model answers, web content, tool arguments, or tool
  results.
- Each provider turn records metadata-only route/health/token telemetry with a
  shared run id and distinct stage/step identity. Provider response bodies stay
  out of telemetry.

## Focused verification

- `OpenBurnBar.App.Presentation.Tests`: **784 passed** locally, including
  parallel completion ordering, partial and total panel failure, judge fallback,
  synthesis, tool-call budgeting, unavailable-tool behavior, public-address
  policy, hosted-search fail-closed behavior, and payload-free journaling.
- `OpenBurnBar.App.ManagedAgentRuntime.Tests`: **279 passed** locally, including
  active/disabled plugin detection and outer-request interception without a
  duplicate provider dispatch.
- The Release app build compiles all portable and Windows C# dependencies on
  macOS, then stops only when macOS cannot execute the Windows-only
  `XamlCompiler.exe`. Exact-head Windows x64/ARM64 CI is the authoritative app
  compile and test proof.

## Honest residual boundary

This evidence closes the implementation row. It does not claim live paid search
quota, production Firebase/App Check credentials, physical-device performance,
manual accessibility, or Store/update certification. Those remain separate
staging and release gates in the certification bundle.
