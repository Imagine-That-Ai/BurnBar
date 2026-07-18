# Independent Windows Parity Audit Against macOS

**Date:** 2026-07-09
**Reference product:** shipping macOS OpenBurnBar
**Audit target:** local windows/liquid-glass-kernel-reskin checkout
**Status:** F1 source/product implementation and applicable WPD-0006 F2 substitutions are complete; corrected signed successor `windows-v1.0.35` passes the automated exact-candidate release gate; fresh physical x64, manual, live-staging, safety, and Store/update lifecycle certification remain

## Corrected Signed Successor - 2026-07-17

Protected tag `windows-v1.0.35` resolves to PR #1832 merge commit
`2cfa9db885dafef7f1f451a9e05a8ee775351d44`. Release workflow
[29557726093](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29557726093)
completed successfully with unsigned direct-download output forbidden. The
published-layout parser smoke passed before signing with both
`OpenBurnBarCore_OpenBurnBarCore.resources` and
`OpenBurnBarCore_OpenBurnBarKernel.resources` present. Its isolated .NET 10
testhost staged the Swift resource bundles beside the host process while the
exact copied publish directory supplied the native DLL dependency search path.

Azure Artifact Signing, portable and direct-MSIX signature verification,
RFC 3161 timestamp checks, x64 and ARM64 native-layout validation, direct and
Store MSIX packaging, Store unsigned-state verification, the hosted x64
clean-install/uninstall/reinstall lifecycle, Ed25519 update-feed signing, SPDX
SBOM, OpenVEX, and all 18 Sigstore attestations passed. Independent download
verification matched both GitHub artifact archive digests, every release
checksum, all four portable/direct native layouts, both Store identities and
resource layouts, the pinned two-entry update feed, and all 18 Sigstore
bundles under the exact tag workflow identity.

Exact distribution hashes:

- x64 portable ZIP: `bd851461b55da12a1b4d5470d26ccb5e8e6f2db7ea7e3a9a352b9ea7d47bf14e`
- ARM64 portable ZIP: `59ddf9ccc07f9c9535d1a49d6d9e824fe952be6d469965a3ca71906665bfc3c7`
- x64 direct MSIX: `1d68c24f044a0247d49a5f2e4030a4d46844ce49c34016d3605f129bcd9a43e1`
- ARM64 direct MSIX: `c3ef5b12c06ede819965f301357ac8d84ef22c4a71631528d353092a425f11bf`
- x64 Store MSIX: `a5fe60b3b0816f4b59482031e9e139725741665db0e2fd2150054a0f3f804d64`
- ARM64 Store MSIX: `eafc14b7a9d6b408d7ce1cf9f82228228d878c2ae416670d70de94fe797ece2c`

The machine-readable record and physical handoff are under
[`evidence/windows-v1.0.35-release/`](evidence/windows-v1.0.35-release/README.md).
This supersedes `windows-v1.0.31` only as the corrected automated signed
candidate. It does not erase that candidate's physical NO-GO result or convert
hosted lifecycle evidence into physical certification. A fresh physical Intel
x64 run is required. Physical ARM64 remains an explicit beta limitation, and
manual accessibility/display, live staging, advanced media/Computer Use
safety, and controlled Store/update lifecycle gates remain open.

The physical-performance gate is now fail-closed against an active numeric
contract rather than a subjective checklist. Independent harness commit
`0ff07832c9a2a8137d7a342682d4ccd785be7034` binds 18 launch, interaction,
CPU, memory, GPU, disk, frame, and soak measurements to
`release-performance-budgets.json`; requires declared tools, workload, power,
display, and sampling context; enforces sample/duration floors; hashes every raw
evidence file; independently derives each statistic from the complete sample
series; bounds sample cardinality and value domains; and re-evaluates every
threshold during receipt validation. This
closes an evidence-integrity gap but is not physical performance evidence: the
Intel x64 protocol must still run against the exact signed candidate, and ARM64
physical performance remains the documented beta limitation.

## Physical Intel x64 Performance Finding - 2026-07-17

The fresh native Intel x64 run for exact signed candidate `windows-v1.0.35`
remains **NO-GO**. Artifact binding, Authenticode identity and timestamp,
install/uninstall/reinstall, local automated checks, hardware attestation, and
the final seven-receipt evidence validator passed. The app completed a 30-minute
soak without a crash or hang, but private memory grew from 99.16 MB to 325.13 MB
across 1,801 samples: +227.88% against a +10% release budget. The sample series
was flat near 99-106 MB for roughly 24 minutes, then recorded two retained
high-water steps around 1,434 and 1,601 seconds. This is a physical performance
failure, not a harness or evidence-integrity failure.

The durable remediation moves the Swift C ABI parser out of the long-lived
WinUI tray process. `OutOfProcessUsageEngine` invokes the already-packaged,
signed `OpenBurnBar.Cli.exe` in a hidden one-scan worker mode over redirected
JSON standard streams. The reviewed launch policy forbids shell execution,
filters inherited environment, bounds stderr, enforces cancellation and a
five-minute timeout, and kills the worker tree on communication failure. Each
successful scan exits the worker so Windows reclaims the complete native heap.
The release workflow executes this real worker against the exact published x64
native engine and Swift resource layout before signing; distribution tests pin
the WinUI composition root to the out-of-process engine.

This source fix does not relabel the failed `windows-v1.0.35` result. A new
signed candidate must pass the same physical Intel x64 performance protocol.
Accessibility/display, authorized live staging, advanced media/Computer Use
safety, and private Store/update lifecycle evidence remain separate open gates.
Physical ARM64 remains the explicit beta limitation.

## Physical Intel x64 Packaging Finding - 2026-07-16

Independent certification on an HP ENVY x360 15-ew0xxx running native Intel
AMD64/x64 invalidated `windows-v1.0.31` as a physical release candidate. The
machine verified the exact tag commit
`9a280a7d36c52276bba083e6d6906a31d698bee1`, x64 MSIX SHA-256
`fd5e8215cd2f6d0f01b971e843742ca9ab1cb049e6e0eef317fa87bde85fe585`,
the expected Imagine That AI LLC Authenticode signer, and its RFC 3161
timestamp. Clean checkout, artifact binding, install, uninstall, and reinstall
passed. Normal and cold launch reproducibly failed with `0xc000001d`, so warm
launch, UI, performance, accessibility, staging, safety, Store/update, and
final evidence-validation gates did not run and remain unproved.

The root cause is the signed package layout, not the Intel CPU, CoreCLR,
ReadyToRun, WebView2, or the host runtime. The C ABI engine transitively uses
`OpenBurnBarKernel` resources during its usage scan, but the signed portable and
MSIX layouts contain only `OpenBurnBarCore_OpenBurnBarCore.resources`; they omit
`OpenBurnBarCore_OpenBurnBarKernel.resources`. Swift traps when `Bundle.module`
resolves the missing Kernel bundle, while Windows Error Reporting attributes the
mixed managed/native crash to `coreclr.dll`.

The replacement release line began at `1.0.32` and produced the corrected
signed successor at `1.0.35`. Its source gate requires both SwiftPM
resource bundles at native staging, MSBuild publish, post-signature manifest
refresh, portable packaging, and MSIX packaging. Both bundles and every file
within them must be hashed by `native-engine-manifest.json`. The Windows engine
workflow executes the real usage scan from the staged layout, and the release
workflow repeats that parser smoke from the published x64 layout before signing.
The exact-head signed artifact now exists as `windows-v1.0.35`; a fresh physical
Intel certification run remains required. No result from `windows-v1.0.31` may
be promoted or relabeled.

## Certification Update - 2026-07-11

At the time of this certification update, the remediation plan's F1
source/product ledger reported 46 rows as Real, with zero DeferredApproved,
Blocked, or Substituted rows. The current ledger is 50/50 Real. Both are scoped
F1 Ship Peer results, not proof that the F2 True 1:1 workstreams or the public
release gates are complete.

