#!/usr/bin/env bash
set -euo pipefail

root="${OB_REPO_ROOT:-/workspace}"

if [[ "${1:-}" == "desktop-inner" ]]; then
  shift
  pkg="$1"
  installed_bin="$2"
  out_dir="$3"
  work_dir="$4"
  socket_path="$5"
  installed_bin_real="$(readlink -f "$installed_bin" 2>/dev/null || printf '%s' "$installed_bin")"

  export HOME="$work_dir/home"
  export XDG_RUNTIME_DIR="$work_dir/runtime"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_CONFIG_HOME="$HOME/.config"
  export DISPLAY=:99
  export XDG_SESSION_TYPE=x11
  export XDG_CURRENT_DESKTOP=XFCE
  export GDK_BACKEND=x11
  export LIBGL_ALWAYS_SOFTWARE=1
  export WEBKIT_DISABLE_COMPOSITING_MODE=1
  export ACCESSIBILITY_ENABLED=1
  export GSETTINGS_BACKEND=memory
  export OPENBURNBAR_SOCKET_PATH="$socket_path"
  export OPENBURNBAR_EVIDENCE_OUT="$out_dir"
  export OPENBURNBAR_NATIVE_NOTIFICATION_EVIDENCE=1
  unset NO_AT_BRIDGE

  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
  chmod 700 "$XDG_RUNTIME_DIR"

  cleanup_inner() {
    jobs -pr | xargs -r kill 2>/dev/null || true
  }
  trap cleanup_inner EXIT

  Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp >"$out_dir/xvfb.log" 2>&1 &
  for _ in $(seq 1 50); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  xdpyinfo -display "$DISPLAY" >"$out_dir/x11-display-info.txt"

  openbox >"$out_dir/openbox.log" 2>&1 &
  xfce4-panel --disable-wm-check >"$out_dir/xfce4-panel.log" 2>&1 &
  sleep 2
  {
    echo "== panel processes =="
    ps -ef | grep -E 'xfce4-panel|panel/plugins/(libsystray|libsntray)' | grep -v grep || true
  } >>"$out_dir/xfce4-panel.log" 2>&1

  {
    echo "== dbus names before app =="
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames
  } >"$out_dir/dbus-before-app.txt" 2>&1 || true

  python3 "$root/scripts/linux-port/freedesktop-notification-test-server.py" \
    --ready-file "$out_dir/native-notification-server-ready.json" \
    --log-jsonl "$out_dir/native-notification-server-events.jsonl" \
    >"$out_dir/native-notification-server.stdout.log" \
    2>"$out_dir/native-notification-server.stderr.log" &
  notification_server_pid="$!"
  for _ in $(seq 1 80); do
    if [[ -s "$out_dir/native-notification-server-ready.json" ]]; then
      break
    fi
    if ! kill -0 "$notification_server_pid" 2>/dev/null; then
      echo "Freedesktop notification test server exited before ready" >&2
      cat "$out_dir/native-notification-server.stderr.log" >&2 || true
      exit 1
    fi
    sleep 0.1
  done
  if [[ ! -s "$out_dir/native-notification-server-ready.json" ]]; then
    echo "Timed out waiting for freedesktop notification test server" >&2
    cat "$out_dir/native-notification-server.stderr.log" >&2 || true
    exit 1
  fi
  gdbus call --session \
    --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.GetServerInformation \
    >"$out_dir/native-notification-server-info.txt"
  gdbus call --session \
    --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.GetCapabilities \
    >"$out_dir/native-notification-server-capabilities.txt"
  node - \
    "$out_dir/native-notification-server-info.txt" \
    "$out_dir/native-notification-server-capabilities.txt" \
    "$out_dir/native-notification-capabilities.json" <<'NOTIFYCAPS'
const fs = require('fs');
const [infoPath, capabilitiesPath, outputPath] = process.argv.slice(2);
const quoted = (text) => [...text.matchAll(/'([^']*)'/g)].map((match) => match[1]);
const info = quoted(fs.readFileSync(infoPath, 'utf8'));
const capabilities = quoted(fs.readFileSync(capabilitiesPath, 'utf8'));
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  available: true,
  serverName: info[0] ?? 'OpenBurnBar Test Notifications',
  vendor: info[1] ?? 'OpenBurnBar',
  version: info[2] ?? '1.0',
  specVersion: info[3] ?? '1.2',
  actions: capabilities.includes('actions'),
  persistence: capabilities.includes('persistence'),
  body: capabilities.includes('body'),
  bodyMarkup: capabilities.includes('body-markup'),
  serverCapabilities: capabilities,
  source: 'org.freedesktop.Notifications test server'
};
fs.writeFileSync(outputPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.available || !payload.actions || !payload.body) process.exit(1);
NOTIFYCAPS

  orca --version >"$out_dir/orca-version.txt" 2>&1
  orca --replace --disable speech --disable braille --disable braille-monitor \
    --debug-file="$out_dir/orca-debug.log" \
    >"$out_dir/orca.stdout.log" 2>"$out_dir/orca.stderr.log" &
  sleep 2
  if ! pgrep -af '[o]rca' >"$out_dir/orca-process.txt"; then
    echo "Orca did not remain active in the packaged desktop session" >&2
    cat "$out_dir/orca.stderr.log" >&2 || true
    exit 1
  fi

  samples_file="$out_dir/runtime-perf-samples.jsonl"
  has_route_sample() {
    [[ -f "$samples_file" ]] && grep -q "packaged-ui-route-after-paint:${1}" "$samples_file"
  }
  sample_file_offset() {
    wc -c <"$samples_file" 2>/dev/null || echo 0
  }
  has_new_route_sample() {
    local route="$1"
    local offset="$2"
    [[ -f "$samples_file" ]] || return 1
    tail -c "+$((offset + 1))" "$samples_file" 2>/dev/null | \
      grep -q "packaged-ui-route-after-paint:${route}"
  }
  wait_for_new_route_sample() {
    local route="$1"
    local offset="$2"
    for _ in $(seq 1 80); do
      if has_new_route_sample "$route" "$offset"; then
        return 0
      fi
      sleep 0.1
    done
    return 1
  }
  notification_route_offset="$(sample_file_offset)"

  start_ms="$(date +%s%3N)"
  "$installed_bin" >"$out_dir/openburnbar-linux-desktop.stdout.log" 2>"$out_dir/openburnbar-linux-desktop.stderr.log" &
  app_pid="$!"
  echo "$app_pid" >"$out_dir/openburnbar-linux-desktop.pid"

  window_id=""
  for _ in $(seq 1 120); do
    window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
    if [[ -n "$window_id" ]]; then
      break
    fi
    if ! kill -0 "$app_pid" 2>/dev/null; then
      echo "OpenBurnBar exited before showing a window" >&2
      cat "$out_dir/openburnbar-linux-desktop.stderr.log" >&2 || true
      exit 1
    fi
    sleep 0.25
  done
  if [[ -z "$window_id" ]]; then
    echo "Timed out waiting for OpenBurnBar window" >&2
    exit 1
  fi
  app_start_ms="$(( $(date +%s%3N) - start_ms ))"
  app_start_samples=("$app_start_ms")
  echo "$window_id" >"$out_dir/openburnbar-window-id.txt"
  xwininfo -id "$window_id" >"$out_dir/window-initial-xwininfo.txt"
  xprop -id "$window_id" >"$out_dir/window-initial-xprop.txt"
  scrot "$out_dir/screenshot-linux-desktop-first-run.png"

  xmessage \
    -title "OpenBurnBar Panic Shortcut Probe" \
    -buttons "Dismiss:0" \
    "This window must retain focus while the OpenBurnBar global panic shortcut fires." \
    >"$out_dir/native-global-panic-probe.stdout.log" \
    2>"$out_dir/native-global-panic-probe.stderr.log" &
  panic_probe_pid="$!"
  panic_probe_window_id=""
  for _ in $(seq 1 80); do
    panic_probe_window_id="$(xdotool search --onlyvisible --name "OpenBurnBar Panic Shortcut Probe" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$panic_probe_window_id" ]]; then
      break
    fi
    if ! kill -0 "$panic_probe_pid" 2>/dev/null; then
      echo "Global panic shortcut focus probe exited before showing a window" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ -z "$panic_probe_window_id" ]]; then
    echo "Timed out waiting for global panic shortcut focus probe" >&2
    exit 1
  fi
  xdotool windowactivate --sync "$panic_probe_window_id" 2>/dev/null || xdotool windowactivate "$panic_probe_window_id"
  xdotool windowfocus --sync "$panic_probe_window_id" 2>/dev/null || true
  panic_active_window_before="$(xdotool getactivewindow)"
  if [[ "$panic_active_window_before" != "$panic_probe_window_id" ]]; then
    echo "Global panic shortcut probe did not hold focus before dispatch" >&2
    exit 1
  fi
  xdotool key --clearmodifiers ctrl+alt+shift+period
  for _ in $(seq 1 80); do
    if [[ -s "$out_dir/native-global-panic-shortcut-response.json" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ ! -s "$out_dir/native-global-panic-shortcut-response.json" ]]; then
    echo "Installed global panic shortcut did not produce daemon response evidence" >&2
    exit 1
  fi
  panic_active_window_after="$(xdotool getactivewindow)"
  node - \
    "$out_dir/native-global-panic-shortcut-response.json" \
    "$out_dir/native-global-panic-shortcut.json" \
    "$window_id" \
    "$panic_probe_window_id" \
    "$panic_active_window_before" \
    "$panic_active_window_after" <<'PANICSHORTCUT'
