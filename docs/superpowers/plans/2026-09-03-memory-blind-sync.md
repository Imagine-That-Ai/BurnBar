# Memory Blind Sync — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]` for tracking.

**Goal:** the Memory MCP's memories replicate across the member's own devices as ciphertext the server cannot read.

**Architecture:** the engine mirrors approved non-secret rows into the SQLCipher control plane marked `source_kind = 'agent'` with a body snapshot; the app seals them with the CloudVault key into `users/{uid}/memory_facts` (the existing collection and envelope) and, in the second half, reads them back, verifies them, and hands them down to the engine to merge. The engine gains no key material; the daemon gains no network.

**Spec:** `docs/superpowers/specs/2026-09-03-memory-blind-sync-design.md`

## Global constraints

- No new cryptography, no new Firestore collection, no new key material in Python.
- Only `review_status = 'approved'`, non-secret rows travel; `memory_vault` never leaves the device.
- Every uploaded document carries exactly the fields `firestore.rules:3208-3221` allows, and no others.
- Every lever is fail-closed: no entitlement, no consent, no Firebase, no daemon → zero network calls and unchanged local behaviour.
- Python: no new dependencies; ruff 0.15.17 clean; the suite runs on 3.12 and 3.11.
- Swift: SwiftLint strict clean; the Xcode project is **generated** — add files, then `xcodegen generate --spec project.yml`, never hand-register.
- Commit trailer `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`; never commit `.serena/`.

## Shipping shape

Two coherent PRs, per the CHEAP_FAST standing rule.

- **PR 1 — blind backup (Tasks 1-3).** Engine memories reach `memory_facts` sealed. Complete and useful on its own: an encrypted off-device copy BurnBar cannot read.
- **PR 2 — blind sync (Tasks 4-6).** The pull half, the engine merge, and the device sub-toggle.

---

## Task 1: Rules, rotation, and the contract widening

**Files:** `firestore.rules`; `AgentLens/Services/CloudSync/CloudVaultRotationRewrapWorker.swift`; the memory remember request contract in `OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/`; `functions/` rules tests if present.

**Produces:** `sourceKind in ["chat", "agent"]` and the widened `kind` allowlist at `firestore.rules:3238-3240`; the rotation-rewrap keys added to the rules' field allowlist; `BurnBarProjectMemoryRememberRequest` gaining one optional field, `engineMemoryID: String?`, whose presence marks a row syncable and whose absence keeps the never-replicated `"code"` default.

**Ruling (2026-09-03):** the rewrap gap was not in `CloudVaultRotationRewrapWorker` — `memory_facts` is already in its data-driven collection set through the `pensieve` data domain. The real stranding bug was in the rules: `validMemoryFactKeys()` did not admit `vaultGeneration` or `rewrapJobId`, so every rotation update on a memory fact was denied. Fixed there instead, with a red-then-green rules case.

**Ruling (2026-09-03):** the contract carries one field, not two. Only the engine sends an id of its own, and only for rows it wants replicated, so its presence *is* the partition; a `sourceKind` companion would allow a contradictory pair and pushed `OpenBurnBarKernel` past its LOC ceiling, which cannot be raised (`check-baseline-monotonic` rejects baseline raises categorically).

- [ ] **Step 1:** rules tests first — a document with `sourceKind: "agent"` and `kind: "decision"` is accepted; one with `sourceKind: "code"`, one with a `text` field, and one without the Data Vault entitlement are all rejected. Run the repo's Firestore rules test job.
- [ ] **Step 2:** widen the two fields; confirm the previously-failing cases pass and the rejection cases still reject.
- [ ] **Step 3:** add `memory_facts` to `CloudVaultRotationRewrapWorker`'s collection set with a test that a rotation rewraps a memory document (mirror the `session_logs` case).
- [ ] **Step 4:** widen the remember contract with defaults, regenerate the IPC canon (`node tools/ipc/generate-burnbarrpc-canon.mjs`), and pin the new fields in the contract test.
- [ ] **Step 5:** commit `feat(memory-sync): admit agent-sourced memory facts and rewrap them on rotation`.

## Task 2: The engine mirror becomes syncable

**Files:** `tools/openburnbar-mcp/server.py` (mirror call site near `:1886-1901`); `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift` (the `agent_memories` upsert) and its body-snapshot neighbour; tests both sides.

**Consumes:** Task 1's contract fields.

**Produces:** approved, non-secret engine writes mirrored with `source_kind = 'agent'` and their body stored in `memory_body_snapshots`, keyed so the app's existing body lookup finds it. Secrets, quarantined rows and expiring rows keep today's exclusion.

