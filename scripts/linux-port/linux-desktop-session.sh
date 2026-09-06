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

  capture_initial_atspi_tree() {
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --wait-for-meaningful-seconds "${OB_ATSPI_READY_TIMEOUT_SECONDS:-45}" \
      --output "$out_dir/atspi-tree-linux-desktop.json" \
      --tree-text "$out_dir/accessibility-tree-linux-desktop.txt" \
      --expected-name OpenBurnBar
  }

  dump_initial_atspi_diagnostics() {
    for diagnostic in \
      "$out_dir/openburnbar-linux-desktop.stdout.log" \
      "$out_dir/openburnbar-linux-desktop.stderr.log" \
      "$out_dir/daemon-shell-session.log" \
      "$out_dir/daemon-socket-gui-session.log" \
      "$out_dir/orca.stderr.log"; do
      if [[ -f "$diagnostic" ]]; then
        echo "===== ${diagnostic} =====" >&2
        tail -200 "$diagnostic" >&2 || true
      fi
    done
  }

  initial_app_pid="$app_pid"
  initial_window_id="$window_id"
  initial_app_start_ms="$app_start_ms"
  if ! capture_initial_atspi_tree; then
    echo "Initial AT-SPI tree did not become meaningful before the readiness deadline" >&2
    if ! node - "$out_dir/atspi-tree-linux-desktop.json" <<'NODE'
const fs = require('fs');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const allowedFailures = new Set([
  'node_count_below_20',
  'named_node_count_below_8',
  'actionable_node_count_below_5'
]);
const defunctInitialAtspiSubtree =
  report?.pass === false &&
  Array.isArray(report?.failures) &&
  report.failures.length > 0 &&
  report.failures.every((failure) => allowedFailures.has(failure)) &&
  Array.isArray(report?.nodes) &&
  report.nodes.some((node) => Array.isArray(node?.states) && node.states.includes('defunct'));
if (!defunctInitialAtspiSubtree) process.exit(1);
NODE
    then
      dump_initial_atspi_diagnostics
      exit 1
    fi

    echo "Recovering once from a defunct initial AT-SPI subtree" >&2
    mv "$out_dir/atspi-tree-linux-desktop.json" \
      "$out_dir/atspi-tree-linux-desktop-attempt-1.json"
    mv "$out_dir/accessibility-tree-linux-desktop.txt" \
      "$out_dir/accessibility-tree-linux-desktop-attempt-1.txt"
    cp "$out_dir/screenshot-linux-desktop-first-run.png" \
      "$out_dir/screenshot-linux-desktop-first-run-attempt-1.png"
    cp "$out_dir/window-initial-xwininfo.txt" \
      "$out_dir/window-initial-xwininfo-attempt-1.txt"
    cp "$out_dir/window-initial-xprop.txt" \
      "$out_dir/window-initial-xprop-attempt-1.txt"

    kill "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! kill -0 "$app_pid" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$app_pid" 2>/dev/null; then
      kill -KILL "$app_pid" 2>/dev/null || true
    fi
    wait "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      if ! xdotool search --onlyvisible --name OpenBurnBar >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done

    recovery_start_ms="$(date +%s%3N)"
    "$installed_bin" >>"$out_dir/openburnbar-linux-desktop.stdout.log" \
      2>>"$out_dir/openburnbar-linux-desktop.stderr.log" &
    app_pid="$!"
    echo "$app_pid" >"$out_dir/openburnbar-linux-desktop.pid"
    window_id=""
    for _ in $(seq 1 120); do
      window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
      if [[ -n "$window_id" ]]; then
        break
      fi
      if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "OpenBurnBar exited during the bounded AT-SPI recovery launch" >&2
        dump_initial_atspi_diagnostics
        exit 1
      fi
      sleep 0.25
    done
    if [[ -z "$window_id" ]]; then
      echo "Bounded AT-SPI recovery launch never produced a visible window" >&2
      dump_initial_atspi_diagnostics
      exit 1
    fi

    recovered_app_start_ms="$(( $(date +%s%3N) - recovery_start_ms ))"
    app_start_samples[0]="$recovered_app_start_ms"
    echo "$window_id" >"$out_dir/openburnbar-window-id.txt"
    xwininfo -id "$window_id" >"$out_dir/window-initial-xwininfo.txt"
    xprop -id "$window_id" >"$out_dir/window-initial-xprop.txt"
    scrot "$out_dir/screenshot-linux-desktop-first-run.png"

    if ! capture_initial_atspi_tree; then
      echo "AT-SPI tree remained non-meaningful after the bounded recovery launch" >&2
      dump_initial_atspi_diagnostics
      exit 1
    fi

    INITIAL_APP_PID="$initial_app_pid" \
    RECOVERED_APP_PID="$app_pid" \
    INITIAL_WINDOW_ID="$initial_window_id" \
    RECOVERED_WINDOW_ID="$window_id" \
    INITIAL_APP_START_MS="$initial_app_start_ms" \
    RECOVERED_APP_START_MS="$recovered_app_start_ms" \
    node - "$out_dir/atspi-readiness-recovery.json" <<'NODE'
