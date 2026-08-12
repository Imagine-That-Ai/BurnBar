# OpenBurnBar Safari certification fixtures

This directory is the controlled local page set for the real-Safari matrix in
[`docs/qa/SAFARI_EXTENSION_QA.md`](../../docs/qa/SAFARI_EXTENSION_QA.md).
It does not replace that matrix and it does not turn Chromium automation into
Safari evidence.

The fixture server is deliberately:

- dependency-free at runtime (Node built-ins only);
- bound to loopback and protected by loopback `Host` validation;
- split across two local ports so the frame fixture has a genuine
  cross-origin child without touching the network;
- read-only at the HTTP boundary;
- explicit about CSP, permission, and form-action policy;
- free of real accounts, credentials, payments, or production side effects;
- deterministic and bound to a machine-readable SHA-256 asset manifest.

## Verify before use

From the repository root:

```bash
node tools/safari-certification-fixtures/verify.mjs
node --test tools/safari-certification-fixtures/*.test.mjs
```

When fixture bytes intentionally change, review the diff first and then refresh
the mechanical hash map:

```bash
node tools/safari-certification-fixtures/verify.mjs --write
node tools/safari-certification-fixtures/verify.mjs
node --test tools/safari-certification-fixtures/*.test.mjs
```

`assetRootSha256` is the SHA-256 of the sorted lines
`<asset-sha256><two spaces><relative-path><newline>`. Preserve it beside the
installed host/appex hashes, source commit/tree, tester, and recording time.

## Run

```bash
node tools/safari-certification-fixtures/server.mjs
```

The server prints one JSON line containing the primary and secondary origins.
Defaults are:

- primary: `http://127.0.0.1:41771`
- secondary frame origin: `http://127.0.0.1:41772`

Use task-owned ports when those are occupied:

```bash
node tools/safari-certification-fixtures/server.mjs \
  --port 42771 \
  --cross-origin-port 42772
```

Never bind this tool to `0.0.0.0` or a LAN address. The server refuses that
configuration.

## Fixture map

| QA class | Route | Stable proof surface |
|---|---|---|
| Semantic article, image, chart | `/mixed` | Exact prose, table values, illustration relationship, chart maximum, prompt-injection sentence |
| React-controlled input/select | `/react-controls` | Actual local React 18.3.1 runtime, controlled values, visible `input` / `change` log and `isTrusted` disclosure |
| Open shadow root | `/shadow` | `open-shadow-marker-velvet`, inspectable root, counter |
| Closed shadow root + supported bridge | `/shadow` | Closed root plus `window.openBurnBarFixture.readClosedShadowState()` and request/response events |
| Strict CSP | `/strict-csp` | Header-only self policy, no inline script, typed interaction status |
| Infinite scroll | `/infinite-scroll` | 20-item batches through 100 stable IDs |
| Zoom + viewport offsets | `/zoom-offset` | 125% body zoom, x/y scroll, fresh target box |
| Same/cross-origin frames | `/frames` | Primary child plus secondary-loopback child and exact `frame-src`/`frame-ancestors` CSP |
| Banking/payment/credential denial | `/protected/banking` | Sensitive semantics, no real values, client-cleared form, server rejects every POST |
| Run-owned tab navigation | `/owned-tabs/start` | Start → child → finish markers for audited open/list/navigate/close |

The closed-shadow page-world expression for an explicitly approved
`run_javascript` action is:

```js
return window.openBurnBarFixture.readClosedShadowState();
```

The result contains only fixture marker, label, and counter. It exposes no
general DOM access and no mutation capability.

## Real-Safari evidence order

1. Bind the recording to the exact source commit/tree, fixture
   `assetRootSha256`, built host and nested appex hashes, installed host and
   appex hashes, extension/daemon versions, tester, and time.
2. Start the server and record its printed origins without placing fixture
   URLs or page content inside the privacy-safe performance JSON.
3. In the installed extension, request Safari site access deliberately. Record
   the denied state first, then the recovery path.
4. Run Ask on `/mixed`. Ask one DOM question, one visual relationship question,
   one chart question, and one mixed question. Record screenshot disclosure and
   whether the selected route is local or cloud.
5. Run the Agentic matrix across the remaining pages. Preserve approvals,
   allow/block/session decisions, audit output, page-state verification,
   owned-tab inventory, Stop, native global panic, and protected-route denial.
6. Perform keyboard-only and VoiceOver passes, including the popup performance
   drawer and learning controls.
7. Export privacy-safe performance batches, hash them, recalculate summary
   statistics, and separately record fixture/provider identity outside those
   JSON bytes.
8. Only after native Safari proof exists, run the same controlled task in the
   Chromium harness or Browser Use and compare transcripts. Label every
   difference as comparison evidence, never Safari proof.

## Evidence boundaries and known browser facts

- Synthetic DOM events normally report `isTrusted: false`. This fixture makes
  that visible; it does not disguise it. A page that requires trusted input
  needs the separately gated macOS fallback and real-Safari validation.
- Stop prevents future work, stops bridge waiting, and rejects stale
  completion. It cannot force-kill or undo arbitrary JavaScript/page effects
  that already executed.
- The fixture route uses `localhost` semantics that OpenBurnBar's production
  deny policy is expected to protect. Ask can be exercised after site access;
  Agentic protected-route behavior must fail closed unless the certification
  plan explicitly uses the controlled override path being audited.
- The server's green tests prove deterministic local content and transport
  policy. They do not prove Safari, a provider contact, an installed CLI,
  Accessibility fallback, signing, notarization, App Store processing, public
  installation, update, or rollback.

## Vendored React

`fixtures/vendor/` contains the upstream React 18.3.1 and ReactDOM 18.3.1
production UMD files under the MIT license. They are local only and pinned by
the asset manifest. React's production diagnostic text contains upstream
documentation URLs but performs no network request; fixture HTML, application
scripts, and styles contain no remote resource/action URL or network primitive.