const fs = require('fs');
const [responsePath, outputPath, appWindowId, probeWindowId, activeBefore, activeAfter] = process.argv.slice(2);
const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
const foregroundProbeFocused = activeBefore === probeWindowId;
const appWindowFocused = activeBefore === appWindowId;
const passed = response.passed === true &&
  response.daemonAccepted === true &&
  response.source === 'hotkey' &&
  response.sessionId === '*' &&
  response.endedAtPresent === true &&
  response.auditHeadPresent === true &&
  response.chord === 'Ctrl+Alt+Shift+Period' &&
  foregroundProbeFocused &&
  !appWindowFocused;
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed,
  source: response.source,
  chord: response.chord,
  daemonAccepted: response.daemonAccepted === true,
  sessionId: response.sessionId,
  foregroundProbeFocused,
  appWindowFocused,
  appWindowId,
  probeWindowId,
  activeWindowBefore: activeBefore,
  activeWindowAfter: activeAfter,
  focusMethod: 'xmessage-foreground-window-plus-xdotool-global-chord'
};
fs.writeFileSync(outputPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!passed) process.exit(1);
PANICSHORTCUT
  kill "$panic_probe_pid" 2>/dev/null || true
  wait "$panic_probe_pid" 2>/dev/null || true

  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >"$out_dir/atspi-bus-address.txt"
  orca --list-apps >"$out_dir/orca-applications.txt" 2>"$out_dir/orca-list-apps.err"
  python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
    --application OpenBurnBar \
    --output "$out_dir/atspi-tree-linux-desktop.json" \
    --tree-text "$out_dir/accessibility-tree-linux-desktop.txt" \
    --expected-name OpenBurnBar

  notification_routed=false
  for _ in $(seq 1 80); do
    if [[ -s "$out_dir/native-notification-action-result.json" ]] && \
       [[ -s "$out_dir/native-notification-response-result.json" ]] && \
       wait_for_new_route_sample chat "$notification_route_offset"; then
      notification_routed=true
      break
    fi
    sleep 0.1
  done
  if [[ ! -s "$out_dir/native-notification-action-result.json" ]]; then
    echo "Native notification action result was not written by the packaged app" >&2
    exit 1
  fi
  if [[ ! -s "$out_dir/native-notification-response-result.json" ]]; then
    echo "Native notification response result was not written by the packaged app" >&2
    exit 1
  fi
  if [[ "$notification_routed" != true ]]; then
    echo "Native notification action did not produce a fresh chat route sample" >&2
    exit 1
  fi
  notification_window_count="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | wc -l | tr -d ' ')"
  notification_existing_alive=false
  if kill -0 "$app_pid" 2>/dev/null; then
    notification_existing_alive=true
  fi
  node - \
    "$out_dir/native-notification-relaunch-route.json" \
    "$out_dir/native-notification-action-result.json" \
    "$out_dir/native-notification-response-result.json" \
    "$notification_existing_alive" \
    "$notification_window_count" <<'NOTIFYROUTE'
const fs = require('fs');
const [outPath, actionPath, responsePath, aliveText, windowCountText] = process.argv.slice(2);
const action = JSON.parse(fs.readFileSync(actionPath, 'utf8'));
const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
const windowCount = Number(windowCountText);
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: action.passed === true &&
    response.passed === true &&
    aliveText === 'true' &&
    windowCount >= 1 &&
    action.route === 'chat' &&
    action.action === 'open-chat',
  focusedExistingWindow: aliveText === 'true' && windowCount >= 1,
  route: action.route,
  action: action.action,
  notificationId: action.notificationId,
  response: response.response,
  windowCount,
  source: 'freedesktop ActionInvoked signal through notify-rust'
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.passed) process.exit(1);
NOTIFYROUTE

  route_tsv="$work_dir/packaged-route-session.tsv"
  : >"$route_tsv"
  route_names=(
    overview
    insights
    database
    providers
    projects
    missions
    activity
    chat
    memory
    settings
    account
    updates
    support
    onboarding
    pet
    text-expansion
    computer-use
    mercury
    smarthub
  )
  # Exact labels from routes.ts — the accessible name of each nav-link button.
  # Must match ROUTES[].label verbatim for AT-SPI exact-name matching.
  route_labels=(
    "Overview"
    "Insights"
    "Database"
    "Providers & models"
    "Projects"
    "Missions"
    "Activity & logs"
    "Chat / Hermes"
    "Memory"
    "Settings"
    "Account & sync"
    "Updates"
    "Support & diagnostics"
    "First-run setup"
    "Pet companion"
    "Text expansion"
    "Computer Use"
    "Mercury"
    "SmartHub / IoT"
  )

  # ── Route navigation via AT-SPI command-palette actions ──────────────
  # The shell's command palette reaches all 19 routes and drives the same
  # shellStore.setRoute() path — emitting the
  # route.navigation perf sample with source
  # packaged-ui-route-after-paint:<route>.
  # Named AT-SPI actions survive chrome layout changes and prove the installed
  # app exposes both the palette trigger and every route row as actionable.
  xdotool windowactivate --sync "$window_id" 2>/dev/null || xdotool windowactivate "$window_id"
  xdotool windowfocus --sync "$window_id" 2>/dev/null || true
  sleep 2

  palette_navigate() {
    local route="$1"
    local label="$2"
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode activate \
      --expected-name "Open command palette" \
      --output "$out_dir/atspi-command-open-${route}.json"
    sleep 0.5
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode activate \
      --within-role dialog \
      --expected-name "$label" \
      --output "$out_dir/atspi-command-route-${route}.json"
    sleep 0.7
  }

  # Bootstrap the first route through the same installed-app AT-SPI path used
  # for all later captures.
  eval "$(xdotool getwindowgeometry --shell "$window_id")"
  palette_navigate "${route_names[0]}" "${route_labels[0]}"
  if ! has_route_sample "${route_names[0]}"; then
    scrot "$out_dir/palette-action-failure.png"
    echo "AT-SPI palette navigation never produced a route.navigation sample (see palette-action-failure.png)" >&2
    exit 1
  fi

  xdotool mousemove --window "$window_id" 8 $((HEIGHT - 8)) click 1
  sleep 0.3
  focus_log_offset="$(wc -c <"$out_dir/orca-debug.log")"
  physical_tab_presses=14
  for _ in $(seq 1 "$physical_tab_presses"); do
    xdotool key --clearmodifiers Tab
    # Orca intentionally serializes accessibility events. Fast synthetic input
    # causes its queue to obsolete intermediate focus changes.
    sleep 1.5
  done
  sleep 4
  node - "$out_dir/orca-debug.log" "$focus_log_offset" "$physical_tab_presses" "$out_dir/atspi-keyboard-focus-sequence.json" <<'FOCUS'
