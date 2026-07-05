#!/usr/bin/env bash
set -euo pipefail

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
  export OPENBURNBAR_SOCKET_PATH="$socket_path"
  export OPENBURNBAR_EVIDENCE_OUT="$out_dir"

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
  echo "$window_id" >"$out_dir/openburnbar-window-id.txt"
  xwininfo -id "$window_id" >"$out_dir/window-initial-xwininfo.txt"
  xprop -id "$window_id" >"$out_dir/window-initial-xprop.txt"
  scrot "$out_dir/screenshot-linux-desktop-first-run.png"

  {
    echo "== at-spi bus =="
    gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress || true
    echo
    echo "== window properties =="
    cat "$out_dir/window-initial-xprop.txt"
  } >"$out_dir/accessibility-tree-linux-desktop.txt" 2>&1

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
  )
  route_click_y=(
    158
    195
    232
    269
    306
    343
    380
    417
    454
    520
    558
    595
    632
    669
    706
    743
  )
  xdotool windowactivate "$window_id"
  for index in "${!route_names[@]}"; do
    route="${route_names[$index]}"
    y="${route_click_y[$index]}"
    xdotool mousemove --window "$window_id" 120 "$y" click 1
    sleep 0.45
    screenshot="$out_dir/screenshot-route-${route}.png"
    xwininfo_route="$out_dir/window-route-${route}-xwininfo.txt"
    scrot "$screenshot"
    current_window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
    if [[ -z "$current_window_id" ]]; then
      echo "OpenBurnBar window disappeared while capturing route $route" >&2
      exit 1
    fi
    xwininfo -id "$current_window_id" >"$xwininfo_route"
    printf '%s\t%s\t%s\t%s\t%s\n' "$route" "$(basename "$screenshot")" "$(basename "$xwininfo_route")" "$current_window_id" "$y" >>"$route_tsv"
  done

  node - "$route_tsv" "$out_dir/packaged-route-session-transcript.json" "$out_dir/daemon-session-oracle.json" <<'NODE'