- [ ] **Step 1:** Python test — a mirrored remember sends `sourceKind: "agent"` and the body; a secret, a quarantined and an expiring row send neither (assert on the fake courier's recorded payloads).
- [ ] **Step 2:** daemon test — the upsert writes `source_kind = 'agent'` and a body snapshot row; a request without the new fields still writes `source_kind = 'code'` and no snapshot (backward compatibility).
- [ ] **Step 3:** implement both sides.
- [ ] **Step 4:** full Python suite, daemon suite, ruff, SwiftLint.
- [ ] **Step 5:** commit `feat(memory-sync): mirror engine memories as syncable agent facts`.

## Task 3: Upload covers agent facts

**Files:** `AgentLens/Services/ControlPlaneStore+MemoryForget.swift` (the `sourceKinds: [.chat]` filter at `:116-132`), `AgentLens/Services/CloudSync/KnowledgeSyncService.swift` (`syncApprovedMemories`, `encodeMemoryFact`), tests.

**Produces:** the eligible-rows query accepts `chat` and `agent`; the payload and document shape are unchanged.

- [ ] **Step 1:** test first — an `agent` row with a body snapshot uploads; its document's key set equals the rules allowlist exactly (a set comparison, so a new field fails); `sourceKind` is `"agent"`; the sealed payload round-trips through `CloudVaultCrypto.openBlob` with the same AAD; a `code` row and a quarantined row do not upload.
- [ ] **Step 2:** widen the filter; confirm the tests pass and `MemoryCloudSyncDomainTests` stays green.
- [ ] **Step 3:** adversarial test — a row whose tags, entities or metadata carry a secret-shaped string uploads with none of it in any plaintext field.
- [ ] **Step 4:** app tests (`scripts/test-openburnbar-app.sh -only-testing:…`), SwiftLint.
- [ ] **Step 5:** commit `feat(memory-sync): upload agent memory facts through the existing blind envelope`. **PR 1 ends here** — open it with the evidence from Tasks 1-3 and `docs/PRIVACY.md` updated.

---

## Task 4: The pull service

**Files:** new `AgentLens/Services/CloudSync/MemoryCloudPullService.swift`; `AgentLens/Services/CloudSync/MemoryCloudSyncDomain.swift`; new `AgentLensTests/Active/MemoryCloudPullServiceTests.swift`; then `xcodegen generate --spec project.yml`.

**Produces:** `func pullRemoteFacts(uid:vaultKey:since:) async throws -> MemoryCloudPullResult` reading `users/{uid}/memory_facts` ordered by `updatedAt` above a watermark held in `sync_watermarks`, opening each envelope, and upserting rows into the control plane with `origin = 'remote'`.

- [ ] **Step 1:** tests first, against a fake Firestore gateway — a well-formed remote document lands as a local row; a document whose AAD names a different doc id is rejected; one whose keyed plaintext HMAC fails is rejected; one carrying a `text` field is rejected; a batch applied twice changes nothing; the watermark advances only past applied documents.
- [ ] **Step 2:** implement; reuse `CloudVaultCrypto.openBlob` and the `AIInboxSyncService` watermark shape.
- [ ] **Step 3:** wire into `MemoryCloudSyncDomain.sync()` behind the new sub-toggle, after the upload half; a pull failure records the error and never blocks the push.
- [ ] **Step 4:** commit `feat(memory-sync): pull and verify remote memory facts`.

## Task 5: The engine merges

**Files:** `tools/openburnbar-mcp/memory_engine/_admin.py` (beside `import_legacy`), `memory_engine/store.py` (a `sync_state` table via a real migration), `tools/openburnbar-mcp/server.py` (a `burnbar_memory_sync_pull` tool), new `tools/openburnbar-mcp/tests/test_memory_blind_sync.py`.

**Produces:** `MemoryEngine.merge_remote(rows) -> dict` applying §5 of the spec: LWW on `updated_at` tie-broken by `memory_id`, convergence by `(project_id, scope, body_hash)`, supersede references parked when their target has not arrived, secrets and injection-labelled rows never resurrected, and a `sync_state` watermark.

- [ ] **Step 1:** tests first — a three-replica simulation (add, update, supersede, retire, and two conflicting edits) converges to an identical active set on every replica; applying a batch twice is a no-op; a parked supersede resolves on the next merge; a remote row that would revive a locally forgotten memory does not.
- [ ] **Step 2:** implement, with the schema migration exercised by `test_store_migrations.py`.
- [ ] **Step 3:** the MCP tool, gated by `memory_write`, plus a stdio smoke assertion.
- [ ] **Step 4:** full Python suite on 3.12 and 3.11, ruff.
- [ ] **Step 5:** commit `feat(memory-sync): merge remote memories with last-writer-wins convergence`.

## Task 6: Consent, docs, and the close

**Files:** `AgentLens/Services/Settings/Stores/MemorySettings.swift`, `AgentLens/Services/SettingsManager.swift`, `AgentLens/Views/Settings/PrivacyIndexingSettingsView.swift`, `AgentLens/Views/Settings/Search/SettingsManifest.swift`, `docs/PRIVACY.md`, `tools/openburnbar-mcp/README.md`.

- [ ] **Step 1:** settings tests first — the sub-toggle defaults off, persists, and is ANDed with the backup opt-in, the entitlement and the fleet ceiling (a fail-closed matrix like `MemoryCloudModelsSettingsTests`).
- [ ] **Step 2:** implement the toggle, its row under the existing memory section, and the settings-search entry.
- [ ] **Step 3:** `docs/PRIVACY.md` — what the server holds for a synced memory, field by field; README — the sync contract and its measured numbers.
- [ ] **Step 4:** app tests, SwiftLint, every debt ratchet, gitleaks over the range.
- [ ] **Step 5:** commit `feat(memory-sync): device sync consent and privacy documentation`. **PR 2 ends here.**

---

## Verification before each PR

| Check | Command |
|---|---|
| Python suite (3.12, 3.11) | `.venv/bin/python -m pytest -q --ignore=tests/test_domain_core_cloudvault.py` |
| Lint | `uvx ruff@0.15.17 check` + `format --check`; SwiftLint strict on changed files |
| Daemon + Core | `swift test --package-path OpenBurnBarDaemon --filter "Memory\|Gateway\|RPCCapability"` under the Xcode toolchain |
| App | `scripts/test-openburnbar-app.sh` with the touched classes |
| Rules | the repo's Firestore rules test job |
| Project | `xcodegen generate --spec project.yml` then `scripts/ci/verify-xcodegen-pbxproj-drift.py` |
| Ratchets, secrets | `scripts/debt/check-*`; `gitleaks detect --log-opts=origin/main..HEAD` |

Rollback: every task is a plain revert; the only schema change is one additive engine table.
