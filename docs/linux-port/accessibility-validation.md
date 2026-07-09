# Linux accessibility validation

This contract prevents Linux accessibility from being inferred from DOM markup
or screenshots alone. It combines semantic checks in the renderer test suite
with live AT-SPI and Orca observation of the installed `.deb`.

Passing this harness is necessary for parity. It is not, by itself, a claim
that every supported desktop environment or assistive-technology workflow has
completed manual certification.

## Automated layers

### Axe route and capability matrix

`apps/linux-desktop/src/accessibility/axeRouteAudit.test.tsx` mounts every one
of the 19 routes, plus representative unavailable and degraded capability
states. Axe must report zero violations in all 21 states. The test disables
only `color-contrast`, because jsdom has no layout or paint engine; packaged
and manual visual QA own that rule.

When `OB_EVIDENCE_OUT` is set, the suite writes
`axe-route-accessibility-scan.json`. `run-shell-evidence.mjs` requires this
artifact and `verify-shell-evidence.mjs` verifies the state and route coverage.

### Installed-app AT-SPI and Orca session

`linux-desktop-session.sh` installs the current `.deb` in an isolated
DBus/X11/XFCE session with AT-SPI enabled. The session:

1. starts Orca with speech and braille output disabled while retaining its
   application observation and debug logging;
2. proves Orca remains active and lists OpenBurnBar;
3. captures a bounded AT-SPI tree with names, roles, states, and actions;
4. navigates all 19 routes through the keyboard command palette and requires
   the expected route name in each live AT-SPI tree;
5. sends a bounded 14-key Tab traversal, records Orca's live AT-SPI
   focused-state events, and requires ten ordered events spanning at least
   three distinct named focus targets; and
6. requests an approximately 200 percent WebKitGTK keyboard zoom, captures the
   result, and proves the Overview surface remains in the AT-SPI tree.

The AT-SPI crawler fails on a missing application, missing expected route name,
fewer than 20 nodes, fewer than eight named nodes, fewer than five actionable
nodes, or a truncated tree. These are anti-empty-evidence thresholds, not a
substitute for reviewing the semantics of critical workflows.

The zoom artifact records `exactScaleObservable: false`. Seven `Ctrl+plus`
increments request an approximate 200 percent scale, but the packaged WebKitGTK
surface does not expose an authoritative zoom percentage to this harness. Do
not describe this artifact as exact 200 percent reflow certification.

## Commands

Run the structural contract and axe matrix locally:

```bash
node --test scripts/linux-port/accessibility-harness-contract.test.mjs
npm test --prefix apps/linux-desktop -- src/accessibility/axeRouteAudit.test.tsx
```

Run the full JSON evidence suite:

```bash
OB_EVIDENCE_OUT="$PWD/docs/linux-port/evidence/mission-002-reanchor/accessibility" \
  node scripts/linux-port/run-shell-evidence.mjs
node scripts/linux-port/verify-shell-evidence.mjs \
  "$PWD/docs/linux-port/evidence/mission-002-reanchor/accessibility" json
```

The packaged desktop session is executed by the Linux smoke/release harness.
Validate its artifacts with:

```bash
node scripts/linux-port/verify-shell-evidence.mjs \
  "$PWD/docs/linux-port/evidence/mission-002-reanchor/accessibility" desktop
```

Use `full` only after JSON, packaged desktop, and performance evidence are in
the same current-HEAD evidence directory.

## Manual certification still required

Before closing the accessibility parity requirement, test the release build on
the supported GNOME and KDE Wayland environments and the documented X11
fallback. At minimum, verify:

- Orca announces route changes, controls, validation errors, progress, and
  live chat output in a useful order;
- every critical workflow is complete with keyboard only, with visible focus
  and no focus trap;
- text reflows without clipping or overlap at an exact desktop-observed 200
  percent zoom;
- high-contrast and system font settings preserve legibility;
- reduced motion removes nonessential animation; and
- unavailable platform capabilities are announced with a reason and recovery
  path without leaving hidden interactive descendants.

Attach assistive-technology transcripts, screenshots, environment metadata,
and failures to a current-HEAD evidence directory. Xvfb evidence must never be
used to claim Wayland compositor or end-user screen-reader certification.
