# ADR: OpenBurnBar Safari extension as a first-party, safety-gated control surface

- **Date:** 2026-08-10
- **Status:** Accepted
- **Owners:** OpenBurnBar macOS, daemon, Computer Use, and release maintainers
- **Related:** [Architecture ADR 016](../architecture/016-safari-extension-trust-boundary.md), [Safari extension guide](../SAFARI_EXTENSION.md), [threat model](../THREAT_MODEL.md)

## Context

OpenBurnBar already has a native macOS app, a local daemon, a Cursor/VS Code
extension, and a CLI. Browser work was limited to launching a browser or using
isolated automation engines. That does not answer questions about the page in
the user's real logged-in Safari session, and it cannot safely carry out
user-approved actions in that session.

A Safari Web Extension can run content scripts in the user's real tab after
Safari grants site access. It can combine DOM/accessibility structure with a
viewport capture, then relay requests through a native extension handler. Apple
documents Safari Web Extensions as WebExtensions embedded in a containing app,
and documents native messaging through the Safari extension handler rather than
direct content-script-to-native communication:

- [Safari Web Extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions)
- [Messaging between the app and JavaScript](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)
- [Optimizing a web extension for Safari](https://developer.apple.com/documentation/safariservices/optimizing-your-web-extension-for-safari)
- [Assessing browser compatibility](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility)

The new surface inherits two unusually sensitive inputs:

1. Page content, accessibility text, images, and screenshots are untrusted model
   input and may contain prompt injection.
2. Page actions operate in a real authenticated browser session, so a mistaken
   click or navigation can have durable consequences.

The extension therefore cannot become an independent provider client or a
parallel automation authority. It must reuse the daemon, provider routing,
Computer Use capability gate, scope/deny rules, approvals, audit chain, and
panic halt.

## Decision

### 1. Add a fifth surface, not a second product spine

The Safari extension is a first-party OpenBurnBar surface:

```text
Safari tab
  -> isolated-world content script
  -> MV3 background service worker
  -> Safari native messaging
  -> OpenBurnBarSafariExtension.appex
  -> authenticated daemon RPC / loopback gateway
  -> provider routing + Computer Use rails
```

The extension does not own provider keys, quota state, durable run state, memory
authority, or independent policy. Those remain daemon/app responsibilities.

### 2. Use DOM-first actions and vision-plus-structure understanding

- Page understanding pairs readable DOM/accessibility output and viewport
  geometry with a viewport screenshot.
- Screenshots are resized to at most 1568 pixels on the long edge and encoded
  as compressed JPEG before model submission.
- Page actions prefer content-script DOM operations in Safari's isolated world.
- The action executor scrolls the target into view, waits for layout, re-reads
  its bounds, performs the action, and verifies the resulting page state before
  continuing.
- Page-world bridging is narrow, explicit, and approval-gated. It is not a
  general bypass around Safari isolation or site content-security policy.
- AppleScript/Accessibility event injection remains a separately gated,
  direct-download-only fallback; it is not required for normal extension
  operation and is unavailable in the Mac App Store build.

### 3. Make the user's tab and site grant the primary scope

- Safari's per-site extension permission is the outer browser grant.
- The only persistent host permissions are the exact IPv4, hostname, and IPv6
  loopback gateway forms; broad HTTP/HTTPS page access remains optional.
- OpenBurnBar's scope matcher and deny registry are an independent inner gate.
- The default scope is the tab explicitly handed to OpenBurnBar.
- The agent may access only that tab and tabs it opened for the active run.
- Banking, payment, credential, account-security, admin, and other built-in deny
  destinations fail closed unless a supported, explicit override exists.
- Every state-changing action receives a preview/approval decision according to
  trust mode and is audit chained as `safari.*`.
- Stop in the popup and the global panic halt terminate the same underlying run.
- Stop is a forward cancellation boundary, not execution rollback. It aborts
  bridge waiting, invalidates the current work generation, rejects late
  completions, prevents queued or new actions, and revokes daemon authority.
  JavaScript already executing in a page or isolated world cannot be forcibly
  killed or undone; page effects completed before Stop remain.

### 4. Treat page material and learned material as untrusted

DOM text, accessibility text, screenshots, extracted data, prior page
memories, and proposed skills are data, never instructions that can alter
system policy. Prompt construction preserves provenance and wraps this material
as untrusted context.

Learning is opt-in and tier-gated. The extension never stores credentials, raw
page dumps, or material from denied domains as durable memory. Proposed
memories/skills remain reviewable, auditable, forgettable, and rollback-capable.

### 5. Use a distinct, attenuated native identity

The containing app embeds:

```text
OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex
```

The extension identity is:

- bundle ID `com.openburnbar.app.safari-extension`
- extension point `com.apple.Safari.web-extension`
- App Sandbox enabled
- outbound network client enabled
- App Group `group.com.openburnbar.app`
- shared host Keychain access group `TEAMID.com.openburnbar.app`

The daemon's signed-peer admission remains fail closed. If the appex does not
meet the designated requirement, the allowed solutions are to admit this exact
first-party identity or relay through the signed host app. Weakening the daemon
peer gate or admitting arbitrary same-user processes is not acceptable.

### 6. Sign and verify the appex independently

Direct-download and Mac App Store artifacts treat the appex as a separate
signed product:

- The direct build uses a dedicated `MAC_APP_DIRECT` profile for
  `com.openburnbar.app.safari-extension`.
- The host's direct and MAS entitlement variants carry the exact same App Group
  and Keychain group as the appex. Direct host and extension profiles must each
  authorize both capabilities; MAS automatic signing must preserve them in
  both signed products.
- Nested code inside the appex is signed deepest-first.
- The appex is signed and verified before the containing app is signed.
- The verifier checks the exact bundle ID, Safari extension point, executable,
  MV3 manifest and referenced resources, Team ID, hardened runtime, and signed
  sandbox/network/App Group/Keychain entitlements. Independently, it verifies
  the profile's authorized application identifier, App Group, Keychain group,
  distribution type, expiry, and certificate membership.
- Public DMG trust and mounted-DMG smoke re-run the nested verifier.
- Mac App Store archive and exported-package inspection both verify the appex.
- MAS builds set only the host-specific
  `OPENBURNBAR_HOST_CODE_SIGN_ENTITLEMENTS`; they never apply the host
  entitlement file globally and overwrite extension entitlements.
- Release remains on migration HOLD until the Apple App IDs/profiles and
  protected direct-profile secrets have been regenerated and an exact signed
  DMG plus MAS archive/export prove the shared capabilities. Source files,
  mocked signatures, and unsigned builds are not that proof.

### 7. Keep CI ownership precise

- `OpenBurnBarSafariExtension/**` selects the macOS lane.
- `extensions/safari/**` and
  `scripts/test-openburnbar-safari-extension.sh` select macOS and web lanes.
- A single wrapper runs locked install plus the package's canonical `test:ci`.
- Safari production TypeScript participates in the existing changed-line
  coverage gate at the same 80% floor and fails closed on stale/missing
  Istanbul evidence.
- Native fast detection includes the web payload because the built resource
  becomes part of the Xcode appex.

## Alternatives considered

### Safari WebDriver or Safari MCP as the primary runtime

Rejected. WebDriver automation is valuable for isolated tests, but it does not
operate in the user's existing logged-in session. The Safari MCP server is
useful for web-development automation, not a replacement for a permissioned
extension in the user's real tab. See WebKit's
[Safari MCP server announcement](https://webkit.org/blog/18136/introducing-the-safari-mcp-server-for-web-developers/).

### AppleScript as the primary runtime

Rejected. It requires a Safari developer preference and Automation permission,
is not Mac App Store compatible for the full fallback ladder, and provides a
weaker site-grant/user-expectation boundary than a Safari extension.

### Direct provider calls from the extension

Rejected. It would duplicate provider credentials, routing, quotas, failover,
usage accounting, privacy disclosure, and revocation across another runtime.

### A broad daemon admission rule for same-user callers

Rejected. Filesystem ownership and a shared login session do not establish that
a caller is first-party code. Admission remains identity-bound and fail closed.

## Consequences

### Positive

- The feature works in the user's real Safari session without Screen Recording
  permission for viewport capture.
- Provider routing, billing, approvals, deny rules, audit, and panic controls
  stay coherent across OpenBurnBar surfaces.
- Both direct and Mac App Store channels can ship the core content-script path.
- CI and release verification bind the nested artifact to the exact candidate.

### Costs and tradeoffs

- Safari site grants remain a user-visible prerequisite.
- Content scripts cannot defeat every closed-shadow-root or hostile-CSP case;
  unsupported cases must surface as typed, recoverable limitations.
- Synthetic DOM events are not trusted browser input, so some sites may require
  a separately approved fallback or may remain unsupported.
- Stop cannot retroactively reverse JavaScript or page effects that already ran.
  Recovery and audit surfaces must distinguish cancellation of future work from
  rollback, which the extension cannot promise.
- Same-user compromise remains a residual risk for App Group files. Chunk
  envelopes therefore require ownership, bounds, integrity hashes, expiry, and
  cleanup rather than being trusted by path alone.
- Real-Safari acceptance and physical user-session behavior cannot be certified
  by Chromium mocks or unit tests. Manual candidate-bound QA remains required.

## Verification

Automated proof:

```bash
./scripts/test-openburnbar-safari-extension.sh
node --test scripts/ci/classify-ci-impact.test.mjs
bash scripts/diff-coverage-ts-self-test.sh
bash scripts/ci/verify-openburnbar-safari-extension.test.sh
```

Release proof:

- direct signed app verifier
- notarized/stapled public DMG verifier
- mounted-DMG app/daemon smoke
- Mac App Store archive verifier
- expanded exported-package verifier

Manual proof is defined in [Safari Extension QA](../qa/SAFARI_EXTENSION_QA.md).
No release claim should merge automated, real-Safari, public-artifact, and App
Store proof into one status.
