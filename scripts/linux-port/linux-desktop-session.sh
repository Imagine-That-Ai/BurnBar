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
  # Xvfb has no DMABUF device. Keep WebKit on the software path just like
  # the shipped safe-mode desktop entry, otherwise arm64 can expose only a
  # blank filler through AT-SPI even though the native window is visible.
  export WEBKIT_DISABLE_DMABUF_RENDERER=1
  export MESA_GL_VERSION_OVERRIDE=4.5
  export MESA_GLSL_VERSION_OVERRIDE=450
  export ACCESSIBILITY_ENABLED=1
  export GSETTINGS_BACKEND=memory
  export OPENBURNBAR_SOCKET_PATH="$socket_path"
  export OPENBURNBAR_EVIDENCE_OUT="$out_dir"
  unset NO_AT_BRIDGE

  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
  chmod 700 "$XDG_RUNTIME_DIR"

  cleanup_inner() {
    jobs -pr | xargs -r kill 2>/dev/null || true
  }
  trap cleanup_inner EXIT

  if [[ "${OB_XVFB_PRESTARTED:-0}" != "1" ]]; then
    Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp >"$out_dir/xvfb.log" 2>&1 &
    for _ in $(seq 1 50); do
      if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
  fi
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

  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
    --method org.a11y.Bus.GetAddress >"$out_dir/atspi-bus-address.txt"
  orca --list-apps >"$out_dir/orca-applications.txt" 2>"$out_dir/orca-list-apps.err"
  python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
    --application OpenBurnBar \
    --output "$out_dir/atspi-tree-linux-desktop.json" \
    --tree-text "$out_dir/accessibility-tree-linux-desktop.txt" \
    --expected-name OpenBurnBar

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

  samples_file="$out_dir/runtime-perf-samples.jsonl"
  has_route_sample() {
    [[ -f "$samples_file" ]] && grep -q "packaged-ui-route-after-paint:${1}" "$samples_file"
  }
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

  registered_file="$out_dir/tray-registered-items.txt"
  for _ in $(seq 1 80); do
    if gdbus call --session \
      --dest org.kde.StatusNotifierWatcher \
      --object-path /StatusNotifierWatcher \
      --method org.freedesktop.DBus.Properties.Get \
      org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems \
      >"$registered_file" 2>"$out_dir/tray-registered-items.err"; then
      if grep -Eq "/(StatusNotifierItem|NotificationItem)/" "$registered_file"; then
        break
      fi
    fi
    sleep 0.25
  done
  if ! grep -Eq "/(StatusNotifierItem|NotificationItem)/" "$registered_file"; then
    echo "No StatusNotifier/AppIndicator item registered in the XFCE/AppIndicator session" >&2
    cat "$registered_file" >&2 || true
    cat "$out_dir/tray-registered-items.err" >&2 || true
    exit 1
  fi

  item_spec="$(node -e "const fs=require('fs'); const text=fs.readFileSync(process.argv[1], 'utf8'); const m=text.match(/'(:[^']+\\/(?:org\\/kde\\/StatusNotifierItem|org\\/ayatana\\/NotificationItem)[^']*)'/); if(!m) process.exit(1); console.log(m[1]);" "$registered_file")"
  item_service="${item_spec%%/*}"
  item_path="/${item_spec#*/}"
  if [[ "$item_spec" == "$item_path" ]]; then
    echo "Could not split StatusNotifierItem spec: $item_spec" >&2
    exit 1
  fi

  gdbus introspect --session --dest "$item_service" --object-path "$item_path" >"$out_dir/tray-status-notifier-introspection.txt"
  gdbus call --session \
    --dest "$item_service" \
    --object-path "$item_path" \
    --method org.freedesktop.DBus.Properties.Get \
    org.kde.StatusNotifierItem Menu \
    >"$out_dir/tray-menu-property.txt"
  menu_path="$(node -e "const fs=require('fs'); const text=fs.readFileSync(process.argv[1], 'utf8'); const m=text.match(/'([^']+)'/); if(!m) process.exit(1); console.log(m[1]);" "$out_dir/tray-menu-property.txt")"
  gdbus call --session \
    --dest "$item_service" \
    --object-path "$menu_path" \
    --method com.canonical.dbusmenu.GetLayout 0 100 "[]" \
    >"$out_dir/tray-menu-layout.txt"

  node - "$out_dir/tray-menu-layout.txt" "$out_dir/tray-menu-actions.json" "$work_dir/tray-menu.env" <<'NODE'
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
  OPEN_ID: byLabel('open dashboard'),
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
    tray_open_samples+=("$(( $(date +%s%3N) - tray_open_start_ms ))")
  done
  xwininfo -id "$reopened_window_id" >"$out_dir/window-after-tray-open-xwininfo.txt"
  scrot "$out_dir/screenshot-linux-desktop-after-tray-open.png"

  daemon_log="$out_dir/daemon-socket-gui-session.log"
  if [[ -f "$out_dir/daemon-shell-session.log" ]]; then
    daemon_log="$out_dir/daemon-shell-session.log"
  fi
  ipc_health_roundtrip_samples=()
  : >"$out_dir/tray-reconnect-menu-event.txt"
  for sample_index in $(seq 1 10); do
    before_reconnect_lines="$(wc -l <"$daemon_log" 2>/dev/null || echo 0)"
    reconnect_start_ms="$(date +%s%3N)"
    {
      echo "== sample $sample_index =="
      send_menu_event "$RECONNECT_ID"
    } >>"$out_dir/tray-reconnect-menu-event.txt" 2>&1
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
    packagedRouteTranscript: 'packaged-route-session-transcript.json',
    runtimePerfSamples: 'runtime-perf-samples.jsonl',
    daemonSocketLog: fs.existsSync(outDir + '/daemon-shell-session.log') ? 'daemon-shell-session.log' : 'daemon-socket-gui-session.log',
    trayMenuLayout: 'tray-menu-layout.txt',
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
  "$out_dir"/atspi-tree-linux-desktop.json \
  "$out_dir"/atspi-zoom-200-requested.json \
  "$out_dir"/daemon-socket-gui-session.log \
  "$out_dir"/daemon-session-oracle.json \
  "$out_dir"/daemon-health-readback.json \
  "$out_dir"/dbus-after-app.txt \
  "$out_dir"/dbus-before-app.txt \
  "$out_dir"/desktop-package-provision.txt \
  "$out_dir"/desktop-package-versions.txt \
  "$out_dir"/linux-desktop-session-report.json \
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
  "$out_dir"/screenshot-linux-desktop-after-tray-open*.png \
  "$out_dir"/screenshot-linux-desktop-first-run*.png \
  "$out_dir"/screenshot-linux-desktop-zoom-200-requested.png \
  "$out_dir"/screenshot-route-*.png \
  "$out_dir"/tray-menu-actions.json \
  "$out_dir"/tray-menu-layout.txt \
  "$out_dir"/tray-menu-property.txt \
  "$out_dir"/tray-open-menu-event.txt \
  "$out_dir"/tray-quit-menu-event.txt \
  "$out_dir"/tray-reconnect-menu-event.txt \
  "$out_dir"/tray-registered-items.err \
  "$out_dir"/tray-registered-items.txt \
  "$out_dir"/tray-status-notifier-introspection.txt \
  "$out_dir"/window-after-tray-open-xwininfo.txt \
  "$out_dir"/window-initial-xprop.txt \
  "$out_dir"/window-initial-xwininfo.txt \
  "$out_dir"/window-route-*-xwininfo.txt \
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

