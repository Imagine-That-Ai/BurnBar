# Hosted Remote MCP Wave 8 Signed Stream Reports

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end
implementation.

Baseline:

- Branch: `chore/router-brand-coherent-rail`
- Latest deployed hosted-MCP revision: `openburnbar-hosted-mcp-00012-dhf`
- Generated Cloud Run URL:
  `https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app`
- Branded fallback domain: `mcp.burnbar.ai`
- Branded domain state: `burnbar.ai` is verified, public DNS resolves
  `mcp.burnbar.ai` to `ghs.googlehosted.com.`, and Cloud Run reports
  `Ready=True`, `CertificateProvisioned=True`, and `DomainRoutable=True`.

Overall recommendation: **hold**.

## Principal Engineer

Signed: Codex primary integrator, acting principal-engineer reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: The hosted MCP service is architecturally separated in
  `services/hosted-mcp`, and the local decrypt bridge remains in
  `tools/openburnbar-mcp-remote`.
- P1: The tool registry is deny-by-default and source-level auth/resource
  ownership checks are centralized instead of ad hoc per tool.
- P1: The branded fallback endpoint is live on
  `https://mcp.burnbar.ai/mcp`.
- P2: Real paid subscriber proof now exists on the branded fallback endpoint.

Evidence:

- `services/hosted-mcp/src/server.ts`
- `services/hosted-mcp/src/mcp.ts`
- `services/hosted-mcp/src/toolRegistry.ts`
- `services/hosted-mcp/src/resources.ts`
- `tools/openburnbar-mcp-remote/src/shim.ts`
- `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`

## Security Reviewer

Signed: Codex primary integrator, acting security reviewer.

Verdict: **Hold.**

Findings:

- P1: Final branded fallback endpoint/audience proof is live for the real paid
  subscriber path.
- P1: Missing-auth, unpaid, revoked, missing-scope, and cross-tenant negative
  paths have controlled live proof on the generated Cloud Run URL.
- P1: Real paid subscriber fixture proof passed on the branded fallback URL with
  active `burnbar_pro`, tools/list, capabilities, search, encrypted body fetch,
  and post-revoke denial.
- P1: Refresh tokens are stored hashed at rest, and MCP access tokens are
  short-lived HMAC tokens rather than Firebase ID tokens.
- P2: Current log scans found no obvious token/body/query leakage, but
  subscriber-backed log proof remains pending.

Evidence:

- `functions/src/remoteMcpOAuth.ts`
- `functions/src/remoteMcpGrant.ts`
- `services/hosted-mcp/src/auth.ts`
- `services/hosted-mcp/src/entitlements.ts`
- `services/hosted-mcp/src/audit.ts`
- `scripts/test-hosted-mcp-security.sh`
- `functions/scripts/prove-hosted-mcp-live.mjs`

## Privacy Reviewer

Signed: Codex primary integrator, acting privacy reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: Default readable content path remains local decrypt; the hosted service
  returns sealed metadata and encrypted body pages by default.
- P1: The hosted service has no visible server-side plaintext decrypt path.
- P2: `functions/scripts/prove-hosted-mcp-privacy-scan.mjs` now performs a
  production-safe scan for forbidden fields and sensitive value patterns across
  Remote MCP/search Firestore collection groups and the encrypted body bucket.
- P2: The scanner passed with zero violations, but current production
  Remote MCP/search collections are empty after controlled proof cleanup, so
  subscriber-backed privacy proof is still pending.

Evidence:

- `docs/HOSTED_REMOTE_MCP.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `docs/PRIVACY.md`
- `services/hosted-mcp/src/search.ts`
- `services/hosted-mcp/src/resources.ts`
- `tools/openburnbar-mcp-remote/src/decrypt.ts`
- `functions/scripts/prove-hosted-mcp-privacy-scan.mjs`

## SRE Reviewer

Signed: Codex primary integrator, acting SRE reviewer.

Verdict: **Hold.**

Findings:

- P1: `mcp.burnbar.ai` is routable, certificate provisioning is complete, and
  branded `/readyz` returns HTTP 200.
- P1: Cloud Run is healthy on the generated URL and serving revision
  `openburnbar-hosted-mcp-00012-dhf` at 100% traffic.
- P1: Alert policies exist for hosted MCP 5xx, 429, auth denials, p95 latency,
  instance pressure, plus project-level Firestore read spikes.
- P1: Rollback was rehearsed on generated Cloud Run traffic; branded-host
  rollback proof remains optional unless launch requires hostname-level proof.

Evidence:

- `scripts/deploy-hosted-mcp.sh`
- `docs/REMOTE_MCP_RUNBOOK.md`
- Cloud Run domain mapping and service status recorded in
  `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`
- Dashboard: `OpenBurnBar Hosted MCP Cost and Capacity`

## QA Lead

Signed: Codex primary integrator, acting QA lead.

Verdict: **Continue hardening.**

Findings:

- P1: Targeted hosted-MCP tests, compatibility config proof, generated-URL live
  proof, real paid subscriber fixture proof, and large-corpus performance proof
  have passed.
- P1: Full app gates are not green because of unrelated existing failures, so
  launch claims must stay scoped to hosted-MCP-specific evidence.
- P1: Real target-client authenticated flows remain pending for Codex,
  Claude Code, Droid/Factory, Kimi, Forge, and generic MCP.
- P2: Real paid fixture proof used temporary search/body artifacts under the
  real subscriber UID and verified cleanup of the proof client, index rows, and
  Storage object.

Evidence:

- `services/hosted-mcp/src/auth.test.ts`
- `services/hosted-mcp/src/search.test.ts`
- `scripts/test-hosted-mcp-security.sh`
- `scripts/test-hosted-mcp-compatibility.sh`
- `functions/scripts/prove-hosted-mcp-performance.mjs`
- `functions/scripts/prove-hosted-mcp-shim-live.mjs`

## Product Designer

Signed: Codex primary integrator, acting product-design reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: iOS/iPadOS, macOS, and Android connected-client list/revoke surfaces exist
  in source and have targeted build evidence where the app gates allow.
- P1: Setup/status/revoke concepts are documented for clients.
- P1: Real signed-in UI proof that a generated client appears and can be revoked
  on every platform is still pending.
- P2: Non-subscriber upgrade copy exists conceptually, but live end-to-end
  upgrade-path proof remains pending.

Evidence:

- `OpenBurnBarMobile/Views/Store/CloudStoreView.swift`
- `AgentLens/Views/Settings/CloudStoreSettingsView.swift`
- `android/app/src/main/java/com/openburnbar/ui/store/CloudStoreView.kt`
- `android/app/src/main/java/com/openburnbar/data/stores/RemoteMcpClientStore.kt`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`

## Protocol Reviewer

Signed: Codex primary integrator, acting protocol reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: MCP initialize, tools/list, tools/call, resources/list, resources/read,
  protocol version handling, protected-resource metadata, JSON-RPC errors, and
  auth challenges exist in source.
- P1: Branded endpoint protocol reachability and security smoke passed.
- P1: Installer output covers Codex, Claude Code, Droid/Factory, Kimi, Forge,
  and generic MCP clients, but real authenticated client execution remains
  pending.

Evidence:

- `services/hosted-mcp/src/server.ts`
- `services/hosted-mcp/src/mcp.ts`
- `services/hosted-mcp/src/oauthMetadata.ts`
- `tools/openburnbar-mcp-remote/src/installers.ts`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`

## Staff Maintainer

Signed: Codex primary integrator, acting staff-maintainer reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: Required docs exist for product/architecture, threat model, runbook, and
  client setup.
- P1: Completion audit is explicit about the hold state and the remaining
  blockers.
- P2: The worktree contains unrelated dirty files; hosted-MCP changes should be
  reviewed and committed narrowly so unrelated user work is preserved.

Evidence:

- `docs/HOSTED_REMOTE_MCP.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `docs/REMOTE_MCP_RUNBOOK.md`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`
- `docs/HOSTED_QUOTA_SYNC.md`
- `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`