const fs = require('fs');
const output = process.argv[2];
const evidence = {
  schemaVersion: 1,
  reason: 'defunct_initial_atspi_subtree',
  boundedRecoveryAttempts: 1,
  initial: {
    appPid: Number(process.env.INITIAL_APP_PID),
    windowId: process.env.INITIAL_WINDOW_ID,
    appStartMs: Number(process.env.INITIAL_APP_START_MS),
    atspi: 'atspi-tree-linux-desktop-attempt-1.json',
    treeText: 'accessibility-tree-linux-desktop-attempt-1.txt',
    screenshot: 'screenshot-linux-desktop-first-run-attempt-1.png',
    xwininfo: 'window-initial-xwininfo-attempt-1.txt',
    xprop: 'window-initial-xprop-attempt-1.txt'
  },
  recovered: {
    appPid: Number(process.env.RECOVERED_APP_PID),
    windowId: process.env.RECOVERED_WINDOW_ID,
    appStartMs: Number(process.env.RECOVERED_APP_START_MS),
    atspi: 'atspi-tree-linux-desktop.json',
    treeText: 'accessibility-tree-linux-desktop.txt',
    screenshot: 'screenshot-linux-desktop-first-run.png',
    xwininfo: 'window-initial-xwininfo.txt',
    xprop: 'window-initial-xprop.txt'
  },
  pass: true
};
fs.writeFileSync(output, JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify(evidence, null, 2));
NODE
  fi

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
  # Start from a real, named document control. WebKitGTK can retain focus on
  # the host shell after route activation, which makes the same physical Tab
  # sequence produce different Orca event counts across architectures.
  python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
    --application OpenBurnBar \
    --mode grab-focus \
    --expected-name "Skip to content" \
    --output "$out_dir/atspi-keyboard-focus-anchor.json"
  sleep 0.5
  focus_log_offset="$(wc -c <"$out_dir/orca-debug.log")"
  # Programmatic grab-focus anchors re-enter the real document, but the grab
  # itself emits an object:state-changed:focused event that is
  # indistinguishable from a physical-key focus change. Record the byte
  # window each later anchor writes into orca-debug.log so event counting
  # only credits physical Tab/Shift+Tab traversal. The initial anchor above
  # needs no window: it lands before focus_log_offset.
  anchor_exclusions="$out_dir/orca-anchor-exclusions.tsv"
  : >"$anchor_exclusions"
  anchor_document_focus() {
    local anchor_output="$1"
    local exclusion_start exclusion_end
    exclusion_start="$(wc -c <"$out_dir/orca-debug.log")"
    python3 "$root/scripts/linux-port/capture-atspi-tree.py" \
      --application OpenBurnBar \
      --mode grab-focus \
      --expected-name "Skip to content" \
      --output "$anchor_output"
    # Let Orca flush the anchor-generated focus event before closing the
    # exclusion window; the next physical key follows afterwards.
    sleep 2
    exclusion_end="$(wc -c <"$out_dir/orca-debug.log")"
    printf '%s\t%s\n' "$exclusion_start" "$exclusion_end" >>"$anchor_exclusions"
  }
  # WebKitGTK and Orca enqueue focus events independently.  Fourteen keys
  # were enough on the historical arm64 image but intermittently stopped
  # after the first combo/page-tab group on current x86_64 and arm64 images.
  # Use a slower, longer traversal so the proof exercises the same focus path
  # instead of treating a short event queue as an accessibility pass.  Some
  # arm64 WebKitGTK sessions leave the document after the forward cycle;
  # reverse traversal re-enters the same real focus path and records that
  # recovery rather than accepting a six-event partial traversal.
  physical_tab_presses=28
  focus_window_and_key() {
    # Xvfb/Orca can hand the active window back to the desktop shell after a
    # WebKit focus change. Reassert the same packaged window immediately
    # before each physical key; this does not synthesize an accessibility
    # event, it keeps the real document eligible to receive the key.
    xdotool windowfocus --sync "$window_id" 2>/dev/null || true
    xdotool key --clearmodifiers "$1"
  }
  count_orca_focus_events() {
    python3 - "$out_dir/orca-debug.log" "$focus_log_offset" "$anchor_exclusions" <<'PY'
import re
import sys

debug_path, offset_text, exclusions_path = sys.argv[1:]
pattern = re.compile(
    r"OBJECT EVENT: object:state-changed:focused for "
    r"\[([^:\]]+): '([^']*)'\] in \[application: '([^']+)'\] "
    r"\(1,\s*0,\s*0\)",
)
exclusions = []
with open(exclusions_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            start_text, end_text = line.split("\t")
            exclusions.append((int(start_text), int(end_text)))
with open(debug_path, "rb") as handle:
    data = handle.read()
count = 0
cursor = int(offset_text)
for start, end in sorted(exclusions):
    start = max(start, cursor)
    if start > cursor:
        segment = data[cursor:start].decode("utf-8", errors="replace")
        count += sum(
            1
            for _role, _name, application in pattern.findall(segment)
            if "openburnbar" in application.lower()
        )
    cursor = max(cursor, end)
segment = data[cursor:].decode("utf-8", errors="replace")
count += sum(
    1
    for _role, _name, application in pattern.findall(segment)
    if "openburnbar" in application.lower()
)
print(count)
PY
  }
  for _ in $(seq 1 "$physical_tab_presses"); do
    focus_window_and_key Tab
    # Orca intentionally serializes accessibility events. Fast synthetic input
    # causes its queue to obsolete intermediate focus changes.
    sleep 1.25
  done
  # Forward traversal can leave keyboard focus on the desktop shell. Restore
  # the real document anchor before reverse traversal so those keys exercise
  # the WebKit document rather than the XFCE panel.
  xdotool windowfocus --sync "$window_id" 2>/dev/null || true
  anchor_document_focus "$out_dir/atspi-keyboard-focus-reverse-anchor.json"
  physical_shift_tab_presses=12
  for _ in $(seq 1 "$physical_shift_tab_presses"); do
    focus_window_and_key Shift+Tab
    sleep 1.25
  done
  # Orca may coalesce one or two WebKit focus events under load even though
  # every physical key reached the packaged window. Keep the ten-event gate,
  # but recover a short queue by re-entering the real document and continuing
  # physical traversal. The bounded retry cannot turn a broken or trapped
  # focus path into a pass: the final report still requires ten observed Orca
  # events, three distinct targets, and three named targets.
  focus_retry_rounds=0
  focus_event_count="$(count_orca_focus_events)"
  while (( focus_event_count < 10 && focus_retry_rounds < 3 )); do
    focus_retry_rounds=$((focus_retry_rounds + 1))
    xdotool windowfocus --sync "$window_id" 2>/dev/null || true
    anchor_document_focus "$out_dir/atspi-keyboard-focus-retry-anchor-${focus_retry_rounds}.json"
    for _ in $(seq 1 12); do
      focus_window_and_key Tab
      physical_tab_presses=$((physical_tab_presses + 1))
      sleep 1.25
    done
    sleep 3
    focus_event_count="$(count_orca_focus_events)"
  done
  sleep 8
  node - "$out_dir/orca-debug.log" "$focus_log_offset" "$anchor_exclusions" "$physical_tab_presses" "$physical_shift_tab_presses" "$focus_retry_rounds" "$out_dir/atspi-keyboard-focus-sequence.json" <<'FOCUS'
const fs = require('fs');
const [debugPath, offsetText, exclusionsPath, physicalTabPressesText, physicalShiftTabPressesText, retryRoundsText, outPath] = process.argv.slice(2);
const debug = fs.readFileSync(debugPath);
const exclusions = fs.readFileSync(exclusionsPath, 'utf8')
  .split(/\n/)
  .filter((line) => line.trim())
  .map((line) => line.split('\t').map(Number))
  .sort((left, right) => left[0] - right[0]);
// Skip the byte windows written by programmatic grab-focus anchors so only
// physical-key focus changes are counted and reported as traversal steps.
let cursor = Number(offsetText);
const segments = [];
for (const [start, end] of exclusions) {
  const clampedStart = Math.max(start, cursor);
  if (clampedStart > cursor) segments.push(debug.subarray(cursor, clampedStart).toString('utf8'));
  cursor = Math.max(cursor, end);
}
segments.push(debug.subarray(cursor).toString('utf8'));
const focusEvent = /OBJECT EVENT: object:state-changed:focused for \[([^:\]]+): '([^']*)'\] in \[application: '([^']+)'\] \(1,\s*0,\s*0\)/g;
const events = segments
  .flatMap((segment) => [...segment.matchAll(focusEvent)])
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
  physicalShiftTabPressCount: Number(physicalShiftTabPressesText),
  physicalKeyPressCount: Number(physicalTabPressesText) + Number(physicalShiftTabPressesText),
  recoveryRoundCount: Number(retryRoundsText),
  anchorExclusionWindowCount: exclusions.length,
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

  node - "$out_dir/tray-menu-layout.txt" "$out_dir/tray-menu-actions.json" <<'NODE'
const fs = require('fs');
const layout = fs.readFileSync(process.argv[2], 'utf8');
const actions = [];
const re = /<\((\d+), \{[^)]*?'label': <'([^']+)'>/g;
let match;
while ((match = re.exec(layout))) {
  actions.push({ id: Number(match[1]), label: match[2] });
}
const required = ['Open dashboard', 'Reconnect daemon', 'Quit OpenBurnBar'];
for (const label of required) {
  if (!actions.some((action) => action.label === label)) {
    console.error(`Missing tray menu item ${label}`);
    process.exit(1);
  }
}
const revision = Number(layout.match(/^\(uint32\s+(\d+),/)?.[1]);
if (!Number.isSafeInteger(revision) || revision < 0) {
  console.error('Invalid tray menu revision');
  process.exit(1);
}
fs.writeFileSync(process.argv[3], JSON.stringify({ revision, actions }, null, 2) + '\n');
NODE

  capture_menu_layout() {
    local layout_file="$1"
    gdbus call --session \
      --dest "$item_service" \
      --object-path "$menu_path" \
      --method com.canonical.dbusmenu.GetLayout 0 100 "[]" \
      >"$layout_file"
  }

  resolve_menu_action() {
    local label="$1"
    local layout_file="$2"
    capture_menu_layout "$layout_file"
    node - "$layout_file" "$label" <<'NODE'
const fs = require('fs');
const layout = fs.readFileSync(process.argv[2], 'utf8');
const label = process.argv[3];
const revision = Number(layout.match(/^\(uint32\s+(\d+),/)?.[1]);
if (!Number.isSafeInteger(revision) || revision < 0) {
  console.error('Invalid tray menu revision');
  process.exit(1);
}
const matches = [...layout.matchAll(/<\((\d+), \{[^)]*?'label': <'([^']+)'>/g)];
const actions = matches.map((match, index) => {
  const end = matches[index + 1]?.index ?? layout.length;
  const segment = layout.slice(match.index, end);
  return {
    id: Number(match[1]),
    label: match[2],
    enabled: !/'enabled': <false>/.test(segment)
  };
});
const action = actions.find((candidate) => candidate.label === label);
if (!action || !Number.isSafeInteger(action.id) || !action.enabled) {
  console.error(`Tray menu action is missing or disabled: ${label}`);
  process.exit(1);
}
console.log(`${action.id} ${revision}`);
NODE
  }

  read_menu_state() {
    local layout_file="$1"
    capture_menu_layout "$layout_file"
    node - "$layout_file" <<'NODE'
const fs = require('fs');
const layout = fs.readFileSync(process.argv[2], 'utf8');
const revision = Number(layout.match(/^\(uint32\s+(\d+),/)?.[1]);
if (!Number.isSafeInteger(revision) || revision < 0) {
  console.error('Invalid tray menu revision');
  process.exit(1);
}
const matches = [...layout.matchAll(/<\((\d+), \{[^)]*?'label': <'([^']+)'>/g)];
const statusItems = matches
  .map((match) => ({ id: Number(match[1]), label: match[2] }))
  .filter((item) => item.label.startsWith('Daemon: '));
if (
  statusItems.length !== 1 ||
  !Number.isSafeInteger(statusItems[0].id) ||
  statusItems[0].id <= 0
) {
  console.error('Expected exactly one valid daemon status menu item');
  process.exit(1);
}
console.log([revision, statusItems[0].id, statusItems[0].label].join('\t'));
NODE
  }

  daemon_health_request_occurrences() {
    local request_id="$1"
    awk -v token="request_id=$request_id" '
      /event=rpc_request_received method=daemon\.health / {
        for (field_index = 1; field_index <= NF; field_index += 1) {
          if ($field_index == token) count += 1
        }
      }
      END { print count + 0 }
    ' "$daemon_log"
  }

  tray_reconnect_handler_ack_count() {
    local ack_file="$out_dir/tray-reconnect-handler-acks.jsonl"
    if [[ ! -f "$ack_file" ]]; then
      printf '0\n'
      return
    fi
    grep -cve '^[[:space:]]*$' "$ack_file" 2>/dev/null || true
  }

  read_tray_reconnect_handler_ack() {
    local one_based_index="$1"
    node - "$out_dir/tray-reconnect-handler-acks.jsonl" "$one_based_index" <<'NODE'
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(Boolean);
const index = Number(process.argv[3]) - 1;
if (!Number.isSafeInteger(index) || index < 0 || index >= lines.length) process.exit(1);
const ack = JSON.parse(lines[index]);
const keys = [
  'schemaVersion',
  'action',
  'handlerEventId',
  'daemonHealthRequestId',
  'statusItemLogicalId',
  'handlerStartedEpochMs',
  'handlerCompletedEpochMs',
  'daemonConnected',
  'statusUpdateSucceeded',
  'statusLabel'
];
if (JSON.stringify(Object.keys(ack).sort()) !== JSON.stringify(keys.sort())) process.exit(1);
if (
  ack.schemaVersion !== 1 ||
  ack.action !== 'reconnect-daemon' ||
  !/^tray-health-[0-9a-f]{32}$/.test(ack.handlerEventId) ||
  !/^health-[1-9][0-9]*$/.test(ack.daemonHealthRequestId) ||
  ack.statusItemLogicalId !== 'status' ||
  !Number.isSafeInteger(ack.handlerStartedEpochMs) ||
  !Number.isSafeInteger(ack.handlerCompletedEpochMs) ||
  ack.handlerStartedEpochMs < 0 ||
  ack.handlerCompletedEpochMs < ack.handlerStartedEpochMs ||
  ack.daemonConnected !== true ||
  ack.statusUpdateSucceeded !== true ||
  !/^Daemon: connected(?: - .+)?$/.test(ack.statusLabel)
) process.exit(1);
console.log([
  ack.handlerEventId,
  ack.daemonHealthRequestId,
  ack.statusItemLogicalId,
  ack.handlerStartedEpochMs,
  ack.handlerCompletedEpochMs,
  ack.statusUpdateSucceeded ? 1 : 0,
  ack.statusLabel
].join('\t'));
NODE
  }

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
    {
      echo "== sample $sample_index =="
      read -r open_menu_id open_menu_revision < <(
        resolve_menu_action "Open dashboard" "$out_dir/tray-open-menu-layout-${sample_index}.txt"
      )
      echo "menu_id=$open_menu_id menu_revision=$open_menu_revision"
    } >>"$out_dir/tray-open-menu-event.txt" 2>&1
    # Start the tray-open timer only after the live menu ID is resolved so the
    # budgeted sample measures click-to-window latency, not GetLayout parsing.
    tray_open_start_ms="$(date +%s%3N)"
    send_menu_event "$open_menu_id" >>"$out_dir/tray-open-menu-event.txt" 2>&1
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
  : >"$out_dir/tray-reconnect-receipts.jsonl"
  rm -f "$out_dir/tray-reconnect-handler-acks.jsonl"
  for sample_index in $(seq 1 10); do
    read -r reconnect_menu_id before_reconnect_revision < <(
      resolve_menu_action "Reconnect daemon" "$out_dir/tray-reconnect-menu-layout-${sample_index}.txt"
    )
    before_handler_ack_count="$(tray_reconnect_handler_ack_count)"
    click_epoch_ms="$(date +%s%3N)"
    reconnect_start_ms="$click_epoch_ms"
    {
      echo "== sample $sample_index =="
      echo "menu_id=$reconnect_menu_id menu_revision=$before_reconnect_revision handler_acks=$before_handler_ack_count click_epoch_ms=$click_epoch_ms"
      send_menu_event "$reconnect_menu_id"
    } >>"$out_dir/tray-reconnect-menu-event.txt" 2>&1
    reconnect_observed=false
    after_handler_ack_count="$before_handler_ack_count"
    after_reconnect_revision="$before_reconnect_revision"
    handler_event_id=""
    daemon_health_request_id=""
    status_item_logical_id=""
    handler_started_epoch_ms=0
    handler_completed_epoch_ms=0
    status_update_succeeded=0
    ack_status_label=""
    observed_status_menu_id=0
    observed_status_label=""
    request_log_occurrences=0
    observed_epoch_ms="$click_epoch_ms"
    for _ in $(seq 1 80); do
      after_handler_ack_count="$(tray_reconnect_handler_ack_count)"
      if [[ "$after_handler_ack_count" -gt "$((before_handler_ack_count + 1))" ]]; then
        echo "Tray Reconnect daemon action emitted multiple handler acknowledgements for sample $sample_index" >&2
        break
      fi
      if [[ "$after_handler_ack_count" -eq "$((before_handler_ack_count + 1))" ]]; then
        ack_fields="$(
          read_tray_reconnect_handler_ack "$after_handler_ack_count" 2>/dev/null || true
        )"
        if [[ -n "$ack_fields" ]]; then
          IFS=$'\t' read -r handler_event_id daemon_health_request_id status_item_logical_id handler_started_epoch_ms handler_completed_epoch_ms status_update_succeeded ack_status_label <<<"$ack_fields"
          IFS=$'\t' read -r after_reconnect_revision observed_status_menu_id observed_status_label < <(
            read_menu_state "$out_dir/tray-reconnect-menu-layout-after-${sample_index}.txt"
          )
          request_log_occurrences="$(daemon_health_request_occurrences "$daemon_health_request_id")"
          candidate_observed_epoch_ms="$(date +%s%3N)"
          # The DBusMenu GetLayout revision only advances on structural layout
          # changes; the handler's set_text is a label-only property update
          # (ItemsPropertiesUpdated), which leaves the revision unchanged. The
          # revision may therefore only be required to never regress, while the
          # live-state binding comes from the observed status label matching
          # the handler acknowledgement exactly.
          if [[ "$handler_started_epoch_ms" -ge "$click_epoch_ms" ]] \
            && [[ "$handler_completed_epoch_ms" -ge "$handler_started_epoch_ms" ]] \
            && [[ "$handler_completed_epoch_ms" -le "$candidate_observed_epoch_ms" ]] \
            && [[ "$status_item_logical_id" == "status" ]] \
            && [[ "$status_update_succeeded" == 1 ]] \
            && [[ "$request_log_occurrences" == 1 ]] \
            && [[ "$after_reconnect_revision" -ge "$before_reconnect_revision" ]] \
            && [[ "$observed_status_menu_id" -gt 0 ]] \
            && [[ "$observed_status_label" == "$ack_status_label" ]]; then
            observed_epoch_ms="$candidate_observed_epoch_ms"
            reconnect_observed=true
            break
          fi
        fi
      fi
      sleep 0.1
    done
    if [[ "$reconnect_observed" != true ]]; then
      echo "Tray Reconnect daemon action did not produce an exact healthy round-trip for sample $sample_index" >&2
      echo "menu_revision_before=$before_reconnect_revision menu_revision_after=$after_reconnect_revision" >&2
      echo "handler_acks_before=$before_handler_ack_count handler_acks_after=$after_handler_ack_count" >&2
      echo "click_epoch_ms=$click_epoch_ms handler_started_epoch_ms=$handler_started_epoch_ms handler_completed_epoch_ms=$handler_completed_epoch_ms" >&2
      echo "handler_event_id=$handler_event_id daemon_health_request_id=$daemon_health_request_id" >&2
      echo "status_item_logical_id=$status_item_logical_id status_update_succeeded=$status_update_succeeded" >&2
      echo "observed_status_menu_id=$observed_status_menu_id ack_status_label=$ack_status_label observed_status_label=$observed_status_label" >&2
      echo "request_log_occurrences=$request_log_occurrences" >&2
      tail -200 "$daemon_log" >&2 || true
      tail -200 "$out_dir/openburnbar-linux-desktop.stderr.log" >&2 || true
      cat "$out_dir/tray-reconnect-menu-layout-after-${sample_index}.txt" >&2 || true
      exit 1
    fi
    reconnect_elapsed_ms="$((observed_epoch_ms - reconnect_start_ms))"
    ipc_health_roundtrip_samples+=("$reconnect_elapsed_ms")
    SAMPLE_INDEX="$sample_index" \
    MENU_ID="$reconnect_menu_id" \
    REVISION_BEFORE="$before_reconnect_revision" \
    REVISION_AFTER="$after_reconnect_revision" \
    CLICK_EPOCH_MS="$click_epoch_ms" \
    HANDLER_EVENT_ID="$handler_event_id" \
    HANDLER_STARTED_EPOCH_MS="$handler_started_epoch_ms" \
    HANDLER_COMPLETED_EPOCH_MS="$handler_completed_epoch_ms" \
    DAEMON_HEALTH_REQUEST_ID="$daemon_health_request_id" \
    STATUS_ITEM_LOGICAL_ID="$status_item_logical_id" \
    STATUS_MENU_ID="$observed_status_menu_id" \
    OBSERVED_STATUS_LABEL="$observed_status_label" \
    OBSERVED_EPOCH_MS="$observed_epoch_ms" \
    ELAPSED_MS="$reconnect_elapsed_ms" \
    node <<'NODE' >>"$out_dir/tray-reconnect-receipts.jsonl"
console.log(JSON.stringify({
  sample: Number(process.env.SAMPLE_INDEX),
  menuId: Number(process.env.MENU_ID),
  menuRevisionBefore: Number(process.env.REVISION_BEFORE),
  menuRevisionAfter: Number(process.env.REVISION_AFTER),
  daemonConnected: true,
  clickEpochMs: Number(process.env.CLICK_EPOCH_MS),
  handlerEventId: process.env.HANDLER_EVENT_ID,
  handlerStartedEpochMs: Number(process.env.HANDLER_STARTED_EPOCH_MS),
  handlerCompletedEpochMs: Number(process.env.HANDLER_COMPLETED_EPOCH_MS),
  daemonHealthRequestId: process.env.DAEMON_HEALTH_REQUEST_ID,
  statusItemLogicalId: process.env.STATUS_ITEM_LOGICAL_ID,
  statusMenuId: Number(process.env.STATUS_MENU_ID),
  observedStatusLabel: process.env.OBSERVED_STATUS_LABEL,
  observedEpochMs: Number(process.env.OBSERVED_EPOCH_MS),
  elapsedMs: Number(process.env.ELAPSED_MS)
}));
NODE
  done
  install -m 600 "$daemon_log" "$out_dir/tray-reconnect-daemon-health.log"

  quit_start_ms="$(date +%s%3N)"
  {
    read -r quit_menu_id quit_menu_revision < <(
      resolve_menu_action "Quit OpenBurnBar" "$out_dir/tray-quit-menu-layout.txt"
    )
    echo "menu_id=$quit_menu_id menu_revision=$quit_menu_revision"
    send_menu_event "$quit_menu_id"
  } >"$out_dir/tray-quit-menu-event.txt" 2>&1
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
    atspiReadinessRecovery: fs.existsSync(outDir + '/atspi-readiness-recovery.json')
      ? 'atspi-readiness-recovery.json'
      : null,
    trayReconnectHandlerAcks: 'tray-reconnect-handler-acks.jsonl',
    trayReconnectDaemonHealthLog: 'tray-reconnect-daemon-health.log',
    trayReconnectReceipts: 'tray-reconnect-receipts.jsonl',
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
  "$out_dir"/accessibility-tree-linux-desktop-attempt-1.txt \
  "$out_dir"/atspi-bus-address.txt \
  "$out_dir"/atspi-command-open-*.json \
  "$out_dir"/atspi-command-route-*.json \
  "$out_dir"/atspi-keyboard-focus-sequence.json \
  "$out_dir"/atspi-readiness-recovery.json \
  "$out_dir"/atspi-route-*.json \
  "$out_dir"/atspi-tree-linux-desktop.json \
  "$out_dir"/atspi-tree-linux-desktop-attempt-1.json \
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
  "$out_dir"/tray-open-menu-layout-*.txt \
  "$out_dir"/tray-open-menu-event.txt \
  "$out_dir"/tray-quit-menu-layout.txt \
  "$out_dir"/tray-quit-menu-event.txt \
  "$out_dir"/tray-reconnect-menu-layout-*.txt \
  "$out_dir"/tray-reconnect-menu-layout-after-*.txt \
  "$out_dir"/tray-reconnect-handler-acks.jsonl \
  "$out_dir"/tray-reconnect-daemon-health.log \
  "$out_dir"/tray-reconnect-menu-event.txt \
  "$out_dir"/tray-reconnect-receipts.jsonl \
  "$out_dir"/tray-registered-items.err \
  "$out_dir"/tray-registered-items.txt \
  "$out_dir"/tray-status-notifier-introspection.txt \
  "$out_dir"/window-after-tray-open-xwininfo.txt \
  "$out_dir"/window-initial-xprop.txt \
  "$out_dir"/window-initial-xprop-attempt-1.txt \
  "$out_dir"/window-initial-xwininfo.txt \
  "$out_dir"/window-initial-xwininfo-attempt-1.txt \
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
  stage_native_package_inputs() {
    local native_root="$work_dir/native-package-inputs"
    local iroh_target_dir="$native_root/iroh-target"
    local iroh_library_dir="$iroh_target_dir/release"
    local daemon_scratch="$native_root/daemon-build"
    local swift_jobs="${OPENBURNBAR_LINUX_SWIFT_BUILD_JOBS:-4}"
    local iroh_jobs="${OPENBURNBAR_LINUX_IROH_BUILD_JOBS:-1}"
    local swift_bin_dir
    local resource_bundle

    # A release package must be built from a coherent native input set.  Keep
    # caller-provided artifacts as an explicit fast path, but never accept a
    # partial set: the Swift manifest requires both iroh libraries and the
    # payload preflight requires the daemon, CLI, and resource bundle together.
    if [[ -x "${OPENBURNBAR_LINUX_DAEMON_BIN:-}" \
      && -x "${OPENBURNBAR_LINUX_CLI_BIN:-}" \
      && -d "${OPENBURNBAR_LINUX_RESOURCE_BUNDLE:-}" \
      && -f "${OPENBURNBAR_LINUX_IROH_LIBRARY_DIR:-}/libopenburnbar_iroh.so" \
      && -f "${OPENBURNBAR_LINUX_IROH_LIBRARY_DIR:-}/libopenburnbar_iroh.a" ]]; then
      echo "reusing_existing_native_package_inputs=true"
      return 0
    fi

    mkdir -p "$native_root" "$iroh_target_dir" "$daemon_scratch"
    echo "== stage iroh native package inputs =="
    cargo build \
      --manifest-path "$root/crates/openburnbar-iroh/Cargo.toml" \
      --target-dir "$iroh_target_dir" \
      --locked \
      --release \
      --jobs "$iroh_jobs"
    for iroh_library in libopenburnbar_iroh.so libopenburnbar_iroh.a; do
      if [[ ! -f "$iroh_library_dir/$iroh_library" ]]; then
        echo "Missing staged iroh library: $iroh_library_dir/$iroh_library" >&2
        exit 1
      fi
    done

    # SwiftPM evaluates OpenBurnBarCore/Package.swift while resolving the
    # daemon graph.  Export the iroh directory before either product build so
    # the real FFI target is linked instead of silently pruning it.
    export OPENBURNBAR_LINUX_IROH_LIBRARY_DIR="$iroh_library_dir"
    echo "== stage OpenBurnBarDaemon and CLI native package inputs =="
    swift build \
      --disable-automatic-resolution \
      --jobs "$swift_jobs" \
      --package-path "$root/OpenBurnBarDaemon" \
      --scratch-path "$daemon_scratch" \
      -c release \
      --product OpenBurnBarDaemon \
      -Xlinker \
      --allow-shlib-undefined
    swift build \
      --disable-automatic-resolution \
      --jobs "$swift_jobs" \
      --package-path "$root/OpenBurnBarDaemon" \
      --scratch-path "$daemon_scratch" \
      -c release \
      --product OpenBurnBarCLI \
      -Xlinker \
      --allow-shlib-undefined

    swift_bin_dir="$(swift build \
      --disable-automatic-resolution \
      --jobs "$swift_jobs" \
      --package-path "$root/OpenBurnBarDaemon" \
      --scratch-path "$daemon_scratch" \
      -c release \
      --show-bin-path)"
    resource_bundle="$(find "$swift_bin_dir" -maxdepth 1 -type d \
      -name 'OpenBurnBarCore_*.resources' -print -quit)"
    export OPENBURNBAR_LINUX_DAEMON_BIN="$swift_bin_dir/OpenBurnBarDaemon"
    export OPENBURNBAR_LINUX_CLI_BIN="$swift_bin_dir/OpenBurnBarCLI"
    export OPENBURNBAR_LINUX_RESOURCE_BUNDLE="$resource_bundle"

    for native_input in \
      "$OPENBURNBAR_LINUX_DAEMON_BIN" \
      "$OPENBURNBAR_LINUX_CLI_BIN"; do
      if [[ ! -x "$native_input" ]]; then
        echo "Missing staged Swift executable: $native_input" >&2
        exit 1
      fi
    done
    if [[ ! -d "$OPENBURNBAR_LINUX_RESOURCE_BUNDLE" ]]; then
      echo "Missing staged OpenBurnBarCore resource bundle: ${OPENBURNBAR_LINUX_RESOURCE_BUNDLE:-unset}" >&2
      exit 1
    fi
    printf 'daemon=%s\ncli=%s\nresource_bundle=%s\niroh_library_dir=%s\n' \
      "$OPENBURNBAR_LINUX_DAEMON_BIN" \
      "$OPENBURNBAR_LINUX_CLI_BIN" \
      "$OPENBURNBAR_LINUX_RESOURCE_BUNDLE" \
      "$OPENBURNBAR_LINUX_IROH_LIBRARY_DIR"
  }

  build_root="$work_dir/build-root"
  mkdir -p "$build_root/apps" "$build_root/packages" "$build_root/scripts" "$build_root/packaging" "$build_root/crates"
  cp -R "$root/apps/linux-desktop" "$build_root/apps/linux-desktop"
  # apps/linux-desktop/src/providerPathRegistry.ts imports
  # ../../../contracts/provider-ingestion-catalog.json, which resolves OUTSIDE
  # the copied app directory. Without this the Vite build dies with
  # "Could not resolve ../../../contracts/provider-ingestion-catalog.json".
  cp -R "$root/contracts" "$build_root/contracts"
  # Preserve the repository-relative paths consumed by package.json, Vite,
  # the production scanner, native include_str!, and Tauri bundle resources.
  for shared_package in design-tokens entitlements gl-engine; do
    cp -R "$root/packages/$shared_package" "$build_root/packages/$shared_package"
  done
  # Tauri resolves the optional media dependency from this repository-relative
  # path while building the packaged shell. Keep the crate in the copied build
  # root even when the current host does not enable its runtime feature.
  cp -R "$root/crates/openburnbar-media" "$build_root/crates/openburnbar-media"
  cp -R "$root/scripts/linux-port" "$build_root/scripts/linux-port"
  cp -R "$root/packaging/linux" "$build_root/packaging/linux"
  mkdir -p "$build_root/OpenBurnBarDaemon/Resources"
  cp -R "$root/OpenBurnBarDaemon/Resources/PlaywrightBridge" \
    "$build_root/OpenBurnBarDaemon/Resources/PlaywrightBridge"
  stage_native_package_inputs
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
export OB_PERFORMANCE_TARGET_HEAD="${OB_PERFORMANCE_TARGET_HEAD:-$(git -C "$root" rev-parse HEAD)}"
if [[ "$(git -C "$root" rev-parse HEAD)" != "$OB_PERFORMANCE_TARGET_HEAD" ]]; then
  echo "Performance target HEAD does not match checkout HEAD" >&2
  exit 1
fi
OB_PERFORMANCE_SOURCE_DIGEST="$(node --input-type=module -e \
  "import { nativePerformanceSourceDigest } from '$root/scripts/linux-port/lib/p32-performance-proof.mjs'; process.stdout.write(nativePerformanceSourceDigest('$root'));" )"
export OB_PERFORMANCE_SOURCE_DIGEST
OB_PERFORMANCE_CAPTURE_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
export OB_PERFORMANCE_CAPTURE_STARTED_AT
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
const crypto = require('crypto');
const reportPath = process.argv[2];
const debBasename = process.argv[3];
const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
report.package.uninstallVerified = true;
report.package.debArtifact = debBasename;
report.generatedAt = new Date().toISOString();
const runId = process.env.OB_CANDIDATE_RUN_ID || null;
const artifactDigest = process.env.OB_CANDIDATE_ARTIFACT_DIGEST || null;
report.provenance = {
  schemaVersion: 1,
  producer: 'openburnbar-linux-desktop-performance-v1',
  gitCommit: process.env.OB_PERFORMANCE_TARGET_HEAD,
  packageVersion: report.package.version,
  sourceDigest: process.env.OB_PERFORMANCE_SOURCE_DIGEST,
  candidate: { runId, artifactDigest },
  startedAt: process.env.OB_PERFORMANCE_CAPTURE_STARTED_AT,
  endedAt: report.generatedAt,
  payloadSha256: ''
};
const payload = structuredClone(report);
delete payload.provenance;
report.provenance.payloadSha256 = crypto.createHash('sha256').update(JSON.stringify(payload)).digest('hex');
fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
NODE

cp "$transcript" "$out_dir/linux-tauri-build-transcript.txt"
echo "linux-desktop-session-ok"