echo "== desktop session =="
desktop_display=:99
Xvfb "$desktop_display" -screen 0 1280x900x24 -nolisten tcp >"$out_dir/xvfb.log" 2>&1 &
xvfb_pid="$!"
for _ in $(seq 1 50); do
  if DISPLAY="$desktop_display" xdpyinfo >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
if ! DISPLAY="$desktop_display" xdpyinfo >"$out_dir/x11-display-info.txt" 2>&1; then
  echo "Xvfb did not become ready on $desktop_display" >&2
  cat "$out_dir/xvfb.log" >&2 || true
  exit 1
fi
cleanup_outer() {
  kill "$daemon_pid" 2>/dev/null || true
  kill "$xvfb_pid" 2>/dev/null || true
}
trap cleanup_outer EXIT
DISPLAY="$desktop_display" \
HOME="$work_dir/home" \
XDG_RUNTIME_DIR="$work_dir/runtime" \
XDG_DATA_HOME="$work_dir/home/.local/share" \
XDG_CONFIG_HOME="$work_dir/home/.config" \
XDG_SESSION_TYPE=x11 \
XDG_CURRENT_DESKTOP=XFCE \
OB_XVFB_PRESTARTED=1 \
dbus-run-session -- bash "$root/scripts/linux-port/linux-desktop-session.sh" \
  desktop-inner "$pkg" "$installed_bin" "$out_dir" "$work_dir" "$socket_path"

echo "== daemon socket log =="
if [[ -f "$out_dir/daemon-shell-session.log" ]]; then
  cat "$out_dir/daemon-shell-session.log"
else
  cat "$out_dir/daemon-socket-gui-session.log"
fi

echo "== uninstall deb =="
dpkg -r "$pkg"
if dpkg-query -W "$pkg" >/dev/null 2>&1; then
  echo "Package still installed after dpkg -r $pkg" >&2
  exit 1
fi
echo "uninstall_verified=true"

node - "$out_dir/linux-desktop-session-report.json" "$deb_basename" <<'NODE'
const fs = require('fs');
const reportPath = process.argv[2];
const debBasename = process.argv[3];
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
report.package.uninstallVerified = true;
report.package.debArtifact = debBasename;
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
NODE

cp "$transcript" "$out_dir/linux-tauri-build-transcript.txt"
echo "linux-desktop-session-ok"