const fs = require('fs');
const [debugPath, offsetText, physicalTabPressesText, outPath] = process.argv.slice(2);
const debug = fs.readFileSync(debugPath);
const segment = debug.subarray(Number(offsetText)).toString('utf8');
const focusEvent = /OBJECT EVENT: object:state-changed:focused for \[([^:\]]+): '([^']*)'\] in \[application: '([^']+)'\] \(1,\s*0,\s*0\)/g;
const events = [...segment.matchAll(focusEvent)]
  .map((match) => ({ role: match[1], name: match[2], application: match[3] }))
  .filter((event) => /openburnbar/i.test(event.application));
const steps = events.slice(0, 10).map((focused, index) => ({
  step: index + 1,
  key: 'Tab',
  focused,
  capturePass: true
}));
const identities = new Set(steps.map((step) => `${step.focused.role}:${step.focused.name}`));
const namedSteps = steps.filter((step) => step.focused.name);
const result = {
  generatedAt: new Date().toISOString(),
  method: 'xdotool-tab-plus-orca-atspi-focus-events',
  sourceLog: 'orca-debug.log',
  physicalTabPressCount: Number(physicalTabPressesText),
  observedTrueFocusEventCount: events.length,
  stepCount: steps.length,
  distinctFocusedTargets: identities.size,
  namedFocusedTargets: namedSteps.length,
  steps,
  pass: events.length >= 10 && steps.length === 10 && identities.size >= 3 && namedSteps.length >= 3
};
fs.writeFileSync(outPath, JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
if (!result.pass) process.exit(1);
FOCUS

  for index in "${!route_names[@]}"; do
    route="${route_names[$index]}"
    label="${route_labels[$index]}"
    nav_method="atspi-command-palette-actions"

    palette_navigate "$route" "$label"

    screenshot="$out_dir/screenshot-route-${route}.png"
    xwininfo_route="$out_dir/window-route-${route}-xwininfo.txt"
    atspi_route="$out_dir/atspi-route-${route}.json"
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode summary \
      --route "$route" \
      --expected-name "$label" \
      --output "$atspi_route"
    scrot "$screenshot"
    current_window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
    if [[ -z "$current_window_id" ]]; then
      echo "OpenBurnBar window disappeared while capturing route $route" >&2
      exit 1
    fi
    xwininfo -id "$current_window_id" >"$xwininfo_route"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$route" "$(basename "$screenshot")" "$(basename "$xwininfo_route")" "$current_window_id" "$nav_method" "$(basename "$atspi_route")" >>"$route_tsv"
  done

  # ── Navigation truth check ────────────────────────────────────────────
  # Every palette navigation must have produced a route.navigation perf
  # sample tagged packaged-ui-route-after-paint:<route>. This catches silent
  # mis-navigation (screenshots of the wrong surface) that coordinate
  # drift previously let through.
  node - "$out_dir/runtime-perf-samples.jsonl" "${route_names[@]}" <<'NAVCHECK'
const fs = require('fs');
const [samplesPath, ...routes] = process.argv.slice(2);
const seen = new Set();
if (fs.existsSync(samplesPath)) {
  for (const line of fs.readFileSync(samplesPath, 'utf8').split(/\n+/)) {
    if (!line.trim()) continue;
    try {
      const row = JSON.parse(line);
      if (row.name === 'route.navigation' && typeof row.source === 'string') {
        const m = row.source.match(/^packaged-ui-route-after-paint:(.+)$/);
        if (m) seen.add(m[1]);
      }
    } catch {}
  }
}
const missing = routes.filter((r) => !seen.has(r));
if (missing.length > 0) {
  console.error(`route.navigation samples missing for: ${missing.join(', ')}`);
  process.exit(1);
}
console.log(`route.navigation verified for all ${routes.length} routes`);
NAVCHECK

  node - "$route_tsv" "$out_dir/packaged-route-session-transcript.json" "$out_dir/daemon-session-oracle.json" <<'NODE'
const fs = require('fs');
const [tsvPath, outPath, oraclePath] = process.argv.slice(2);
const oracle = fs.existsSync(oraclePath) ? JSON.parse(fs.readFileSync(oraclePath, 'utf8')) : null;
const targetRoutes = new Set([
  'overview', 'insights', 'database', 'providers', 'projects', 'missions',
  'activity', 'chat', 'memory', 'settings', 'account', 'updates', 'support',
  'onboarding', 'pet', 'text-expansion', 'computer-use', 'mercury', 'smarthub'
]);
const routes = fs.readFileSync(tsvPath, 'utf8')
  .trim()
  .split(/\n+/)
  .filter(Boolean)
  .map((line, index) => {
    const [route, screenshot, xwininfo, windowId, navMethod, atspi] = line.split('\t');
    return {
      index,
      route,
      screenshot,
      xwininfo,
      windowId,
      action: `AT-SPI press of command palette route \"${route}\"`,
      surface: 'installed-tauri-deb-xvfb-xfce',
      targetScenario: targetRoutes.has(route),
      daemonOracleMode: oracle?.mode ?? 'missing',
      navMethod: navMethod || 'atspi-command-palette-actions',
      atspi
    };
  });
const payload = {
  generatedAt: new Date().toISOString(),
  mode: 'packaged-desktop-route-navigation',
  surface: 'installed-tauri-deb-xvfb-xfce',
  routeCount: routes.length,
  targetScenarioRoutes: routes.filter((route) => route.targetScenario).map((route) => route.route),
  daemonOracle: oracle,
  routes
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
NODE

  palette_navigate "overview" "Overview"
  for _ in $(seq 1 7); do
    xdotool key --clearmodifiers ctrl+plus
    sleep 0.1
  done
  sleep 0.7
  scrot "$out_dir/screenshot-linux-desktop-zoom-200-requested.png"
  python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
    --application OpenBurnBar \
    --mode summary \
    --route overview \
    --expected-name Overview \
    --output "$out_dir/atspi-zoom-200-requested.json"
  node - "$out_dir/zoom-accessibility-evidence.json" <<'ZOOM'
const fs = require('fs');
const output = process.argv[2];
const result = {
  generatedAt: new Date().toISOString(),
  method: 'packaged-webkitgtk-keyboard-zoom',
  keyboardShortcut: 'Ctrl+plus',
  incrementCount: 7,
  requestedApproximatePercent: 200,
  exactScaleObservable: false,
  screenshot: 'screenshot-linux-desktop-zoom-200-requested.png',
  atspiSummary: 'atspi-zoom-200-requested.json',
  pass: true
};
fs.writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
ZOOM
  xdotool key --clearmodifiers ctrl+0 || true
  sleep 0.3

  refresh_tray_item_handles() {
    local prefix="$1"
    local registered_file="$out_dir/${prefix}-registered-items.txt"
    local registered_err="$out_dir/${prefix}-registered-items.err"
    local introspection_file="$out_dir/${prefix}-status-notifier-introspection.txt"
    local menu_property_file="$out_dir/${prefix}-menu-property.txt"
    local menu_layout_file="$out_dir/${prefix}-menu-layout.txt"

    for _ in $(seq 1 80); do
      if gdbus call --session \
        --dest org.kde.StatusNotifierWatcher \
        --object-path /StatusNotifierWatcher \
        --method org.freedesktop.DBus.Properties.Get \
        org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems \
        >"$registered_file" 2>"$registered_err"; then
        if grep -Eq "/(StatusNotifierItem|NotificationItem)/" "$registered_file"; then
          break
        fi
      fi
      sleep 0.25
    done
    if ! grep -Eq "/(StatusNotifierItem|NotificationItem)/" "$registered_file"; then
      echo "No StatusNotifier/AppIndicator item registered in the XFCE/AppIndicator session" >&2
      cat "$registered_file" >&2 || true
      cat "$registered_err" >&2 || true
      exit 1
    fi

    refreshed_item_spec="$(node -e "const fs=require('fs'); const text=fs.readFileSync(process.argv[1], 'utf8'); const m=text.match(/'(:[^']+\\/(?:org\\/kde\\/StatusNotifierItem|org\\/ayatana\\/NotificationItem)[^']*)'/); if(!m) process.exit(1); console.log(m[1]);" "$registered_file")"
    refreshed_item_service="${refreshed_item_spec%%/*}"
    refreshed_item_path="/${refreshed_item_spec#*/}"
    if [[ "$refreshed_item_spec" == "$refreshed_item_path" ]]; then
      echo "Could not split StatusNotifierItem spec: $refreshed_item_spec" >&2
      exit 1
    fi

    gdbus introspect --session --dest "$refreshed_item_service" --object-path "$refreshed_item_path" >"$introspection_file"
    gdbus call --session \
      --dest "$refreshed_item_service" \
      --object-path "$refreshed_item_path" \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierItem Menu \
      >"$menu_property_file"
    refreshed_menu_path="$(node -e "const fs=require('fs'); const text=fs.readFileSync(process.argv[1], 'utf8'); const m=text.match(/'([^']+)'/); if(!m) process.exit(1); console.log(m[1]);" "$menu_property_file")"
    gdbus call --session \
      --dest "$refreshed_item_service" \
      --object-path "$refreshed_menu_path" \
      --method com.canonical.dbusmenu.GetLayout 0 100 "[]" \
      >"$menu_layout_file"
  }

  capture_tray_menu_actions() {
    local layout_file="$1"
    local actions_file="$2"
    local env_file="$3"
    node - "$layout_file" "$actions_file" "$env_file" <<'NODE'
const fs = require('fs');
const layout = fs.readFileSync(process.argv[2], 'utf8');
const actions = [];
const re = /<\((\d+), \{[^)]*?'label': <'([^']+)'>/g;
let match;
while ((match = re.exec(layout))) {
  actions.push({ id: Number(match[1]), label: match[2] });
}
const byLabel = (needle) => actions.find((action) => action.label.toLowerCase().includes(needle))?.id;
const env = {
  QUICK_STATUS_ID: byLabel('open quick status'),
  OPEN_ID: byLabel('open dashboard'),
  CHAT_ID: byLabel('open chat'),
  PROVIDERS_ID: byLabel('open providers'),
  UPDATES_ID: byLabel('check updates'),
  LOGIN_START_ID: byLabel('start at login'),
  RECONNECT_ID: byLabel('reconnect daemon'),
  QUIT_ID: byLabel('quit openburnbar')
};
fs.writeFileSync(process.argv[3], JSON.stringify({ actions, selected: env }, null, 2) + '\n');
for (const [key, value] of Object.entries(env)) {
  if (typeof value !== 'number') {
    console.error(`Missing tray menu item ${key}`);
    process.exit(1);
  }
}
fs.writeFileSync(process.argv[4], Object.entries(env).map(([key, value]) => `${key}=${value}`).join('\n') + '\n');
NODE
  }

  refresh_tray_item_handles tray
  item_spec="$refreshed_item_spec"
  item_service="$refreshed_item_service"
  item_path="$refreshed_item_path"
  menu_path="$refreshed_menu_path"
  capture_tray_menu_actions "$out_dir/tray-menu-layout.txt" "$out_dir/tray-menu-actions.json" "$work_dir/tray-menu.env"
  # shellcheck disable=SC1091
  source "$work_dir/tray-menu.env"

  send_menu_event() {
    local menu_id="$1"
    dbus-send --session \
      --dest="$item_service" \
      --type=method_call \
      --print-reply \
      "$menu_path" \
      com.canonical.dbusmenu.Event \
      int32:"$menu_id" \
      string:"clicked" \
      variant:string:"" \
      uint32:0
  }

  list_installed_app_pids() {
    local candidate exe
    for candidate in /proc/[0-9]*; do
      exe="$(readlink -f "$candidate/exe" 2>/dev/null || true)"
      if [[ "$exe" == "$installed_bin_real" ]]; then
        basename "$candidate"
      fi
    done | sort -n
  }

  capture_native_status_window() {
    : >"$out_dir/tray-quick-status-menu-event.txt"
    {
      echo "== open quick status =="
      send_menu_event "$QUICK_STATUS_ID"
    } >"$out_dir/tray-quick-status-menu-event.txt" 2>&1

    status_window_id=""
    for _ in $(seq 1 80); do
      status_window_id="$(xdotool search --onlyvisible --name "OpenBurnBar Status" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$status_window_id" ]]; then
        break
      fi
      sleep 0.1
    done
    if [[ -z "$status_window_id" ]]; then
      echo "Open quick status did not show the native status window" >&2
      exit 1
    fi

    xdotool windowactivate --sync "$status_window_id" 2>/dev/null || xdotool windowactivate "$status_window_id"
    xdotool windowfocus --sync "$status_window_id" 2>/dev/null || true
    sleep 0.5
    xwininfo -id "$status_window_id" >"$out_dir/native-status-window-xwininfo.txt"
    scrot -u "$out_dir/screenshot-native-status-window.png"
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode summary \
      --route native-status \
      --expected-name "Quick status" \
      --output "$out_dir/native-status-window-atspi-summary.json"
    xdotool key --clearmodifiers Tab
    sleep 0.5
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode focus \
      --route native-status \
      --output "$out_dir/native-status-window-focus.json"

    xdotool key --clearmodifiers Escape || true
    sleep 0.5
    status_closed=false
    status_close_method=escape
    if xdotool search --onlyvisible --name "OpenBurnBar Status" >/dev/null 2>&1; then
      status_close_method=windowclose
      xdotool windowclose "$status_window_id" 2>/dev/null || true
      for _ in $(seq 1 40); do
        if ! xdotool search --onlyvisible --name "OpenBurnBar Status" >/dev/null 2>&1; then
          status_closed=true
          break
        fi
        sleep 0.1
      done
    else
      status_closed=true
    fi

    node - \
      "$out_dir/native-status-window-report.json" \
      "$out_dir/native-status-window-a11y.json" \
      "$out_dir/native-status-window-xwininfo.txt" \
      "$out_dir/screenshot-native-status-window.png" \
      "$out_dir/native-status-window-atspi-summary.json" \
      "$out_dir/native-status-window-focus.json" \
      "$status_window_id" \
      "$status_closed" \
      "$status_close_method" <<'STATUS'
