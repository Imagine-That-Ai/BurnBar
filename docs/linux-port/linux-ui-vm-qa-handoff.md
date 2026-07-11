# Linux UI And VM QA Handoff

Generated: 2026-07-05

## Current Live VM

- Surface: Ubuntu 24.04 aarch64 QEMU VM, viewed through macOS Screen Sharing.
- VNC URL: `vnc://127.0.0.1:5901`
- Run directory: `/tmp/obb-live/live-openburnbar-20260705-085818/ubuntu-24.04`
- Status file: `/tmp/obb-live/live-openburnbar-20260705-085818/ubuntu-24.04/live-vm-status.json`
- Installed package observed: `open-burn-bar 0.1.0`
- App binary observed: `/usr/bin/openburnbar-linux-desktop`

## Bugs Found In Real VM

### P0 - User-Facing Raw Daemon Error

The shell rendered `No such file or directory (os error 2)` in the global status pill. That is implementation leakage in the first-view chrome.

Fixed in source:

- Global status now says `Daemon offline`.
- Missing socket guidance points to the AF_UNIX socket path and daemon start action.
- Raw OS errors are retained only in Support diagnostics.
- Added unit coverage for missing socket, browser preview, and permission-denied states.

### P0 - First-Run Setup Could Stall Without Completion

The wizard reached `Privacy choices`, but `Continue` did not produce a visible completed state. It also had no step count and Retry produced no visible feedback.

Fixed in source:

- Onboarding now shows `Step N of 8`.
- Final action is `Finish setup`.
- Completed onboarding renders `Setup checklist complete`.
- Retry check shows visible daemon-status feedback without advancing the wizard.

### P1 - Retry/Reconnect Feedback Is Too Weak

`Retry check` and `Reconnect` need clear progress and result states. The source fix adds visible onboarding retry feedback, but the broader dashboard reconnect path still needs a richer inline result, timestamp, and last failure detail.

### P1 - Empty Routes Feel Like Placeholders

Most dashboard routes render a sparse card plus daemon-offline copy. That proves routing but does not prove macOS parity. Each route needs a real offline skeleton matching the final data shape.

### P1 - Provider Route Is Not Actionable

Provider chips render, but there is no credential state, model catalog, routing policy, or disabled action surface. Mac parity requires provider lanes, logos, quota/status rows, and setup actions.

### P1 - Support Diagnostics Are Useful But Not Productized

Support has perf rows and failure cases, but the layout reads like a validation artifact. It needs export controls, grouped health checks, timestamps, daemon/log/package sections, and redaction labels.

### P2 - Skin Toggle Is Developer Chrome

`Skin: editorial` / `Skin: aurora` is useful for evidence, but it belongs in Appearance settings, not the main sidebar footer.

### P2 - Visual Density And Hierarchy Are Below Mac Standard

The current shell is a thin dark frame: one card, small type, weak grouping, and little sense of product power. It is functional scaffolding, not a premium desktop app.

## VM Requirements For Proper Visual QA

The VM must be provisioned as a repeatable visual test target, not a one-off terminal rescue:

1. QEMU run directory under a short path such as `/tmp/obb-live/...`; long paths can break QEMU monitor sockets.
2. Working user-mode networking with guest NIC up, IPv4 address, default route, and DNS configured.
3. Desktop stack installed: `xvfb`, `openbox`, `dbus-x11`, `x11vnc`, `xdotool`, `wmctrl`, `scrot`, `x11-utils`, `at-spi2-core`.
4. VNC host forward: `tcp::5901-:5900`.
5. VNC password set for macOS Screen Sharing. Anonymous VNC was rejected by Screen Sharing.
6. OpenBurnBar package installed from the same `.deb` being reviewed.
7. Local daemon installed and running, or explicitly absent with the UI showing a polished offline mode.
8. Real daemon socket at `~/.local/share/openburnbar/openburnbar-daemon.sock` for dashboard parity testing.
9. Evidence capture command that clicks every route, captures one PNG per route, records window geometry, and saves app stdout/stderr.
10. Optional SSH host forward for fast package replacement; serial-only access is workable but slow for rebuild/install loops.

## Mac Parity Target

Linux should mirror the macOS information architecture, adjusted for Linux platform facts:

- Use the macOS adaptive editorial palette from `AgentLens/Theme/DesignSystem.swift`.
- Keep a split-view app shell, but make the sidebar closer to the macOS dashboard/settings navigation.
- Bring over dashboard primitives: hero metrics, provider/model lanes, activity lane, credential lane, and project spend lane.
- Bring over Settings structure: searchable command bar, grouped settings sections, provider logo stacks, and clear detail panes.
- Bring over Hermes/Chat structure: thread list, message panel, approval state, and offline disabled states.
- Bring over Memory structure: review inbox, recall boundaries, and source/provenance rows.
- Treat Linux-only constraints as first-class rows: AF_UNIX daemon, Secret Service/KWallet, XDG provider paths, portal capture/input, tray support, update channel.

## Route Acceptance Criteria

- Overview: daemon card, recent activity, perf health, provider status, and explicit offline recovery.
- Insights: usage/diagnostic cards that match macOS dashboard semantics, not placeholder text.
- Database: encrypted SQLite status, migration status, backup/export affordances, and failure recovery.
- Providers & models: provider logo lanes, credential health, model catalog, routing policy, quota/status.
- Projects: workspace list, current repo scope, memory scope, and disabled/empty state.
- Missions: mission list, approval state, controller status, and Linux capability limitations.
- Activity & logs: parser ingest timeline, redaction status, source filters.
- Chat / Hermes: thread list, composer disabled/offline state, approval queue, model/provider identity.
- Memory: review inbox, citation/source rows, local-only sync state.
- Settings: grouped Linux settings with search/copilot parity.
- Account & sync: lower-trust Linux identity, sync pause/resume, signed-out state.
- Updates: package channel, installed version, restart required, rollback notes.
- Support & diagnostics: export bundle, redaction manifest, daemon logs, package versions, perf rows.
- First-run setup: real checklist with pass/fail/warn states, not just explanatory text.
- Pet companion: compositor tier, contained fallback, visible GLB state, input passthrough policy.
- Text expansion: in-app-only consent, snippet CRUD, disabled global capture copy.

## Verification Checklist

Run before claiming visual or functional parity:

```bash
npm test --prefix apps/linux-desktop
npm run build --prefix apps/linux-desktop
OB_EVIDENCE_OUT=/tmp/openburnbar-linux-ui-qa node scripts/linux-port/run-shell-desktop-session.mjs
OB_LINUX_ENVIRONMENT_ID=<support-row-id> \
  node scripts/linux-port/verify-shell-evidence.mjs /tmp/openburnbar-linux-ui-qa
OPENBURNBAR_LINUX_INSTALLED_EVIDENCE=<installed-package-evidence.json> \
OPENBURNBAR_LINUX_ACCESSIBILITY_EVIDENCE=<installed-accessibility-evidence.json> \
OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE=/tmp/openburnbar-linux-ui-qa/native-shell-evidence.json \
  node scripts/linux-port/run-linux-matrix-harness.mjs --environment <support-row-id>
git diff --check
```

The desktop-session run should produce `tray-chat-menu-event.txt`,
`tray-providers-menu-event.txt`, `tray-updates-menu-event.txt`,
`tray-login-start-menu-event.txt`, `tray-action-route-results.json`,
`native-status-window-report.json`, `native-status-window-a11y.json`,
`screenshot-native-status-window.png`, `native-notification-capabilities.json`,
`native-notification-action-result.json`,
`native-notification-response-result.json`,
`native-notification-relaunch-route.json`,
`native-notification-server-events.jsonl`, and
`native-deep-link-relaunch.json`.
Treat a missing artifact as a failed native shell capture, not as a manual QA
item.

Manual visual pass:

1. Open `vnc://127.0.0.1:5901`.
2. Visit every sidebar route.
3. Capture before/after screenshots for Overview, Providers, Chat, Support, First-run setup, Pet, and Text expansion.
4. Verify no raw OS error appears outside Support diagnostics.
5. Verify onboarding can finish and relaunch lands on Overview.
6. Verify offline mode and daemon-connected mode both have intentional layouts.

## Current Score

- Functional shell routing: 7/10 after the daemon/offline/onboarding fixes.
- Linux VM inspectability: 6/10. VNC works, but setup still needed manual network and desktop repair.
- Visual polish: 3/10. The current shell is too sparse and evidence-oriented.
- Mac parity: 2/10. It has route names, not matching product surfaces.

## Recommendation

Do not call the Linux UI parity-complete yet. The port is inspectable and the most embarrassing live bugs are fixed in source, but the UI needs a dedicated parity implementation pass that ports the macOS dashboard/settings/chat primitives instead of treating route coverage as product completion.