Current evidence materially supersedes the original source-only findings:

- Native Windows usage runtime, storage recovery, protected configuration,
  direct-process chat, settings/onboarding, activation, distribution, and the
  remaining declared parity surfaces are integrated on `main`.
- [Signed release run 29160512069](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160512069)
  succeeded for x64 and ARM64 with unsigned output forbidden. Azure Artifact
  Signing, Authenticode verification, timestamps, checksums, Ed25519 feed,
  SBOM, OpenVEX, and Sigstore steps all passed.
- [Exact-candidate x64 run 29160940577](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29160940577)
  verified 10,476/10,476 exported blobs with zero mismatches and passed the
  Windows foundation harness and secret scan.
- [Signed hosted x64 run 29162867538](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29162867538)
  passed clean signed-MSIX registration, package identity checks, uninstall
  with absence verification, and reinstall. It did not launch the app and is
  registration evidence only, not a runtime certification result.
- An exact `778e735a69ea9d812db87146630223ac1a3a49d7` candidate was imported into
  Windows 11 Pro ARM64 under UTM with 10,475/10,475 files verified and zero
  mismatches. The ARM64 solution build, 180 focused tests, all ten storage
  failure/recovery cases, chat evidence, and a zero-finding artifact secret scan
  passed. The evidence archive SHA-256 is
  `1a276bd023f5d6078fee4501ced80a94da9ba1db0414b774fd184fb4a843c7ad`.
- The decisive foundation host pass for the same exact candidate captured all
  53 required scenarios: 17 process cases and 14 interactive UIA cases in
  signed-in session 1. Its manifest indexes 94 artifacts with no missing
  scenarios and zero secret findings. The evidence collector is independently
  bound to PR #1546 commit `05e6a0bb5c` by matching expected/actual SHA-256
  `8844a50251d2239d6d8a0f4120436c3f143ce6f5006bf10c498ac953ec3ed137`.
  The committed evidence includes the exact aggregate UIA result, all 34
  manifest-indexed UIA/route JSON artifacts, and a process trace with signed-in
  profile paths deterministically redacted; raw and committed hashes are in
  `arm64-utm/foundation-host-v6/host-evidence-provenance.json`.
- The initial signed ARM64 receipt was invalidated. Its process samples were
  taken about 0.1 seconds after creation; repeated sustained launches later
  exited with `Microsoft.UI.Xaml.Markup.XamlParseException` at
  `FlyoutWindow.InitializeComponent` because the manual MSIX lacked a
  package-root `resources.pri`. Signature, identity, install, uninstall, and
  reinstall evidence remain valid, but runtime launch did not pass. PR #1541
  fixes the resource index and adds 20-second clean-install and reinstall
  launch holds with WER and WinUI diagnostic rejection. Exact signed successor
  [run 29166970379](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29166970379)
  completed successfully from `9dbcaa791794944326ce9ffb18ed4d9771f31ecc`.
  Its hosted x64 receipt passed both responsive launch holds with zero crash
  events. The exact ARM64 MSIX was then hash-verified, signature-verified, and
  independently passed the same lifecycle on Windows 11 Pro ARM64 under UTM
  with zero crash events or fatal WinUI diagnostics. The corrected package
  hashes are `ac5b63a258c2151c7f1c8f3092ff54720d8c97b375efa38754a2e4a1857e0f43`
  for x64 and `7350fd248f65fd9de6eb3b2b5804508d9b47386a9fa0d9028526d70791874d8b`
  for ARM64.
- These are related but deliberately separate proof candidates. Foundation
  candidate `778e735a69ea9d812db87146630223ac1a3a49d7` proves source import,
  build/tests, storage, process, and interactive UIA behavior. Descendant signed
  runtime candidate `9dbcaa791794944326ce9ffb18ed4d9771f31ecc` proves corrected
  package signing, install, sustained launch, uninstall, and reinstall. Its
  ARM64 import independently verified 10,477/10,477 files with zero mismatches.
  Git ancestry establishes `778e735a` as the successor's merge base and
  ancestor. Their exact eight-file delta is confined to release workflows,
  candidate export/evidence tooling, and MSIX packaging/lifecycle gates; no
  Windows app/product source file differs. The collector fix does not change
  product behavior.
- The physical iPhone companion built, signed, installed, and launched. Its
  suite recorded 1,240 passed, 13 failed, and 28 skipped tests, so this is
  physical compile/install evidence rather than a green-suite claim.

The committed evidence index is
[`evidence/final-certification-2026-07-11/README.md`](evidence/final-certification-2026-07-11/README.md).
The remaining blockers to a 100% certification statement are physical Windows
x64/ARM64 hardware performance and graphics coverage; Narrator, keyboard, DPI,
and high-contrast manual protocols; live staging OAuth/App Check/CloudVault and
cross-device flows; physical Computer Use/media/file-safety validation; and the
public update/rollback/Store release lifecycle. The QA checklist below remains
unchecked where a row combines any of these unproven requirements.

## Exact-Head Signed Windows Candidate Update - 2026-07-15

Protected tag `windows-v1.0.31` resolves exactly to merged PR #1800 commit
`9a280a7d36c52276bba083e6d6906a31d698bee1`. Signed release workflow
[29423558731](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29423558731)
completed successfully from that tag with unsigned output forbidden. Both native
Swift engine legs, the distribution core, WinUI publish, portable and MSIX
Authenticode signing, portable layout validation, x64 signed-MSIX lifecycle,
checksums, the signed Ed25519 update feed, SPDX SBOM, OpenVEX, and Sigstore
provenance passed.

Independent verification of the downloaded release and provenance artifacts
confirmed all six checksums, both native-engine resource layouts, both
public-production domain-core layouts, both signed feed entries, and all 15
Sigstore bundles under the exact tag workflow identity. All 15 detached
predicates matched their DSSE payloads. The SPDX 2.3 SBOM contains 617 packages
and 4,573 relationships. The OpenVEX 0.2 document contains one `not_affected`
statement. The x64 lifecycle receipt records responsive 20-second launches after
both clean install and reinstall, with zero crash events and no fatal crash log.

Exact distribution hashes:

- x64 portable ZIP: `c19c5f8dfafb6a6ad91b6b010f4f483353fa1fbaddf47ce3b9134b97121a43cd`
- ARM64 portable ZIP: `3ae17ef85cf784cdf43cf7d84b8c6988e8acdbed8440b37e40644ffa06fe012d`
- x64 MSIX: `fd5e8215cd2f6d0f01b971e843742ca9ab1cb049e6e0eef317fa87bde85fe585`
- ARM64 MSIX: `9083b8b08275b72ec1a4ec5a02e20083850a3b8fae35ef58a5e99d8257c013f4`

The machine-readable record and verification boundary are under
[`evidence/windows-v1.0.31-release/`](evidence/windows-v1.0.31-release/README.md).
This closes the exact-head signed automated release gate. It does not convert
hosted lifecycle evidence into physical certification or close manual
accessibility/display, live staging, advanced safety, or public Store/update
gates. Physical ARM64 remains an explicit beta limitation until qualifying
hardware is available.

## Signed Windows Candidate Update - 2026-07-13

Fresh signed workflow [29259964411](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29259964411)
completed successfully from commit `2683c57e77c60f40feecf24e6bb734a8941eaa90`.
Both x64 and ARM64 native Swift engine legs, Tree-sitter parser builds, WinUI
publish, native-engine manifest verification, Azure Authenticode signing,
portable signature checks, MSIX creation/signing, pinned update-feed signing,
SBOM/OpenVEX/Sigstore provenance, and the signed x64 MSIX clean-install,
20-second launch, uninstall, reinstall, and second 20-second launch all passed.
The lifecycle receipt records zero crash events and zero fatal crash-log findings.