const fs = require('fs');
const [
  reportPath,
  a11yPath,
  xwininfoPath,
  screenshotPath,
  summaryPath,
  focusPath,
  windowId,
  closedText,
  closeMethod
] = process.argv.slice(2);
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const summary = readJson(summaryPath);
const focus = readJson(focusPath);
const screenshotBytes = fs.statSync(screenshotPath).size;
const xwininfo = fs.readFileSync(xwininfoPath, 'utf8');
const closed = closedText === 'true';
const a11y = {
  schemaVersion: 1,
  passed: summary.pass === true && focus.pass === true,
  keyboard: focus.pass === true,
  assistiveTechnology: summary.pass === true,
  summary: 'native-status-window-atspi-summary.json',
  focus: 'native-status-window-focus.json',
  nodeCount: summary.nodeCount,
  namedNodeCount: summary.namedNodeCount,
  actionableNodeCount: summary.actionableNodeCount,
  focusedNodes: focus.focusedNodes ?? []
};
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: a11y.passed && closed && screenshotBytes >= 256 && /OpenBurnBar Status/.test(xwininfo),
  windowId,
  title: 'OpenBurnBar Status',
  screenshot: 'screenshot-native-status-window.png',
  screenshotBytes,
  openedFrom: 'tray-open-quick-status-dbusmenu',
  closed,
  closeMethod,
  accessibility: a11y
};
fs.writeFileSync(a11yPath, JSON.stringify(a11y, null, 2) + '\n');
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ report, a11y }, null, 2));
if (!report.passed) process.exit(1);
STATUS
  }

  activate_tray_route_action() {
    local menu_id="$1"
    local route="$2"
    local action="$3"
    local event_file="$4"
    local expected_name="$5"
    local offset
    offset="$(sample_file_offset)"
    {
      echo "== route=$route action=$action =="
      send_menu_event "$menu_id"
    } >"$event_file" 2>&1
    if ! wait_for_new_route_sample "$route" "$offset"; then
      echo "Tray action $action did not produce a fresh route.navigation sample for $route" >&2
      exit 1
    fi
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode summary \
      --route "$route" \
      --expected-name "$expected_name" \
      --output "$out_dir/atspi-tray-route-${route}.json"
  }

  capture_native_status_window

  tray_open_samples=()
  reopened_window_id="$window_id"
  : >"$out_dir/tray-open-menu-event.txt"
  for sample_index in $(seq 1 10); do
    xdotool windowunmap "$reopened_window_id"
    for _ in $(seq 1 50); do
      if ! xdotool search --onlyvisible --name OpenBurnBar >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    tray_open_start_ms="$(date +%s%3N)"
    tray_open_route_offset="$(sample_file_offset)"
    {
      echo "== sample $sample_index =="
      send_menu_event "$OPEN_ID"
    } >>"$out_dir/tray-open-menu-event.txt" 2>&1
    reopened_window_id=""
    for _ in $(seq 1 80); do
      reopened_window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
      if [[ -n "$reopened_window_id" ]]; then
        break
      fi
      sleep 0.1
    done
    if [[ -z "$reopened_window_id" ]]; then
      echo "Tray Open dashboard action did not reopen the window for sample $sample_index" >&2
      exit 1
    fi
    if ! wait_for_new_route_sample overview "$tray_open_route_offset"; then
      echo "Tray Open dashboard action did not produce a fresh overview route sample for sample $sample_index" >&2
      exit 1
    fi
    tray_open_samples+=("$(( $(date +%s%3N) - tray_open_start_ms ))")
  done
  xwininfo -id "$reopened_window_id" >"$out_dir/window-after-tray-open-xwininfo.txt"
  scrot "$out_dir/screenshot-linux-desktop-after-tray-open.png"

  activate_tray_route_action "$CHAT_ID" chat "open-chat" "$out_dir/tray-chat-menu-event.txt" "Chat / Hermes"
  activate_tray_route_action "$PROVIDERS_ID" providers "open-providers" "$out_dir/tray-providers-menu-event.txt" "Providers & models"
  activate_tray_route_action "$UPDATES_ID" updates "open-updates" "$out_dir/tray-updates-menu-event.txt" "Updates"

  login_autostart_file="$XDG_CONFIG_HOME/autostart/dev.openburnbar.OpenBurnBar.desktop"
  rm -f "$login_autostart_file"
  : >"$out_dir/tray-login-start-menu-event.txt"
  {
    echo "== enable start at login =="
    send_menu_event "$LOGIN_START_ID"
  } >>"$out_dir/tray-login-start-menu-event.txt" 2>&1
  login_start_enabled=false
  for _ in $(seq 1 40); do
    if [[ -s "$login_autostart_file" ]]; then
      login_start_enabled=true
      break
    fi
    sleep 0.1
  done
  if [[ "$login_start_enabled" != true ]]; then
    echo "Tray Start at login action did not create $login_autostart_file" >&2
    exit 1
  fi
  cp "$login_autostart_file" "$out_dir/native-login-start-enabled.desktop"
  {
    echo "== disable start at login =="
    send_menu_event "$LOGIN_START_ID"
  } >>"$out_dir/tray-login-start-menu-event.txt" 2>&1
  login_start_disabled=false
  for _ in $(seq 1 40); do
    if [[ ! -e "$login_autostart_file" ]]; then
      login_start_disabled=true
      break
    fi
    sleep 0.1
  done
  if [[ "$login_start_disabled" != true ]]; then
    echo "Tray Start at login action did not remove $login_autostart_file" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$login_autostart_file")"
  printf '%s\n' "[Desktop Entry]" "Name=stale OpenBurnBar test entry" "Exec=/tmp/stale-openburnbar" >"$login_autostart_file"
  {
    echo "== replace stale start-at-login file =="
    send_menu_event "$LOGIN_START_ID"
  } >>"$out_dir/tray-login-start-menu-event.txt" 2>&1
  login_start_stale_replaced=false
  for _ in $(seq 1 40); do
    if [[ -s "$login_autostart_file" ]] && grep -q "openburnbar-linux-desktop" "$login_autostart_file" && ! grep -q "stale-openburnbar" "$login_autostart_file"; then
      login_start_stale_replaced=true
      break
    fi
    sleep 0.1
  done
  if [[ "$login_start_stale_replaced" != true ]]; then
    echo "Tray Start at login action did not replace stale autostart file" >&2
    exit 1
  fi
  cp "$login_autostart_file" "$out_dir/native-login-start-stale-replaced.desktop"
  node - \
    "$out_dir/native-login-start-roundtrip.json" \
    "$login_autostart_file" \
    "$login_start_enabled" \
    "$login_start_disabled" \
    "$login_start_stale_replaced" <<'LOGIN'
const fs = require('fs');
const [outPath, autostartFile, enabledText, disabledText, staleText] = process.argv.slice(2);
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: false,
  enabled: enabledText === 'true',
  disabled: disabledText === 'true',
  relogin: false,
  staleFileReplaced: staleText === 'true',
  finalEnabled: fs.existsSync(autostartFile),
  uninstallRemoved: false,
  autostartFile,
  reloginArtifact: 'native-login-start-relogin.json',
  note: 'Installed session proves tray enable, disable, and stale replacement. Fresh-session relogin and package-owned uninstall proof are merged by the outer lifecycle finalizer.'
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
LOGIN

  daemon_log="$out_dir/daemon-socket-gui-session.log"
  if [[ -f "$out_dir/daemon-shell-session.log" ]]; then
    daemon_log="$out_dir/daemon-shell-session.log"
  fi
  ipc_health_roundtrip_samples=()
  : >"$out_dir/tray-reconnect-menu-event.txt"
  for sample_index in $(seq 1 10); do
    before_reconnect_lines="$(wc -l <"$daemon_log" 2>/dev/null || echo 0)"
    reconnect_start_ms="$(date +%s%3N)"
    reconnect_route_offset="$(sample_file_offset)"
    {
      echo "== sample $sample_index =="
      send_menu_event "$RECONNECT_ID"
    } >>"$out_dir/tray-reconnect-menu-event.txt" 2>&1
    if ! wait_for_new_route_sample support "$reconnect_route_offset"; then
      echo "Tray Reconnect daemon action did not produce a fresh support route sample for sample $sample_index" >&2
      exit 1
    fi
    reconnect_observed=false
    for _ in $(seq 1 80); do
      current_lines="$(wc -l <"$daemon_log" 2>/dev/null || echo 0)"
      if [[ "$current_lines" -gt "$before_reconnect_lines" ]]; then
        reconnect_observed=true
        break
      fi
      sleep 0.1
    done
    if [[ "$reconnect_observed" != true ]]; then
      echo "Tray Reconnect daemon action produced no daemon activity for sample $sample_index" >&2
      exit 1
    fi
    ipc_health_roundtrip_samples+=("$(( $(date +%s%3N) - reconnect_start_ms ))")
  done

  deep_link_start_ms="$(date +%s%3N)"
  deep_link_route_offset="$(sample_file_offset)"
  "$installed_bin" "openburnbar://chat" >>"$out_dir/openburnbar-linux-desktop.stdout.log" 2>>"$out_dir/openburnbar-linux-desktop.stderr.log" &
  deep_link_pid="$!"
  deep_link_secondary_exited=false
  for _ in $(seq 1 80); do
    if ! kill -0 "$deep_link_pid" 2>/dev/null; then
      deep_link_secondary_exited=true
      break
    fi
    sleep 0.1
  done
  if [[ "$deep_link_secondary_exited" != true ]]; then
    kill "$deep_link_pid" 2>/dev/null || true
    wait "$deep_link_pid" 2>/dev/null || true
    echo "Secondary openburnbar://chat launch did not exit after single-instance handoff" >&2
    exit 1
  fi
  wait "$deep_link_pid" 2>/dev/null || true
  deep_link_routed=false
  if wait_for_new_route_sample chat "$deep_link_route_offset"; then
    deep_link_routed=true
  fi
  deep_link_existing_alive=false
  if kill -0 "$app_pid" 2>/dev/null; then
    deep_link_existing_alive=true
  fi
  deep_link_window_count="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | wc -l | tr -d ' ')"
  deep_link_process_count="$(list_installed_app_pids | wc -l | tr -d ' ')"
  deep_link_duration_ms="$(( $(date +%s%3N) - deep_link_start_ms ))"
  node - \
    "$out_dir/native-deep-link-relaunch.json" \
    "$deep_link_routed" \
    "$deep_link_existing_alive" \
    "$deep_link_secondary_exited" \
    "$deep_link_window_count" \
    "$deep_link_process_count" \
    "$deep_link_duration_ms" <<'DEEPLINK'
