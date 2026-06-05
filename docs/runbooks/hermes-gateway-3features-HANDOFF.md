# HANDOFF — finish the Hermes Gateway 3 features (device-capable agent)

> **Superseded on 2026-06-03 and refreshed on 2026-06-04:** this was the
> pre-merge handoff checklist. For current launch status, audit evidence, and E2EE
> remediation proof, use
> `docs/runbooks/hermes-gateway-3features.md` §7-§8 and
> `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md`. Do not treat the command counts
> or branch names below as current proof.

You are picking up finished, tested server + adapter work. Your job is the part
that needs **real hardware, deploy credentials, and a push** — none of which the
prior agent had. Do NOT re-do the server/adapter work; it is done and green.

Full background: `docs/runbooks/hermes-gateway-3features.md` (read §6a + §7).

2026-06-04 update: the hardware approval gate this handoff called out is now
closed. The focused live iPad approval test armed approve/reject/expiry cases,
resolved approve/reject from trusted iPad device
`6566F689-F2FA-4A57-8A0F-4B38D47A76C0`, proved public expiry and late-response
fail-closed behavior, and read back allowlisted approval docs with no plaintext
command detail. Sentry issue/event readback is now closed against the transferred
`openburnbar-functions` project in `imagine-that-ai-qh`.

**Alberto has authorized you to: re-audit (correctness + security), run the real
on-device E2E, and PUBLISH the Hermes PR once the gates below are green.** Order of
operations: Preflight → Job 1 (iOS build) → Job 2 (deploy) → Job 4 (device E2E) →
Job 5 (re-audit: correctness + security) → Job 3 (publish the PR). Do not publish
until Jobs 4 and 5 are both green.

## The three features (so you can test them)
1. **Runtime state** — phone shows gateway online/offline (truthful), current model, agent version, connected clients.
2. **Model switching** — pick a model on the phone; the agent uses it for the next reply; off-catalog ids are rejected.
3. **Human-in-the-loop oversight** — supervised (default) makes risky agent actions wait for phone approval on a trusted device; autonomous runs unattended. The gate is control-plane only; the command detail arrives end-to-end encrypted.

## Current state (verified green by the prior agent — re-confirm before you start)
Run this preflight from the repo root (`/Users/albertonunez/Documents/Windsurf/BurnBar`). The worktree is edited by multiple agents, so re-verify:
```bash
cd functions
npm run build && node scripts/test-hermes-gateway.mjs && npx vitest run src/__tests__/hermesGateway.test.ts && npm run lint
npm run test:firestore-rules                      # 45/45 expected
cd ..
node scripts/privacy/scan-chat-cloud-plaintext.mjs
diff -q tools/hermes-platform-burnbar/adapter.py ~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py   # must be identical
( cd ~/.hermes/hermes-agent && bash scripts/run_tests.sh tests/gateway/test_burnbar_plugin.py tests/gateway/test_relay_e2ee.py )  # 62 expected
```
If any of these are red, STOP and report — that means concurrent churn broke something; do not build on a red base.

Branches at handoff: BurnBar repo `release/cut-builds-20260603`; Hermes repo `ajnunezg/burnbar-platform` (the original mission named `ajnunezg/burnbar-platform-ready` — confirm with Alberto which branch the PR targets).

---

