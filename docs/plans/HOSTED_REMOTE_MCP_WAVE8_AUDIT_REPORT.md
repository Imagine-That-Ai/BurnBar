# Hosted Remote MCP Wave 8 Audit Report

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end
implementation.

## Executive Verdict

**Hold.** The hosted MCP implementation, generated-URL deploy, controlled
paid/unpaid/revoked/cross-tenant proof, and core monitoring are in place, but
launch readiness is blocked by branded-domain verification, real subscriber
proof, real client compatibility proof, rollback rehearsal, and MCP-specific
read-budget evidence.

## Evidence Baseline

- Branch: `chore/router-brand-coherent-rail`
- Latest committed hosted-MCP deploy revision:
  `openburnbar-hosted-mcp-00004-xf4`
- Live generated Cloud Run URL:
  `https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app`
- Verified service traffic: `openburnbar-hosted-mcp-00004-xf4`, `100%`
- Current branded endpoint status: blocked because neither `openburnbar.com`
  nor `burnbar.ai` is verified in the active Google account.
- Current synced state before this audit report: branch was synced to upstream;
  unrelated local worktree changes remain outside the hosted-MCP commits.

## Audit Stream Reports

### Principal Engineer

Signed: Codex primary integrator, acting principal-engineer reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: The standards-first service shape exists, but the public production
  resource URL is still generated Cloud Run, not a branded endpoint.
- P1: Source and tests show deny-by-default tool metadata and resource-route
  auth enforcement, but real client compatibility is still config-output level
  rather than login/list/search/body proof across all target clients.
- P2: The local shim and hosted service are separated cleanly, but launch proof
  still depends on temporary Firestore proof users, not a real subscriber.

Evidence:

- `services/hosted-mcp/src/mcp.ts`
- `services/hosted-mcp/src/toolRegistry.ts`
- `tools/openburnbar-mcp-remote/src/installers.ts`
- `functions/scripts/prove-hosted-mcp-live.mjs`
- `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`

### Security Reviewer

Signed: Codex primary integrator, acting security reviewer.

Verdict: **Hold.**

Findings:

- P0: Branded endpoint is not live, so the final audience/endpoint pairing has
  not been proven with production clients.
- P1: Controlled live proof covers paid, unpaid, revoked, missing-scope, and
  cross-tenant denials, but it uses temporary proof accounts.
- P1: Resource list/read routes were previously a bypass risk; they now enforce
  scope, active client, entitlement, and rate limits.
- P2: Log scan covered the proof window and found no obvious tokens, raw query,
  body, signed URL markers, or proof content, but it is not a full production
  corpus leakage audit.

Evidence:

- `services/hosted-mcp/src/auth.ts`
- `services/hosted-mcp/src/entitlements.ts`
- `services/hosted-mcp/src/mcp.ts`
- `services/hosted-mcp/src/auth.test.ts`
- `scripts/test-hosted-mcp-security.sh`
- Cloud Run log scan recorded in
  `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`

### Privacy Reviewer

Signed: Codex primary integrator, acting privacy reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: Default privacy documentation and code preserve sealed-only/local-decrypt
  architecture.
- P1: No evidence shows hosted server-side plaintext decrypt shipped.
- P2: Firestore plaintext leakage inspection is currently weak after temporary
  proof cleanup; a production collection scan or targeted real-user audit is
  still needed before launch.

Evidence:

- `docs/HOSTED_REMOTE_MCP.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `tools/openburnbar-mcp-remote/src/decrypt.ts`
- `services/hosted-mcp/src/search.ts`
- `services/hosted-mcp/src/resources.ts`

### SRE Reviewer

Signed: Codex primary integrator, acting SRE reviewer.

Verdict: **Hold.**

Findings:

- P0: Domain mapping is blocked until `burnbar.ai` or `openburnbar.com` is
  verified in Google.
- P1: Cloud Run service is deployed and healthy on the generated URL.
- P1: Alert coverage now includes hosted-MCP 5xx, 429, auth-denial, p95 latency,
  instance pressure, and project-level Firestore read spikes.
- P1: Rollback command is documented but has not been rehearsed with a real
  traffic shift and restore.
- P2: Cost dashboard separation for Cloud Run, Firestore, Storage, KMS, and
  Redis is not proven.

Evidence:

- `docs/REMOTE_MCP_RUNBOOK.md`
- `scripts/deploy-hosted-mcp.sh`
- Cloud Run service status recorded in
  `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`
- Monitoring policies:
  - `OpenBurnBar Hosted MCP 5xx spike`
  - `OpenBurnBar Hosted MCP 429 spike`
  - `OpenBurnBar Hosted MCP auth denial spike`
  - `OpenBurnBar Hosted MCP p95 latency spike`
  - `OpenBurnBar Hosted MCP instance pressure`
  - `OpenBurnBar Firestore read spike`

### QA Lead

Signed: Codex primary integrator, acting QA lead.

Verdict: **Continue hardening.**

Findings:

- P1: Targeted hosted-MCP service tests, lint, security smoke, and live proof
  passed during implementation.
- P1: Full app gate is not green because of unrelated existing failures; the
  hosted-MCP iOS Cloud Store source compiled in a targeted mobile build.
- P1: Real client matrix remains incomplete. The current compatibility script
  verifies deterministic installer output, not actual client login/list/search
  and body fetch.
- P2: Missing-data and stale-index behavior have source/test coverage, but
  large-corpus warm p50/p95 performance proof is still missing.

Evidence:

- `scripts/test-hosted-mcp-compatibility.sh`
- `scripts/test-hosted-mcp-security.sh`
- `functions/scripts/prove-hosted-mcp-live.mjs`
- `services/hosted-mcp/src/auth.test.ts`
- Verification command list in
  `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`

### Product Designer

Signed: Codex primary integrator, acting product-design reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: iOS/iPadOS Cloud Store connected-client list and revoke path exists.
- P1: macOS and Android parity for connected-client list/revoke is not proven.
- P2: Non-subscriber upgrade path is documented conceptually, but end-to-end
  UI proof across platforms is incomplete.

Evidence:

- `OpenBurnBarMobile/Views/Store/CloudStoreView.swift`
- `OpenBurnBarMobile/Services/FunctionsRepository.swift`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`

### Protocol Reviewer

Signed: Codex primary integrator, acting protocol reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: MCP methods, JSON-RPC error handling, authorization challenges, protocol
  version handling, and metadata endpoints exist in source.
- P1: Generated-URL protocol proof exists; branded endpoint proof is blocked by
  domain verification.
- P1: Target clients are represented in installer output, but real client
  protocol proof is missing for Codex, Claude Code, Droid/Factory, Kimi, Forge,
  and a generic inspector/client.

Evidence:

- `services/hosted-mcp/src/server.ts`
- `services/hosted-mcp/src/mcp.ts`
- `services/hosted-mcp/src/oauthMetadata.ts`
- `tools/openburnbar-mcp-remote/src/installers.ts`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`

### Staff Maintainer

Signed: Codex primary integrator, acting staff-maintainer reviewer.

Verdict: **Continue hardening.**

Findings:

- P1: Core docs exist and were updated for Secret Manager, domain mapping,
  monitoring, and live proof state.
- P2: The completion audit is accurate and says hold, but it should remain the
  canonical launch checklist until all blocked items are cleared.
- P2: The worktree contains many unrelated modified/untracked files; hosted-MCP
  changes must continue to be committed in narrow, named commits.

Evidence:

- `docs/HOSTED_REMOTE_MCP.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `docs/REMOTE_MCP_RUNBOOK.md`
- `docs/REMOTE_MCP_CLIENT_SETUP.md`
- `docs/plans/HOSTED_REMOTE_MCP_COMPLETION_AUDIT.md`

## Prioritized Findings

| Severity | Finding | Required Resolution |
| --- | --- | --- |
| P0 | Branded hosted endpoint is blocked by unverified domain ownership. | Verify `burnbar.ai` or `openburnbar.com` in Google, create Cloud Run domain mapping, add DNS records, prove `/readyz` and `/mcp`. |
| P0 | Final production launch proof is not on a branded endpoint. | Rerun live paid/unpaid/revoked/cross-tenant proof against the branded endpoint. |
| P1 | Real subscriber proof is missing. | Use real paid and unpaid proof users instead of temporary entitlement documents. |
| P1 | Real client compatibility matrix is incomplete. | Configure Codex, Claude Code, Droid/Factory, Kimi, Forge, and generic MCP in isolated profiles and prove login/tools/list/search/body. |
| P1 | Rollback is documented but unrehearsed. | Perform controlled Cloud Run traffic rollback and restoration, then record revision names and timestamps. |
| P1 | MCP-specific Firestore read-budget proof is missing. | Capture read counts or service audit counters for representative search/body fetches and compare to launch budgets. |
| P1 | macOS and Android connected-client list/revoke parity is not proven. | Implement or explicitly scope out platform parity with owner/date before launch. |
| P2 | Cost dashboard separation is missing. | Add or verify a dashboard separating Cloud Run, Firestore, Storage, KMS, and Redis. |
| P2 | Firestore plaintext leakage scan is weak. | Run a production-safe scan over relevant remote MCP/search collections and document exact redaction checks. |

## Final Recommendation

**Hold.** Continue hardening. The next unblocker is domain verification for
`burnbar.ai` or `openburnbar.com`; the next non-blocked engineering work is real
client compatibility proof in isolated profiles plus MCP-specific read-budget
instrumentation.