const fs = require('fs');
const [
  outPath,
  routedText,
  existingAliveText,
  secondaryExitedText,
  windowCountText,
  processCountText,
  durationText
] = process.argv.slice(2);
const windowCount = Number(windowCountText);
const processCount = Number(processCountText);
const routed = routedText === 'true';
const existingAlive = existingAliveText === 'true';
const secondaryExited = secondaryExitedText === 'true';
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: routed && existingAlive && secondaryExited && processCount === 1 && windowCount === 1,
  sameProcess: existingAlive && secondaryExited && processCount === 1,
  route: 'chat',
  action: 'open-chat',
  uri: 'openburnbar://chat',
  focusedExistingWindow: windowCount === 1,
  secondaryProcessExited: secondaryExited,
  processCount,
  windowCount,
  durationMs: Number(durationText)
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.passed) process.exit(1);
DEEPLINK

  capture_tray_host_loss_recovery() {
    local original_item_spec="$item_spec"
    local original_menu_path="$menu_path"
    local host_loss_observed=false
    local recovery_registered=false
    local recovered_action=false
    local recovered_window_count=0
    local recovered_process_count=0
    local recovered_registered_count=0
    local recovery_route_offset

    {
      echo "== panel processes before host loss =="
      ps -ef | grep -E 'xfce4-panel|panel/plugins/(libsystray|libsntray)' | grep -v grep || true
      echo "== dbus names before host loss =="
      gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames || true
      echo "== original item =="
      printf '%s\n' "$original_item_spec"
      echo "== original menu =="
      printf '%s\n' "$original_menu_path"
    } >"$out_dir/tray-host-loss-before.txt" 2>&1

    pkill -TERM -x xfce4-panel 2>/dev/null || true
    pkill -TERM -f 'panel/plugins/(libsystray|libsntray)' 2>/dev/null || true
    for _ in $(seq 1 80); do
      if ! gdbus call --session \
        --dest org.kde.StatusNotifierWatcher \
        --object-path /StatusNotifierWatcher \
        --method org.freedesktop.DBus.Properties.Get \
        org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems \
        >"$out_dir/tray-host-loss-registered-items.txt" 2>"$out_dir/tray-host-loss-registered-items.err"; then
        host_loss_observed=true
        break
      fi
      if ! grep -Eq "/(StatusNotifierItem|NotificationItem)/" "$out_dir/tray-host-loss-registered-items.txt"; then
        host_loss_observed=true
        break
      fi
      sleep 0.1
    done
    if [[ "$host_loss_observed" != true ]]; then
      echo "StatusNotifier watcher stayed registered after tray host termination" >&2
      cat "$out_dir/tray-host-loss-registered-items.txt" >&2 || true
      exit 1
    fi

    {
      echo "== panel processes during host loss =="
      ps -ef | grep -E 'xfce4-panel|panel/plugins/(libsystray|libsntray)' | grep -v grep || true
      echo "== dbus names during host loss =="
      gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames || true
    } >"$out_dir/tray-host-loss-during.txt" 2>&1

    xfce4-panel --disable-wm-check >>"$out_dir/xfce4-panel-restart.log" 2>&1 &
    echo "$!" >"$out_dir/xfce4-panel-restart.pid"
    sleep 2
    refresh_tray_item_handles tray-recovered
    item_spec="$refreshed_item_spec"
    item_service="$refreshed_item_service"
    item_path="$refreshed_item_path"
    menu_path="$refreshed_menu_path"
    capture_tray_menu_actions "$out_dir/tray-recovered-menu-layout.txt" "$out_dir/tray-recovered-menu-actions.json" "$work_dir/tray-menu-recovered.env"
    # shellcheck disable=SC1091
    source "$work_dir/tray-menu-recovered.env"
    recovery_registered=true

    recovery_route_offset="$(sample_file_offset)"
    {
      echo "== recovered tray action =="
      send_menu_event "$OPEN_ID"
    } >"$out_dir/tray-host-loss-recovery-menu-event.txt" 2>&1
    if wait_for_new_route_sample overview "$recovery_route_offset"; then
      recovered_action=true
    fi

    recovered_window_count="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | wc -l | tr -d ' ')"
    recovered_process_count="$(list_installed_app_pids | wc -l | tr -d ' ')"
    recovered_registered_count="$(node -e "const fs=require('fs'); const text=fs.readFileSync(process.argv[1], 'utf8'); const matches=[...text.matchAll(/'(:[^']+\\/(?:org\\/kde\\/StatusNotifierItem|org\\/ayatana\\/NotificationItem)[^']*)'/g)]; console.log(matches.length);" "$out_dir/tray-recovered-registered-items.txt")"
    {
      echo "== panel processes after recovery =="
      ps -ef | grep -E 'xfce4-panel|panel/plugins/(libsystray|libsntray)' | grep -v grep || true
      echo "== dbus names after recovery =="
      gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames || true
      echo "== recovered item =="
      printf '%s\n' "$item_spec"
      echo "== recovered menu =="
      printf '%s\n' "$menu_path"
    } >"$out_dir/tray-host-loss-after.txt" 2>&1

    node - \
      "$out_dir/tray-host-loss-recovery.json" \
      "$original_item_spec" \
      "$original_menu_path" \
      "$item_spec" \
      "$menu_path" \
      "$host_loss_observed" \
      "$recovery_registered" \
      "$recovered_action" \
      "$recovered_window_count" \
      "$recovered_process_count" \
      "$recovered_registered_count" <<'HOSTLOSS'
const fs = require('fs');
const [
  outPath,
  originalItem,
  originalMenu,
  recoveredItem,
  recoveredMenu,
  hostLossObservedText,
  recoveryRegisteredText,
  recoveredActionText,
  windowCountText,
  processCountText,
  registeredCountText
] = process.argv.slice(2);
const windowCount = Number(windowCountText);
const processCount = Number(processCountText);
const registeredCount = Number(registeredCountText);
const hostLossObserved = hostLossObservedText === 'true';
const recoveryRegistered = recoveryRegisteredText === 'true';
const recoveredAction = recoveredActionText === 'true';
const staleActions = registeredCount !== 1 || processCount !== 1;
const actionAfterRecovery = {
  passed: recoveredAction,
  returned: recoveredAction,
  routeSampleObserved: recoveredAction,
  route: 'overview',
  action: 'open-dashboard',
  eventArtifact: 'tray-host-loss-recovery-menu-event.txt'
};
const hostLost = hostLossObserved;
const recovered = hostLost && recoveryRegistered && actionAfterRecovery.passed;
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: recovered && windowCount >= 1 && !staleActions,
  hostLost,
  recovered,
  staleActions,
  hostLossObserved,
  recoveryRegistered,
  recoveredAction,
  actionAfterRecovery,
  originalItem,
  originalMenu,
  recoveredItem,
  recoveredMenu,
  registeredItemCountAfterRecovery: registeredCount,
  processCount,
  windowCount,
  action: 'open-dashboard',
  route: 'overview',
  artifacts: {
    before: 'tray-host-loss-before.txt',
    during: 'tray-host-loss-during.txt',
    after: 'tray-host-loss-after.txt',
    lostRegisteredItems: 'tray-host-loss-registered-items.txt',
    recoveredRegisteredItems: 'tray-recovered-registered-items.txt',
    recoveredMenuActions: 'tray-recovered-menu-actions.json',
    recoveredMenuEvent: 'tray-host-loss-recovery-menu-event.txt'
  }
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.passed) process.exit(1);
HOSTLOSS
  }

  capture_tray_host_loss_recovery

  quit_start_ms="$(date +%s%3N)"
  send_menu_event "$QUIT_ID" >"$out_dir/tray-quit-menu-event.txt" 2>&1
  for _ in $(seq 1 80); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$app_pid" 2>/dev/null; then
    echo "Tray Quit action did not terminate OpenBurnBar" >&2
    exit 1
  fi
  tray_quit_ms="$(( $(date +%s%3N) - quit_start_ms ))"
  node - \
    "$out_dir/tray-action-route-results.json" \
    "$login_start_enabled" \
    "$login_start_disabled" \
    "$login_start_stale_replaced" \
    "$tray_quit_ms" <<'TRAYRESULTS'
