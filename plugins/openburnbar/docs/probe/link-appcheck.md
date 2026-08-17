# Probe: CLI link route and `/link` App Check diagnosis

Captured 2026-08-16 against production. No device code was minted by these
probes: the real start route was only proven reachable with a malformed body
(HTTP 400 before any grant state), and no `mcp login` loop was run.

## 1. Real CLI start route exists (reachable without minting a code)

```
POST https://burnbar.ai/api/cli-link/start
Content-Type: application/json
Body: "not-json-garbage"   (malformed on purpose — never a valid start request)
→ HTTP/2 400  (text/html "Bad Request"; content-security-policy: default-src 'none')
```

The route is live: 400 on a malformed POST proves the endpoint is not a 404,
and no pending grant / user code was created because the request body could
not be parsed. A real start call is only performed as part of a single
human-confirmed live mint after PR 1 is on production (see below).

## 2. Wrong-host trap

`https://mcp.burnbar.ai/api/cli-link/start` returns 404 for both POST and GET
(details in [`unauth-mcp.md`](./unauth-mcp.md#8-wrong-host-cli-start-trap)).
Device-code start is `https://burnbar.ai/api/cli-link/start` only. The
unpublished CLI derives start from the MCP host unless the operator sets
`OPENBURNBAR_MCP_ENDPOINT=https://burnbar.ai/mcp` and
`OPENBURNBAR_MCP_ALLOW_CUSTOM_ENDPOINT=true` (see `AUTH.md`).

## 3. Diagnosis: production `/link` confirm fails as platform `Unauthenticated`

**Symptom.** A signed-in confirm on `https://burnbar.ai/link` returned Firebase
platform `Unauthenticated` (not a bad-code error), so no grant could be minted
from production before this fix.

**Root cause.** The confirm handler on production called the `completeCliLink`
callable with only the code:

```ts
await completeCliLink({ userCode: codeInput.value.trim() });
```

That call carried no App Check binding and no high-risk nonce. Production
`completeCliLink` runs with `enforceAppCheck: true` and enforces a
high-risk-action nonce, so Firebase rejected the request as platform
`Unauthenticated` **before the handler ever ran**. The device code itself was
not the problem; the callable was being invoked without the required
attestation chain.

**Fix (website-only; App Check was NOT weakened).** PR 1
(`https://github.com/Imagine-That-Ai/BurnBar/pull/2286`) adds
`website/src/lib/attestedCallable.ts` and rewires `website/src/pages/link.astro`
to follow the Mac client order:

1. `bindAppCheckAttestation`
2. `getIdToken(true)` (force refresh)
3. `issueHighRiskActionNonce` → `nonce`
4. `completeCliLink({ userCode, nonce })` (hyphenated `XXXX-XXXX` display value)

with one rebound path (rebind → refresh ID token → remint nonce) when the
nonce mint is rejected at the App Check binding gate. No `functions/**` file
is touched, and `enforceAppCheck` is not set to false anywhere.

## 4. Deploy blocker: PR 1 is not on production yet

As of 2026-08-16 PR 1 is **OPEN and unmerged**
(`state: OPEN`, `mergedAt: null`; `origin/main` still at `fbdb83157`, the
pre-fix parent):

- PR URL: https://github.com/Imagine-That-Ai/BurnBar/pull/2286
- Title: `fix(website): attest completeCliLink with App Check bind + nonce`
- Files (website-only): `website/src/lib/attestedCallable.ts` (added),
  `website/src/pages/link.astro` (modified),
  `website/scripts/test-link-attestation.mjs` (added)
- Label: `factory-review`

Because the attested `/link` is not on production `burnbar.ai`, no fresh live
grant could be minted, so there is **no authenticated metadata call transcript
in this probe set**. This is the named deploy blocker per the validation
contract; the live metadata call is captured (token redacted) once PR 1 deploys
and a human confirms a fresh device code. The operator must **not** loop
`openburnbar mcp login` in the meantime.