Exact artifact hashes:

- x64 portable ZIP: `194f1b058558932dc80bff6b64a2a3a302e9a3c29d5650e7bfc8456b53a75ecd`
- ARM64 portable ZIP: `5d7504cd4310dec8cc2ab4e5fb3d3d146fb6917a9c5a2b0e7214e0206ce9a026`
- x64 MSIX: `ca7f3c7ab8d74be0035714634f8be3c844d8aae752c507d2cd9f91f01a8f4019`
- ARM64 MSIX: `4eea35eb423790f6a093ec4e07ea1bc1d04f688c40daac3430e20e192d83a029`

This supersedes the earlier missing-resource-bundle candidate for automated
packaging/runtime evidence. It does not convert the candidate into physical
Intel/ARM hardware certification or close the manual accessibility/display,
live staging, advanced Computer Use/media safety, or public Store/update gates.

## Implementation Update - 2026-07-13

The current checkout adds a real F2 implementation slice, without promoting
unproven host behavior to certification:

- The configurable local gateway now forwards bounded OpenAI-compatible completion
  requests through an explicit model route, exposes model/metric surfaces,
  enforces bearer authentication when configured, and fails closed when no
  healthy route is available. It also has a bounded Anthropic Messages adapter
  for non-streaming text and tool requests, including system-message conversion,
  API-key/OAuth header selection, required version headers, tool-definition and
  tool-result conversion, tool-choice mapping, normalized `tool_calls` response
  output, and bounded Anthropic SSE-to-OpenAI event conversion. OpenAI image
  blocks now convert to bounded Anthropic base64 or HTTPS image sources;
  truncated SSE, malformed tool data, unsafe image URLs, and unsupported
  multimodal shapes fail closed before transport.
- The desktop gateway composition now preserves a configured bearer token or
  generates and persists a URL-safe 256-bit token through the Windows secret
  store; unauthenticated loopback is available only through the explicit opt
  out. Persisted enable/host/port settings now control the real listener, and
  unauthenticated mode is rejected for every resolved non-loopback bind even
  when the opt-out was saved or supplied by the environment. The token itself
  is never logged or placed in route metadata.
- Provider routes now persist as typed, non-secret Windows settings and resolve
  per-route bearer credentials only from DPAPI-protected storage. The production
  app, HTTP gateway, Elder Wand catalog, fusion loop, and companion runtime share
  that catalog instead of relying on an environment JSON manifest. The Model
  Proxy leaf provides add/edit/delete and enable controls with automatic shared
  runtime restart. Unsafe remote HTTP endpoints, URI credentials/fragments,
  duplicate IDs, missing enabled-route credentials, and plaintext gateway-token
  environment overrides fail closed. The production router now consumes
  persisted non-secret score metadata with the macOS five-factor weights for
  capability, cost, latency, trust, and policy fit. Strict quota-drain ordering
  applies only within matching provider/model/canonical-model/format/endpoint
  pools; active windows reset soonest first, then the largest remaining quota,
  before composite score and deterministic LRU/slot ties. Exhausted,
  missing-secret, disabled, and statically unhealthy routes cannot win. Live
  upstream failures now drive the same temporary health blocks as macOS for
  transient capacity, rate limits, authentication, and quota exhaustion. The
  block key is provider/account/format/model; expiry or a success restores the
  route. The authenticated model and metrics endpoints expose health metadata,
  while provider bodies and credentials never enter the health file. Live
  provider traffic remains a staging/F2 evidence gate.
- Cross-vendor degradation is now off by default and cannot be enabled by an
  untrusted request alone. The operator must explicitly enable the policy, and
  the request must separately opt in. Candidates are restricted to a bounded
  allow-list of OpenAI-compatible vendors and preferred models, pass the shared
  scorecard and live-health filters, and are capped per request. The gateway
  rewrites `model` to the selected fallback before transport, so it does not
  replay an unavailable model name to the substitute provider. Anthropic wire
  routes and non-allow-listed paid providers cannot be selected.
- Gateway route and usage telemetry now persists as bounded metadata-only JSONL
  with a 5,000-record retention cap. Exact, failed, and cross-vendor decisions
  are recorded without prompts, messages, attachments, tools, response bodies,
  endpoints, or credentials. OpenAI/Anthropic JSON and final authoritative SSE
  usage events separate uncached input, output, cache creation, cache read, and
  reasoning tokens. Invalid rows are refused, corrupt rows are skipped, and
  telemetry persistence failures cannot fail a provider request. The
  authenticated metrics endpoint exposes aggregate counters and at most 50
  recent route records.
- Ollama-local routes whose configured base URL does not select the `/v1`
  compatibility API now execute through Ollama's native `/api/chat` transport.
  The adapter maps OpenAI messages, tool arguments, JSON schemas, sampling
  options, and reasoning effort; converts buffered and NDJSON streaming text,
  tool calls, finish reasons, and exact usage back to OpenAI shapes; and rejects
  malformed or truncated streams before reporting success. `/v1` Ollama routes
  remain byte-preserving OpenAI-compatible transports.
- Explicit `cli://codex` and `cli://factory` routes now execute through guarded
  provider adapters that match the macOS contracts. Codex receives its request
  on stdin under a read-only, ephemeral invocation; Factory receives a guarded
  prompt in a random temporary directory with mutating tools disabled and
  strict Standard-tier enforcement. The production runner resolves only
  protected, hash-approved executable identities, uses no shell, bounds each
  output stream, scrubs ambient secrets, kills the process tree on cancellation
  or timeout, and removes temporary inputs after every outcome. CLI failures are
  classified without returning raw provider output or credentials.
- Proactive local discovery now refreshes loopback Ollama `/api/tags`, loopback
  OpenAI-compatible `/v1/models`, and the protected Factory Droid help catalog.
  Successful models become atomic executable routes without shadowing configured
  rows; failed authoritative refreshes remove stale rows. Source concurrency,
  response bytes, model counts, refresh cadence, and timeouts are bounded.
  Remote routes are never probed, authentication failures enter the shared
  cooldown, and authenticated model/companion catalogs expose discovery source,
  display name, freshness, counts, and safe errors without credentials.
- Cloud startup now restores a non-expired OAuth session from the protected
  session store without opening a browser; only a signed-out or expired session
  falls back to the explicit dev-host path. When
  `OPENBURNBAR_APPCHECK_APP_ID` is explicitly configured, the WinUI composition
  also wires the real Windows CNG/TPM attestation producer and bounded HTTP mint
  transport into that OAuth root; without the switch it remains id-token-only.
  Live Firebase/App Check/TPM staging and server-verifier acceptance remain
  external certification gates.
- Headless execution now has two production-composed paths. The local Mission
  Control DAG keeps its bounded safe-step executor. The new durable agent run
  service owns provider work independently of the requesting socket, stores
  prompt/context/approval/tool state in a dedicated bounded current-user-DPAPI
  payload store without registering opaque state in the token redactor,
  writes only metadata to its JSONL journal, resumes non-terminal work after
  restart, and exposes submit/get/poll/cancel/retry/recover through the
  authenticated companion plane. Exact-model failover updates shared health
  and telemetry, while iteration, context, tool, and retry limits fail closed.
- The authenticated companion plane now exposes the macOS-equivalent
  side-effect-free `planner.plan` contract. It preserves explicit-intent,
  workflow, tool, prompt, and generic precedence; requested-tool inference;
  typed constraints/risk/desired outputs; and exact deterministic outlines.
  Unsupported workflows and schema versions fail closed before execution. This
  is intent planning only: provider/tool policy and execution remain separate.