const fs = require('fs');
const [outPath, loginEnabledText, loginDisabledText, staleReplacedText, quitMsText] = process.argv.slice(2);
const loginStart = {
  passed: loginEnabledText === 'true' && loginDisabledText === 'true' && staleReplacedText === 'true',
  enabled: loginEnabledText === 'true',
  disabled: loginDisabledText === 'true',
  staleFileReplaced: staleReplacedText === 'true',
  enabledArtifact: 'native-login-start-enabled.desktop',
  staleReplacedArtifact: 'native-login-start-stale-replaced.desktop'
};
const actions = {
  openDashboard: {
    passed: true,
    route: 'overview',
    action: 'open-dashboard',
    routeSampleObserved: true,
    eventArtifact: 'tray-open-menu-event.txt',
    screenshot: 'screenshot-linux-desktop-after-tray-open.png'
  },
  openChat: {
    passed: true,
    route: 'chat',
    action: 'open-chat',
    routeSampleObserved: true,
    eventArtifact: 'tray-chat-menu-event.txt',
    atspiSummary: 'atspi-tray-route-chat.json'
  },
  openProviders: {
    passed: true,
    route: 'providers',
    action: 'open-providers',
    routeSampleObserved: true,
    eventArtifact: 'tray-providers-menu-event.txt',
    atspiSummary: 'atspi-tray-route-providers.json'
  },
  openUpdates: {
    passed: true,
    route: 'updates',
    action: 'open-updates',
    routeSampleObserved: true,
    eventArtifact: 'tray-updates-menu-event.txt',
    atspiSummary: 'atspi-tray-route-updates.json'
  },
  reconnectDaemon: {
    passed: true,
    route: 'support',
    action: 'reconnect-daemon',
    routeSampleObserved: true,
    daemonActivityObserved: true,
    eventArtifact: 'tray-reconnect-menu-event.txt'
  },
  loginStart,
  quit: {
    passed: true,
    exited: true,
    durationMs: Number(quitMsText),
    eventArtifact: 'tray-quit-menu-event.txt'
  }
};
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: Object.values(actions).every((action) => action.passed === true),
  actions
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.passed) process.exit(1);
TRAYRESULTS

  # Add nine warm relaunches to the first cold launch. The process is fully
  # terminated between samples, and each sample ends only when the real X11
  # window becomes visible.
  for sample_index in $(seq 2 10); do
    relaunch_start_ms="$(date +%s%3N)"
    "$installed_bin" >>"$out_dir/openburnbar-linux-desktop.stdout.log" 2>>"$out_dir/openburnbar-linux-desktop.stderr.log" &
    relaunch_pid="$!"
    relaunch_window_id=""
    for _ in $(seq 1 120); do
      relaunch_window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
      if [[ -n "$relaunch_window_id" ]]; then
        break
      fi
      if ! kill -0 "$relaunch_pid" 2>/dev/null; then
        echo "OpenBurnBar exited during startup sample $sample_index" >&2
        exit 1
      fi
      sleep 0.25
    done
    if [[ -z "$relaunch_window_id" ]]; then
      echo "Startup sample $sample_index never produced a visible window" >&2
      kill "$relaunch_pid" 2>/dev/null || true
      exit 1
    fi
    app_start_samples+=("$(( $(date +%s%3N) - relaunch_start_ms ))")
    kill "$relaunch_pid" 2>/dev/null || true
    wait "$relaunch_pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! xdotool search --onlyvisible --name OpenBurnBar >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  done

  app_start_samples_json="$(IFS=,; echo "[${app_start_samples[*]}]")"
  tray_open_samples_json="$(IFS=,; echo "[${tray_open_samples[*]}]")"
  ipc_health_roundtrip_samples_json="$(IFS=,; echo "[${ipc_health_roundtrip_samples[*]}]")"

  {
    echo "== dbus names after app =="
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames
  } >"$out_dir/dbus-after-app.txt" 2>&1 || true

  node - "$out_dir/linux-desktop-session-report.json" "$out_dir" <<NODE
const fs = require('fs');
const outDir = process.argv[3];
const summarize = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const percentile = (quantile) => {
    const position = quantile * (sorted.length - 1);
    const lower = Math.floor(position);
    const upper = Math.ceil(position);
    return lower === upper
      ? sorted[lower]
      : sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
  };
  return {
    minimum: sorted[0],
    p50: percentile(0.50),
    p95: percentile(0.95),
    p99: percentile(0.99),
    maximum: sorted[sorted.length - 1]
  };
};
const appStartSamples = $app_start_samples_json;
const trayClickOpenSamples = $tray_open_samples_json;
const ipcHealthRoundTripSamples = $ipc_health_roundtrip_samples_json;
const report = {
  generatedAt: new Date().toISOString(),
  profile: 'dbus-x11-xvfb-xfce-statusnotifier',
  package: {
    name: '$pkg',
    version: fs.readFileSync(outDir + '/package-version.txt', 'utf8').trim(),
    executable: '$installed_bin',
    daemonExecutable: fs.readFileSync(outDir + '/package-daemon-path.txt', 'utf8').trim(),
    shellVersionReadback: fs.readFileSync(outDir + '/shell-version-readback.txt', 'utf8').trim(),
    daemonHealthReadback: JSON.parse(fs.readFileSync(outDir + '/daemon-health-readback.json', 'utf8'))
  },
  session: {
    display: process.env.DISPLAY,
    xdgSessionType: process.env.XDG_SESSION_TYPE,
    desktop: process.env.XDG_CURRENT_DESKTOP,
    statusNotifierItem: '$item_spec',
    menuPath: '$menu_path',
    windowId: '$window_id',
    reopenedWindowId: '$reopened_window_id'
  },
  performance: {
    appStartMs: summarize(appStartSamples).p95,
    trayClickOpenMs: summarize(trayClickOpenSamples).p95,
    ipcHealthRoundTripMs: summarize(ipcHealthRoundTripSamples).p95,
    appStartSamples,
    trayClickOpenSamples,
    ipcHealthRoundTripSamples,
    appStartPercentiles: summarize(appStartSamples),
    trayClickOpenPercentiles: summarize(trayClickOpenSamples),
    ipcHealthRoundTripPercentiles: summarize(ipcHealthRoundTripSamples),
    trayQuitMs: Number('$tray_quit_ms')
  },
  accessibility: {
    atspiTree: JSON.parse(fs.readFileSync(outDir + '/atspi-tree-linux-desktop.json', 'utf8')),
    keyboardFocus: JSON.parse(fs.readFileSync(outDir + '/atspi-keyboard-focus-sequence.json', 'utf8')),
    zoom: JSON.parse(fs.readFileSync(outDir + '/zoom-accessibility-evidence.json', 'utf8')),
    orcaVersion: fs.readFileSync(outDir + '/orca-version.txt', 'utf8').trim(),
    orcaApplications: fs.readFileSync(outDir + '/orca-applications.txt', 'utf8').trim(),
    orcaProcessObserved: fs.readFileSync(outDir + '/orca-process.txt', 'utf8').trim().length > 0
  },
  evidence: {
    firstRunScreenshot: 'screenshot-linux-desktop-first-run.png',
    afterTrayOpenScreenshot: 'screenshot-linux-desktop-after-tray-open.png',
    nativeStatusWindowScreenshot: 'screenshot-native-status-window.png',
    packagedRouteTranscript: 'packaged-route-session-transcript.json',
    runtimePerfSamples: 'runtime-perf-samples.jsonl',
    daemonSocketLog: fs.existsSync(outDir + '/daemon-shell-session.log') ? 'daemon-shell-session.log' : 'daemon-socket-gui-session.log',
    trayMenuLayout: 'tray-menu-layout.txt',
    trayMenuActions: 'tray-menu-actions.json',
    trayActionRouteResults: 'tray-action-route-results.json',
    nativeStatusWindowReport: 'native-status-window-report.json',
    nativeStatusWindowA11y: 'native-status-window-a11y.json',
    nativeNotificationCapabilities: 'native-notification-capabilities.json',
    nativeNotificationActionResult: 'native-notification-action-result.json',
    nativeNotificationResponseResult: 'native-notification-response-result.json',
    nativeNotificationRelaunchRoute: 'native-notification-relaunch-route.json',
    nativeDeepLinkRelaunch: 'native-deep-link-relaunch.json',
    nativeLoginStartRoundtrip: 'native-login-start-roundtrip.json',
    trayHostLossRecovery: 'tray-host-loss-recovery.json',
    accessibilitySnapshot: 'accessibility-tree-linux-desktop.txt',
    atspiTree: 'atspi-tree-linux-desktop.json',
    atspiFocusSequence: 'atspi-keyboard-focus-sequence.json',
    orcaDebugLog: 'orca-debug.log',
    zoomScreenshot: 'screenshot-linux-desktop-zoom-200-requested.png',
    zoomAtspiSummary: 'atspi-zoom-200-requested.json'
  }
};
fs.writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
NODE
  exit 0
fi

