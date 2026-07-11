use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::ffi::OsStr;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::menu::{
    CheckMenuItem, CheckMenuItemBuilder, MenuBuilder, MenuItem, MenuItemBuilder, PredefinedMenuItem,
};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, Wry};
use url::Url;

const AUTOSTART_ENTRY: &str =
    include_str!("../../../../packaging/linux/autostart/openburnbar.desktop");
const DEEP_LINK_EVENT: &str = "native-deep-link";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeDeepLink {
    pub route: String,
    pub action: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchIntent {
    pub background: bool,
    pub deep_links: Vec<NativeDeepLink>,
    pub rejected_deep_links: usize,
}

impl LaunchIntent {
    pub fn from_args<I, S>(args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut background = false;
        let mut deep_links = Vec::new();
        let mut rejected_deep_links = 0;
        for arg in args.into_iter().skip(1) {
            let value = arg.as_ref().to_string_lossy();
            if value == "--background" {
                background = true;
            } else if value.to_ascii_lowercase().starts_with("openburnbar:") {
                match validate_deep_link(&value) {
                    Ok(link) => deep_links.push(link),
                    Err(()) => rejected_deep_links += 1,
                }
            }
        }
        Self {
            background,
            deep_links,
            rejected_deep_links,
        }
    }
}

fn validate_deep_link(raw: &str) -> Result<NativeDeepLink, ()> {
    if raw.len() > 2_048 || raw.chars().any(char::is_control) {
        return Err(());
    }
    let url = Url::parse(raw).map_err(|_| ())?;
    if url.scheme() != "openburnbar"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
        || url.fragment().is_some()
        || url.query().is_some()
    {
        return Err(());
    }
    let host = url.host_str().unwrap_or("").to_ascii_lowercase();
    let path = url.path().trim_matches('/').to_ascii_lowercase();
    let key = if path.is_empty() {
        host
    } else if host.is_empty() {
        path
    } else {
        format!("{host}/{path}")
    };
    let (route, action) = match key.as_str() {
        "dashboard" => ("overview", "open-dashboard"),
        "search" => ("activity", "open-search"),
        "chat" => ("chat", "open-chat"),
        "insights" | "insights/today" | "insights/year" => ("insights", "open-insights"),
        "membership" | "membership/success" => ("account", "membership-success"),
        "membership/cancel" => ("account", "membership-cancel"),
        _ => return Err(()),
    };
    Ok(NativeDeepLink {
        route: route.to_string(),
        action: action.to_string(),
    })
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeShellSnapshot {
    pub login_start_enabled: bool,
    pub login_start_path: String,
    pub background_launch: bool,
    pub rejected_deep_links: usize,
    pub degraded_reason: Option<String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeTraySnapshot {
    pub today_cost_usd: f64,
    pub today_tokens: u64,
    pub connected_providers: u16,
    pub quota_floor_remaining_percent: Option<u8>,
    pub freshness: NativeTrayFreshness,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NativeTrayFreshness {
    Live,
    Stale,
    Offline,
    Unavailable,
}

impl Default for NativeTraySnapshot {
    fn default() -> Self {
        Self {
            today_cost_usd: 0.0,
            today_tokens: 0,
            connected_providers: 0,
            quota_floor_remaining_percent: None,
            freshness: NativeTrayFreshness::Unavailable,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeStatusSnapshot {
    pub shell: NativeShellSnapshot,
    pub tray: NativeTraySnapshot,
}

struct TrayHandles {
    status: MenuItem<Wry>,
    cost: MenuItem<Wry>,
    quota: MenuItem<Wry>,
    providers: MenuItem<Wry>,
    login_start: CheckMenuItem<Wry>,
}

pub struct NativeShellState {
    pending_deep_links: Mutex<VecDeque<NativeDeepLink>>,
    renderer_ready: AtomicBool,
    background_launch: bool,
    rejected_deep_links: usize,
    tray_handles: Mutex<Option<TrayHandles>>,
    last_tray_snapshot: Mutex<NativeTraySnapshot>,
}

impl NativeShellState {
    pub fn new(intent: LaunchIntent) -> Self {
        Self {
            pending_deep_links: Mutex::new(intent.deep_links.into()),
            renderer_ready: AtomicBool::new(false),
            background_launch: intent.background,
            rejected_deep_links: intent.rejected_deep_links,
            tray_handles: Mutex::new(None),
            last_tray_snapshot: Mutex::new(NativeTraySnapshot::default()),
        }
    }

    pub fn background_launch(&self) -> bool {
        self.background_launch
    }

    fn deliver(&self, app: &AppHandle, link: NativeDeepLink) {
        if self.renderer_ready.load(Ordering::Acquire) {
            let _ = app.emit(DEEP_LINK_EVENT, link);
        } else if let Ok(mut pending) = self.pending_deep_links.lock() {
            pending.push_back(link);
        }
    }

    fn renderer_ready(&self) -> Vec<NativeDeepLink> {
        self.renderer_ready.store(true, Ordering::Release);
        self.pending_deep_links
            .lock()
            .map(|mut pending| pending.drain(..).collect())
            .unwrap_or_default()
    }

    fn snapshot(&self) -> NativeShellSnapshot {
        match autostart_path_from_environment() {
            Ok(path) => match login_start_enabled_at(&path) {
                Ok(enabled) => NativeShellSnapshot {
                    login_start_enabled: enabled,
                    login_start_path: path.display().to_string(),
                    background_launch: self.background_launch,
                    rejected_deep_links: self.rejected_deep_links,
                    degraded_reason: None,
                },
                Err(error) => NativeShellSnapshot {
                    login_start_enabled: false,
                    login_start_path: path.display().to_string(),
                    background_launch: self.background_launch,
                    rejected_deep_links: self.rejected_deep_links,
                    degraded_reason: Some(error),
                },
            },
            Err(error) => NativeShellSnapshot {
                login_start_enabled: false,
                login_start_path: String::new(),
                background_launch: self.background_launch,
                rejected_deep_links: self.rejected_deep_links,
                degraded_reason: Some(error),
            },
        }
    }

    fn status_snapshot(&self) -> NativeStatusSnapshot {
        NativeStatusSnapshot {
            shell: self.snapshot(),
            tray: self
                .last_tray_snapshot
                .lock()
                .map(|snapshot| *snapshot)
                .unwrap_or_default(),
        }
    }

    fn store_tray_snapshot(&self, snapshot: NativeTraySnapshot) -> Result<(), String> {
        let mut last = self
            .last_tray_snapshot
            .lock()
            .map_err(|_| "native_status_snapshot_unavailable".to_string())?;
        *last = snapshot;
        Ok(())
    }

    fn install_tray_handles(&self, handles: TrayHandles) {
        if let Ok(mut state) = self.tray_handles.lock() {
            *state = Some(handles);
        }
    }
}

fn resolve_autostart_path(
    home: Option<&OsStr>,
    xdg_config_home: Option<&OsStr>,
) -> Result<PathBuf, String> {
    let config_home = xdg_config_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|path| path.join(".config"))
        })
        .ok_or_else(|| "native_shell_config_home_unavailable".to_string())?;
    Ok(config_home
        .join("autostart")
        .join("dev.openburnbar.OpenBurnBar.desktop"))
}

fn autostart_path_from_environment() -> Result<PathBuf, String> {
    resolve_autostart_path(
        std::env::var_os("HOME").as_deref(),
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
    )
}

fn login_start_enabled_at(path: &Path) -> Result<bool, String> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(contents == AUTOSTART_ENTRY),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("native_shell_autostart_read_failed".to_string()),
    }
}

fn set_login_start_at(path: &Path, enabled: bool) -> Result<(), String> {
    if !enabled {
        return match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err("native_shell_autostart_remove_failed".to_string()),
        };
    }
    let parent = path
        .parent()
        .ok_or_else(|| "native_shell_autostart_parent_missing".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|_| "native_shell_autostart_directory_failed".to_string())?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|_| "native_shell_autostart_permissions_failed".to_string())?;
    let temp_path = parent.join(format!(
        ".dev.openburnbar.OpenBurnBar.desktop.{}-{}.tmp",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "native_shell_clock_unavailable".to_string())?
            .as_nanos()
    ));
    let mut temp = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp_path)
        .map_err(|_| "native_shell_autostart_temp_create_failed".to_string())?;
    let write_result = temp
        .write_all(AUTOSTART_ENTRY.as_bytes())
        .and_then(|_| temp.sync_all())
        .map_err(|_| "native_shell_autostart_write_failed".to_string());
    if write_result.is_ok() {
        if fs::rename(&temp_path, path).is_err() {
            let _ = fs::remove_file(&temp_path);
            return Err("native_shell_autostart_commit_failed".to_string());
        }
    } else {
        let _ = fs::remove_file(&temp_path);
        return write_result;
    }
    Ok(())
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