- The companion plane also exposes side-effect-free `policy.evaluate` with the
  macOS tool-risk matrix, approval descriptors, retryability, progress
  detection, and model-requested-approval rules. The durable run path now
  consumes that policy: `approval.respond` resolves protected run state,
  `workspace.executeTool` leases approved work to the owning authenticated
  companion, and `workspace.toolResult` advances or recovers the run. A
  run-level approval can authorize exactly the next risky tool; tool results
  cannot arrive before a claim, and duplicate results are idempotent.
- Browser Computer Use process mode now uses a direct executable plus a
  JSON-line bridge with no shell interpolation, bounded responses, serialized
  commands, cancellation, and process-tree cleanup. The bridge now accepts the
  Windows launch/navigate/evaluate/close envelope as well as the existing
  method-based protocol, so the direct driver reaches the real Playwright
  lifecycle rather than only the in-process fallback. SSRF and DNS-rebinding
  guards remain enforced at the browser route chokepoint. The production app
  now packages that reviewed bridge, discovers an explicit or pinned
  Playwright/Chromium runtime, launches it through the central child-process
  policy, and exposes a persisted, user-initiated settings check with no
  arbitrary script entry. A live local driver-to-Chromium test passes. Hosted
  Windows Full run 29304837991 passed the same x64 lifecycle with one pass and
  zero skips, together with the full x64 and ARM64 suites.
- Project code now has a bounded symbol index with durable metadata-only
  persistence and a file watcher. The index can invoke the existing Rust
  Tree-sitter JSONL parser through a direct process client with Git-blob SHA
  verification, and the Windows release workflow builds and signs one parser
  executable for each RID before packaging it into portable and MSIX outputs.
- The Projects page now provides a Windows folder picker for the active Project
  Code workspace instead of requiring `OPENBURNBAR_PROJECT_ROOT`. The normalized
  non-secret selection persists across launches, rejects volume roots and
  reparse-point roots, visibly preserves unavailable folders for recovery, and
  enables indexing when the user makes an explicit selection. Failed changes
  restore the prior folder and indexing preference. Environment selection remains
  only as a non-persisted compatibility override when no user selection exists.
  Per-root JSON fallback metadata is stored under
  `%LOCALAPPDATA%\OpenBurnBar\ProjectCode\indexes`, not inside the user's repository.
- The app composes one long-lived `ProjectCodeMemoryService` for the selected
  root and shares it between the Projects page and companion operations. A new
  service must load and complete its initial refresh before an atomic live swap;
  disposal waits for any parser or watcher refresh, and recursive inventory reads
  do not cross nested file/directory reparse points. Explicit reference/context
  reads revalidate the root and every path component against stale links. It
  restores and watches the
  metadata-only index, refreshes asynchronously with lexical fallback when the
  configured parser process is wholly unavailable, and exposes
  bounded `code.index`, `code.search`, `code.symbol`, `code.status`,
  `code.semantic_search`, and `code.context_pack` companion operations without
  persisting source text.
  Context packs are explicit, path-confined, UTF-8 bounded, secret-redacted,
  and wrapped as untrusted source before returning to a caller.
- The project-code watcher now writes a durable Pensieve-compatible SQLite
  metadata store by default under `%LOCALAPPDATA%\\OpenBurnBar`. Atomic refresh
  transactions persist project identity, file manifests, artifact hashes,
  symbols, lexical references/call edges, and index checkpoints; restart loads
  the durable checkpoint before falling back to the legacy JSON index. Source
  text is never inserted into the store, and `code.status` exposes bounded
  storage/index counters; the companion plane exposes bounded
  `code.call_graph` traversal and semantic search over versioned deterministic
  96-dimensional vectors. Tree-sitter symbol ranges now drive AST-aware chunks;
  bounded line-aware slicing handles gaps and oversized symbols. Chunk offsets
  and vectors are persisted without source text, and semantic results read
  source only for an explicit context request. The shared service keeps visible
  symbols and companion operations on one encrypted durable checkpoint.
- The WinUI app lifecycle now owns the separate general Pensieve watcher. It
  recursively reconciles configured repo-docs/notes and settled Claude session
  roots on startup, debounced file events, and a periodic backstop. Windows uses
  the same keyed dedup/slug hashes, deterministic 384-dimensional embedder,
  HKDF-derived Householder cloak, secret redaction, CloudVault envelopes, and
  queue schema as Swift/TypeScript. Document text and paths are sealed before an
  atomic queue write; raw sessions create metadata-only extraction sentinels.
  Missing protected vault material fails closed, source/queue bounds prevent
  runaway scans and self-watch loops, and shutdown cancels and awaits all work.
  Detailed evidence is in
  `docs/windows-port/evidence/f2/pensieve-knowledge-watcher.md`.
- App startup always composes the router, companion CLI, and durable run journal,
  while opening the HTTP listener only when the resolved Model Proxy setting is
  enabled. The settings leaf restarts the shared local runtime as one operation so
  endpoint and token changes apply to both planes; listener failure does not
  discard the internal route graph. The CLI exposes health/models plus bounded `run.submit`,
  `run.resume`, and `run.recover` commands; startup surfaces the count of
  interrupted runs without logging payloads. Only explicitly safe built-in
  steps execute by default, while arbitrary shell/provider work fails closed.
- The companion TCP plane now requires the same bearer token as the local
  gateway when composed by the app; missing or incorrect credentials fail closed
  and the token is stripped before command handlers receive the request.
- The Computer Use settings host now composes a real file-backed audit service
  instead of an unavailable placeholder. It validates the canonical manifest,
  parent-linked chain, and terminal head anchor; verifies an optional signed
  head; and atomically exports bounded ZIP evidence with optional screenshots.
  Missing archives, malformed JSON, tampered chains, path traversal, and
  reparse-point paths fail closed. OpenTimestamps notarization remains an
  explicit authenticated-account gate.
- The Media & Sharing settings route now composes a real Mercury capability
  projection. It evaluates the shared entitlement, budget, quota, concurrent
  session, requested-duration, kill-switch, and host-capture signals instead
  of presenting a placeholder. Missing account/host inputs remain visibly
  data-gated; this does not claim live capture, cross-device transport, or
  physical safety certification.
- The Windows Computer Use input adapter now has bounded allowlisted virtual-key
  and modifier mapping, key/shortcut sequencing, drag/drop sequencing,
  horizontal and vertical scroll, and virtual-desktop-origin coordinate
  normalization. Unknown inputs and oversized payloads fail closed before the
  native call. The adapter remains advisory SendInput; signed-driver routing,
  UIA target denial, and physical safety evidence remain external gates.
- The semantic-search provider boundary now includes a bounded OpenAI-compatible
  embeddings transport for the three macOS-supported models. It validates
  model dimensions, batch/input/response bounds, indexed response order, finite
  vectors, status errors, and secret-safe typed failures through an injectable
  HTTP client. The Windows app now selects that provider from persisted embedding
  settings and a protected provider secret, carries its model-derived
  version/dimension identity into the durable project-code store, and falls back
  deterministically when it is not configured. This matches the macOS
  user-selectable index contract: deterministic local embeddings or OpenAI with
  the same three models. macOS BGE explicitly reports unavailable because no
  model is bundled, while its NaturalLanguage implementation is a separate
  memory fallback rather than a selectable index provider. Live OpenAI
  account/quota acceptance remains a staging evidence gate.
- The memory-extraction network seam now has a bounded OpenAI-compatible and
  Ollama HTTP implementation. It preserves the macOS request/response contracts,
  structured content handling, GPT-5.5/OpenRouter hints, status-based cooldowns,
  cancellation, and fail-closed size/endpoint validation without exposing keys.
  Production consent/account selection and provider quota behavior remain
  separate host/staging gates.