const fs = require('fs');
const [tsvPath, outPath, oraclePath] = process.argv.slice(2);
const oracle = fs.existsSync(oraclePath) ? JSON.parse(fs.readFileSync(oraclePath, 'utf8')) : null;
const targetRoutes = new Set(['settings', 'account', 'updates', 'support', 'onboarding', 'pet', 'text-expansion']);
const routes = fs.readFileSync(tsvPath, 'utf8')
  .trim()
  .split(/\n+/)
  .filter(Boolean)
  .map((line, index) => {
    const [route, screenshot, xwininfo, windowId, clickY] = line.split('\t');
    return {
      index,
      route,
      screenshot,
      xwininfo,
      windowId,
      action: `xdotool click visible nav at x=120 y=${clickY}`,
      surface: 'installed-tauri-deb-xvfb-xfce',
      targetScenario: targetRoutes.has(route),
      daemonOracleMode: oracle?.mode ?? 'missing'
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

  xdotool windowunmap "$window_id"
  for _ in $(seq 1 50); do
    if ! xdotool search --onlyvisible --name OpenBurnBar >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  tray_open_start_ms="$(date +%s%3N)"
  send_menu_event "$OPEN_ID" >"$out_dir/tray-open-menu-event.txt" 2>&1
  reopened_window_id=""
  for _ in $(seq 1 80); do
    reopened_window_id="$(xdotool search --onlyvisible --name OpenBurnBar 2>/dev/null | head -n 1 || true)"
    if [[ -n "$reopened_window_id" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$reopened_window_id" ]]; then
    echo "Tray Open dashboard action did not reopen the window" >&2
    exit 1
  fi
  tray_open_ms="$(( $(date +%s%3N) - tray_open_start_ms ))"
  xwininfo -id "$reopened_window_id" >"$out_dir/window-after-tray-open-xwininfo.txt"
  scrot "$out_dir/screenshot-linux-desktop-after-tray-open.png"

  daemon_log="$out_dir/daemon-socket-gui-session.log"
  if [[ -f "$out_dir/daemon-shell-session.log" ]]; then
    daemon_log="$out_dir/daemon-shell-session.log"
  fi
  before_reconnect_lines="$(wc -l <"$daemon_log" 2>/dev/null || echo 0)"
  reconnect_start_ms="$(date +%s%3N)"
  send_menu_event "$RECONNECT_ID" >"$out_dir/tray-reconnect-menu-event.txt" 2>&1
  for _ in $(seq 1 80); do
    current_lines="$(wc -l <"$daemon_log" 2>/dev/null || echo 0)"
    if [[ "$current_lines" -gt "$before_reconnect_lines" ]]; then
      break
    fi
    sleep 0.1
  done
  ipc_health_roundtrip_ms="$(( $(date +%s%3N) - reconnect_start_ms ))"

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

  {
    echo "== dbus names after app =="
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames
  } >"$out_dir/dbus-after-app.txt" 2>&1 || true

  node - "$out_dir/linux-desktop-session-report.json" "$out_dir" <<NODE
const fs = require('fs');
const outDir = process.argv[3];
const report = {
  generatedAt: new Date().toISOString(),
  profile: 'dbus-x11-xvfb-xfce-statusnotifier',
  package: { name: '$pkg', executable: '$installed_bin' },
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
    appStartMs: Number('$app_start_ms'),
    trayClickOpenMs: Number('$tray_open_ms'),
    ipcHealthRoundTripMs: Number('$ipc_health_roundtrip_ms'),
    trayQuitMs: Number('$tray_quit_ms')
  },
  evidence: {
    firstRunScreenshot: 'screenshot-linux-desktop-first-run.png',
    afterTrayOpenScreenshot: 'screenshot-linux-desktop-after-tray-open.png',
    packagedRouteTranscript: 'packaged-route-session-transcript.json',
    runtimePerfSamples: 'runtime-perf-samples.jsonl',
    daemonSocketLog: fs.existsSync(outDir + '/daemon-shell-session.log') ? 'daemon-shell-session.log' : 'daemon-socket-gui-session.log',
    trayMenuLayout: 'tray-menu-layout.txt',
    accessibilitySnapshot: 'accessibility-tree-linux-desktop.txt'
  }
};
fs.writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
NODE
  exit 0
fi

root="/workspace"
out_dir="${OB_EVIDENCE_OUT:-/evidence}"
work_dir="${OB_SESSION_WORKDIR:-/tmp/openburnbar-linux-desktop-session}"
mkdir -p "$out_dir"
rm -rf "$work_dir"
mkdir -p "$work_dir"

transcript="$out_dir/linux-deb-install-run-transcript.txt"
exec > >(tee "$transcript") 2>&1

rm -f \
  "$out_dir"/accessibility-tree-linux-desktop.txt \
  "$out_dir"/daemon-socket-gui-session.log \
  "$out_dir"/daemon-session-oracle.json \
  "$out_dir"/dbus-after-app.txt \
  "$out_dir"/dbus-before-app.txt \
  "$out_dir"/desktop-package-provision.txt \
  "$out_dir"/desktop-package-versions.txt \
  "$out_dir"/linux-desktop-session-report.json \
  "$out_dir"/openburnbar-linux-desktop.pid \
  "$out_dir"/openburnbar-linux-desktop.stderr.log \
  "$out_dir"/openburnbar-linux-desktop.stdout.log \
  "$out_dir"/openburnbar-window-id.txt \
  "$out_dir"/packaged-route-session-transcript.json \
  "$out_dir"/runtime-perf-samples.jsonl \
  "$out_dir"/openbox.log \
  "$out_dir"/screenshot-linux-desktop-after-tray-open*.png \
  "$out_dir"/screenshot-linux-desktop-first-run*.png \
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
  "$out_dir"/xvfb.log

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
  cp -R "$root/apps/linux-desktop" "$work_dir/app"
  cd "$work_dir/app"
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
installed_bin="$(dpkg -L "$pkg" | grep '/bin/' | head -n 1 || true)"
if [[ -z "$installed_bin" || ! -x "$installed_bin" ]]; then
  echo "Could not find installed executable for $pkg" >&2
  dpkg -L "$pkg" >&2
  exit 1
fi
echo "desktop_file=${desktop_file:-missing}"
echo "installed_bin=$installed_bin"

echo "== daemon socket for packaged session =="
home_dir="$work_dir/home"
runtime_dir="$work_dir/runtime"
data_dir="$home_dir/.local/share/openburnbar"
mkdir -p "$data_dir" "$runtime_dir"
chmod 700 "$runtime_dir"
socket_path="$("$root/scripts/linux-port/start-shell-session-daemon.sh" "$root" "$out_dir" "$work_dir")"
daemon_pid="$(cat "$work_dir/daemon.pid")"
ls -l "$socket_path"
cleanup_outer() {
  kill "$daemon_pid" 2>/dev/null || true
}
trap cleanup_outer EXIT

echo "== desktop session =="
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