pub fn route_action_allowed(route: &str, action: &str) -> bool {
    matches!(
        (route, action),
        ("overview", "open-dashboard")
            | ("activity", "open-search")
            | ("chat", "open-chat")
            | ("insights", "open-insights")
            | ("providers", "open-providers")
            | ("updates", "open-updates")
            | ("support", "reconnect-daemon")
            | ("account", "membership-success")
            | ("account", "membership-cancel")
    )
}

pub fn deliver_route_action(app: &AppHandle, route: &str, action: &str) -> Result<(), String> {
    if !route_action_allowed(route, action) {
        return Err("native_route_action_invalid".to_string());
    }
    show_main_window(app);
    app.state::<NativeShellState>().deliver(
        app,
        NativeDeepLink {
            route: route.to_string(),
            action: action.to_string(),
        },
    );
    Ok(())
}

fn route_from_tray(app: &AppHandle, route: &str, action: &str) {
    let _ = deliver_route_action(app, route, action);
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct StatusWindowGeometry {
    x: f64,
    y: f64,
}

fn clamp_status_window_position(
    anchor_x: f64,
    anchor_y: f64,
    monitor_x: f64,
    monitor_y: f64,
    monitor_width: f64,
    monitor_height: f64,
) -> StatusWindowGeometry {
    let width = 420.0;
    let height = 540.0;
    let margin = 12.0;
    let min_x = monitor_x + margin;
    let min_y = monitor_y + margin;
    let max_x = monitor_x + monitor_width - width - margin;
    let max_y = monitor_y + monitor_height - height - margin;
    StatusWindowGeometry {
        x: (anchor_x - width + margin).clamp(min_x, max_x.max(min_x)),
        y: (anchor_y + margin).clamp(min_y, max_y.max(min_y)),
    }
}

fn status_anchor_position(
    app: &AppHandle,
    physical_x: f64,
    physical_y: f64,
) -> StatusWindowGeometry {
    let monitor = app
        .monitor_from_point(physical_x, physical_y)
        .ok()
        .flatten()
        .or_else(|| app.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let scale = monitor.scale_factor();
        let position = monitor.position();
        let size = monitor.size();
        return clamp_status_window_position(
            physical_x / scale,
            physical_y / scale,
            f64::from(position.x) / scale,
            f64::from(position.y) / scale,
            f64::from(size.width) / scale,
            f64::from(size.height) / scale,
        );
    }
    clamp_status_window_position(physical_x, physical_y, 0.0, 0.0, 1_920.0, 1_080.0)
}

fn show_status_window_at(app: &AppHandle, anchor: Option<(f64, f64)>) -> Result<(), String> {
    let window = if let Some(window) = app.get_webview_window("status") {
        window
    } else {
        WebviewWindowBuilder::new(
            app,
            "status",
            WebviewUrl::App("index.html?surface=status".into()),
        )
        .title("OpenBurnBar Status")
        .inner_size(420.0, 540.0)
        .min_inner_size(360.0, 420.0)
        .max_inner_size(520.0, 680.0)
        .resizable(false)
        .skip_taskbar(true)
        .visible(false)
        .build()
        .map_err(|error| format!("native_status_window_create_failed:{error}"))?
    };
    if let Some((x, y)) = anchor {
        let position = status_anchor_position(app, x, y);
        let _ = window.set_position(tauri::Position::Logical(tauri::LogicalPosition {
            x: position.x,
            y: position.y,
        }));
    }
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
    Ok(())
}

pub fn handle_secondary_launch(app: &AppHandle, args: Vec<String>) {
    let intent = LaunchIntent::from_args(args);
    if intent.deep_links.is_empty() && !intent.background {
        route_from_tray(app, "overview", "open-dashboard");
        return;
    }
    if !intent.deep_links.is_empty() {
        show_main_window(app);
    }
    let state = app.state::<NativeShellState>();
    for link in intent.deep_links {
        state.deliver(app, link);
    }
}

pub fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let quick_status = MenuItemBuilder::with_id("quick_status", "Open quick status").build(app)?;
    let open = MenuItemBuilder::with_id("open", "Open dashboard").build(app)?;
    let chat = MenuItemBuilder::with_id("chat", "Open chat").build(app)?;
    let providers_route =
        MenuItemBuilder::with_id("providers_route", "Open providers").build(app)?;
    let updates = MenuItemBuilder::with_id("updates", "Check updates").build(app)?;
    let status = MenuItemBuilder::with_id("native_status", "Connecting to daemon...")
        .enabled(false)
        .build(app)?;
    let cost = MenuItemBuilder::with_id("native_cost", "Today: waiting for usage")
        .enabled(false)
        .build(app)?;
    let quota = MenuItemBuilder::with_id("native_quota", "Quota: waiting for providers")
        .enabled(false)
        .build(app)?;
    let providers = MenuItemBuilder::with_id("native_providers", "Providers: waiting for data")
        .enabled(false)
        .build(app)?;
    let login_enabled = autostart_path_from_environment()
        .and_then(|path| login_start_enabled_at(&path))
        .unwrap_or(false);
    let login_start = CheckMenuItemBuilder::with_id("login_start", "Start at login")
        .checked(login_enabled)
        .build(app)?;
    let reconnect = MenuItemBuilder::with_id("health", "Reconnect daemon").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit OpenBurnBar").build(app)?;
    let separator_1 = PredefinedMenuItem::separator(app)?;
    let separator_2 = PredefinedMenuItem::separator(app)?;
    let separator_3 = PredefinedMenuItem::separator(app)?;
    let separator_4 = PredefinedMenuItem::separator(app)?;
    let menu = MenuBuilder::new(app)
        .items(&[
            &quick_status,
            &separator_1,
            &open,
            &chat,
            &providers_route,
            &updates,
            &separator_2,
            &status,
            &cost,
            &quota,
            &providers,
            &separator_3,
            &login_start,
            &reconnect,
            &separator_4,
            &quit,
        ])
        .build()?;

    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or_else(|| tauri::Error::AssetNotFound("default OpenBurnBar tray icon".to_string()))?;
    let tray = TrayIconBuilder::with_id("openburnbar-main")
        .icon(icon)
        .menu(&menu)
        .tooltip("OpenBurnBar - connecting")
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                position,
                ..
            } = event
            {
                let _ = show_status_window_at(tray.app_handle(), Some((position.x, position.y)));
            }
        })
        .on_menu_event(|app, event| match event.id.as_ref() {
            "quick_status" => {
                let _ = show_status_window_at(app, None);
            }
            "open" => route_from_tray(app, "overview", "open-dashboard"),
            "chat" => route_from_tray(app, "chat", "open-chat"),
            "providers_route" => route_from_tray(app, "providers", "open-providers"),
            "updates" => route_from_tray(app, "updates", "open-updates"),
            "health" => route_from_tray(app, "support", "reconnect-daemon"),
            "login_start" => {
                let state = app.state::<NativeShellState>();
                let next = state
                    .tray_handles
                    .lock()
                    .ok()
                    .and_then(|handles| {
                        handles
                            .as_ref()
                            .and_then(|item| item.login_start.is_checked().ok())
                    })
                    .unwrap_or(false);
                let result = autostart_path_from_environment()
                    .and_then(|path| set_login_start_at(&path, next));
                if result.is_err() {
                    if let Ok(handles) = state.tray_handles.lock() {
                        if let Some(handles) = handles.as_ref() {
                            let _ = handles.login_start.set_checked(!next);
                        }
                    }
                }
                let _ = app.emit("native-shell-state", state.snapshot());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    let _ = tray.set_show_menu_on_left_click(false);
    app.state::<NativeShellState>()
        .install_tray_handles(TrayHandles {
            status,
            cost,
            quota,
            providers,
            login_start,
        });
    Ok(())
}

#[tauri::command]
pub fn native_shell_ready(state: tauri::State<'_, NativeShellState>) -> Vec<NativeDeepLink> {
    state.renderer_ready()
}

#[tauri::command]
pub fn native_shell_snapshot(state: tauri::State<'_, NativeShellState>) -> NativeShellSnapshot {
    state.snapshot()
}

#[tauri::command]
pub fn native_shell_set_login_start(
    enabled: bool,
    state: tauri::State<'_, NativeShellState>,
) -> Result<NativeShellSnapshot, String> {
    let path = autostart_path_from_environment()?;
    set_login_start_at(&path, enabled)?;
    if let Ok(handles) = state.tray_handles.lock() {
        if let Some(handles) = handles.as_ref() {
            let _ = handles.login_start.set_checked(enabled);
        }
    }
    Ok(state.snapshot())
}

#[tauri::command]
pub fn native_status_snapshot(state: tauri::State<'_, NativeShellState>) -> NativeStatusSnapshot {
    state.status_snapshot()
}

#[tauri::command]
pub fn native_status_show(
    app: AppHandle,
    state: tauri::State<'_, NativeShellState>,
) -> Result<NativeStatusSnapshot, String> {
    show_status_window_at(&app, None)?;
    Ok(state.status_snapshot())
}

#[tauri::command]
pub fn native_status_close(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("status") {
        window
            .hide()
            .map_err(|error| format!("native_status_window_close_failed:{error}"))?;
    }
    Ok(())
}

#[tauri::command]
pub fn native_status_route(app: AppHandle, route: String, action: String) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("status") {
        let _ = window.hide();
    }
    deliver_route_action(&app, &route, &action)
}

#[tauri::command]
pub fn native_tray_update(
    app: AppHandle,
    snapshot: NativeTraySnapshot,
    state: tauri::State<'_, NativeShellState>,
) -> Result<(), String> {
    if !snapshot.today_cost_usd.is_finite()
        || snapshot.today_cost_usd < 0.0
        || snapshot.today_cost_usd > 1_000_000_000.0
        || snapshot.connected_providers > 1_024
        || snapshot
            .quota_floor_remaining_percent
            .is_some_and(|value| !(0..=100).contains(&value))
    {
        return Err("native_tray_snapshot_invalid".to_string());
    }
    state.store_tray_snapshot(snapshot)?;
    let _ = app.emit("native-status-snapshot", state.status_snapshot());
    let handles = state
        .tray_handles
        .lock()
        .map_err(|_| "native_tray_state_unavailable".to_string())?;
    let handles = handles
        .as_ref()
        .ok_or_else(|| "native_tray_not_initialized".to_string())?;
    let status = match snapshot.freshness {
        NativeTrayFreshness::Live => "Live - daemon data current",
        NativeTrayFreshness::Stale => "Stale - reconnecting",
        NativeTrayFreshness::Offline => "Offline - last values shown",
        NativeTrayFreshness::Unavailable => "Data unavailable",
    };
    let quota = snapshot
        .quota_floor_remaining_percent
        .map(|value| format!("Quota floor: {value}% remaining"))
        .unwrap_or_else(|| "Quota floor: no active quota".to_string());
    handles.status.set_text(status).map_err(|e| e.to_string())?;
    handles
        .cost
        .set_text(format!(
            "Today: ${:.2} - {} tokens",
            snapshot.today_cost_usd, snapshot.today_tokens
        ))
        .map_err(|e| e.to_string())?;
    handles.quota.set_text(quota).map_err(|e| e.to_string())?;
    handles
        .providers
        .set_text(format!(
            "Providers: {} connected",
            snapshot.connected_providers
        ))
        .map_err(|e| e.to_string())?;
    if let Some(tray) = app.tray_by_id("openburnbar-main") {
        let _ = tray.set_tooltip(Some(format!(
            "OpenBurnBar - {} - ${:.2} today",
            match snapshot.freshness {
                NativeTrayFreshness::Live => "live",
                NativeTrayFreshness::Stale => "stale",
                NativeTrayFreshness::Offline => "offline",
                NativeTrayFreshness::Unavailable => "unavailable",
            },
            snapshot.today_cost_usd
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deep_links_are_allowlisted_and_renderer_safe() {
        let links = [
            ("openburnbar://dashboard", "overview", "open-dashboard"),
            ("openburnbar://search", "activity", "open-search"),
            ("openburnbar://chat", "chat", "open-chat"),
            ("openburnbar://insights/today", "insights", "open-insights"),
            (
                "openburnbar://membership/success",
                "account",
                "membership-success",
            ),
            (
                "openburnbar://membership/cancel",
                "account",
                "membership-cancel",
            ),
        ];
        for (raw, route, action) in links {
            assert_eq!(
                validate_deep_link(raw),
                Ok(NativeDeepLink {
                    route: route.to_string(),
                    action: action.to_string(),
                })
            );
        }
    }

    #[test]
    fn hostile_or_privileged_deep_links_fail_closed() {
        for raw in [
            "https://openburnbar.dev/dashboard",
            "openburnbar://link-cli",
            "openburnbar://membership/success?token=secret",
            "openburnbar://user@example.com/dashboard",
            "openburnbar://dashboard#fragment",
            "openburnbar://unknown",
            "openburnbar://chat\nignored",
        ] {
            assert_eq!(validate_deep_link(raw), Err(()), "{raw}");
        }
    }

    #[test]
    fn launch_intent_tracks_background_and_rejections() {
        let intent = LaunchIntent::from_args([
            "openburnbar-linux-desktop",
            "--background",
            "openburnbar://chat",
            "openburnbar://unknown",
        ]);
        assert!(intent.background);
        assert_eq!(intent.deep_links.len(), 1);
        assert_eq!(intent.rejected_deep_links, 1);
    }

    #[test]
    fn native_route_actions_are_locked_to_known_pairs() {
        assert!(route_action_allowed("providers", "open-providers"));
        assert!(route_action_allowed("support", "reconnect-daemon"));
        assert!(!route_action_allowed("providers", "open-chat"));
        assert!(!route_action_allowed("unknown", "open-dashboard"));
    }

    #[test]
    fn status_window_position_clamps_to_monitor_bounds() {
        assert_eq!(
            clamp_status_window_position(1_910.0, 20.0, 0.0, 0.0, 1_920.0, 1_080.0),
            StatusWindowGeometry {
                x: 1_488.0,
                y: 32.0
            }
        );
        assert_eq!(
            clamp_status_window_position(10.0, 1_070.0, 0.0, 0.0, 1_920.0, 1_080.0),
            StatusWindowGeometry { x: 12.0, y: 528.0 }
        );
    }

    #[test]
    fn xdg_autostart_path_requires_an_absolute_owned_config_root() {
        assert_eq!(
            resolve_autostart_path(Some(OsStr::new("/home/alice")), None).unwrap(),
            PathBuf::from("/home/alice/.config/autostart/dev.openburnbar.OpenBurnBar.desktop")
        );
        assert_eq!(
            resolve_autostart_path(
                Some(OsStr::new("/home/alice")),
                Some(OsStr::new("/tmp/config"))
            )
            .unwrap(),
            PathBuf::from("/tmp/config/autostart/dev.openburnbar.OpenBurnBar.desktop")
        );
        assert!(resolve_autostart_path(None, Some(OsStr::new("relative"))).is_err());
    }

    #[test]
    fn login_start_round_trips_exact_canonical_entry() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "openburnbar-native-shell-{}-{nonce}",
            std::process::id()
        ));
        let path = root.join("autostart/dev.openburnbar.OpenBurnBar.desktop");
        assert!(!login_start_enabled_at(&path).unwrap());
        set_login_start_at(&path, true).unwrap();
        assert!(login_start_enabled_at(&path).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), AUTOSTART_ENTRY);
        assert_eq!(
            fs::metadata(path.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::write(&path, "[Desktop Entry]\nExec=evil\n").unwrap();
        assert!(!login_start_enabled_at(&path).unwrap());
        set_login_start_at(&path, false).unwrap();
        assert!(!path.exists());
        let _ = fs::remove_dir_all(root);
    }
}