- Elder Wand now runs the full bounded panel -> comparison judge -> originating
  model synthesis contract through both the OpenAI-compatible gateway plugin
  and authenticated companion command. Panel members execute in parallel and
  degrade independently; inner calls cannot recursively re-enter fusion;
  DNS-pinned web tools, exact-model route selection, saved-default presets,
  metadata/digest-only journaling, and route/token telemetry are production
  composed. The production page consumes the same router catalog instead of an
  empty provider array. Detailed evidence is in
  `docs/windows-port/evidence/f2/elder-wand-fusion.md` and
  `docs/windows-port/evidence/f2/model-proxy-settings-live-catalog.md`.
- The final connector/tooling deferral is production-composed through the
  authenticated companion plane. Non-secret connector configuration is durable,
  credentials use the current-user DPAPI store, outbound actions are HTTPS-only
  and DNS-pinned, and the tooling facade includes the single-call workspace
  broker plus read-before-patch context selector. Focused connector tests pass
  `115/115`; live credentialed calls remain part of staging certification.
- The Cursor connector session now runs a portable provider/model preflight
  before invoking any broker, proxy, tunnel, or Cursor-settings runtime step.
  Empty provider/model configurations fail closed; API-key presence remains in
  the injected platform secret-store validation step.
- The command palette now searches the bounded local session index through FTS
  ids with deterministic title/project/provider/session fallback matching for
  older databases. Search cancels stale queries, surfaces loading/empty/error
  states, and carries an activated session id through shell navigation so the
  session-log detail pane opens on the selected record instead of only opening
  the generic route.
- The Switcher now launches persisted account profiles through a real embedded
  ConPTY session. Profile type selects a fixed executable, Windows command-line
  quoting preserves each argument, config and environment overrides are bounded
  and allowlisted, the shared child-process policy removes ambient secrets, and
  cancellation terminates the process tree. Invalid profile paths fail visibly
  before process creation; no shell interpolation or arbitrary executable path is
  accepted.
- Direct-process chat now composes a bounded transcript context from persisted
  history before launching the approved CLI executable. The current user turn
  is included exactly once, attachment metadata and bounded previews are
  carried without absolute paths, and prior transcript text is explicitly
  marked as untrusted context. The focused chat runtime suite covers ordering,
  duplicate-current-turn suppression, attachment redaction, and prompt-size
  bounds.
- The project-code parser now preserves explicit blob-integrity state on its
  JSONL wire response and exposes bounded LSP reference lookups through the
  Windows presentation service and `code.references` companion operation. The
  user-facing API accepts one-based project lines, converts to zero-based LSP
  coordinates, confines files to the configured project root, and returns
  relative reference paths. Tree-sitter symbol extraction now covers the
  repository's primary C#, JavaScript, Rust, Swift, Python, TypeScript, and TSX
  files, Java/Kotlin/Go, and the remaining macOS inventory grammars for
  C/C++/Objective-C, JSON, Markdown, and YAML. The dedicated Windows x64/ARM64
  MSVC workflow now smoke-tests each grammar. Hosted run 29299426836 passed its
  x64 tests/smoke and ARM64 build, closing the WPD-0003 parser-host gate. The
  inventory still uses bounded lexical fallback only when a parser is
  unavailable.
- The project-code presentation layer now has a bounded shell-free JSON-RPC
  language-server client. It performs initialize/open/document-symbol or
  references/shutdown lifecycle exchange, correlates framed responses, confines
  returned paths, and emits `exact_lsp` evidence only for the current source
  blob. App startup composes this client from an explicit JSON command map and
  falls back to the bundled Tree-sitter parser when an LSP is unavailable. LSP
  support is additional precision beyond the macOS selectable parser contract;
  a configured language-server inventory remains optional deployment evidence,
  not a blocker for the bundled Tree-sitter F2 parser row.
- The Windows General settings page now persists its time range, usage mode,
  refresh cadence, indexing and auto-summary toggles, embedding provider/model,
  and protected OpenAI key through one normalized settings model. The prior
  hard-coded toggles and picker defaults no longer discard user changes; the
  selected provider is consumed by the project-code store after indexing
  restarts. The app now also consumes the normalized snapshot: usage-runtime
  periodic refresh uses the saved cadence, and companion/Projects code indexing
  honors the saved indexing toggle. Native scan requests suppress conversation
  bodies when indexing is off, preserving the macOS privacy boundary. The
  General page now exposes the exact five macOS windows, migrates legacy values,
  and routes its wizard action to onboarding. Local SQLCipher summaries, the
  bounded cloud fallback, the live dashboard/flyout projection, provider/model
  ranking, sparklines, and the shell BURN capsule all consume the same selected
  range and Dollars/Tokens mode. Bounded windows no longer mix current-period
  cost with all-time tokens/sessions or silently fall back to all-time rows.
- The last primary WPD-0006 SUB-BUILD row now has a production Windows
  substitute. An exact approval authorizes one durable desktop-input tool call;
  the app writes a redacted tamper-evident audit reservation, then dispatches
  through an isolated exact-publisher broker with UIA protected-target policy,
  an at-most-once receipt ledger, authenticated watchdog health, and leaf kill
  checks. Ctrl+Alt+Win+Period, workstation lock, explicit halt, and app exit
  synchronously set the durable kill flag before notifying the independent
  watchdog. The signed release layout carries
  complete self-contained watchdog and broker runtimes for x64 and ARM64 and
  executes exact-publisher checks after signing. This covers the ordinary
  interactive desktop; secure-desktop, lock-screen, and cross-integrity input
  remain explicit non-goals pending a purpose-built signed keyboard/mouse HID
  driver. ViGEm is not used because it emulates game controllers rather than
  desktop keyboard/mouse devices. See
  [`evidence/f2/privileged-input-production-composition.md`](evidence/f2/privileged-input-production-composition.md).
- Native Swift engine staging now requires the SwiftPM
  `OpenBurnBarCore_OpenBurnBarCore.resources` bundle, copies it beside the C ABI
  DLL into every RID's publish output, and records SHA-256/size entries for its
  files in `native-engine-manifest.json`. The Windows app publish target also
  carries that directory into portable and MSIX layouts, failing closed when a
  required native-engine publish omits it. Portable/MSIX packagers and the
  release workflow independently reverify every manifest file's relative path,
  size, and SHA-256, including the resource bundle, before an artifact can be
  signed or zipped.

These changes are covered by focused managed-runtime (293/293 planner, policy,
mission, gateway, durable agent-run, and recovery tests plus 97/97
managed-agent-runtime tests),
CloudSync (80/80), connector
(99/99), presentation (778/778), General settings (166/166), storage (18/18),
Computer Use (148 passed plus one explicit live Chromium platform skip),
settings (186/186), configuration (58/58), distribution (101/101), bridge-policy,
and provider-boundary tests. They are an implementation increment, not a claim
that the F2 workstreams or release certification are all complete: the
physical Computer Use/media safety and host evidence still remain. The ledger's 50/50 `Real`
result is the scoped F1 source/product gate; WPD-0009 continues to define F2
True 1:1 as the actual 100% parity endpoint.

The exact implementation commit also passed [PR Windows Fast Gate
29299426816](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426816)
at commit `6c5abc8bd81cb9a87003f4a029d87acac293a88e`: x64 restore,
transitive NuGet vulnerability audit, full solution/WinUI XAML build, 37 test
projects (3,315 passed, 14 skipped, 3,329 total), the parity ledger, test-result
upload, and the aggregate Windows gate all passed. The same commit passed [PR
Windows Full Suite
29299426779](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426779)
with the same 37 projects and results on both x64 and native-hosted ARM64, and
the [Project Code parser MSVC gate
29299426836](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426836)
passed its x64 tests/smoke plus ARM64 build. [OpenBurnBarCore Engine run
29299426807](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29299426807)
also passed production C-ABI staging, managed-to-Swift integration, quota
contracts, walking skeletons, parser parity, and safety vectors on both hosted
x64 and ARM64. This closes the hosted x64/ARM64 compile/test boundary for the
implementation slice. It does not prove installed UI interaction, physical
hardware, manual accessibility/display, live staging, advanced safety, or public
release lifecycle behavior.