## JOB 1 — iOS: compile in Xcode + run on a trusted physical iOS device
The iOS oversight wiring is written but never compiled (no toolchain on the prior agent's box). Files touched:
`OpenBurnBarMobile/Services/FunctionsRepository.swift`,
`OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift`,
`OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`,
`OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift`.

1. This is an **XcodeGen** project — if you change file membership, edit `project.yml` and run `xcodegen`; never hand-edit the `.pbxproj`.
2. Build the iOS app target in Xcode (or `xcodebuild -scheme OpenBurnBarMobile`). Fix any compile errors. **The one spot the prior agent flagged**: the `gatewayClientRow` restructure in `HermesSettingsView.swift` (an `HStack` was wrapped in a `VStack`) — confirm the `@ViewBuilder` body compiles; brace/paren balance was checked but a real compile is the proof.
3. Run the focused iOS unit tests (`OpenBurnBarMobileTests`) — the mock repo gained the two new methods; make sure the target compiles and passes.
4. Install on a **trusted physical iOS device** (iPhone or iPad; no simulator for
   the approval E2E).

Expected behavior, no code change owed: the approval card shows a server-derived label ("Approve {toolName} action"); the full command text arrives as an end-to-end-encrypted chat message.

## JOB 2 — Deploy backend
Deploy the new/changed Cloud Functions and rules. New/changed exports:
`burnBarHermesGateway` (adds `/state` + `/approvals` routes), `setHermesGatewayOversightMode`, `respondHermesGatewayApproval`, `reapHermesGatewayApprovals` (scheduled), plus `firestore.rules` (new `hermes_gateway_approvals` matcher).

- Use the project's normal flow (see `project_burnbar_deploy` memory / `.github/workflows/deploy-production.yml`): **Node 22 to build, Node 24 to run `firebase deploy`**, Firebase project `burnbar`.
- Deploy functions + firestore rules. Confirm `reapHermesGatewayApprovals` registers as a scheduled function.

## JOB 3 — Publish the Hermes plugin PR (author as Ajnunezg) — AFTER Jobs 4 & 5 pass
The Hermes repo (`~/.hermes/hermes-agent`) is dirty with the integrated work:
`plugins/platforms/burnbar/adapter.py`, `tests/gateway/test_burnbar_plugin.py`, `tests/gateway/test_relay_e2ee.py`, `gateway/crypto/relay_e2ee.py` (confirm tracked), and test fixtures.

1. Sync the **de-hyped README** into the Hermes copy (the BurnBar mirror has the good one; `~/.hermes` still has the old hyped version):
   `cp tools/hermes-platform-burnbar/README.md ~/.hermes/hermes-agent/plugins/platforms/burnbar/README.md`
2. Re-run the Hermes tests (preflight command above) — must be 62 green.
3. **Confirm the PR target branch with Alberto** (mission named `ajnunezg/burnbar-platform-ready`; repo is on `ajnunezg/burnbar-platform`). Don't include unrelated dirty files (`.serena/`, `assets/user_ascii_apple.txt`) unless they belong — stage only the BurnBar-gateway plugin + crypto + tests + fixtures + README.
4. Commit in the Hermes repo **authored as Ajnunezg** (not as the agent/Codex):
   `git -C ~/.hermes/hermes-agent -c user.name='Ajnunezg' -c user.email='ajnunezg@users.noreply.github.com' commit ...`. Keep Hermes commits separate from BurnBar commits.
5. Push the branch and **open the PR** to the upstream (`github.com/NousResearch/hermes-agent`, fork remote `ajnunezg`) via `gh pr create`. Title/body: terse + factual, matching the de-hyped README (what ships, how to test). **You are cleared to publish once Jobs 4 (device E2E) and 5 (audit) are green** — report the PR URL back to Alberto.

---

## JOB 5 — Re-audit (correctness + security) before publishing
Run a fresh, adversarial pass. This is a gate for the PR — do not publish if any check below fails.

**Correctness re-audit**
- Re-run the full preflight (build, all suites, scanner, mirror-identical, 62 Hermes tests).
- Run `/security-review` (or `/code-review high`) on the gateway diff; triage findings.
- Confirm the three features actually behaved on-device in Job 4 (not just unit-green).

**Security checklist — verify each holds in the deployed system:**
1. **No self-approve.** A `hermes.gateway.write` bearer token (the agent) cannot resolve its own oversight gate. Resolution requires `respondHermesGatewayApproval` (signed-in owner + App Check) bound to a **trusted native escrow device**; `approvedByDeviceId` is server-stamped. `hermes_gateway_approvals` is `allow write: if false` (owner-read only) — try a direct client write and confirm it's denied.
2. **Single resolution / idempotent.** A gate resolves once (transaction guard); a second approve/deny → failed-precondition. An expired gate cannot be approved.
3. **TTL.** Unanswered gates expire (~5 min) and `reapHermesGatewayApprovals` flips stale ones to `expired`; the agent never blocks forever.
4. **Privacy / E2EE.** On paired links the gateway is an untrusted relay:
   message/event/attachment bodies, sender names, and file names are sealed with
   production v2/v3 relay envelopes or ratchet envelopes where both peers support
   them; the server cannot read those bodies. The oversight gate is
   **control-plane only** — it stores a server-derived label, never the agent's
   command (the detail rides the sealed channel). Re-run
   `scan-chat-cloud-plaintext.mjs`; spot-check a live `hermes_gateway_approvals`
   doc in Firestore and confirm there is **no plaintext command**. The
   2026-06-04 deployed iPad run completed this approval readback for
   approve/reject/expiry.
5. **Auth/scope.** Every HTTP route validates the bearer token + scope + entitlement; `/state` & `/approvals` GET use `read`, arm uses `write`. Tokens are SHA-256-hashed at rest, expire (90d), and model/oversight callables require Auth + App Check.
6. **Model switch can't be abused.** Off-catalog model ids are rejected; the switch only affects the target client.
7. **Input hardening.** actionId/toolName/destination are bounded + sanitized; oversize/CRLF/path-traversal inputs are rejected.

Record the audit result (pass + any fixed findings) in `docs/runbooks/hermes-gateway-3features.md` before publishing.

---

## JOB 4 — PHYSICAL-IOS E2E (the real acceptance test — needs Jobs 1 & 2 done first)
1. Install latest OpenBurnBar on the trusted iOS device.
2. `hermes gateway restart` → `hermes gateway status`.
3. `hermes gateway setup` → **BurnBar Cloud** → approve the device code in the app.
4. **State:** app shows gateway **online** + current model + agent version + this client connected.
5. **Model switch:** pick a different model on the trusted iOS device → brief "switching…" → settles → next reply uses it. Try an off-catalog id → expect `model_not_available`.
6. **Oversight ON (supervised, default):** trigger a risky action that routes through Hermes slash-confirm → approval card appears on the trusted iOS device → **approve** → it runs; repeat and **deny** → cancelled; leave one unanswered past 5 min → it expires.
7. **Oversight OFF (autonomous):** same action runs with no prompt.
8. **Offline truthfulness:** stop the gateway → trusted iOS device shows **offline** within ~90s.

## Gotchas / guardrails
- Don't trust a one-off green check — re-run the preflight if you see "file was modified" notices; concurrent agents churn these files.
- Mirror and `~/.hermes` adapter are byte-identical now; keep them in sync if you touch either.
- Oversight resolution requires a **trusted native escrow device** — exercise approve/deny from the real attested iOS device, not a simulator.
- Report results back to Alberto; hold the Hermes PR push for his explicit go.