if [[ "${1:-}" == "login-start-inner" ]]; then
  shift
  pkg="$1"
  installed_bin="$2"
  out_dir="$3"
  work_dir="$4"
  socket_path="$5"
  installed_bin_real="$(readlink -f "$installed_bin" 2>/dev/null || printf '%s' "$installed_bin")"

  export HOME="$work_dir/home"
  export XDG_RUNTIME_DIR="$work_dir/login-runtime"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_CONFIG_HOME="$HOME/.config"
  export DISPLAY=:100
  export XDG_SESSION_TYPE=x11
  export XDG_CURRENT_DESKTOP=XFCE
  export GDK_BACKEND=x11
  export LIBGL_ALWAYS_SOFTWARE=1
  export WEBKIT_DISABLE_COMPOSITING_MODE=1
  export ACCESSIBILITY_ENABLED=1
  export GSETTINGS_BACKEND=memory
  export OPENBURNBAR_SOCKET_PATH="$socket_path"
  export OPENBURNBAR_EVIDENCE_OUT="$out_dir"
  unset OPENBURNBAR_NATIVE_NOTIFICATION_EVIDENCE
  unset NO_AT_BRIDGE

  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 700 "$XDG_RUNTIME_DIR"

  cleanup_login_inner() {
    jobs -pr | xargs -r kill 2>/dev/null || true
  }
  trap cleanup_login_inner EXIT

  Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp >"$out_dir/login-start-xvfb.log" 2>&1 &
  for _ in $(seq 1 50); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  xdpyinfo -display "$DISPLAY" >"$out_dir/login-start-x11-display-info.txt"
  openbox >"$out_dir/login-start-openbox.log" 2>&1 &
  xfce4-panel --disable-wm-check >"$out_dir/login-start-xfce4-panel.log" 2>&1 &
  sleep 2

  login_autostart_file="$XDG_CONFIG_HOME/autostart/dev.openburnbar.OpenBurnBar.desktop"
  if [[ ! -s "$login_autostart_file" ]]; then
    echo "Login-start lifecycle could not find enabled autostart file: $login_autostart_file" >&2
    exit 1
  fi
  autostart_exec="$(grep -E '^Exec=' "$login_autostart_file" | head -n 1 | cut -d= -f2-)"
  if [[ "$autostart_exec" != "openburnbar-linux-desktop --background" ]]; then
    echo "Unexpected autostart Exec line: $autostart_exec" >&2
    exit 1
  fi
  printf '%s\n' "$autostart_exec" >"$out_dir/native-login-start-autostart-exec.txt"

  list_installed_app_pids() {
    local candidate exe
    for candidate in /proc/[0-9]*; do
      exe="$(readlink -f "$candidate/exe" 2>/dev/null || true)"
      if [[ "$exe" == "$installed_bin_real" ]]; then
        basename "$candidate"
      fi
    done | sort -n
  }
  sample_file_offset() {
    wc -c <"$out_dir/runtime-perf-samples.jsonl" 2>/dev/null || echo 0
  }
  wait_for_new_route_sample() {
    local route="$1"
    local offset="$2"
    for _ in $(seq 1 80); do
      if [[ -f "$out_dir/runtime-perf-samples.jsonl" ]] && \
        tail -c "+$((offset + 1))" "$out_dir/runtime-perf-samples.jsonl" 2>/dev/null | \
          grep -q "packaged-ui-route-after-paint:${route}"; then
        return 0
      fi
      sleep 0.1
    done
    return 1
  }

  "$installed_bin" --background >"$out_dir/native-login-start-relogin.stdout.log" 2>"$out_dir/native-login-start-relogin.stderr.log" &
  app_pid="$!"
  background_process_started=false
  hidden_background_window=true
  for _ in $(seq 1 80); do
    if kill -0 "$app_pid" 2>/dev/null; then
      background_process_started=true
      break
    fi
    sleep 0.1
  done
  for _ in $(seq 1 10); do
    if xdotool search --onlyvisible --name OpenBurnBar >/dev/null 2>&1; then
      hidden_background_window=false
      break
    fi
    sleep 0.1
  done

  route_offset="$(sample_file_offset)"
  "$installed_bin" "openburnbar://chat" >>"$out_dir/native-login-start-relogin.stdout.log" 2>>"$out_dir/native-login-start-relogin.stderr.log" &
  secondary_pid="$!"
  secondary_exited=false
  for _ in $(seq 1 80); do
    if ! kill -0 "$secondary_pid" 2>/dev/null; then
      secondary_exited=true
      break
    fi
    sleep 0.1
  done
  if [[ "$secondary_exited" != true ]]; then
    kill "$secondary_pid" 2>/dev/null || true
    wait "$secondary_pid" 2>/dev/null || true
  fi
  wait "$secondary_pid" 2>/dev/null || true

  routed=false
  if wait_for_new_route_sample chat "$route_offset"; then
    routed=true
  fi
  visible_after_route=false
  window_count="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$window_count" -ge 1 ]]; then
    visible_after_route=true
  fi
  process_count="$(list_installed_app_pids | wc -l | tr -d ' ')"

  node - \
    "$out_dir/native-login-start-relogin.json" \
    "$login_autostart_file" \
    "$background_process_started" \
    "$hidden_background_window" \
    "$secondary_exited" \
    "$routed" \
    "$visible_after_route" \
    "$process_count" \
    "$window_count" <<'LOGINREL'
const fs = require('fs');
const [
  outPath,
  autostartFile,
  backgroundText,
  hiddenText,
  secondaryExitedText,
  routedText,
  visibleText,
  processCountText,
  windowCountText
] = process.argv.slice(2);
const processCount = Number(processCountText);
const windowCount = Number(windowCountText);
const payload = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: backgroundText === 'true' &&
    hiddenText === 'true' &&
    secondaryExitedText === 'true' &&
    routedText === 'true' &&
    visibleText === 'true' &&
    processCount === 1,
  method: 'fresh-dbus-x11-autostart-session',
  autostartFile,
  execLine: 'openburnbar-linux-desktop --background',
  backgroundProcessStarted: backgroundText === 'true',
  hiddenBeforeRoute: hiddenText === 'true',
  secondaryProcessExited: secondaryExitedText === 'true',
  sameProcess: processCount === 1,
  route: 'chat',
  action: 'open-chat',
  routeSampleObserved: routedText === 'true',
  visibleAfterRoute: visibleText === 'true',
  processCount,
  windowCount
};
fs.writeFileSync(outPath, JSON.stringify(payload, null, 2) + '\n');
console.log(JSON.stringify(payload, null, 2));
if (!payload.passed) process.exit(1);
LOGINREL

  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  exit 0
fi

out_dir="${OB_EVIDENCE_OUT:-/evidence}"
work_dir="${OB_SESSION_WORKDIR:-/tmp/openburnbar-linux-desktop-session}"
mkdir -p "$out_dir"
rm -rf "$work_dir"
mkdir -p "$work_dir"

transcript="$out_dir/linux-deb-install-run-transcript.txt"
exec > >(tee "$transcript") 2>&1

rm -f \
  "$out_dir"/accessibility-tree-linux-desktop.txt \
  "$out_dir"/atspi-bus-address.txt \
  "$out_dir"/atspi-command-open-*.json \
  "$out_dir"/atspi-command-route-*.json \
  "$out_dir"/atspi-keyboard-focus-sequence.json \
  "$out_dir"/atspi-route-*.json \
  "$out_dir"/atspi-tray-route-*.json \
  "$out_dir"/atspi-tree-linux-desktop.json \
  "$out_dir"/atspi-zoom-200-requested.json \
  "$out_dir"/daemon-socket-gui-session.log \
  "$out_dir"/daemon-session-oracle.json \
  "$out_dir"/daemon-health-readback.json \
  "$out_dir"/dbus-after-app.txt \
  "$out_dir"/dbus-before-app.txt \
  "$out_dir"/desktop-package-provision.txt \
  "$out_dir"/desktop-package-versions.txt \
  "$out_dir"/login-start-openbox.log \
  "$out_dir"/login-start-x11-display-info.txt \
  "$out_dir"/login-start-xfce4-panel.log \
  "$out_dir"/login-start-xvfb.log \
  "$out_dir"/linux-desktop-session-report.json \
  "$out_dir"/native-deep-link-relaunch.json \
  "$out_dir"/native-global-panic-probe.stderr.log \
  "$out_dir"/native-global-panic-probe.stdout.log \
  "$out_dir"/native-global-panic-shortcut-response.json \
  "$out_dir"/native-global-panic-shortcut.json \
  "$out_dir"/native-login-start-autostart-exec.txt \
  "$out_dir"/native-login-start-enabled.desktop \
  "$out_dir"/native-login-start-relogin.json \
  "$out_dir"/native-login-start-relogin.stderr.log \
  "$out_dir"/native-login-start-relogin.stdout.log \
  "$out_dir"/native-login-start-roundtrip.json \
  "$out_dir"/native-login-start-stale-replaced.desktop \
  "$out_dir"/native-notification-action-result.json \
  "$out_dir"/native-notification-capabilities.json \
  "$out_dir"/native-notification-relaunch-route.json \
  "$out_dir"/native-notification-response-result.json \
  "$out_dir"/native-notification-server-capabilities.txt \
  "$out_dir"/native-notification-server-events.jsonl \
  "$out_dir"/native-notification-server-info.txt \
  "$out_dir"/native-notification-server-ready.json \
  "$out_dir"/native-notification-server.stderr.log \
  "$out_dir"/native-notification-server.stdout.log \
  "$out_dir"/native-status-window-a11y.json \
  "$out_dir"/native-status-window-atspi-summary.json \
  "$out_dir"/native-status-window-focus.json \
  "$out_dir"/native-status-window-report.json \
  "$out_dir"/native-status-window-xwininfo.txt \
  "$out_dir"/package-daemon-path.txt \
  "$out_dir"/package-version.txt \
  "$out_dir"/openburnbar-linux-desktop.pid \
  "$out_dir"/openburnbar-linux-desktop.stderr.log \
  "$out_dir"/openburnbar-linux-desktop.stdout.log \
  "$out_dir"/openburnbar-window-id.txt \
  "$out_dir"/orca-applications.txt \
  "$out_dir"/orca-debug.log \
  "$out_dir"/orca-list-apps.err \
  "$out_dir"/orca-process.txt \
  "$out_dir"/orca.stderr.log \
  "$out_dir"/orca.stdout.log \
  "$out_dir"/orca-version.txt \
  "$out_dir"/packaged-route-session-transcript.json \
  "$out_dir"/runtime-perf-samples.jsonl \
  "$out_dir"/shell-version-readback.txt \
  "$out_dir"/openbox.log \
  "$out_dir"/screenshot-native-status-window.png \
  "$out_dir"/screenshot-linux-desktop-after-tray-open*.png \
  "$out_dir"/screenshot-linux-desktop-first-run*.png \
  "$out_dir"/screenshot-linux-desktop-zoom-200-requested.png \
  "$out_dir"/screenshot-route-*.png \
  "$out_dir"/tray-action-route-results.json \
  "$out_dir"/tray-host-loss-*.err \
  "$out_dir"/tray-host-loss-*.txt \
  "$out_dir"/tray-host-loss-recovery.json \
  "$out_dir"/tray-host-loss-recovery-menu-event.txt \
  "$out_dir"/tray-menu-actions.json \
  "$out_dir"/tray-menu-layout.txt \
  "$out_dir"/tray-menu-property.txt \
  "$out_dir"/tray-recovered-*.err \
  "$out_dir"/tray-recovered-*.json \
  "$out_dir"/tray-recovered-*.txt \
  "$out_dir"/tray-chat-menu-event.txt \
  "$out_dir"/tray-login-start-menu-event.txt \
  "$out_dir"/tray-open-menu-event.txt \
  "$out_dir"/tray-providers-menu-event.txt \
  "$out_dir"/tray-quick-status-menu-event.txt \
  "$out_dir"/tray-quit-menu-event.txt \
  "$out_dir"/tray-reconnect-menu-event.txt \
  "$out_dir"/tray-registered-items.err \
  "$out_dir"/tray-registered-items.txt \
  "$out_dir"/tray-updates-menu-event.txt \
  "$out_dir"/tray-status-notifier-introspection.txt \
  "$out_dir"/window-after-tray-open-xwininfo.txt \
  "$out_dir"/window-initial-xprop.txt \
  "$out_dir"/window-initial-xwininfo.txt \
  "$out_dir"/window-route-*-xwininfo.txt \
  "$out_dir"/xfce4-panel-restart.log \
  "$out_dir"/xfce4-panel-restart.pid \
  "$out_dir"/x11-display-info.txt \
  "$out_dir"/xfce4-panel.log \
  "$out_dir"/xvfb.log \
  "$out_dir"/zoom-accessibility-evidence.json