## Implementation Update - 2026-07-10

The foundation remediation branch implements the audit's highest-value daily-use
and distribution gaps without changing the release-certification boundary:

- A composed Windows usage runtime now discovers supported local logs, parses
  usage records, persists encrypted snapshots, and supplies flyout, dashboard,
  Atelier, command-palette, and onboarding scan surfaces from app startup.
- Settings and Updates routes now use typed controls and durable Windows
  persistence, with explicit unavailable reasons and Windows-native startup and
  update status. Onboarding performs real dependency, storage, notification,
  UI Automation, and chat-executable probes instead of placeholder readiness.
- Single-instance warm/cold activation routes URI, file, toast, startup, and
  command actions through one typed router. The WinSparkle host, bundled feed
  metadata, package images, and startup-task integration are composed into the
  app rather than remaining declaration-only assets.
- Chat executable management remains reachable after approval, durable chat and
  retrieval state use the encrypted store, Explorer restart re-registers the
  tray icon, and diagnostics can create bounded redacted support bundles.
- The foundation host harness verifies an exact exported Git candidate before
  running focused tests, process-containment checks, secret scans, route smokes,
  and interactive WinUI UI Automation in the signed-in user session.

This update is not a 1:1 parity or release claim. Signed publishing, hosted x64
evidence, physical x64/ARM64 hardware certification, production account/cloud
lifecycle, and the deeper daemon, Computer Use, and Mercury workflows retain
their independent release gates.

## Certification Harness Update - 2026-07-10

The UI automation harness now has an explicit `--certification-profile
accessibility` mode. It keeps the default smoke path fast, while adding a
machine-readable certification scenario manifest for baseline screenshots,
high-contrast rendering, reduced-transparency rendering, measured 100% DPI
captures, and the keyboard/input safety contract. High-contrast and
reduced-transparency scenarios seed the real persisted Windows appearance state
before `ThemeService` initializes, so route captures exercise production theme
composition rather than a test-only style shim.

Candidate `d8fc5675568f` has now passed exact import verification on the Windows
11 ARM64 UTM host (`10,255 / 10,255` files, zero mismatches), an ARM64 WinUI
build, `25 / 25` route/scenario captures, semantic UI Automation, and all nine
input-route contract rows. Its three DPI captures independently measured 100%
through `XamlRoot.RasterizationScale`. The compact receipt is
`docs/windows-port/evidence/accessibility-certification/host-run-d8fc567556.json`;
the external 200-file bundle is content-addressed by SHA-256
`ea53024c64534edc3fe6a731c2a9b501b0a5c04d80d74f755b15654fbe728275`.

This closes part of the certification infrastructure gap: CI and host evidence
can no longer treat generic route smoke as equivalent to accessibility/DPI
coverage. It does not replace the remaining physical-device Narrator protocol,
150%/200% DPI sweeps, high-contrast OS theme validation, or manual keyboard
certification required before a parity release claim.

## Original Executive Summary (Superseded)

The following was the audit-time finding on 2026-07-09. It is retained as the
remediation baseline and is superseded by the certification update above.

Windows is a substantial code port, but it is not at macOS product parity or
ready for a parity release. The shell, tray foundation, WinUI navigation,
visual primitives, portable parser/crypto/update cores, and x64/ARM64 unit CI
are meaningful strengths. The core daily-use path is still incomplete: fresh
installs do not create and populate a live local data plane; the tray and
dashboard are sample-or-empty; settings are largely diagnostic text;
updates/activation are declared but not shipped; and several advanced
capabilities are uncomposed or explicitly deferred.

This audit reviewed current source, current release assets, the 47-row Windows
ledger, selected Windows unit suites, and the Windows full-suite CI result.
The initial audit snapshot found the local Windows VM locked and its guest-exec
channel unavailable. The later exact-candidate receipt above supersedes that
statement for the bounded ARM64 UIA/accessibility scenarios only. Installed
release behavior, visual performance, notifications, activation, Narrator,
150%/200% DPI, OS-level high contrast, and physical x64/ARM64 hardware remain
uncertified.

The public v1.0.29 release has macOS artifacts but no Windows installer or
MSIX package. A passing scoped ledger and portable C# tests must not be
treated as end-to-end product parity evidence.

## Original Audit Evidence and Limitations (Superseded)

- The selected Windows Settings, Shell, and Dashboard suites passed: 233 tests.
- scripts/ci/verify-windows-parity-ledger.sh passed for its 46 scoped rows; its
  result validates declared blocking paths, not a clean-install product flow.
- The current PR Windows Full Suite run passed x64 and ARM64 .NET build/test
  jobs: https://github.com/Imagine-That-Ai/BurnBar/actions/runs/29027436509.
- The current checkout was windows/liquid-glass-kernel-reskin, ahead 23 and
  behind 28 commits of its upstream at audit time. Treat branch CI, release
  assets, and local source as separate facts.
- The macOS reference excludes disabled raw iCloud session mirroring. It does
  include real local aggregation, menu-bar operation, settings/onboarding,
  daemon lifecycle, update/recovery, chat, notifications, Computer Use, and
  Mercury/media behavior where supported by its distribution channel.

## Original Detailed Parity Matrix (Remediation Baseline)

