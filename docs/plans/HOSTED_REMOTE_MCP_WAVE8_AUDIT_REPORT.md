# Hosted Remote MCP Wave 8 Audit Report

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end
implementation.

## Executive Verdict

**Hold.** The hosted MCP implementation, generated-URL deploy, controlled
paid/unpaid/revoked/cross-tenant proof, core monitoring, cross-platform
connected-client revoke surfaces, `burnbar.ai` ownership verification, and
large-corpus search/body performance proof are in place. Launch readiness is
still blocked by Google-managed certificate issuance for `mcp.burnbar.ai`, real
subscriber proof, and real client compatibility proof.

## Evidence Baseline

- Branch: `chore/router-brand-coherent-rail`
- Latest hosted-MCP deploy revision:
  `openburnbar-hosted-mcp-00012-dhf`
- Live generated Cloud Run URL:
  `https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app`
- Verified service traffic: `openburnbar-hosted-mcp-00012-dhf`, `100%`
- Current branded endpoint status: `burnbar.ai` ownership is verified in Google,
  Namecheap DNS has `mcp CNAME ghs.googlehosted.com.`, public resolvers return
  that CNAME from Cloudflare, Google, and Quad9, and the Cloud Run domain
  mapping exists with `DomainRoutable=True`. HTTPS proof is blocked only by
  Cloud Run managed certificate status `CertificatePending`; the
  `2026-05-15T07:25:09Z` retry kept the certificate pending and set the next
  polling interval to one hour.
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
  auth enforcement, and temp-profile real CLI config proof now passes for
  Codex, Claude Code, Droid/Factory, Kimi, and Forge. Final client proof is
  still missing login/list/search/body against the branded endpoint.
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

- P0: Branded endpoint DNS is configured, but HTTPS is not live until Google
  finishes managed certificate issuance; the final audience/endpoint pairing
  still has not been proven with production clients.
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
- P2: A production-safe Firestore/Storage privacy scanner now exists and passes
  with zero violations, but current production Remote MCP/search collections are
  empty after controlled proof cleanup; rerun it against a real subscriber
  fixture before launch.

Evidence:

- `docs/HOSTED_REMOTE_MCP.md`
- `docs/REMOTE_MCP_THREAT_MODEL.md`
- `tools/openburnbar-mcp-remote/src/decrypt.ts`
- `services/hosted-mcp/src/search.ts`
- `services/hosted-mcp/src/resources.ts`
- `functions/scripts/prove-hosted-mcp-privacy-scan.mjs`

### SRE Reviewer

Signed: Codex primary integrator, acting SRE reviewer.

Verdict: **Hold.**

Findings:

- P0: `mcp.burnbar.ai` domain mapping is created and DNS resolves, but the
  managed certificate remains pending.
- P1: Cloud Run service is deployed and healthy on the generated URL. The latest
  read-budget/performance/body-bucket revision is `openburnbar-hosted-mcp-00012-dhf`
  at 100% traffic.
- P1: Alert coverage now includes hosted-MCP 5xx, 429, auth-denial, p95 latency,
  instance pressure, and project-level Firestore read spikes.
- P1: Rollback command is documented and was rehearsed by moving traffic from
  `openburnbar-hosted-mcp-00005-ndq` to `00004-xf4`, checking `/readyz`, and
  restoring `00005-ndq` to 100% traffic.
- P2: Cost/capacity dashboard separation now exists for Cloud Run, Firestore,
  Storage, KMS, and Redis.

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
- Monitoring dashboard:
  - `OpenBurnBar Hosted MCP Cost and Capacity`
    (`projects/246956661961/dashboards/4df51728-d486-44a0-a11f-bc3dc0eeea2b`)

### QA Lead

Signed: Codex primary integrator, acting QA lead.

Verdict: **Continue hardening.**

Findings:

- P1: Targeted hosted-MCP service tests, lint, security smoke, and live proof
  passed during implementation.
- P1: Full app gate is not green because of unrelated existing failures; the
  hosted-MCP iOS Cloud Store source compiled in a targeted mobile build, Android
  `assembleDebug` passed, and macOS `OpenBurnBar` fresh-DerivedData build passed.
- P1: Real client matrix remains incomplete. The compatibility script now
  verifies deterministic installer output and installed-client temp-profile
  configuration, and the local stdio shim now has live tools/list/search/body
  proof against the generated endpoint. Authenticated target-client UI flows
  remain pending.
- P2: Controlled live search read-budget proof reports 4 Firestore document
  reads, zero Storage reads, and `withinSearchReadBudget: true`; Cloud Build
  large-corpus body-enabled proof against the live generated endpoint passed
  with 1000 docs, 100 matching candidates, search p50 267 ms / p95 471 ms,
  body p50 304 ms / p95 534 ms, search reads 50 Firestore + 0 Storage, and
  body reads 1 Firestore + 1 Storage.

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
- P1: macOS and Android connected-client list/revoke paths now exist and are
  build-verified at source level; real signed-in UI flow proof is still pending.
- P2: Non-subscriber upgrade path is documented conceptually, but end-to-end
  UI proof across platforms is incomplete.

Evidence:

- `OpenBurnBarMobile/Views/Store/CloudStoreView.swift`
- `OpenBurnBarMobile/Services/FunctionsRepository.swift`
- `AgentLens/Views/Settings/CloudStoreSettingsView.swift`
- `android/app/src/main/java/com/openburnbar/ui/store/CloudStoreView.kt`
- `android/app/src/main/java/com/openburnbar/data/stores/RemoteMcpClientStore.kt`
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
| P0 | Branded hosted endpoint is blocked by Google-managed certificate issuance. | `burnbar.ai` is verified, `mcp.burnbar.ai` DNS resolves to `ghs.googlehosted.com.` from Cloudflare, Google, and Quad9, and Cloud Run mapping is domain-routable; wait for `CertificateProvisioned=True`, then prove `/readyz` and `/mcp`. |
| P0 | Final production launch proof is not on a branded endpoint. | Rerun live paid/unpaid/revoked/cross-tenant proof against the branded endpoint. |
| P1 | Real subscriber proof is missing. | Use real paid and unpaid proof users instead of temporary entitlement documents; bounded production fixture check sampled one user and found no active entitlement, search artifact, or Remote MCP client. |
| P1 | Real client compatibility matrix is incomplete. | Temp-profile config proof passes for installed CLIs and live stdio shim proof passes; prove authenticated target-client flows against the branded endpoint. |
| P1 | Branded-endpoint rollback proof is still pending. | Generated-URL Cloud Run rollback rehearsal passed; repeat after branded domain mapping if launch requires hostname-level proof. |
| P1 | Real subscriber body-fetch proof is missing. | Large-corpus proof-object body fetch passes; repeat against a real subscriber fixture after branded HTTPS is live. |
| P1 | Real signed-in connected-client UI proof is pending. | iOS/iPadOS, macOS, and Android list/revoke surfaces are implemented and build-verified where gates allow; prove an authenticated client appears and revokes on each platform. |
| P2 | Body-fetch read-budget proof is controlled, not subscriber-backed. | Proof Storage object shows 1 Firestore read + 1 Storage read; add a real subscriber fixture before launch. |
| P2 | Firestore plaintext leakage scan is not subscriber-backed. | Production-safe scan passed with zero violations, but the current Remote MCP/search collections were empty after proof cleanup; rerun with a real subscriber fixture. |

## Final Recommendation

**Hold.** Continue hardening. The next unblocker is Google-managed certificate
issuance for `mcp.burnbar.ai`; the next non-blocked engineering work is real
client compatibility proof in isolated profiles plus real-subscriber proof.
