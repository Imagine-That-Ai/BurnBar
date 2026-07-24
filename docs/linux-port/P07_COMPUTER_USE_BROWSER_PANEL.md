# P-07 Browser Computer Use panel

The Linux desktop exposes a bounded Browser Computer Use workflow through the
existing daemon contracts. It is a control surface, not a second executor:
every action goes through `computer_use_invoke`, where the daemon remains the
authority for run binding, scope, approval, panic, Playwright dispatch, and
tamper-evident audit.

## Supported boundary

- Session mode is **Browser** only.
- The panel can request `browser_goto`, `browser_screenshot`, `browser_click`,
  and `browser_fill` actions.
- Each request carries the selected run ID, call ID, generation, Linux client
  identity, requested timestamp, and typed action arguments.
- The UI renders the daemon's typed `executed`, `denied`,
  `awaiting_approval`, or `error` result. A pending result is not presented as
  success.
- Fixture mode renders a deterministic pending-approval result and never
  dispatches a native action.

The Tauri input uses lower-camel serde keys (`clientId`, `runId`, `runCallId`,
`callId`). Rust translates these to the Swift Codable daemon keys
(`clientID`, `runID`, `runCallID`, `callID`). Session defaults are explicit:
empty scope rules, no optional peer nodes, a 50-action cap, and a 1,800-second
timeout.

## Unavailable boundary

System Computer Use (desktop capture, accessibility inspection, and input) is
not exposed by this panel. When the native `computer-use.system` capability is
missing or unavailable, the UI states that boundary and keeps the System mode
hidden. It must not offer a guaranteed-failure start action or fall back to
browser automation.

Linux approval controls stay disabled in a release build until the separate
phone-signed action-authority contract is available. Panic halt and audit export
remain available through their existing daemon commands; neither path is
implemented in the Browser action panel.

## QA

Run from `apps/linux-desktop`:

```bash
npx vitest run src/surfaces/computerUse/ComputerUseSurface.test.tsx src/bridgeRpcBehavior.test.ts --reporter=dot
npx tsc --noEmit
npm run build
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --manifest-path src-tauri/Cargo.toml --lib
```

The focused UI tests cover complete request shape, explicit action invocation,
approval-pending rendering, authoritative session retirement, fixture mode, and
system-capability fail-closed behavior. Installed QA must still exercise the
physical paired-device approval, real Playwright targets, panic/audit/restart,
and every supported Linux compositor before P-07 can be certified.