| Area | What differs and why it matters | Recommended fix and implementation notes | Priority | Test steps |
|---|---|---|---|---|
| Live ingestion, tray, and dashboard | macOS discovers, parses, persists, and renders live usage. Windows configures quota acquisition, but the main flyout is sample-or-empty and Scan is explicitly a no-op. Dashboard command data is also sample-or-empty. See windows/app/OpenBurnBar.App/FlyoutWindow.xaml.cs:89-92,342-346 and Dashboard/DashboardPage.xaml.cs:101-109. The primary product value is unavailable in a normal fresh install. | Build WindowsUsageRuntime: Windows log discovery, watchers, parsers, encrypted persistence, snapshot publication, scan cancellation/progress/error/retry, and freshness metadata. Compose it into flyout, dashboard, insights, and session logs at app launch. | Critical | On a clean Windows VM with no environment variables or copied database, create Claude/Codex/Cursor activity. Verify automatic flyout/dashboard refresh and a Scan that changes persisted data. |
| Fresh-install storage, session logs, and recovery | Windows requires a pre-existing SQLCipher DB and passphrase; failure can fall back to empty data. See windows/app/OpenBurnBar.App/Storage/WindowsStorageDevHost.cs:13-34. macOS has durable aggregation and recovery UI. | Provision/migrate the database automatically, generate a protected key, repair the database picker owner window, and expose loading, no-data, invalid-key, locked-DB, migration, retry, archive/reset, and reveal-log states. | Critical | Exercise fresh install, corrupt DB, wrong key, locked file, and migration interruption. Each must expose an actionable path and recover after retry. |
| Secrets, identity, and cloud | SQLCipher passphrase, Firebase token, App Check token, and vault key persist in plaintext %LOCALAPPDATA%/OpenBurnBar/app_config.json; cloud startup is dev-token wiring rather than composed sign-in. See windows/app/OpenBurnBar.App.Configuration/AppConfiguration.cs:37-48,66-95 and AppConfigurationModel.cs:8-27. This is a credential-at-rest issue and a false production sign-in experience. | Add ISecretStore backed by DPAPI/Credential Manager, migrate and securely remove legacy values, then compose OAuth PKCE, refresh, TPM/App Check, offline queue, and sign-out cleanup. | Critical security / High feature | Assert that config, logs, diagnostics, child process environments, crash reports, and support bundles contain no secrets. Test staging sign-in, expiry, invalid App Check, offline recovery, and sign-out. |
| Chat correctness and command safety | Windows now resolves approved executables directly and composes bounded persisted transcript context, including attachment metadata, before each turn. Prior transcript text is marked untrusted and absolute attachment paths are removed; streamed output, cancellation, and backend-unavailable behavior remain separate runtime gates. macOS supports persistent streamed chat, retrieval, attachments, and durable error handling. | Keep `ProcessStartInfo.ArgumentList`, stdin or structured temporary input, cancellation, output limits, persisted conversation state, and backend-unavailable UI aligned with the Windows runtime. Extend the same boundary to retrieval and multimodal providers as they become available. | Critical | Metacharacter/quote payload, cancellation, streamed-error, restart/history, duplicate-current-turn, attachment/paste/drop, and retrieval-degradation tests. |
| Daemon, gateway, missions, and memory depth | macOS has an installed/repairable daemon lifecycle. Windows now production-composes the authenticated in-process gateway, standalone authenticated companion CLI staged for signed RID packaging, provider routing, Mission DAG, intent planner/policy, durable headless agent loop, exact-approval isolated input broker, protected recovery state, project index, general sealed Pensieve watcher, parallel Elder Wand fusion, indexed search, guarded Switcher shells, connector/tooling plane, and metadata-only journals. No applicable WPD-0006 primary row remains SUB-BUILD. | Prove Windows-host restart/sleep lifecycle UX for every promoted execution path and run the signed privileged-input physical protocol. | Critical | An approved execution run survives companion disconnect and app restart, rehydrates safely, records redacted audit state, and exposes meaningful health and error UX. |
| Settings and preferences | macOS has interactive, searchable settings with persistence. Many Windows tabs route to a generic reflection/text-dump host with in-memory/no-op defaults; Updates is static. See windows/app/OpenBurnBar.App/Settings/SettingsViewModelHostPage.xaml.cs:47-123 and UpdatesSettingsPage.xaml:28-44. | Replace generic host pages with concrete bound controls and production stores. Persist state securely; disable unavailable functions with a reason; wire every visible toggle and command. | High | Change each preference, restart, validate persistence and live effect. Test failed saves, unavailable services, and OS-disabled states. |
| Onboarding and permissions | macOS probes and refreshes real permissions. Windows system permissions are informational and chat gateway health is a placeholder. See windows/app/OpenBurnBar.App/Onboarding/Steps/SystemPermissionsStepPage.xaml.cs:6-22 and ChatEngineStepPage.xaml.cs:142-146. | Add Windows-native probes for notification registration, storage/log access, runtime dependencies, UI Automation, screen capture, and optional input components. Use Windows terminology, not copied TCC labels. | High | In a clean VM, deny, grant, revoke, restart, and recover each capability. Onboarding must never falsely report readiness. |
| Notifications, background behavior, and tray resilience | Windows has a tray foundation and a toast adapter, but live tray data, session/digest delivery, activation routing, preference persistence, Explorer restart recovery, and richer context actions are not proven or composed. See windows/app/OpenBurnBar.App/Budget/BudgetToastNotifier.cs:24-71. | Compose a notification router with the runtime. Add dedupe/rate limits, deep links, OS-disabled status, background cadence, TaskbarCreated re-registration, and Dashboard/Settings/Update tray actions. | High | Test app open/hidden/closed, sleep/wake, reboot, Explorer restart, disabled notifications, toast click/cold activation, and multi-monitor DPI. |
| Packaging, updater, URI/file/startup activation | MSIX declares protocol, file associations, startup, and toast activation, but app launch only handles route smoke then creates the tray. The updater core is unreferenced and required MSIX images are absent. See windows/packaging/msix/Package.appxmanifest:102-167 and windows/app/OpenBurnBar.App/App.xaml.cs:44-76. | Wire activation/update services, generate package assets, sign MSIX and portable artifacts, implement startup and single-instance handoff, and publish Windows release metadata/SBOM/attestations. | Critical | Clean x64 and ARM64 install; URI/file activation warm and cold; startup toggle; valid update, tampered-feed rejection, rollback, uninstall, and reinstall. |
| Computer Use, Mercury, and file transfer | macOS has approvals, audit, kill paths, media permissions, calls, mirroring, and guarded file transfer/quarantine. Windows production-composes exact approvals, redacted resumable audit, isolated `SendInput`, UIA protected-target policy, an independent watchdog, global panic/workstation-lock paths, media settings, and the existing capture/transfer cores. Physical behavior is not yet certified. | Run the signed x64 protected-target/input/panic/restart protocol, then complete capture consent, immutable outbound snapshots, Defender/MOTW-aware inbound quarantine, and cross-device media evidence. | High | On physical x64, test protected-target denial, panic halt, capture consent, Windows-to-Mac transfer/call/share, and malicious-file handling. Physical ARM64 remains an explicit beta limitation until hardware is available. |
| Navigation and command palette | Windows now searches the bounded local session index through FTS ids with deterministic metadata fallback, cancellation, loading/empty/error states, and direct session deep links. Project and memory-specific result types remain future depth beyond the current section + session contract. | Add project/memory result providers when those stores expose stable read/search contracts; keep the current session path fail-closed and keyboard accessible. | Medium | Keyboard-only tests for populated, empty, slow, cancelled, and failing queries; verify each selected session opens its detail record. |
| Visual polish and responsiveness | Windows has Mica/Acrylic, WebView2/Win2D fallbacks, and semantic styling, but data-backed layouts and performance are unverified; no runtime screenshot/performance release gate exists. See windows/app/OpenBurnBar.App/Dashboard/DashboardPage.xaml.cs:38-82. | Establish shared semantic design tokens and loading/empty/error/offline/partial state components. Tune density, resizing, motion, and GPU fallbacks against macOS intent rather than copying macOS chrome. | High | Screenshot and pixel-diff baselines at 100/150/200% DPI, narrow/wide windows, light/dark/high-contrast, reduced motion/transparency, and disabled WebView2/Win2D. Capture frame/input/memory budgets. |
| Accessibility and keyboard | macOS has extensive annotations and Cmd shortcuts. Windows currently has limited automation metadata and mostly Ctrl+K; no UIA/Narrator interaction suite proves real accessibility. | Define accessible names/values/help, focus order, live-region announcements, Ctrl/Alt shortcuts, visible focus, high-contrast/reduced-motion behavior, and Windows UI Automation tests. | High | Narrator/manual keyboard protocol plus automated UIA tests for tray, onboarding, dashboard, settings, dialogs, palette, errors, and panic behavior. |
| Diagnostics and failure UX | macOS has recovery, redaction, archive/reset, reveal/copy diagnostics. Windows diagnostics are mostly local logs while storage failures can look like empty data. See windows/app/OpenBurnBar.App/Diagnostics/AppDiagnostics.cs:85-110. | Add redaction, bounded retention, correlation IDs, consented support bundle, data-source/native capability/updater status, and retry/repair/archive/reset controls. | High | Induce bad storage, expired auth, graphics/runtime absence, updater failure, and parser crash. Validate redaction and a usable support bundle. |
| Parity reporting and release evidence | The 47-row ledger and green .NET CI prove scoped paths, not a whole-product clean-install experience. The checkout, main CI, and public release are separate states. | Make real-device functional certification a required release artifact: fresh-install proof, screenshots, UIA, package tests, performance, security checks, and explicit residual scope. | High | Do not use a 1:1 parity label until every visible capability is functional or intentionally unavailable with a named, user-visible explanation. |

## Windows-Native Adaptation Requirements

Parity must preserve outcomes rather than imitate macOS APIs or chrome:

- Retain a notification-area tray instead of copying an NSStatusItem literally.
- Use adaptive WinUI NavigationView behavior, Windows Ctrl/Alt conventions,
  Windows privacy/UAC/UIA concepts, and Windows file/Defender handling.
