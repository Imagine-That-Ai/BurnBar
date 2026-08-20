# Agent Goals

This file is the project-level index of active and completed agent goals. It records goal chains, not full implementation detail.

| Goal | Status | Parent | Ledger | Updated |
|---|---|---|---|---|
| `burnbar-budgeting-overhaul-2026-05-25` | active | none | `.agent/runs/burnbar-budgeting-overhaul-2026-05-25/` | 2026-05-26T00:27:24Z |
| `pensieve-mnemo-2026-06-02` | backend-complete (native UX [incomplete]) | none | `.agent/runs/pensieve-mnemo-2026-06-02/` | 2026-06-02T12:33:04Z |
| `privacy-leak-remediation-2026-06-02` | complete + verified (Wave 1+2+3; all platforms green; gateway E2E → child goal) | none | `.agent/runs/privacy-leak-remediation-2026-06-02/` | 2026-06-03T08:30:00Z |
| `hermes-gateway-e2e-rearchitecture` | complete + verified; fork PRs #1/#2 open on Ajnunezg/hermes-agent; BurnBar companion committed (edee4da0a) | privacy-leak-remediation-2026-06-02 | `.agent/runs/hermes-gateway-e2e-rearchitecture/` | 2026-06-03T09:45:00Z |
| `hermes-gateway-e2ee-remediation-20260603` | active | none | `.agent/runs/hermes-gateway-e2ee-remediation-20260603/` | 2026-06-03T21:59:17Z |
| `signalification-phases-3to8-20260604` | server/proof/audit DONE + landed on main @9cc095ff4 (flag-OFF); productionization (app vendoring + on-device E2E + activation) [incomplete], feasibility proven | none | `.agent/runs/signalification-phases-3to8-20260604/` | 2026-06-05T06:20:00Z |
| `sotasignal-full-ship-20260605` | safety/proof layers COMPLETE + verified, activation still BLOCKED: rules+admin (L31/L23/L37), L40 backend+rules sourceManifestId, CI/ops gates + fast-feedback crypto harness, native L37 mandatory expectedBinding+AAD-from-expected (Swift+Android), L41 server/rules prekey/session contract, data-domains drift fixed, user-facing honesty over-claims fixed, external/legal templates indexed; current sweep green (emulator 50, L40 functions 14, export 22, bridge 5, crypto-harness 18, honesty, activation parity, physical iPhone chat+CLI Signal relocation, physical iPad Pensieve+chat Signal relocation, Android physical Signal). Activation validator intentionally fails with 32 real Phase-E issues: external crypto+legal/MAS review, Rule-0 approvals, Apple notarization/MAS proof, live cross-device production flows, producer/client-reader wiring across pensieve/chat/CLI, L41 revocation/rewrap, Phase-E activation+rollback. | signalification-phases-3to8-20260604 | `.agent/runs/sotasignal-full-ship-20260605/` | 2026-06-05T09:35:00Z |
| `signal-remediation-20260605` | historical remediation sub-goal COMPLETE + green and now superseded by `sotasignal-full-ship-20260605`: R2/R3/R5/R7/R8/R9/R10/R11/R12 landed in commit `e01cca1ae`; the later SOTASIGNAL continuation independently reverified the tree, closed the iPad physical-device gap, and records the current blockers in `docs/signalification/REMAINING_SIGNAL_WORK_HANDOFF.md`. Do not use the older R1b ready-patch note as the current activation plan. | sotasignal-full-ship-20260605 | `.agent/runs/signal-remediation-20260605/` | 2026-06-05T09:35:00Z |
| `burnbar-sota-hardening-2026-06-12` | substantially DONE + build-verified. **RR-8 FIXED+VERIFIED** (Android AAD parity wired for mobile_assistant_chats + cli_agent_mission_requests; Swift KAT 5/5 `swift test` + Android KAT 6/6 `./gradlew testDebugUnitTest`). **RR-1 brick FIXED+VERIFIED** (codec-absent → disclosed plaintext, no brick; macOS app test `** TEST SUCCEEDED **` 16/0). **RR-7 false copy FIXED**. Earlier: RR-15b SSRF/rebinding (+IPv6 bug), RR-13 MCP prod posture (50/50), RR-4 ops fail-closed, RR-15c wrapper, signal-parity gate — all verified. REMAINING (gated, in claims register): RR-1 **real** encryption (vendor SQLCipher codec + key daemon — SPM links stock sqlite3, proven), RR-7 Android over-the-wire approval feature (control-ingest receiver + device E2E), RR-3 daemon re-exec (root-owned install / peer-SecCode — self-attestation rejected as theater). | none | `.agent/runs/burnbar-sota-hardening-2026-06-12/` | 2026-06-13T01:04:50Z |
| `kotlin-relay-codegen-2026-06-15` | COMPLETE — Phases A–D done + verified, shipped as PR #440 (Alberto merges). 56/60 relay payload types schema-generated; HermesRealtimeRelayFrame.kt 1349→362 LOC; CI drift gate now covers the real android+Swift Generated dirs. 4 types deliberately hand-written (PresenceHeartbeat dual-key, PhoneControlSigningKeyKind app-domain, AgentFocusFollowMode/ErrorCode inline-String). gradle (iroh-relay + app unit + androidTest compile) green; node 15/15; codegen idempotent. | none | `.agent/runs/kotlin-relay-codegen-2026-06-15/` | 2026-06-15T16:50:00Z |

