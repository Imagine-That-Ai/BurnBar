# Bring Cure53 remediation to SOTA 10/10

Goal ID: `burnbar-sota-hardening-2026-06-12`
Started: 2026-06-13T01:04:50Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/burnbar-sota-hardening-2026-06-12/`

## Objective

Close all launch-blockers and residuals from the adversarial audit so BurnBar's security posture is genuinely ship-ready, not changelog-ready

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/burnbar-sota-hardening-2026-06-12/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Finishing Criteria

A genuine SOTA 10/10 = every audit launch-blocker + high residual is either FIXED with a passing automated gate, or explicitly accepted in `SECURITY_CLAIMS_REGISTER.md` with a tracked completion gate. Per-item:

- [doing] RR-15b browser SSRF / DNS-rebinding — resolve-and-block at the bridge chokepoint + deterministic unit test wired into CI. (Verifiable THIS session.)
- [todo] RR-4 ops gates fail-open — DR/governance workflow must fail (not skip-green) when creds absent on main/release. (Verifiable: YAML.)
- [todo] RR-13 hosted-MCP — prod startup guard refusing HMAC-only when Ed25519 key unset + vitest. (Verifiable: TS.)
- [blocked] RR-1 local DB encryption — codec presence requires a RELEASE build (un-quarantine `testMakeConfigurationWithKey_reportsCipherVersion`); daemon must open keyed. Needs macOS build + decision. NOT verifiable this session.
- [blocked] RR-8 Android at-rest AAD parity — thread `CloudVaultAADContext` through Kotlin to match Swift byte-for-byte + Swift↔Kotlin KAT. Needs Android Gradle build. NOT verifiable this session.
- [blocked] RR-7 Android wire approvals — connect `phoneControlSender` + ingest path + cross-lang `respondedAt` KAT. Needs Android build + device. NOT verifiable this session.
- [todo] Update `SECURITY_CLAIMS_REGISTER.md` so every accepted residual is named with its gate.
- [todo] Keep `implementation-notes.html` current; link bulky proof from `evidence/`.

### Validation commands
- `node scripts/test-playwright-bridge-guard.mjs` (new, deterministic SSRF unit test)
- `node scripts/test-computer-use-browser-scenarios.mjs` (existing, real Chromium — CI)
- `cd services/hosted-mcp && npm test`
- `cd functions && npm test`
- `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/security-pr.yml'))"`

### Reality note (escape-hatch invoked, scope honesty)
This session can VERIFY JS/TS/YAML/shell but CANNOT run xcodebuild (macOS/iOS) or Android Gradle. Swift/Kotlin fixes are validated only by the team's CI on push (their CI builds + ran my prior wrapper-fix test in PR #331). Therefore RR-1/RR-8/RR-7 are implemented-and-gated or specced, marked `[blocked]` on build/device verification — a *verified* 10/10 cannot be asserted from this session alone. Do not blind-ship unverified crypto (that is how RR-8 was introduced).

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