- Use Windows app notifications with reliable activation routing.
- Preserve semantic spacing, density, motion, contrast, and status-state quality
  while respecting high contrast, reduced motion, and reduced transparency.

References: [Windows notification area guidance](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area), [WinUI NavigationView guidance](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/navigationview), [Windows notifications](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/), and [accessibility best practices](https://learn.microsoft.com/en-us/windows/win32/winauto/accessibility-best-practices).

## Windows Parity Implementation Plan

| Sequence | Engineering work | Complexity and dependency | Acceptance criteria |
|---|---|---|---|
| 0 | Freeze misleading live labels; hide or explain incomplete capability; write the Windows runtime ADR. | M; first | Every visible control has a working action or a truthful unavailable state. |
| 1 | Security foundation: DPAPI/Credential Manager secret store, migration, secret redaction, and direct-process chat execution. | M; before cloud/chat release | No plaintext secrets or shell-injection path; security regression tests block release. |
| 2 | Native data plane: WindowsUsageRuntime, automatic DB provisioning/migration, agent-log discovery/watchers, snapshot store, recovery UI. | XL; depends on 1 | Fresh install shows real usage, sessions, quotas, and errors without developer configuration. |
| 3 | Replace generic settings/onboarding hosts with real bindings and a shared async-state component. | L; depends on 1-2 | Preferences persist and affect services; every route has loading/empty/error/retry coverage. |
| 4 | Background runtime/service: lifecycle, IPC, journal/recovery, notifications, health/status, tray integration. | XL; depends on 2 | Work survives app closure/restart when intended and fails closed when not. |
| 5 | Production cloud: OAuth PKCE, TPM/App Check, CloudVault, offline queue, account/device state. | L; depends on 1 and 4 | Real staging account lifecycle and cross-device sync pass without raw token entry. |
| 6 | Distribution: updater composition, MSIX/portable packaging, signing, activation, startup, release workflow. | L; depends on 1 and stable shell | Signed x64/ARM64 artifacts update/rollback and handle URI/file/toast activation. |
| 7 | True macOS-depth features: gateway/router, local missions, memory/project depth, Computer Use, Mercury/media/file transfer. | XL; depends on 4-5 | Each feature has end-to-end Windows host proof, not only portable-core tests. |
| 8 | Certification polish: visual baselines, performance harness, UIA/Narrator, stress/lifecycle, and physical-device test matrix. | L; spans 2-7 | Release gates produce evidence for all supported Windows configurations. |

### Shared Architecture Work

Use contract-first refactors: IUsageRuntime, ISecretStore, IActivationRouter,
INotificationRouter, and IRuntimeLifecycle. Keep UI implementations native to
each platform, while sharing domain contracts, parser vectors, state semantics,
and release acceptance fixtures between Swift and C#.

## Prioritized Remediation Roadmap

1. **P0 - release blockers:** plaintext secrets, shell-composed chat,
   fresh-install data plane, inert update/package/activation path.
2. **P1 - daily-use completeness:** real settings, onboarding probes,
   notifications, tray resilience, command-palette search, diagnostics/recovery.
3. **P2 - true feature parity:** persistent runtime/daemon, gateway/router,
   local missions, memory/project depth, Computer Use, Mercury/media.
4. **P3 - certification:** visual/performance/accessibility automation,
   hardware validation, signed distribution, and independent release evidence.

## QA Verification Checklist

- [ ] Clean Windows 11 x64 and ARM64 installation works without copied DBs,
  secrets, or developer variables.
- [ ] Agent activity updates tray, dashboard, insights, session logs, quota,
  and command palette in real time.
- [ ] Every loading, empty, error, offline, and partial state is explicit,
  recoverable, and keyboard accessible.
- [ ] Restart, sleep/wake, GUI close, Explorer restart, startup, update,
  rollback, URI, file, and toast activation work.
- [ ] Config, logs, support bundles, screenshots, and child-process
  environments contain no secrets.
- [ ] OAuth/App Check/CloudVault flows pass staging sign-in, expiry, offline
  queue, sign-out, and cross-device tests.
- [ ] UIA, Narrator, keyboard-only, high-contrast, reduced-motion, DPI, and
  screenshot tests run in CI.
- [ ] Performance is measured on real x64 and ARM64 hardware with GPU/WebView2
  fallback coverage.
- [ ] Computer Use, media, and file-transfer safety tests cover deny paths,
  permissions, panic kill, quarantine, and audit integrity.
- [ ] Release evidence contains signed artifacts, hashes, SBOM/attestations,
  install/update results, and physical-device certification.

## Conclusion

The audit's F1 implementation plan is complete under the repository's scoped
ledger. The applicable WPD-0006 F2 source substitutions are also complete: no
primary row remains SUB-BUILD. That source result covers the gateway, durable
runs/missions, Browser Computer Use, the exact-approval privileged-input broker,
project symbols, the sealed Pensieve watcher, the full Elder Wand fusion
pipeline, standalone companion CLI, guarded Switcher, indexed search, and the
connector/tooling plane. It does not close signed-host or physical evidence.
The x64/ARM64 build, signing/provenance, hosted x64 registration, ARM64 UTM
foundation, and corrected signed-runtime gates are proven. The corrected x64
and ARM64 packages each passed clean-install and reinstall 20-second responsive
launch holds with zero crash events. The evidence does not yet close every row
in the QA checklist.

Accordingly, the accurate current claim is: **F1 source/product parity is
ledger-green; applicable F2 source composition is complete; the exact-head
signed automated release is verified; F2 True 1:1 is not release-certified
because physical/manual/live/public-lifecycle evidence is incomplete**.
A public parity release remains gated on the explicitly named
physical Windows, manual accessibility/display, live staging/cross-device,
advanced safety, and public lifecycle evidence above.

## Independent physical-release certification addendum - 2026-07-11

The independent release-certification lane is recorded under
[`evidence/physical-release-certification-2026-07-11/CERTIFICATION_REPORT.md`](evidence/physical-release-certification-2026-07-11/CERTIFICATION_REPORT.md).
Its post-fix macOS-reachable matrix is green, but the overall verdict remains
**NO-GO**: physical x64/ARM64 performance, manual accessibility/display,
live staging OAuth/App Check/CloudVault, advanced media/Computer Use safety,
and Store/update lifecycle evidence are each explicitly blocked by named
external prerequisites. The UTM ARM64 guest is retained for preparation only
and is not counted as physical ARM64 certification.

## External-certification campaign update - 2026-07-12

The follow-on campaign is recorded under
[`evidence/external-certification-2026-07-12/README.md`](evidence/external-certification-2026-07-12/README.md).
It binds the exact signed candidate `7c362298230e14bfd51dcdcbaf9476cd86cefa66`
to workflow run `29177583506` and retains a validator-clean ARM64 UTM bundle.
Because the branch was subsequently repaired and rebased (post-#1557), that
bundle is historical supporting context for its recorded commit only; any
release decision for a later head requires regenerating the campaign against
that head's own signed candidate.
The candidate began from a clean tree and passed restore, serialized Release
build, and the full Windows solution test run. The service-session UIA probe
failed to launch WinUI routes and is retained as negative supporting evidence,
not accessibility certification.

The campaign also provisions the isolated `burnbar-staging` Firebase project,
GitHub OIDC federation, and least-privilege deploy identity without enabling
deployment or touching production. Company billing-project quota prevents the
live staging deploy. A connected physical iPhone passed its focused media and
Computer Use peer suite (`114/114`), but no physical Windows peer was available.

The physical-release verdict therefore remains **NO-GO**. Physical Windows x64
and ARM64 performance, signed-in manual accessibility/display, deployed staging
OAuth/App Check/CloudVault with physical TPM, live cross-device media/Computer
Use safety, and Partner Center Store/update lifecycle evidence remain external
requirements. VM, unit, source, and mobile-peer evidence do not satisfy them.