echo "== profile =="
cat >"$out_dir/ci-compositor-profile.json" <<JSON
{
  "name": "dbus-x11-xvfb-xfce-statusnotifier",
  "displayServer": "X11 via Xvfb",
  "desktop": "XFCE panel in dbus-run-session",
  "trayHost": "xfce4-sntray-plugin with Ayatana AppIndicator runtime",
  "windowManager": "openbox",
  "purpose": "CI compositor profile for packaged Tauri .deb install/run/tray proof"
}
JSON
cat "$out_dir/ci-compositor-profile.json"

desktop_packages=(
  xvfb
  openbox
  xfce4-panel
  xfce4-sntray-plugin
  ayatana-indicator-application
  libayatana-appindicator3-1
  dbus-x11
  xdotool
  x11-utils
  scrot
  at-spi2-core
  python3
  python3-dbus
  python3-gi
  python3-pyatspi
  orca
)

echo "== provision desktop packages =="
missing_packages=()
for package_name in "${desktop_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q 'install ok installed'; then
    missing_packages+=("$package_name")
  fi
done
if [[ "${#missing_packages[@]}" -gt 0 ]]; then
  {
    echo "missing=${missing_packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
  } >"$out_dir/desktop-package-provision.txt" 2>&1
else
  echo "all required desktop packages already installed" >"$out_dir/desktop-package-provision.txt"
fi
cat "$out_dir/desktop-package-provision.txt"

echo "== package versions =="
dpkg-query -W -f='${binary:Package}=${Version}\n' "${desktop_packages[@]}" >"$out_dir/desktop-package-versions.txt"
cat "$out_dir/desktop-package-versions.txt"

echo "== build deb =="
if [[ "${OB_REUSE_EXISTING_DEB:-0}" == "1" ]]; then
  deb="$(find "$out_dir" -maxdepth 1 -name '*.deb' -type f | sort | head -n 1)"
  if [[ -z "$deb" ]]; then
    echo "OB_REUSE_EXISTING_DEB=1 was set, but no existing .deb was found in $out_dir" >&2
    exit 1
  fi
  echo "reusing_deb=$deb"
else
  build_root="$work_dir/build-root"
  mkdir -p "$build_root/apps" "$build_root/packages" "$build_root/scripts" "$build_root/packaging"
  cp -R "$root/apps/linux-desktop" "$build_root/apps/linux-desktop"
  # Preserve the repository-relative paths consumed by package.json, Vite,
  # the production scanner, native include_str!, and Tauri bundle resources.
  for shared_package in design-tokens entitlements gl-engine; do
    cp -R "$root/packages/$shared_package" "$build_root/packages/$shared_package"
  done
  cp -R "$root/scripts/linux-port" "$build_root/scripts/linux-port"
  cp -R "$root/packaging/linux" "$build_root/packaging/linux"
  cd "$build_root/apps/linux-desktop"
  npm ci --no-audit --no-fund
  npm run build
  npm run tauri:build -- --bundles deb
  deb="$(find src-tauri/target/release/bundle/deb -maxdepth 2 -name '*.deb' -type f | sort | head -n 1)"
fi
if [[ -z "$deb" ]]; then
  echo "No .deb bundle produced" >&2
  exit 1
fi
deb_basename="$(basename "$deb")"
if [[ "$(realpath -m "$deb")" != "$(realpath -m "$out_dir/$deb_basename")" ]]; then
  cp "$deb" "$out_dir/$deb_basename"
fi
dpkg-deb -f "$deb" >"$out_dir/linux-deb-control.txt"
dpkg-deb -c "$deb" >"$out_dir/linux-deb-contents.txt"
cat "$out_dir/linux-deb-control.txt"

echo "== install deb =="
pkg="$(dpkg-deb -f "$deb" Package)"
dpkg -i "$deb"
dpkg-query -W -f='${binary:Package}=${Version} ${Status}\n' "$pkg"
desktop_file="$(dpkg -L "$pkg" | grep '/applications/.*\.desktop$' | head -n 1 || true)"
installed_bin="$(dpkg -L "$pkg" | grep -E '/usr/bin/openburnbar-linux-desktop$' | head -n 1 || true)"
installed_daemon="$(dpkg -L "$pkg" | grep -E '/usr/bin/openburnbar-daemon$' | head -n 1 || true)"
if [[ -z "$installed_bin" || ! -x "$installed_bin" ]]; then
  echo "Could not find installed executable for $pkg" >&2
  dpkg -L "$pkg" >&2
  exit 1
fi
if [[ -z "$installed_daemon" || ! -x "$installed_daemon" ]]; then
  echo "Could not find package-owned daemon executable for $pkg" >&2
  dpkg -L "$pkg" >&2
  exit 1
fi
pkg_version="$(dpkg-query -W -f='${Version}' "$pkg")"
"$installed_bin" --version >"$out_dir/shell-version-readback.txt"
grep -F "$pkg_version" "$out_dir/shell-version-readback.txt" >/dev/null
printf '%s\n' "$installed_daemon" >"$out_dir/package-daemon-path.txt"
printf '%s\n' "$pkg_version" >"$out_dir/package-version.txt"
echo "desktop_file=${desktop_file:-missing}"
echo "installed_bin=$installed_bin"
echo "installed_daemon=$installed_daemon"
echo "package_version=$pkg_version"

echo "== daemon socket for packaged session =="
home_dir="$work_dir/home"
runtime_dir="$work_dir/runtime"
data_dir="$home_dir/.local/share/openburnbar"
mkdir -p "$data_dir" "$runtime_dir"
chmod 700 "$runtime_dir"
socket_path="$(OB_SHELL_DAEMON_BIN="$installed_daemon" OB_SHELL_DAEMON_VERSION="$pkg_version" \
  OB_SHELL_HEALTH_CLIENT_BIN="$installed_bin" \
  "$root/scripts/linux-port/start-shell-session-daemon.sh" "$root" "$out_dir" "$work_dir")"
daemon_pid="$(cat "$work_dir/daemon.pid")"
ls -l "$socket_path"
cleanup_outer() {
  kill "$daemon_pid" 2>/dev/null || true
}
trap cleanup_outer EXIT

echo "== desktop session =="
dbus-run-session -- bash "$root/scripts/linux-port/linux-desktop-session.sh" \
  desktop-inner "$pkg" "$installed_bin" "$out_dir" "$work_dir" "$socket_path"

echo "== login-start lifecycle session =="
dbus-run-session -- bash "$root/scripts/linux-port/linux-desktop-session.sh" \
  login-start-inner "$pkg" "$installed_bin" "$out_dir" "$work_dir" "$socket_path"

echo "== daemon socket log =="
if [[ -f "$out_dir/daemon-shell-session.log" ]]; then
  cat "$out_dir/daemon-shell-session.log"
else
  cat "$out_dir/daemon-socket-gui-session.log"
fi

echo "== uninstall deb =="
package_autostart_reference="/usr/share/openburnbar/autostart/openburnbar.desktop"
dpkg -r "$pkg"
if dpkg-query -W "$pkg" >/dev/null 2>&1; then
  echo "Package still installed after dpkg -r $pkg" >&2
  exit 1
fi
package_autostart_removed=false
if [[ ! -e "$package_autostart_reference" ]]; then
  package_autostart_removed=true
fi
echo "uninstall_verified=true"

node - \
  "$out_dir/linux-desktop-session-report.json" \
  "$out_dir/native-login-start-roundtrip.json" \
  "$out_dir/native-login-start-relogin.json" \
  "$deb_basename" \
  "$package_autostart_reference" \
  "$package_autostart_removed" <<'NODE'
const fs = require('fs');
const [
  reportPath,
  loginRoundtripPath,
  loginReloginPath,
  debBasename,
  packageAutostartReference,
  packageAutostartRemovedText
] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const loginRoundtrip = JSON.parse(fs.readFileSync(loginRoundtripPath, 'utf8'));
const loginRelogin = JSON.parse(fs.readFileSync(loginReloginPath, 'utf8'));
const packageAutostartRemoved = packageAutostartRemovedText === 'true';
const userAutostartPreserved = fs.existsSync(loginRoundtrip.autostartFile);
const finalizedLoginStart = {
  ...loginRoundtrip,
  generatedAt: new Date().toISOString(),
  passed: loginRoundtrip.enabled === true &&
    loginRoundtrip.disabled === true &&
    loginRoundtrip.staleFileReplaced === true &&
    loginRelogin.passed === true &&
    packageAutostartRemoved,
  relogin: loginRelogin.passed === true,
  reloginEvidence: loginRelogin,
  uninstallRemoved: packageAutostartRemoved,
  uninstallScope: 'package-owned-autostart-reference',
  packageAutostartReference,
  userAutostartPreserved
};
fs.writeFileSync(loginRoundtripPath, JSON.stringify(finalizedLoginStart, null, 2) + '\n');
report.package.uninstallVerified = true;
report.package.debArtifact = debBasename;
report.package.autostartReferenceRemoved = packageAutostartRemoved;
report.evidence.nativeLoginStartRelogin = 'native-login-start-relogin.json';
report.evidence.nativeLoginStartRoundtrip = 'native-login-start-roundtrip.json';
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ report, loginStart: finalizedLoginStart }, null, 2));
if (!finalizedLoginStart.passed) process.exit(1);
NODE

cp "$transcript" "$out_dir/linux-tauri-build-transcript.txt"
echo "linux-desktop-session-ok"