| `linux-desktop-port-2026-07-03` | active | none | `.agent/runs/linux-desktop-port-2026-07-03/` | 2026-07-03T01:13:34Z |
| `linux-macos-parity-2026-07-05` | COMPLETE + LANDED — PR #1273 MERGED into linux/mission-001-port-landing (3d7592b38d, 2026-07-06): all 15 ui-parity packets, deferred stubs wired/ledgered, live gateway chat on Linux, packaged proof 9/9 perf + 6/6 a11y + 16-route truth check; release signing = named blocker | linux-desktop-port-2026-07-03 | `.agent/runs/linux-macos-parity-2026-07-05/` | 2026-07-06T10:30:00Z |
| `windows-parity-100-2026-07-06` | active — Wave 0 COMPLETE + MERGED (#1270 #1274 #1275 #1280 #1282 on main; #1279 pending green rerun); Wave 1 executing: G2 harness proven-pending-evidence-row (15 providers/26 fixtures), B/C lanes confirmed already-integrated (stale refs marked do-not-merge), storage decided WPD-0005 (C# seam permanent), daemon decided WPD-0006 (per-capability substitution), 4 build lanes in flight (WPD-0005 exec, WPD-0006 matrix, native FFI shim, quota acquisition); Alberto-owned: W0 cert, Win11 Pro pass (gates R14+WS-D), WS-A2 flip, publisher accounts, issues #1276-#1278 | none | `.agent/runs/windows-parity-100-2026-07-06/` | 2026-07-06T17:00:00Z |
| `linux-w5-mercury-engine-2026-07-06` | active | linux-macos-parity-2026-07-05 | `.agent/runs/linux-w5-mercury-engine-2026-07-06/` | 2026-07-06T10:01:10Z |
| `sota-quality-apple-apps-2026-07-06` | active | none | `.agent/runs/sota-quality-apple-apps-2026-07-06/` | 2026-07-06T11:22:23Z |
| `burnbar-accretive-pr-merge-2026-08-07` | complete — #2191/#2172/#2125/#2088/#2054/#2186 MERGED; main@20ec5aba4e | none | `.agent/runs/burnbar-accretive-pr-merge-2026-08-07/` | 2026-08-08T07:38:18Z |
| `windows-macos-parity-completion-2026-08-09` | active | windows-parity-100-2026-07-06 | `.agent/runs/windows-macos-parity-completion-2026-08-09/` | 2026-08-09T21:43:11Z |
| `product-truth-activation-2026-08-16` | active | none | `.agent/runs/product-truth-activation-2026-08-16/` | 2026-08-17T01:36:55Z |
| `burnbar-glass-system-2026-08-19` | active | none | `.agent/runs/burnbar-glass-system-2026-08-19/` | 2026-08-20T04:09:47Z |
| `first-launch-permission-trust-2026-08-20` | active | none | `.agent/runs/first-launch-permission-trust-2026-08-20/` | 2026-08-20T05:29:18Z |

## first-launch-permission-trust-2026-08-20 — in progress
Remove every uninvited macOS dialog from first launch and make BurnBar explain agent
permissions in its own voice before macOS ever asks.
- Ledger: `.agent/runs/first-launch-permission-trust-2026-08-20/`
- Done: A1 (non-interactive keychain reads + unreadable-key guard), A3, B1 (notification /
  local-network / accessibility launch prompts removed), B2 (`FirstRunPermissionLadder`),
  B3 (permissions step off the onboarding path), C1/C1b (`SafetyFrame` + honesty guard),
  C2 (pre-prompt trust sheet, nine sites rewired).
- Incomplete: A2 (data-protection keychain migration — needs app+daemon sequencing).
- Todo: C3 trust-overview card, C4–C6, MAS configuration build.
- Parent goal: none. Source plan: `~/.claude/plans/but-when-users-first-modular-hanrahan.md`.
