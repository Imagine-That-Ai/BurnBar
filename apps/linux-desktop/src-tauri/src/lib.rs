use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};
use tauri::ipc::Channel;
use tauri::menu::{MenuBuilder, MenuItem, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_global_shortcut::{Code, Modifiers, ShortcutState};
use tauri_plugin_shell::ShellExt;

mod media;
mod single_instance;
mod update_feed;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DaemonHealth {
    ok: bool,
    protocol_version: Option<u32>,
    daemon_version: Option<String>,
    socket_path: Option<String>,
    gateway_enabled: Option<bool>,
    gateway_host: Option<String>,
    gateway_port: Option<u16>,
    error: Option<String>,
}

impl Default for DaemonHealth {
    fn default() -> Self {
        Self {
            ok: false,
            protocol_version: None,
            daemon_version: None,
            socket_path: None,
            gateway_enabled: None,
            gateway_host: None,
            gateway_port: None,
            error: None,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct PerfSample {
    name: String,
    ms: f64,
    at: String,
    source: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct PerfOperationResult {
    name: String,
    ms: f64,
    source: String,
    ok: bool,
    detail: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceParityRow {
    adapter: String,
    status: String,
    discovery_method: String,
    blocker: Option<String>,
    evidence: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IntegrationStatusRow {
    kind: String,
    label: String,
    state: String,
    detail: String,
    dependency: Option<String>,
    config_location: String,
    docs_href: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct IntegrationsStatusPayload {
    integrations: Vec<IntegrationStatusRow>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SmartHubCommandPayload {
    operation: String,
    payload: serde_json::Value,
}

/// The Linux CLI is the existing SmartHub contract. Keep this operation map
/// intentionally closed: the renderer can request a known operation, never an
/// arbitrary executable or argument vector.
fn smart_hub_cli_args(operation: &str) -> Result<&'static [&'static str], String> {
    match operation {
        "discover" => Ok(&["devices", "discover", "smarthub", "--json"]),
        "status" => Ok(&["devices", "iot", "smarthub", "status", "--json"]),
        "cast_status" => Ok(&["devices", "iot", "cast", "status", "--json"]),
        "homeassistant_status" => Ok(&["devices", "iot", "homeassistant", "status", "--json"]),
        "parity" => Ok(&["devices", "parity", "--json"]),
        _ => Err("smarthub_operation_not_allowlisted".to_string()),
    }
}

/// First non-empty trimmed env value among the given keys (VAL-PATH-001 parity with TS/Swift).
fn first_non_empty_env(keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Ok(value) = std::env::var(key) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn linux_support_dir() -> PathBuf {
    if let Some(override_dir) = first_non_empty_env(&[
        "OPENBURNBAR_DAEMON_SUPPORT_DIR",
        "BURNBAR_DAEMON_SUPPORT_DIR",
    ]) {
        return PathBuf::from(override_dir);
    }
    if let Some(xdg) = first_non_empty_env(&["XDG_DATA_HOME"]) {
        return PathBuf::from(xdg).join("openburnbar");
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".local/share/openburnbar")
}

fn linux_socket_path() -> PathBuf {
    if let Some(override_path) = first_non_empty_env(&[
        "OPENBURNBAR_SOCKET_PATH",
        "OPENBURNBAR_DAEMON_SOCKET_PATH",
        "BURNBAR_DAEMON_SOCKET_PATH",
    ]) {
        return PathBuf::from(override_path);
    }
    if let Some(runtime_dir) = first_non_empty_env(&["XDG_RUNTIME_DIR"]) {
        return PathBuf::from(runtime_dir)
            .join("openburnbar")
            .join("daemon.sock");
    }
    linux_support_dir().join("openburnbar-daemon.sock")
}

/// Read socket auth token; refuse world/group-readable files (mode must be 0600 or tighter).
fn read_auth_token() -> Option<String> {
    read_token_file_secure(&linux_support_dir().join("daemon-socket-auth-token"))
}

/// Read a token file only when it is a regular file with mode 0600 or tighter.
fn read_token_file_secure(path: &std::path::Path) -> Option<String> {
    use std::os::unix::fs::FileTypeExt;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    let ft = meta.file_type();
    if !ft.is_file()
        || ft.is_fifo()
        || ft.is_socket()
        || ft.is_block_device()
        || ft.is_char_device()
    {
        eprintln!(
            "openburnbar: refusing token path {} (not a regular file)",
            path.display()
        );
        return None;
    }
    let mode = meta.permissions().mode() & 0o777;
    if mode & 0o077 != 0 {
        eprintln!(
            "openburnbar: refusing token file {} with mode {:o} (require 0600 or tighter)",
            path.display(),
            mode
        );
        return None;
    }
    if meta.uid() != unsafe { libc::geteuid() } || meta.nlink() != 1 {
        eprintln!(
            "openburnbar: refusing token file {} with invalid owner or link count",
            path.display()
        );
        return None;
    }
    if meta.len() > 16_384 {
        eprintln!(
            "openburnbar: refusing oversized token file {}",
            path.display()
        );
        return None;
    }
    let mut contents = String::new();
    file.read_to_string(&mut contents).ok()?;
    let token = contents.trim().to_string();
    (!token.is_empty()).then_some(token)
}

fn read_gateway_auth_token() -> Option<String> {
    // Prefer file-based token (0600); env is last-resort for CI/dev only.
    if let Ok(path) = std::env::var("OPENBURNBAR_GATEWAY_AUTH_TOKEN_FILE") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            if let Some(token) = read_token_file_secure(std::path::Path::new(trimmed)) {
                return Some(token);
            }
        }
    }
    if let Some(token) = read_token_file_secure(&linux_support_dir().join("gateway-auth-token")) {
        return Some(token);
    }
    if let Ok(token) = std::env::var("OPENBURNBAR_GATEWAY_AUTH_TOKEN") {
        let trimmed = token.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    None
}

const GATEWAY_MAX_MESSAGES: usize = 256;
const GATEWAY_MAX_CONTENT_BYTES: usize = 1_048_576;
const GATEWAY_MAX_RESPONSE_BYTES: usize = 16_777_216;
const DAEMON_ONBOARDING_SNAPSHOT_METHOD: &str = "daemon.onboarding.snapshot";
const DAEMON_ONBOARDING_ACTION_METHOD: &str = "daemon.onboarding.action";
const DAEMON_ONBOARDING_RESET_METHOD: &str = "daemon.onboarding.reset";
const DAEMON_SUBSCRIPTION_START_METHOD: &str = "subscription.start";
const DAEMON_SUBSCRIPTION_RESUME_METHOD: &str = "subscription.resume";
const DAEMON_SUBSCRIPTION_STOP_METHOD: &str = "subscription.stop";

static INITIAL_DEEP_LINK_ROUTE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static FORWARDED_ROUTE_QUEUE: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

fn initial_deep_link_route_store() -> &'static Mutex<Option<String>> {
    INITIAL_DEEP_LINK_ROUTE.get_or_init(|| Mutex::new(None))
}

fn forwarded_route_queue() -> &'static Mutex<Vec<String>> {
    FORWARDED_ROUTE_QUEUE.get_or_init(|| Mutex::new(Vec::new()))
}

/// Accept only the routes registered by the Linux shell. External URLs,
/// credentials, query strings, and fragments are deliberately rejected at the
/// native boundary before they can influence renderer navigation.
fn validated_deep_link_route(raw: &str) -> Option<&'static str> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.scheme() != "openburnbar"
        || url.username() != ""
        || url.password().is_some()
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let host = url.host_str()?;
    let path = url.path().trim_matches('/');
    match (host, path) {
        ("dashboard", "") | ("overview", "") => Some("overview"),
        ("chat", "") => Some("chat"),
        ("settings", "") => Some("settings"),
        ("updates", "") => Some("updates"),
        ("membership", "success" | "cancel") => Some("account"),
        ("route", "overview") => Some("overview"),
        ("route", "chat") => Some("chat"),
        ("route", "settings") => Some("settings"),
        ("route", "updates") => Some("updates"),
        _ => None,
    }
}

fn store_initial_deep_link_route(route: Option<String>) {
    if let Some(mut slot) = initial_deep_link_route_store().lock().ok() {
        *slot = route;
    }
}

fn route_from_single_instance_message(message: &single_instance::Message) -> Option<String> {
    match message {
        single_instance::Message::Focus => Some("overview".to_string()),
        single_instance::Message::Route { route } => Some(route.clone()),
        single_instance::Message::NotificationAction { action, .. } => {
            single_instance::notification_action_route(action).map(str::to_string)
        }
    }
}

fn store_forwarded_route(route: String) {
    if let Ok(mut routes) = forwarded_route_queue().lock() {
        routes.push(route);
        if routes.len() > 16 {
            let excess = routes.len() - 16;
            routes.drain(0..excess);
        }
    }
}

fn start_single_instance_dispatcher(app: AppHandle, receiver: Receiver<single_instance::Message>) {
    let _ = thread::Builder::new()
        .name("openburnbar-single-instance-dispatch".to_string())
        .spawn(move || {
            while let Ok(message) = receiver.recv() {
                if let Some(route) = route_from_single_instance_message(&message) {
                    store_forwarded_route(route.clone());
                    emit_tray_route(&app, &route);
                }
                if let single_instance::Message::NotificationAction { action, payload } = message {
                    let _ = app.emit(
                        "notification-action",
                        serde_json::json!({ "action": action, "payload": payload }),
                    );
                }
            }
        });
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GatewayProxyMessage {
    role: String,
    content: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GatewayProxyRequest {
    request_id: String,
    model: String,
    messages: Vec<GatewayProxyMessage>,
}

static GATEWAY_CANCELLATIONS: OnceLock<
    Mutex<HashMap<String, tokio_util::sync::CancellationToken>>,
> = OnceLock::new();

fn gateway_cancellations() -> &'static Mutex<HashMap<String, tokio_util::sync::CancellationToken>> {
    GATEWAY_CANCELLATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn validate_gateway_request(request: &GatewayProxyRequest) -> Result<(), String> {
    let request_id_is_valid = !request.request_id.is_empty()
        && request.request_id.len() <= 128
        && request
            .request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
    if !request_id_is_valid {
        return Err("gateway_invalid_request_id".into());
    }

    let model = request.model.trim();
    if model.is_empty() || model.len() > 256 {
        return Err("gateway_invalid_model".into());
    }
    if request.messages.is_empty() || request.messages.len() > GATEWAY_MAX_MESSAGES {
        return Err("gateway_invalid_message_count".into());
    }
    let content_bytes = request.messages.iter().try_fold(0usize, |total, message| {
        if !matches!(
            message.role.as_str(),
            "system" | "user" | "assistant" | "tool"
        ) {
            return Err("gateway_invalid_message_role".to_string());
        }
        total
            .checked_add(message.content.len())
            .ok_or_else(|| "gateway_request_too_large".to_string())
    })?;
    if content_bytes > GATEWAY_MAX_CONTENT_BYTES {
        return Err("gateway_request_too_large".into());
    }
    Ok(())
}

fn gateway_endpoint_from_health(health: &DaemonHealth, path: &str) -> Result<reqwest::Url, String> {
    if !health.ok || health.gateway_enabled != Some(true) {
        return Err("gateway_disabled".into());
    }
    let host = health.gateway_host.as_deref().unwrap_or("127.0.0.1");
    if !matches!(host, "127.0.0.1" | "::1" | "localhost") {
        return Err("gateway_non_loopback_host_refused".into());
    }
    let port = health
        .gateway_port
        .filter(|port| *port > 0)
        .ok_or("gateway_missing_port")?;
    let authority = if host == "::1" {
        format!("[::1]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let url = reqwest::Url::parse(&format!("http://{authority}{path}"))
        .map_err(|_| "gateway_invalid_endpoint".to_string())?;
    if url.scheme() != "http"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("gateway_invalid_endpoint".into());
    }
    Ok(url)
}

fn gateway_http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| format!("gateway_client_init:{error}"))
}

#[tauri::command]
async fn gateway_probe() -> Result<bool, String> {
    let health = probe_daemon_health();
    let url = gateway_endpoint_from_health(&health, "/health")?;
    let token = read_gateway_auth_token().ok_or("gateway_token_unavailable")?;
    let response = gateway_http_client()?
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|error| format!("gateway_unreachable:{error}"))?;
    Ok(response.status().is_success())
}

async fn run_gateway_chat_stream(
    request: &GatewayProxyRequest,
    on_event: &Channel<String>,
    cancellation: &tokio_util::sync::CancellationToken,
) -> Result<(), String> {
    validate_gateway_request(request)?;
    let health = probe_daemon_health();
    let url = gateway_endpoint_from_health(&health, "/v1/chat/completions")?;
    let token = read_gateway_auth_token().ok_or("gateway_token_unavailable")?;
    let body = serde_json::json!({
        "model": request.model.trim(),
        "stream": true,
        "stream_options": { "include_usage": true },
        "messages": &request.messages,
    });
    let send = gateway_http_client()?
        .post(url)
        .bearer_auth(token)
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .json(&body)
        .send();
    let response = tokio::select! {
        _ = cancellation.cancelled() => return Err("gateway_aborted".into()),
        result = send => result.map_err(|error| format!("gateway_unreachable:{error}"))?,
    };

    let status = response.status();
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        let bounded = detail.chars().take(4096).collect::<String>();
        return Err(format!("gateway_http:{}:{bounded}", status.as_u16()));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    if !content_type
        .split(';')
        .next()
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("text/event-stream"))
    {
        return Err("gateway_invalid_content_type".into());
    }

    let mut total_bytes = 0usize;
    let mut pending_utf8 = Vec::new();
    let mut stream = response.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = cancellation.cancelled() => return Err("gateway_aborted".into()),
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let bytes = chunk.map_err(|error| format!("gateway_stream_interrupted:{error}"))?;
        total_bytes = total_bytes
            .checked_add(bytes.len())
            .ok_or("gateway_response_too_large")?;
        if total_bytes > GATEWAY_MAX_RESPONSE_BYTES {
            return Err("gateway_response_too_large".into());
        }
        pending_utf8.extend_from_slice(&bytes);
        loop {
            match std::str::from_utf8(&pending_utf8) {
                Ok(text) => {
                    if !text.is_empty() {
                        on_event
                            .send(text.to_string())
                            .map_err(|_| "gateway_renderer_disconnected".to_string())?;
                    }
                    pending_utf8.clear();
                    break;
                }
                Err(error) => {
                    let valid_up_to = error.valid_up_to();
                    if valid_up_to > 0 {
                        let text = std::str::from_utf8(&pending_utf8[..valid_up_to])
                            .map_err(|_| "gateway_invalid_utf8")?;
                        on_event
                            .send(text.to_string())
                            .map_err(|_| "gateway_renderer_disconnected".to_string())?;
                        pending_utf8.drain(..valid_up_to);
                    }
                    if error.error_len().is_some() {
                        return Err("gateway_invalid_utf8".into());
                    }
                    break;
                }
            }
        }
    }
    if !pending_utf8.is_empty() {
        return Err("gateway_invalid_utf8".into());
    }
    Ok(())
}

/// Returns the gateway bearer for the HTTP gateway client (chat stream).
/// Security note (Issue 20): this enters the renderer JS heap. Mitigations:
/// restrictive CSP (tauri.conf.json), token file over env, short-lived tokens.
/// Full fix is a Rust-side gateway proxy (Phase 4) that never returns the secret.
#[tauri::command]
async fn gateway_chat_stream(
    request: GatewayProxyRequest,
    on_event: Channel<String>,
) -> Result<(), String> {
    let cancellation = tokio_util::sync::CancellationToken::new();
    {
        let mut requests = gateway_cancellations()
            .lock()
            .map_err(|_| "gateway_cancellation_registry_poisoned")?;
        if requests.contains_key(&request.request_id) {
            return Err("gateway_duplicate_request_id".into());
        }
        requests.insert(request.request_id.clone(), cancellation.clone());
    }

    let result = run_gateway_chat_stream(&request, &on_event, &cancellation).await;
    if let Ok(mut requests) = gateway_cancellations().lock() {
        requests.remove(&request.request_id);
    }
    result
}

#[tauri::command]
fn gateway_chat_cancel(request_id: String) -> Result<(), String> {
    let requests = gateway_cancellations()
        .lock()
        .map_err(|_| "gateway_cancellation_registry_poisoned")?;
    if let Some(cancellation) = requests.get(&request_id) {
        cancellation.cancel();
    }
    Ok(())
}

fn probe_daemon_health() -> DaemonHealth {
    probe_daemon_health_with_timeout(Duration::from_secs(5), false)
}

fn probe_authenticated_daemon_health(timeout: Duration) -> DaemonHealth {
    probe_daemon_health_with_timeout(timeout, true)
}

fn probe_daemon_health_with_timeout(timeout: Duration, require_auth: bool) -> DaemonHealth {
    let socket_path = linux_socket_path();
    let auth_token = read_auth_token();
    if require_auth && auth_token.is_none() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Daemon socket auth token is unavailable".into()),
            ..Default::default()
        };
    }
    let mut stream = match UnixStream::connect(&socket_path) {
        Ok(s) => s,
        Err(e) => {
            return DaemonHealth {
                ok: false,
                socket_path: Some(socket_path.display().to_string()),
                error: Some(e.to_string()),
                ..Default::default()
            };
        }
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut envelope = serde_json::json!({
        "protocolVersion": 1,
        "id": format!("health-{stamp}"),
        "method": "daemon.health",
        "traceId": format!("trace-{stamp}"),
    });
    if let Some(token) = auth_token {
        envelope["authToken"] = serde_json::Value::String(token);
    }
    let payload = format!("{envelope}\n");
    if stream.write_all(payload.as_bytes()).is_err() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Failed to write health request".into()),
            ..Default::default()
        };
    }

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Failed to read health response".into()),
            ..Default::default()
        };
    }
    let parsed: serde_json::Value = match serde_json::from_str(line.trim()) {
        Ok(v) => v,
        Err(e) => {
            return DaemonHealth {
                ok: false,
                socket_path: Some(socket_path.display().to_string()),
                error: Some(format!("Invalid JSON response: {e}")),
                ..Default::default()
            };
        }
    };
    if let Some(err) = parsed
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
    {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some(err.to_string()),
            ..Default::default()
        };
    }
    let result = parsed
        .get("result")
        .cloned()
        .unwrap_or(serde_json::json!({}));
    DaemonHealth {
        ok: result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false),
        protocol_version: result
            .get("protocolVersion")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32),
        daemon_version: result
            .get("daemonVersion")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        socket_path: Some(
            result
                .get("socketPath")
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .unwrap_or_else(|| socket_path.display().to_string()),
        ),
        gateway_enabled: result.get("gatewayEnabled").and_then(|v| v.as_bool()),
        gateway_host: result
            .get("gatewayHost")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        gateway_port: result
            .get("gatewayPort")
            .and_then(|v| v.as_u64())
            .map(|v| v as u16),
        error: None,
    }
}

const SYSTEM_DAEMON_LAUNCHER: &str = "/usr/libexec/openburnbar-daemon-launch";
const SYSTEM_GUI_EXECUTABLE: &str = "/usr/bin/openburnbar-linux-desktop";
const APPIMAGE_DAEMON_LAUNCHER: &str = "usr/libexec/openburnbar-daemon-launch";
const DAEMON_STARTUP_PROBE_TIMEOUT: Duration = Duration::from_millis(250);
const DAEMON_STARTUP_RETRY_DELAY: Duration = Duration::from_millis(250);
const DAEMON_STARTUP_READINESS_ATTEMPTS: usize = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DaemonLauncherKind {
    AppImage,
    SystemPackage,
}

#[derive(Debug, PartialEq, Eq)]
enum DaemonStartupOutcome {
    AlreadyRunning,
    Started,
    Unpackaged,
    SpawnFailed(String),
    ReadinessTimedOut,
}

fn path_filesystem_is_read_only(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;

    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    let mut stats = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: `path` is NUL-terminated and `statvfs` initializes `stats` on success.
    let result = unsafe { libc::statvfs(path.as_ptr(), stats.as_mut_ptr()) };
    if result != 0 {
        return false;
    }
    // SAFETY: a successful `statvfs` call initialized the structure.
    let stats = unsafe { stats.assume_init() };
    stats.f_flag & libc::ST_RDONLY as libc::c_ulong != 0
}

fn trusted_packaged_launcher(candidate: &Path, kind: DaemonLauncherKind) -> bool {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    if !candidate.is_absolute() {
        return false;
    }
    let Ok(canonical_candidate) = fs::canonicalize(candidate) else {
        return false;
    };
    if canonical_candidate != candidate {
        return false;
    }
    let Ok(metadata) = fs::symlink_metadata(candidate) else {
        return false;
    };
    let mode = metadata.permissions().mode();
    if !metadata.file_type().is_file() || mode & 0o111 == 0 {
        return false;
    }

    match kind {
        DaemonLauncherKind::AppImage => {
            let Some(appdir) = std::env::var_os("APPDIR").map(PathBuf::from) else {
                return false;
            };
            let Ok(canonical_appdir) = fs::canonicalize(&appdir) else {
                return false;
            };
            if !appdir.is_absolute()
                || canonical_appdir != appdir
                || candidate != canonical_appdir.join(APPIMAGE_DAEMON_LAUNCHER)
                || !path_filesystem_is_read_only(&canonical_appdir)
                || !path_filesystem_is_read_only(candidate)
            {
                return false;
            }
            let Ok(current_exe) = std::env::current_exe().and_then(fs::canonicalize) else {
                return false;
            };
            current_exe.starts_with(&canonical_appdir)
        }
        DaemonLauncherKind::SystemPackage => {
            let Ok(current_exe) = std::env::current_exe().and_then(fs::canonicalize) else {
                return false;
            };
            let Ok(current_exe_metadata) = fs::symlink_metadata(&current_exe) else {
                return false;
            };
            let current_exe_mode = current_exe_metadata.permissions().mode();
            if candidate != Path::new(SYSTEM_DAEMON_LAUNCHER)
                || metadata.uid() != 0
                || mode & 0o022 != 0
                || current_exe != Path::new(SYSTEM_GUI_EXECUTABLE)
                || !current_exe_metadata.file_type().is_file()
                || current_exe_metadata.uid() != 0
                || current_exe_mode & 0o111 == 0
                || current_exe_mode & 0o022 != 0
            {
                return false;
            }
            [
                Path::new("/usr"),
                Path::new("/usr/bin"),
                Path::new("/usr/libexec"),
            ]
            .into_iter()
            .all(|directory| {
                fs::symlink_metadata(directory).is_ok_and(|directory_metadata| {
                    directory_metadata.file_type().is_dir()
                        && directory_metadata.uid() == 0
                        && directory_metadata.permissions().mode() & 0o022 == 0
                }) && fs::canonicalize(directory).is_ok_and(|path| path == directory)
            })
        }
    }
}

fn resolve_packaged_daemon_launcher_with<Verify>(
    appdir: Option<&std::ffi::OsStr>,
    system_package_executable: bool,
    verify: Verify,
) -> Option<PathBuf>
where
    Verify: Fn(&Path, DaemonLauncherKind) -> bool,
{
    if let Some(appdir) = appdir {
        let appdir = Path::new(appdir);
        if appdir.is_absolute() {
            let candidate = appdir.join(APPIMAGE_DAEMON_LAUNCHER);
            if verify(&candidate, DaemonLauncherKind::AppImage) {
                return Some(candidate);
            }
        }
    }

    if system_package_executable {
        let candidate = PathBuf::from(SYSTEM_DAEMON_LAUNCHER);
        return verify(&candidate, DaemonLauncherKind::SystemPackage).then_some(candidate);
    }
    None
}

fn resolve_packaged_daemon_launcher() -> Option<PathBuf> {
    let system_package_executable = std::env::current_exe()
        .and_then(fs::canonicalize)
        .is_ok_and(|path| path == Path::new(SYSTEM_GUI_EXECUTABLE));
    resolve_packaged_daemon_launcher_with(
        std::env::var_os("APPDIR").as_deref(),
        system_package_executable,
        trusted_packaged_launcher,
    )
}

fn spawn_daemon_launcher(path: &Path) -> Result<(), String> {
    let mut child = Command::new(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| format!("daemon launcher failed: {error}"))?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

fn ensure_daemon_running_with<Probe, Spawn, Sleep>(
    launcher: Option<PathBuf>,
    mut probe: Probe,
    spawn: Spawn,
    mut sleep: Sleep,
    readiness_attempts: usize,
) -> DaemonStartupOutcome
where
    Probe: FnMut() -> bool,
    Spawn: FnOnce(&Path) -> Result<(), String>,
    Sleep: FnMut(),
{
    if probe() {
        return DaemonStartupOutcome::AlreadyRunning;
    }
    let Some(launcher) = launcher else {
        return DaemonStartupOutcome::Unpackaged;
    };
    if let Err(error) = spawn(&launcher) {
        return DaemonStartupOutcome::SpawnFailed(error);
    }
    for attempt in 0..readiness_attempts {
        if probe() {
            return DaemonStartupOutcome::Started;
        }
        if attempt + 1 < readiness_attempts {
            sleep();
        }
    }
    DaemonStartupOutcome::ReadinessTimedOut
}

fn start_packaged_daemon_lifecycle(app: AppHandle) {
    thread::spawn(move || {
        let outcome = ensure_daemon_running_with(
            resolve_packaged_daemon_launcher(),
            || probe_authenticated_daemon_health(DAEMON_STARTUP_PROBE_TIMEOUT).ok,
            spawn_daemon_launcher,
            || thread::sleep(DAEMON_STARTUP_RETRY_DELAY),
            DAEMON_STARTUP_READINESS_ATTEMPTS,
        );
        match outcome {
            DaemonStartupOutcome::AlreadyRunning => {
                tracing::debug!("authenticated daemon is already running");
            }
            DaemonStartupOutcome::Started => {
                tracing::info!("packaged daemon launcher reached authenticated readiness");
                let _ = app.emit("daemon-health", probe_daemon_health());
            }
            DaemonStartupOutcome::Unpackaged => {
                tracing::debug!(
                    "no trusted packaged daemon launcher; leaving development launch unchanged"
                );
            }
            DaemonStartupOutcome::SpawnFailed(error) => {
                tracing::warn!(error = %error, "packaged daemon launcher failed");
            }
            DaemonStartupOutcome::ReadinessTimedOut => {
                tracing::warn!(
                    "packaged daemon did not reach authenticated readiness before timeout"
                );
            }
        }
    });
}

fn call_daemon_perf_measure(name: &str) -> Result<(bool, String, Option<String>), String> {
    let socket_path = linux_socket_path();
    let mut stream = UnixStream::connect(&socket_path).map_err(|e| e.to_string())?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut envelope = serde_json::json!({
        "protocolVersion": 1,
        "id": format!("perf-{stamp}"),
        "method": "perf.measure",
        "traceId": format!("trace-perf-{stamp}"),
        "params": { "name": name },
    });
    if let Some(token) = read_auth_token() {
        envelope["authToken"] = serde_json::Value::String(token);
    }
    stream
        .write_all(format!("{envelope}\n").as_bytes())
        .map_err(|e| e.to_string())?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(line.trim()).map_err(|e| e.to_string())?;
    if let Some(err) = parsed
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
    {
        return Err(err.to_string());
    }
    let result = parsed
        .get("result")
        .ok_or_else(|| "perf.measure response missing result".to_string())?;
    let ok = result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false);
    let source = result
        .get("source")
        .and_then(|v| v.as_str())
        .unwrap_or("daemon-perf-measure")
        .to_string();
    let detail = result.get("detail").map(|value| value.to_string());
    Ok((ok, source, detail))
}

#[tauri::command]
fn daemon_health() -> DaemonHealth {
    probe_daemon_health()
}

fn trusted_root_owned_executable(candidates: &[&str]) -> Option<PathBuf> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};

    for path in candidates {
        let candidate = PathBuf::from(path);
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        let file_type = metadata.file_type();
        if !file_type.is_file()
            || file_type.is_symlink()
            || file_type.is_fifo()
            || file_type.is_socket()
            || file_type.is_block_device()
            || file_type.is_char_device()
            || metadata.uid() != 0
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o022 != 0
        {
            continue;
        }
        return Some(candidate);
    }
    None
}

fn trusted_openburnbar_cli() -> Result<PathBuf, String> {
    trusted_root_owned_executable(&[
        "/usr/bin/openburnbar-cli",
        "/usr/local/bin/openburnbar-cli",
        "/opt/openburnbar/bin/openburnbar-cli",
    ])
    .ok_or_else(|| "trusted_openburnbar_cli_unavailable".to_string())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilityCatalog {
    schema_version: u32,
    catalog_version: String,
    capabilities: Vec<RuntimeCapabilityDefinition>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilityDefinition {
    id: String,
    domain: String,
    evaluator: String,
    unavailable_reason: String,
    substitute: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilityEntry {
    id: String,
    domain: String,
    state: String,
    reason: String,
    substitute: Option<String>,
    source: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilityManifest {
    schema_version: u32,
    catalog_version: String,
    shell_version: String,
    daemon_version: Option<String>,
    daemon_protocol_version: Option<u32>,
    session_type: Option<String>,
    desktop: Option<String>,
    capabilities: Vec<RuntimeCapabilityEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeMediaCapability {
    available: bool,
    codecs_known: bool,
    source: String,
    detail: Option<String>,
}

const RUNTIME_CAPABILITY_CATALOG: &str =
    include_str!("../../../../packaging/linux/runtime-capability-catalog.json");

fn evaluate_runtime_capability(
    definition: RuntimeCapabilityDefinition,
    health: &DaemonHealth,
    session_type: Option<&str>,
    has_session_bus: bool,
    media: Option<&RuntimeMediaCapability>,
) -> Result<RuntimeCapabilityEntry, String> {
    let available = |reason: &str, source: &str| {
        (
            "available".to_string(),
            reason.to_string(),
            source.to_string(),
        )
    };
    let unavailable = || {
        (
            "unavailable".to_string(),
            definition.unavailable_reason.clone(),
            "runtime-probe".to_string(),
        )
    };
    let (state, reason, source) = match definition.evaluator.as_str() {
        "always" => available("Implemented by the native Linux shell.", "compiled-shell-contract"),
        "daemon" if health.ok => available("Supported by the connected daemon.", "daemon-health"),
        "daemon" => unavailable(),
        "gateway" if health.ok && health.gateway_enabled == Some(true) => {
            available("The authenticated loopback gateway is enabled.", "daemon-health")
        }
        "gateway" => unavailable(),
        "media" => match media {
            Some(capability) if capability.available && capability.codecs_known => available(
                capability
                    .detail
                    .as_deref()
                    .unwrap_or("The daemon media engine and codec pipeline are available."),
                &capability.source,
            ),
            Some(capability) if capability.available => (
                "degraded".to_string(),
                capability.detail.clone().unwrap_or_else(|| {
                    "Mercury control and file transfer are available, but capture codec support is not confirmed."
                        .to_string()
                }),
                capability.source.clone(),
            ),
            Some(capability) => (
                "unavailable".to_string(),
                capability
                    .detail
                    .clone()
                    .unwrap_or_else(|| definition.unavailable_reason.clone()),
                capability.source.clone(),
            ),
            None => unavailable(),
        },
        "trusted-cli" if trusted_openburnbar_cli().is_ok() => {
            available("A trusted packaged CLI is installed.", "root-owned-package-path")
        }
        "trusted-cli" => unavailable(),
        "secret-service"
            if has_session_bus
                && trusted_root_owned_executable(&[
                    "/usr/bin/secret-tool",
                    "/usr/local/bin/secret-tool",
                    "/bin/secret-tool",
                ])
                .is_some() =>
        {
            available("Secret Service tooling and a session bus are present.", "native-tool-probe")
        }
        "secret-service" => unavailable(),
        "kwallet"
            if has_session_bus
                && trusted_root_owned_executable(&[
                    "/usr/bin/kwallet-query",
                    "/usr/local/bin/kwallet-query",
                    "/bin/kwallet-query",
                ])
                .is_some() =>
        {
            available("KWallet tooling and a session bus are present.", "native-tool-probe")
        }
        "kwallet" => unavailable(),
        "portal" if has_session_bus => (
            "degraded".to_string(),
            "A session bus is present; each portal grant still requires a live request and user consent."
                .to_string(),
            "desktop-session-probe".to_string(),
        ),
        "portal" => unavailable(),
        "tray" if !TRAY_INIT_FAILED.load(Ordering::Relaxed) => {
            available("The native tray item initialized.", "tauri-tray-runtime")
        }
        "tray" => unavailable(),
        "x11-overlay" if session_type == Some("x11") => {
            available("The X11 session supports the constrained overlay tier.", "desktop-session-probe")
        }
        "x11-overlay" => (
            "degraded".to_string(),
            definition.unavailable_reason.clone(),
            "desktop-session-probe".to_string(),
        ),
        "unavailable" => unavailable(),
        unknown => return Err(format!("runtime_capability_unknown_evaluator:{unknown}")),
    };
    Ok(RuntimeCapabilityEntry {
        id: definition.id,
        domain: definition.domain,
        state,
        reason,
        substitute: definition.substitute,
        source,
    })
}

fn evaluate_runtime_capabilities() -> Result<RuntimeCapabilityManifest, String> {
    let catalog: RuntimeCapabilityCatalog = serde_json::from_str(RUNTIME_CAPABILITY_CATALOG)
        .map_err(|error| format!("runtime_capability_catalog_invalid:{error}"))?;
    if catalog.schema_version != 1 {
        return Err("runtime_capability_schema_unsupported".to_string());
    }
    let health = probe_daemon_health();
    let session_type = std::env::var("XDG_SESSION_TYPE")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let desktop = std::env::var("XDG_CURRENT_DESKTOP")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let has_session_bus = std::env::var("DBUS_SESSION_BUS_ADDRESS")
        .ok()
        .is_some_and(|value| !value.trim().is_empty());
    let media = health
        .ok
        .then(|| {
            call_daemon_method_with_timeout(
                "daemon.media.capability.get",
                Some(serde_json::json!({})),
                Duration::from_secs(2),
            )
        })
        .and_then(Result::ok)
        .and_then(|value| serde_json::from_value::<RuntimeMediaCapability>(value).ok());
    let capabilities = catalog
        .capabilities
        .into_iter()
        .map(|definition| {
            evaluate_runtime_capability(
                definition,
                &health,
                session_type.as_deref(),
                has_session_bus,
                media.as_ref(),
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(RuntimeCapabilityManifest {
        schema_version: catalog.schema_version,
        catalog_version: catalog.catalog_version,
        shell_version: env!("CARGO_PKG_VERSION").to_string(),
        daemon_version: health.daemon_version,
        daemon_protocol_version: health.protocol_version,
        session_type,
        desktop,
        capabilities,
    })
}

#[tauri::command]
async fn runtime_capabilities() -> Result<RuntimeCapabilityManifest, String> {
    tauri::async_runtime::spawn_blocking(evaluate_runtime_capabilities)
        .await
        .map_err(|error| format!("runtime_capability_probe_join_failed:{error}"))?
}

fn integration_label(kind: &str) -> &'static str {
    match kind {
        "pixel_clock" => "PixelClock",
        "google_cast" => "Google Cast",
        "awtrix_http" => "AWTRIX HTTP",
        "home_assistant" => "Home Assistant",
        "smart_hub_bridge" => "SmartHub Bridge",
        _ => "Smart Device Integration",
    }
}

fn integration_dependency(kind: &str, discovery_method: &str) -> Option<String> {
    match kind {
        "pixel_clock" => {
            Some("AWTRIX HTTP endpoint, runtime agent, or _http._tcp mDNS".to_string())
        }
        "google_cast" => {
            Some("avahi-daemon + avahi-utils for _googlecast._tcp discovery".to_string())
        }
        "awtrix_http" => Some("avahi-daemon + avahi-utils for _http._tcp discovery".to_string()),
        "home_assistant" => {
            Some("OPENBURNBAR_HOME_ASSISTANT_URL and daemon-held Home Assistant token".to_string())
        }
        "smart_hub_bridge" => Some("Linux SmartHub bridge on loopback HTTP".to_string()),
        _ if discovery_method.is_empty() => None,
        _ => Some(discovery_method.to_string()),
    }
}

fn integration_config_location(kind: &str) -> &'static str {
    match kind {
        "pixel_clock" => "Configure via openburnbar-cli devices pixel-clock ...",
        "google_cast" => "Configure via openburnbar-cli devices iot cast status",
        "awtrix_http" => "Configure via openburnbar-cli devices discover awtrix",
        "home_assistant" => "Configure via openburnbar-cli devices iot homeassistant status",
        "smart_hub_bridge" => "Configure via openburnbar-cli devices iot smarthub status",
        _ => "Configure via openburnbar-cli devices parity --json",
    }
}

fn map_integration_state(kind: &str, status: &str, blocker: Option<&str>) -> &'static str {
    match status {
        "control_ok" | "cast_reachable" | "home_assistant_control_ok" | "bridge_control_ok" => {
            "connected"
        }
        "runtime_agent_detected"
        | "discoverable"
        | "api_reachable_control_blocked"
        | "bridge_reachable_control_blocked" => "configured",
        "disabled" => "disabled",
        "blocked"
        | "blocked_no_runtime_agent_or_device"
        | "blocked_missing_home_assistant_url"
        | "blocked_home_assistant_api_unreachable"
        | "blocked_bridge_not_reachable"
        | "blocked_googlecast_control_unreachable"
        | "blocked_no_googlecast_instances"
        | "blocked_until_bridge_health_reachable" => "unavailable",
        "configured" if kind == "home_assistant" => "configured",
        _ if blocker.map(|b| !b.trim().is_empty()).unwrap_or(false) => "unavailable",
        _ => "configured",
    }
}

fn map_parity_row(row: DeviceParityRow) -> Option<IntegrationStatusRow> {
    let kind = row.adapter.as_str();
    match kind {
        "pixel_clock" | "google_cast" | "awtrix_http" | "home_assistant" | "smart_hub_bridge" => {}
        _ => return None,
    }
    let state =
        map_integration_state(kind, row.status.as_str(), row.blocker.as_deref()).to_string();
    let status_detail = row.status.replace('_', " ");
    let detail = row
        .blocker
        .as_ref()
        .filter(|b| !b.trim().is_empty())
        .cloned()
        .unwrap_or_else(|| {
            format!(
                "{} via {}; evidence: {}",
                status_detail, row.discovery_method, row.evidence
            )
        });
    Some(IntegrationStatusRow {
        kind: kind.to_string(),
        label: integration_label(kind).to_string(),
        state,
        detail,
        dependency: integration_dependency(kind, row.discovery_method.as_str()),
        config_location: integration_config_location(kind).to_string(),
        docs_href: "docs/SMART_DISPLAY_DEVICE_QA.md".to_string(),
    })
}

#[tauri::command]
fn integrations_status() -> Result<IntegrationsStatusPayload, String> {
    let cli = trusted_openburnbar_cli()?;
    let output = Command::new(cli)
        .args(["devices", "parity", "--json"])
        .output()
        .map_err(|_| "openburnbar_cli_launch_failed".to_string())?;
    if !output.status.success() {
        return Err("openburnbar_cli_integrations_failed".to_string());
    }
    let rows = serde_json::from_slice::<Vec<DeviceParityRow>>(&output.stdout)
        .map_err(|e| format!("Invalid devices parity JSON: {e}"))?;
    Ok(IntegrationsStatusPayload {
        integrations: rows.into_iter().filter_map(map_parity_row).collect(),
    })
}

/// Execute one of the existing Linux SmartHub/device CLI contracts.
///
/// This intentionally does not become a generic CLI bridge. Every operation
/// has a fixed argv, the executable must be the root-owned packaged binary,
/// and the response must be bounded JSON before it reaches the renderer.
#[tauri::command]
fn smarthub_command(operation: String) -> Result<SmartHubCommandPayload, String> {
    let args = smart_hub_cli_args(operation.as_str())?;
    let cli = trusted_openburnbar_cli()?;
    let mut child = Command::new(cli)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "openburnbar_cli_smarthub_launch_failed".to_string())?;
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("openburnbar_cli_smarthub_timeout".to_string());
            }
            Ok(None) => thread::sleep(Duration::from_millis(25)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("openburnbar_cli_smarthub_wait_failed".to_string());
            }
        }
    }
    let output = child
        .wait_with_output()
        .map_err(|_| "openburnbar_cli_smarthub_output_failed".to_string())?;
    if !output.status.success() {
        return Err("openburnbar_cli_smarthub_command_failed".to_string());
    }
    const MAX_SMARTHUB_OUTPUT_BYTES: usize = 1_048_576;
    if output.stdout.len() > MAX_SMARTHUB_OUTPUT_BYTES {
        return Err("openburnbar_cli_smarthub_output_too_large".to_string());
    }
    let payload = serde_json::from_slice::<serde_json::Value>(&output.stdout)
        .map_err(|_| "openburnbar_cli_smarthub_invalid_json".to_string())?;
    Ok(SmartHubCommandPayload { operation, payload })
}

fn validate_external_url(raw_url: &str) -> Result<String, String> {
    if raw_url.len() > 2_048 {
        return Err("external_url_too_long".to_string());
    }
    let url = reqwest::Url::parse(raw_url).map_err(|_| "external_url_invalid".to_string())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.port(), None | Some(443))
    {
        return Err("external_url_origin_refused".to_string());
    }
    let allowed_host = matches!(
        url.host_str(),
        Some("checkout.stripe.com" | "billing.stripe.com" | "buy.stripe.com")
    );
    if !allowed_host {
        return Err("external_url_host_refused".to_string());
    }
    Ok(url.to_string())
}

fn validate_auth_url(raw_url: &str) -> Result<String, String> {
    if raw_url.len() > 4_096 {
        return Err("auth_url_too_long".to_string());
    }
    let url = reqwest::Url::parse(raw_url).map_err(|_| "auth_url_invalid".to_string())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.port(), None | Some(443))
        || url.host_str() != Some("accounts.google.com")
        || url.path() != "/o/oauth2/v2/auth"
    {
        return Err("auth_url_origin_refused".to_string());
    }
    let mut query = BTreeMap::new();
    for (name, value) in url.query_pairs() {
        if query
            .insert(name.into_owned(), value.into_owned())
            .is_some()
        {
            return Err("auth_url_duplicate_parameter".to_string());
        }
    }
    let expected = [
        "client_id",
        "code_challenge",
        "code_challenge_method",
        "redirect_uri",
        "response_type",
        "scope",
        "state",
    ];
    if query.len() != expected.len() || expected.iter().any(|key| !query.contains_key(*key)) {
        return Err("auth_url_parameters_refused".to_string());
    }
    let client_id = query.get("client_id").expect("required key checked");
    let client_prefix = client_id
        .strip_suffix(".apps.googleusercontent.com")
        .filter(|prefix| {
            (12..=512).contains(&prefix.len())
                && prefix
                    .chars()
                    .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
        })
        .ok_or_else(|| "auth_url_client_id_refused".to_string())?;
    if client_prefix.is_empty() {
        return Err("auth_url_client_id_refused".to_string());
    }
    let redirect = reqwest::Url::parse(query.get("redirect_uri").expect("required key checked"))
        .map_err(|_| "auth_url_redirect_refused".to_string())?;
    if redirect.scheme() != "http"
        || redirect.host_str() != Some("127.0.0.1")
        || redirect.port().is_none()
        || redirect.path() != "/callback"
        || redirect.query().is_some()
        || redirect.fragment().is_some()
        || !redirect.username().is_empty()
        || redirect.password().is_some()
    {
        return Err("auth_url_redirect_refused".to_string());
    }
    let is_base64_url = |value: &str, exact_length: usize| {
        value.len() == exact_length
            && value.chars().all(|character| {
                character.is_ascii_alphanumeric() || matches!(character, '-' | '_')
            })
    };
    if query.get("response_type").map(String::as_str) != Some("code")
        || query.get("code_challenge_method").map(String::as_str) != Some("S256")
        || !is_base64_url(query.get("state").expect("required key checked"), 43)
        || !is_base64_url(
            query.get("code_challenge").expect("required key checked"),
            43,
        )
        || !query
            .get("scope")
            .expect("required key checked")
            .split_ascii_whitespace()
            .any(|scope| scope == "openid")
    {
        return Err("auth_url_pkce_refused".to_string());
    }
    Ok(url.to_string())
}

#[tauri::command]
fn open_external_url(app: AppHandle, url: String) -> Result<(), String> {
    let validated = validate_external_url(&url)?;
    // reason: tauri-plugin-shell retains this Tauri 2 API while the app keeps URL validation native.
    #[allow(deprecated)]
    app.shell()
        .open(validated, None)
        .map_err(|_| "external_url_open_failed".to_string())
}

#[tauri::command]
fn open_update_url(app: AppHandle, url: String) -> Result<(), String> {
    let validated = update_feed::validate_update_artifact_url(&url)?;
    // reason: tauri-plugin-shell retains this Tauri 2 API while the app keeps URL validation native.
    #[allow(deprecated)]
    app.shell()
        .open(validated, None)
        .map_err(|_| "update_url_open_failed".to_string())
}

#[tauri::command]
fn open_dashboard(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn initial_deep_link_route() -> Option<String> {
    if let Some(route) = initial_deep_link_route_store()
        .lock()
        .ok()
        .and_then(|mut route| route.take())
    {
        return Some(route);
    }
    forwarded_route_queue()
        .lock()
        .ok()
        .and_then(|mut routes| routes.first().cloned().map(|_| routes.remove(0)))
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

static TRAY_INIT_FAILED: AtomicBool = AtomicBool::new(false);
const COMPUTER_USE_PANIC_SHORTCUTS: [&str; 2] = ["Ctrl+Alt+Super+Period", "Ctrl+Alt+Shift+Period"];

#[tauri::command]
fn tray_degraded() -> bool {
    let forced = std::env::var("OPENBURNBAR_FORCE_TRAY_DEGRADED")
        .map(|v| v == "1")
        .unwrap_or(false);
    forced || TRAY_INIT_FAILED.load(Ordering::Relaxed)
}

#[tauri::command]
fn record_perf_sample(sample: PerfSample) -> Result<(), String> {
    let out_dir = match std::env::var("OPENBURNBAR_EVIDENCE_OUT") {
        Ok(value) if !value.trim().is_empty() => PathBuf::from(value),
        _ => return Ok(()),
    };
    fs::create_dir_all(&out_dir).map_err(|e| e.to_string())?;
    let path = out_dir.join("runtime-perf-samples.jsonl");
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| e.to_string())?;
    let line = serde_json::to_string(&sample).map_err(|e| e.to_string())?;
    writeln!(file, "{line}").map_err(|e| e.to_string())
}

#[tauri::command]
fn measure_perf_operation(name: String) -> Result<PerfOperationResult, String> {
    let started = std::time::Instant::now();
    match call_daemon_perf_measure(&name) {
        Ok((ok, source, detail)) => Ok(PerfOperationResult {
            name,
            ms: started.elapsed().as_secs_f64() * 1000.0,
            source: format!("packaged-af-unix-perf.measure:{source}"),
            ok,
            detail,
        }),
        Err(error) => Ok(PerfOperationResult {
            name,
            ms: started.elapsed().as_secs_f64() * 1000.0,
            source: "packaged-af-unix-perf.measure:error".to_string(),
            ok: false,
            detail: Some(error),
        }),
    }
}

/// Generic AF_UNIX socket RPC call for arbitrary daemon methods.
/// Follows the same newline-framed JSON envelope pattern as
/// `probe_daemon_health` and `call_daemon_perf_measure`, but accepts any
/// method + params pair. Wire strings must match `BurnBarRPCMethod` in
/// OpenBurnBarCore/Contracts/BurnBarRPCContracts.swift exactly.
fn call_daemon_method(
    method: &str,
    params: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    call_daemon_method_with_timeout(method, params, Duration::from_secs(5))
}

fn request_computer_use_panic_halt(
    session_id: String,
    source: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.computer_use.panic_halt",
        Some(serde_json::json!({ "sessionId": session_id, "source": source })),
    )
}

fn trigger_computer_use_panic_hotkey() {
    thread::spawn(|| {
        if let Err(error) = request_computer_use_panic_halt("*".to_string(), "hotkey".to_string()) {
            eprintln!("computer_use_global_panic_hotkey_failed: {error}");
        }
    });
}

fn register_computer_use_panic_shortcuts(app: &AppHandle) {
    let builder = match tauri_plugin_global_shortcut::Builder::new()
        .with_shortcuts(COMPUTER_USE_PANIC_SHORTCUTS)
    {
        Ok(builder) => builder,
        Err(error) => {
            eprintln!("computer_use_global_panic_hotkey_degraded: {error}");
            return;
        }
    };
    let plugin = builder
        .with_handler(|_app, shortcut, event| {
            if event.state != ShortcutState::Pressed {
                return;
            }
            let base = Modifiers::CONTROL | Modifiers::ALT;
            let meta_chord = base | Modifiers::SUPER;
            let shift_chord = base | Modifiers::SHIFT;
            if shortcut.matches(meta_chord, Code::Period)
                || shortcut.matches(shift_chord, Code::Period)
            {
                trigger_computer_use_panic_hotkey();
            }
        })
        .build();
    if let Err(error) = app.plugin(plugin) {
        eprintln!("computer_use_global_panic_hotkey_degraded: {error}");
    }
}

fn call_daemon_method_with_timeout(
    method: &str,
    params: Option<serde_json::Value>,
    timeout: Duration,
) -> Result<serde_json::Value, String> {
    let socket_path = linux_socket_path();
    let mut stream = UnixStream::connect(&socket_path).map_err(|e| e.to_string())?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut envelope = serde_json::json!({
        "protocolVersion": 1,
        "id": format!("rpc-{stamp}"),
        "method": method,
        "traceId": format!("trace-{stamp}"),
    });
    if let Some(p) = params {
        envelope["params"] = p;
    }
    if let Some(token) = read_auth_token() {
        envelope["authToken"] = serde_json::Value::String(token);
    }
    stream
        .write_all(format!("{envelope}\n").as_bytes())
        .map_err(|e| e.to_string())?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(line.trim()).map_err(|e| e.to_string())?;
    if let Some(err) = parsed
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
    {
        return Err(err.to_string());
    }
    parsed
        .get("result")
        .cloned()
        .ok_or_else(|| "RPC response missing result".to_string())
}

fn call_daemon_method_report(method: &str, params: Option<serde_json::Value>) -> serde_json::Value {
    match call_daemon_method(method, params) {
        Ok(result) => serde_json::json!({
            "ok": true,
            "method": method,
            "result": result,
        }),
        Err(error) => serde_json::json!({
            "ok": false,
            "method": method,
            "error": error,
        }),
    }
}

// ───────────────── P01: usage summary ─────────────────
// Wire: daemon.usage.recent (BurnBarRPCMethod.usageRecent)
#[tauri::command]
fn usage_summary() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.usage.recent",
        Some(serde_json::json!({"limit": 50})),
    )
}

// ───────────────── P02: provider catalog ─────────────────
// Wire: daemon.config.get (BurnBarRPCMethod.configGet)
#[tauri::command]
fn provider_catalog() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
}

// ───────────────── P03: session list ─────────────────
// Wire: daemon.usage.recent (BurnBarRPCMethod.usageRecent)
// BurnBarRecentUsageRequest has ONLY `limit` — no offset field exists.
// Fetch a large batch; the TS store paginates client-side (page size 50).
#[tauri::command]
fn session_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.usage.recent",
        Some(serde_json::json!({"limit": 500})),
    )
}

// ───────────────── P03: session search ─────────────────
// Wire: daemon.search.query (BurnBarRPCMethod.searchQuery)
#[tauri::command]
fn session_search(query: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.search.query",
        Some(serde_json::json!({"query": query})),
    )
}

// ───────────── Exact persisted chat threads ─────────────

fn chat_thread_list_wire(query: Option<String>, limit: u32) -> (&'static str, serde_json::Value) {
    let mut params = serde_json::Map::from_iter([("limit".into(), serde_json::json!(limit))]);
    if let Some(query) = query {
        params.insert("query".into(), serde_json::json!(query));
    }
    ("daemon.chat.thread.list", serde_json::Value::Object(params))
}

#[tauri::command]
fn chat_thread_list(query: Option<String>, limit: u32) -> Result<serde_json::Value, String> {
    let (method, params) = chat_thread_list_wire(query, limit);
    call_daemon_method(method, Some(params))
}

fn chat_thread_get_wire(
    thread_id: String,
    max_messages: u32,
    before_timestamp: Option<String>,
    before_message_id: Option<String>,
) -> (&'static str, serde_json::Value) {
    let mut params = serde_json::Map::from_iter([
        ("threadID".into(), serde_json::json!(thread_id)),
        ("maxMessages".into(), serde_json::json!(max_messages)),
    ]);
    if let Some(before_timestamp) = before_timestamp {
        params.insert(
            "beforeTimestamp".into(),
            serde_json::json!(before_timestamp),
        );
    }
    if let Some(before_message_id) = before_message_id {
        params.insert(
            "beforeMessageID".into(),
            serde_json::json!(before_message_id),
        );
    }
    ("daemon.chat.thread.get", serde_json::Value::Object(params))
}

#[tauri::command]
fn chat_thread_get(
    thread_id: String,
    max_messages: u32,
    before_timestamp: Option<String>,
    before_message_id: Option<String>,
) -> Result<serde_json::Value, String> {
    let (method, params) =
        chat_thread_get_wire(thread_id, max_messages, before_timestamp, before_message_id);
    call_daemon_method(method, Some(params))
}

#[tauri::command]
fn chat_message_append(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.chat.message.append", Some(request))
}

// ───────────────── P05: usage insights ─────────────────
// Wire: daemon.usage.recent (aggregated client-side in the TS bridge)
#[tauri::command]
fn usage_insights() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.usage.recent",
        Some(serde_json::json!({"limit": 200})),
    )
}

// ───────────────── P06: mission list ─────────────────
// Wire: daemon.mission.list (BurnBarRPCMethod.missionsList)
#[tauri::command]
fn mission_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.list",
        Some(serde_json::json!({
            "projectSlug": null,
            "statuses": [
                "draft",
                "awaiting_approval",
                "approved",
                "dispatching",
                "in_progress",
                "partially_completed",
                "completed",
                "failed",
                "cancelled"
            ],
            "limit": 100
        })),
    )
}

// ───────────────── P20: mission detail ─────────────────
// Wire: daemon.mission.get (BurnBarRPCMethod.missionGet)
#[tauri::command]
fn mission_get(mission_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.get",
        Some(serde_json::json!({"missionID": mission_id})),
    )
}

// ───────────────── P06: mission create ─────────────────
// Wire: daemon.mission.create (BurnBarRPCMethod.missionCreate)
// BurnBarMissionCreateRequest requires projectSlug, title, summary,
// createdBy, recommendation, and metadata.
#[tauri::command]
fn mission_create(
    project_slug: String,
    title: String,
    summary: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.create",
        Some(serde_json::json!({
            "projectSlug": project_slug,
            "title": title,
            "summary": summary,
            "createdBy": "linux-shell",
            "recommendation": "review",
            "metadata": {
                "source": "linux-shell",
                "surface": "missions"
            }
        })),
    )
}

// ───────────────── P06: mission approval decision ─────────────────
// Wire: daemon.mission.approve / daemon.mission.cancel
// (BurnBarRPCMethod.missionApprove / .missionCancel)
// BurnBarMissionApproveRequest/CancelRequest require `missionID` (capital ID —
// matches the Swift property name verbatim, no CodingKeys remap) and a
// non-optional `actor: String`. Missing either → Swift Codable decode throws.
fn mission_decision_wire(id: &str, decision: &str) -> (&'static str, serde_json::Value) {
    let method = if decision == "deny" {
        "daemon.mission.cancel"
    } else {
        "daemon.mission.approve"
    };
    (
        method,
        serde_json::json!({"missionID": id, "actor": "linux-shell"}),
    )
}

#[tauri::command]
fn mission_approval_decision(id: String, decision: String) -> Result<serde_json::Value, String> {
    let (method, params) = mission_decision_wire(&id, &decision);
    call_daemon_method(method, Some(params))
}

// ───────────────── P20: explicit mission cancellation ─────────────────
// Wire: daemon.mission.cancel (BurnBarMissionCancelRequest)
#[tauri::command]
fn mission_cancel(mission_id: String, note: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.mission.cancel",
        Some(serde_json::json!({
            "missionID": mission_id,
            "actor": "linux-shell",
            "note": note
        })),
    )
}

// ───────────────── P07: config snapshot ─────────────────
// Wire: daemon.config.get (BurnBarRPCMethod.configGet)
#[tauri::command]
fn config_snapshot() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
}

#[tauri::command]
fn onboarding_snapshot() -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_SNAPSHOT_METHOD, None)
}

#[tauri::command]
fn onboarding_action(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_ACTION_METHOD, Some(request))
}

#[tauri::command]
fn onboarding_reset() -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_ONBOARDING_RESET_METHOD, None)
}

#[tauri::command]
fn subscription_start(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_START_METHOD, Some(request))
}

#[tauri::command]
fn subscription_resume(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_RESUME_METHOD, Some(request))
}

#[tauri::command]
fn subscription_stop(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(DAEMON_SUBSCRIPTION_STOP_METHOD, Some(request))
}

#[tauri::command]
fn config_update(snapshot: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.config.update",
        Some(serde_json::json!({ "snapshot": snapshot })),
    )
}

#[tauri::command]
fn provider_credential_slot_upsert(params: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.provider.credential_slot.upsert", Some(params))
}

#[tauri::command]
fn provider_credential_slot_remove(
    provider_id: String,
    slot_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.credential_slot.remove",
        Some(serde_json::json!({ "providerID": provider_id, "slotID": slot_id })),
    )
}

#[tauri::command]
fn provider_model_variant_upsert(
    provider_id: String,
    variant: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_variant.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "variant": variant })),
    )
}

#[tauri::command]
fn provider_model_variant_remove(
    provider_id: String,
    variant_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_variant.remove",
        Some(serde_json::json!({ "providerID": provider_id, "variantID": variant_id })),
    )
}

#[tauri::command]
fn provider_model_alias_upsert(
    provider_id: String,
    alias: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_alias.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "alias": alias })),
    )
}

#[tauri::command]
fn provider_model_alias_remove(
    provider_id: String,
    alias_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_alias.remove",
        Some(serde_json::json!({ "providerID": provider_id, "aliasID": alias_id })),
    )
}

#[tauri::command]
fn provider_custom_model_upsert(
    provider_id: String,
    custom_model: serde_json::Value,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.custom_model.upsert",
        Some(serde_json::json!({ "providerID": provider_id, "customModel": custom_model })),
    )
}

#[tauri::command]
fn provider_custom_model_remove(
    provider_id: String,
    model_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.custom_model.remove",
        Some(serde_json::json!({ "providerID": provider_id, "modelID": model_id })),
    )
}

#[tauri::command]
fn provider_model_display_name_set(
    provider_id: String,
    model_id: String,
    display_name: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_display_name.set",
        Some(
            serde_json::json!({ "providerID": provider_id, "modelID": model_id, "displayName": display_name }),
        ),
    )
}

#[tauri::command]
fn provider_model_display_name_clear(
    provider_id: String,
    model_id: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.provider.model_display_name.clear",
        Some(serde_json::json!({ "providerID": provider_id, "modelID": model_id })),
    )
}

#[tauri::command]
fn proxy_route_log_recent(limit: i32) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.proxy.route_log.recent",
        Some(serde_json::json!({ "limit": limit })),
    )
}

#[tauri::command]
fn proxy_route_log_clear() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.proxy.route_log.clear", Some(serde_json::json!({})))
}

#[tauri::command]
fn notification_config_get() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.config.get",
        Some(serde_json::json!({})),
    )
}

#[tauri::command]
fn notification_config_update(config: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.config.update",
        Some(serde_json::json!({ "config": config })),
    )
}

#[tauri::command]
fn notification_health() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.notification.health", Some(serde_json::json!({})))
}

#[tauri::command]
fn notification_command(
    command: String,
    arguments: Vec<String>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.notification.command",
        Some(
            serde_json::json!({ "command": command, "arguments": arguments, "actor": "linux-shell" }),
        ),
    )
}

// ───────────────── P07: db status ─────────────────
// Derived from daemon.config.get — no dedicated db RPC exists in the enum.
#[tauri::command]
fn db_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
}

// ───────────────── P07: project list ─────────────────
// Wire: daemon.controller.project.list (BurnBarRPCMethod.controllerProjectsList)
#[tauri::command]
fn project_list() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.controller.project.list",
        Some(serde_json::json!({
            "includePaused": true,
            "limit": 200
        })),
    )
}

// ───────────────── P19: project lifecycle ─────────────────
// Wire: daemon.controller.project.get / daemon.controller.project.upsert /
// daemon.controller.project.delete / daemon.controller.project.reassign.
// (BurnBarRPCMethod.controllerProjectGet / controllerProjectUpsert /
// controllerProjectDelete / controllerProjectReassign).
fn validate_project_identifier(value: &str, field: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 160 || value != value.trim() {
        return Err(format!("{field} must be a canonical non-empty identifier"));
    }
    if !value.is_ascii()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(format!(
            "{field} must contain only ASCII letters, digits, '-', '_', '.', or ':'"
        ));
    }
    Ok(value.to_owned())
}

fn validate_project_slug(value: &str, field: &str) -> Result<String, String> {
    let slug = validate_project_identifier(value, field)?;
    if slug.len() > 96
        || slug != slug.to_ascii_lowercase()
        || !slug.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        || !slug.as_bytes().last().is_some_and(u8::is_ascii_alphanumeric)
    {
        return Err(format!(
            "{field} must be a lowercase canonical project slug"
        ));
    }
    Ok(slug)
}

#[tauri::command]
fn project_get(project_slug: String) -> Result<serde_json::Value, String> {
    let project_slug = validate_project_slug(&project_slug, "projectSlug")?;
    call_daemon_method(
        "daemon.controller.project.get",
        Some(serde_json::json!({ "projectSlug": project_slug })),
    )
}

fn validate_project_upsert_payload(project: &serde_json::Value) -> Result<(), String> {
    let object = project
        .as_object()
        .ok_or_else(|| "project must be a JSON object".to_string())?;
    for field in ["projectSlug", "displayName", "summary", "id"] {
        let value = object
            .get(field)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty());
        if value.is_none() {
            return Err(format!("project.{field} must be a non-empty string"));
        }
    }
    let project_slug = object
        .get("projectSlug")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "project.projectSlug must be a non-empty string".to_string())?;
    validate_project_slug(project_slug, "project.projectSlug")?;
    let project_id = object
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "project.id must be a non-empty string".to_string())?;
    validate_project_identifier(project_id, "project.id")?;
    Ok(())
}

#[tauri::command]
fn project_upsert(project: serde_json::Value) -> Result<serde_json::Value, String> {
    validate_project_upsert_payload(&project)?;
    call_daemon_method(
        "daemon.controller.project.upsert",
        Some(serde_json::json!({ "project": project })),
    )
}

#[tauri::command]
fn project_delete(project_slug: String) -> Result<serde_json::Value, String> {
    let project_slug = validate_project_slug(&project_slug, "projectSlug")?;
    call_daemon_method(
        "daemon.controller.project.delete",
        Some(serde_json::json!({ "projectSlug": project_slug })),
    )
}

#[tauri::command]
fn project_reassign(
    source_project_slug: String,
    target_project_slug: String,
) -> Result<serde_json::Value, String> {
    let source_project_slug = validate_project_slug(&source_project_slug, "sourceProjectSlug")?;
    let target_project_slug = validate_project_slug(&target_project_slug, "targetProjectSlug")?;
    if source_project_slug == target_project_slug {
        return Err("sourceProjectSlug and targetProjectSlug must differ".to_string());
    }
    call_daemon_method(
        "daemon.controller.project.reassign",
        Some(serde_json::json!({
            "sourceProjectSlug": source_project_slug,
            "targetProjectSlug": target_project_slug
        })),
    )
}

// ───────────────── P07: memory boundaries ─────────────────
// Wire: daemon.memory.analytics (BurnBarRPCMethod.memoryAnalytics)
#[tauri::command]
fn memory_boundaries() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.memory.analytics",
        Some(serde_json::json!({"projectPath": null})),
    )
}

// ───────────────── P07: memory review inbox ─────────────────
// Wire: daemon.memory.recall + daemon.memory.audit_trail.
// There is no Linux/macOS-parity approve/reject review-row RPC yet; this
// returns durable recalled memories plus audit facts so the UI can show an
// honest approved-memory inbox and wire revoke to daemon.memory.forget.
#[tauri::command]
fn memory_review_inbox() -> serde_json::Value {
    let recall = call_daemon_method_report(
        "daemon.memory.recall",
        Some(serde_json::json!({
            "query": "project memory",
            "projectPath": null,
            "limit": 50,
            "scope": "all",
            "includeCrossProject": true
        })),
    );
    let audit = call_daemon_method_report(
        "daemon.memory.audit_trail",
        Some(serde_json::json!({
            "projectPath": null,
            "limit": 50
        })),
    );
    serde_json::json!({
        "recall": recall,
        "auditTrail": audit
    })
}

// ───────────────── P07: memory forget / revoke ─────────────────
// Wire: daemon.memory.forget (BurnBarRPCMethod.memoryForget)
#[tauri::command]
fn memory_forget(memory_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.memory.forget",
        Some(serde_json::json!({
            "memoryID": memory_id,
            "projectPath": null,
            "requireCloudDelete": false
        })),
    )
}

// ───────────────── P07: database workspace status ─────────────────
// Wire: daemon.code.index_status / explore / diagnostics / ops_diagnostics.
#[tauri::command]
fn database_workspace_status(project_path: Option<String>) -> serde_json::Value {
    let status = call_daemon_method_report(
        "daemon.code.index_status",
        Some(serde_json::json!({"projectPath": project_path.clone()})),
    );
    let explore = call_daemon_method_report(
        "daemon.code.explore",
        Some(serde_json::json!({
            "projectPath": project_path.clone(),
            "query": null,
            "limit": 50,
            "maxBytes": 24000
        })),
    );
    let diagnostics = call_daemon_method_report(
        "daemon.code.diagnostics",
        Some(serde_json::json!({
            "projectPath": project_path.clone(),
            "filePath": null
        })),
    );
    let ops = call_daemon_method_report("daemon.code.ops_diagnostics", Some(serde_json::json!({})));
    serde_json::json!({
        "indexStatus": status,
        "explore": explore,
        "diagnostics": diagnostics,
        "opsDiagnostics": ops
    })
}

// ───────────────── P07: database indexing controls ─────────────────
// Wire: daemon.code.index_project (BurnBarRPCMethod.codeIndexProject)
#[tauri::command]
fn database_index_project(project_path: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method_with_timeout(
        "daemon.code.index_project",
        Some(serde_json::json!({
            "projectPath": project_path,
            "maxFiles": 2500,
            "maxFileBytes": 512000,
            "storageBudgetBytes": null
        })),
        Duration::from_secs(120),
    )
}

// Wire: daemon.code.watch_project (BurnBarRPCMethod.codeWatchProject).
// Linux watcher is poll-only; Darwin FSEvents nudges are not available here.
#[tauri::command]
fn database_watch_project(project_path: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.watch_project",
        Some(serde_json::json!({
            "projectPath": project_path,
            "maxFiles": 2500,
            "maxFileBytes": 512000,
            "storageBudgetBytes": null,
            "pollIntervalSeconds": 2.0
        })),
    )
}

// ───────────────── P22: bounded code retrieval ─────────────────
// Wire: daemon.code.search / daemon.code.context_pack.
// Keep the shell read-only and bounded; index ownership and trust wrapping
// remain in OpenBurnBarDaemon.
fn bounded_code_query(query: String) -> Result<String, String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Err("Code search query must not be empty.".to_string());
    }
    Ok(trimmed.chars().take(512).collect())
}

fn bounded_code_limit(limit: Option<u32>, default: u32) -> u32 {
    limit.unwrap_or(default).clamp(1, 50)
}

fn bounded_context_bytes(max_bytes: Option<u32>) -> u32 {
    max_bytes.unwrap_or(24_000).clamp(1_024, 24_000)
}

#[tauri::command]
fn database_code_search(
    query: String,
    project_path: Option<String>,
    limit: Option<u32>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.search",
        Some(serde_json::json!({
            "query": bounded_code_query(query)?,
            "projectPath": project_path,
            "limit": bounded_code_limit(limit, 20)
        })),
    )
}

#[tauri::command]
fn database_code_context_pack(
    query: String,
    project_path: Option<String>,
    limit: Option<u32>,
    max_bytes: Option<u32>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.code.context_pack",
        Some(serde_json::json!({
            "query": bounded_code_query(query)?,
            "projectPath": project_path,
            "limit": bounded_code_limit(limit, 10),
            "maxBytes": bounded_context_bytes(max_bytes)
        })),
    )
}

fn bounded_recovery_path(path: String) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() || trimmed.len() > 4096 || !trimmed.starts_with('/') {
        return Err("Recovery bundle path must be an absolute local path under 4096 bytes.".to_string());
    }
    if trimmed.chars().any(|character| character == '\0' || character == '\n' || character == '\r') {
        return Err("Recovery bundle path contains a prohibited control character.".to_string());
    }
    Ok(trimmed.to_string())
}

fn bounded_recovery_passphrase(passphrase: String) -> Result<String, String> {
    if passphrase.trim().is_empty() || passphrase.len() > 4096 {
        return Err("Recovery bundle passphrase must be between 1 and 4096 bytes.".to_string());
    }
    if passphrase.contains('\0') {
        return Err("Recovery bundle passphrase contains a prohibited NUL character.".to_string());
    }
    // Preserve intentional leading/trailing spaces: they are part of the
    // macOS passphrase input and therefore part of the PBKDF2 password.
    Ok(passphrase)
}

#[tauri::command]
fn database_recovery_bundle_export(
    destination_path: String,
    passphrase: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.database.recovery_bundle.export",
        Some(serde_json::json!({
            "destinationPath": bounded_recovery_path(destination_path)?,
            "passphrase": bounded_recovery_passphrase(passphrase)?
        })),
    )
}

#[tauri::command]
fn database_recovery_bundle_import(
    source_path: String,
    passphrase: String,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.database.recovery_bundle.import",
        Some(serde_json::json!({
            "sourcePath": bounded_recovery_path(source_path)?,
            "passphrase": bounded_recovery_passphrase(passphrase)?
        })),
    )
}

// ───────────────── P08: daemon-owned account authority ─────────────────
#[tauri::command]
fn account_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.auth.status", None)
}

fn finish_account_browser_launch<Launch, Cancel, Status>(
    mut result: serde_json::Value,
    launch: Launch,
    cancel: Cancel,
    status: Status,
) -> Result<serde_json::Value, String>
where
    Launch: FnOnce(String) -> Result<(), String>,
    Cancel: FnOnce(&str) -> Result<(), String>,
    Status: FnOnce() -> Result<serde_json::Value, String>,
{
    let operation_id = result
        .get("operationID")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= 160)
        .ok_or_else(|| "auth_begin_missing_operation_id".to_string())?
        .to_string();
    let authorization_url = result
        .get("authorizationURL")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "auth_begin_missing_authorization_url".to_string());
    let validated = authorization_url.and_then(validate_auth_url);
    let launch_result = validated.and_then(launch);
    if let Err(launch_error) = launch_result {
        if cancel(&operation_id).is_ok() {
            return Err(launch_error);
        }

        let status = status();
        let status_operation_id = status
            .as_ref()
            .ok()
            .and_then(|value| value.get("authorizationOperationID"))
            .and_then(serde_json::Value::as_str);
        if status.is_ok() && status_operation_id != Some(operation_id.as_str()) {
            return Err(launch_error);
        }

        if let Some(object) = result.as_object_mut() {
            object.remove("authorizationURL");
            if let Some(expires_at) = status
                .as_ref()
                .ok()
                .and_then(|value| value.get("authorizationExpiresAt"))
                .and_then(serde_json::Value::as_str)
            {
                object.insert(
                    "expiresAt".to_string(),
                    serde_json::Value::String(expires_at.to_string()),
                );
            }
            object.insert(
                "nativeBrowserLaunchFailed".to_string(),
                serde_json::Value::Bool(true),
            );
            object.insert(
                "cancelRetryRequired".to_string(),
                serde_json::Value::Bool(true),
            );
            object.insert(
                "cancelStatusVerified".to_string(),
                serde_json::Value::Bool(status_operation_id == Some(operation_id.as_str())),
            );
        }
        tracing::warn!(
            operation_id = %operation_id,
            cancel_status_verified = status_operation_id == Some(operation_id.as_str()),
            "native auth browser launch and cleanup failed; preserving operation for retry"
        );
        return Ok(result);
    }
    if let Some(object) = result.as_object_mut() {
        object.remove("authorizationURL");
    }
    Ok(result)
}

#[tauri::command]
fn account_begin_sign_in(app: AppHandle) -> Result<serde_json::Value, String> {
    let result = call_daemon_method("daemon.auth.begin", None)?;
    finish_account_browser_launch(
        result,
        |validated| {
            // reason: tauri-plugin-shell retains this Tauri 2 API while auth URLs stay natively validated.
            #[allow(deprecated)]
            app.shell()
                .open(validated, None)
                .map_err(|_| "auth_url_open_failed".to_string())
        },
        |operation_id| {
            call_daemon_method(
                "daemon.auth.cancel",
                Some(serde_json::json!({ "operationID": operation_id })),
            )
            .map(|_| ())
        },
        || call_daemon_method("daemon.auth.status", None),
    )
}

#[tauri::command]
fn account_cancel_sign_in(operation_id: String) -> Result<serde_json::Value, String> {
    let operation_id = operation_id.trim();
    if operation_id.is_empty() || operation_id.len() > 160 {
        return Err("auth_operation_id_invalid".to_string());
    }
    call_daemon_method(
        "daemon.auth.cancel",
        Some(serde_json::json!({ "operationID": operation_id })),
    )
}

#[tauri::command]
fn account_sign_out() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.auth.sign_out", None)
}

// Rotation may refresh Firebase auth, register the replacement key, issue and
// sign an App Check challenge, mint App Check, and bind it. Each cloud stage is
// bounded to 20 seconds in the daemon, so the shell permits the complete
// sequence plus scheduling margin without making the socket wait unbounded.
const ACCOUNT_ROTATE_IDENTITY_RPC_TIMEOUT: Duration = Duration::from_secs(135);

fn account_rotate_identity_with(
    call: impl FnOnce(&str, Option<serde_json::Value>, Duration) -> Result<serde_json::Value, String>,
) -> Result<serde_json::Value, String> {
    call(
        "daemon.auth.rotate_identity",
        None,
        ACCOUNT_ROTATE_IDENTITY_RPC_TIMEOUT,
    )
}

#[tauri::command]
async fn account_rotate_identity() -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(|| {
        account_rotate_identity_with(call_daemon_method_with_timeout)
    })
    .await
    .map_err(|error| format!("account_identity_rotation_join_failed:{error}"))?
}

// ───────────────── P10: membership status ─────────────────
// Proposed wire: daemon.membership.status. Older daemons reject it; the TS
// store treats unknown-method errors as capability-absent, not fatal UI spam.
#[tauri::command]
fn membership_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.membership.status", None)
}

// ───────────────── P10: membership checkout URL ─────────────────
// Proposed wire: daemon.membership.checkoutUrl. Tier-C StoreKit substitute:
// the daemon mints the Stripe URL; the React layer opens it externally.
#[tauri::command]
fn membership_checkout_url() -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.membership.checkoutUrl",
        Some(serde_json::json!({
            "success_url": "openburnbar://membership/success",
            "cancel_url": "openburnbar://membership/cancel"
        })),
    )
}

// ───────────────── P10: membership restore ─────────────────
// Proposed wire: daemon.membership.restore. Older daemons reject it; the UI
// presents the membership capability as absent and keeps fixture mode usable.
#[tauri::command]
fn membership_restore() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.membership.restore", None)
}

// ───────────────── P09: app version info ─────────────────
// Local: shell version from compile-time env, daemon version from health probe.
#[tauri::command]
fn app_version_info() -> Result<serde_json::Value, String> {
    let shell_version = env!("CARGO_PKG_VERSION");
    let daemon_version = probe_daemon_health()
        .daemon_version
        .unwrap_or_else(|| "unknown".to_string());
    let package = detect_linux_package_facts();
    let runtime = linux_runtime_facts();
    Ok(serde_json::json!({
        "shellVersion": shell_version,
        "daemonVersion": daemon_version,
        "packageChannel": package.channel.clone(),
        "package": package,
        "runtime": runtime
    }))
}

#[tauri::command]
async fn update_status() -> update_feed::LinuxUpdateStatus {
    let package_channel = detect_linux_package_channel();
    let status = update_feed::check_linux_update(env!("CARGO_PKG_VERSION"), &package_channel).await;
    let status = update_feed::attach_update_instructions(status, &package_channel);
    let daemon_version = probe_daemon_health().daemon_version;
    update_feed::attach_compatibility(status, env!("CARGO_PKG_VERSION"), daemon_version.as_deref())
}

// ───────────────── P09: redacted diagnostics export ─────────────────
fn diagnostics_bundle(
    stamp: u64,
    health: &DaemonHealth,
    package: &LinuxPackageFacts,
    runtime: &LinuxRuntimeFacts,
) -> serde_json::Value {
    serde_json::json!({
        "schemaVersion": 1,
        "exportedAt": stamp,
        "shellVersion": env!("CARGO_PKG_VERSION"),
        "daemonHealth": {
            "ok": health.ok,
            "daemonVersion": health.daemon_version,
            "protocolVersion": health.protocol_version,
            "socketPath": health.socket_path,
        },
        "package": package,
        "runtime": runtime,
        "included": DIAGNOSTICS_INCLUDED,
        "excluded": DIAGNOSTICS_EXCLUDED,
    })
}

fn diagnostics_preview(byte_count: usize) -> serde_json::Value {
    serde_json::json!({
        "schemaVersion": 1,
        "byteCount": byte_count,
        "fileMode": "0600",
        "included": DIAGNOSTICS_INCLUDED,
        "excluded": DIAGNOSTICS_EXCLUDED,
    })
}

// Writes a JSON bundle to the support dir. Redaction is structural: this
// command only persists shell/health/package/runtime metadata — it never reads
// provider payloads, tokens, or socket auth material. File mode is 0600.
#[tauri::command]
fn export_diagnostics() -> Result<serde_json::Value, String> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let dir = linux_support_dir();
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    // Ensure support dir is owner-only when possible.
    let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = dir.join(format!("diagnostics-{stamp}.json"));
    let health = probe_daemon_health();
    let package = detect_linux_package_facts();
    let runtime = linux_runtime_facts();
    let bundle = diagnostics_bundle(stamp, &health, &package, &runtime);
    let json = serde_json::to_string_pretty(&bundle).map_err(|e| e.to_string())?;
    let preview = diagnostics_preview(json.len());
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| e.to_string())?;
    file.write_all(json.as_bytes()).map_err(|e| e.to_string())?;
    // Re-apply the owner-only mode even when a timestamp collision reopens an
    // existing file; `OpenOptionsExt::mode` only affects newly-created files.
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    Ok(serde_json::json!({
        "path": path.display().to_string(),
        "preview": preview
    }))
}

// ───────────────── P11: session env ─────────────────
// Reads XDG env vars for real pet-tier detection (not hardcoded).
#[tauri::command]
fn session_env() -> serde_json::Value {
    serde_json::json!({
        "xdg_session_type": std::env::var("XDG_SESSION_TYPE").ok(),
        "xdg_current_desktop": std::env::var("XDG_CURRENT_DESKTOP").ok(),
    })
}

// ───────────────── P12: Mercury media ─────────────────
#[tauri::command]
fn media_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.status", Some(serde_json::json!({})))
}

#[tauri::command]
fn media_session_state() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.session.state", None)
}

#[tauri::command]
fn media_accept_call(request_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.media.call.accept",
        Some(serde_json::json!({ "requestId": request_id })),
    )
}

#[tauri::command]
fn media_decline_call(request_id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.media.call.decline",
        Some(serde_json::json!({ "requestId": request_id })),
    )
}

#[tauri::command]
fn media_end_call() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.call.end", Some(serde_json::json!({})))
}

#[tauri::command]
fn media_capability_get() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.capability.get", Some(serde_json::json!({})))
}

#[tauri::command]
fn media_file_offer_list() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.file.offer.list", Some(serde_json::json!({})))
}

#[tauri::command]
fn media_file_accept(
    transfer_id: Option<String>,
    manifest_id: Option<String>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.media.file.accept",
        Some(serde_json::json!({
            "transferID": transfer_id,
            "manifestID": manifest_id
        })),
    )
}

#[tauri::command]
fn media_file_decline(
    transfer_id: Option<String>,
    manifest_id: Option<String>,
    reason: Option<String>,
) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.media.file.decline",
        Some(serde_json::json!({
            "transferID": transfer_id,
            "manifestID": manifest_id,
            "reason": reason
        })),
    )
}

#[tauri::command]
fn media_file_send(path: String, peer_id: Option<String>) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.media.file.send",
        Some(serde_json::json!({
            "path": path,
            "peerID": peer_id
        })),
    )
}

fn media_session_source(value: &serde_json::Value) -> &serde_json::Value {
    value
        .get("session")
        .or_else(|| value.get("activeSession"))
        .or_else(|| value.get("active_session"))
        .unwrap_or(value)
}

fn media_phase(value: &serde_json::Value) -> Option<String> {
    let session = media_session_source(value);
    session
        .get("phase")
        .or_else(|| session.get("state"))
        .or_else(|| session.get("status"))
        .or_else(|| value.get("phase"))
        .or_else(|| value.get("state"))
        .or_else(|| value.get("status"))
        .and_then(|phase| phase.as_str())
        .map(|phase| phase.to_string())
}

fn media_request_id(value: &serde_json::Value) -> Option<String> {
    let session = media_session_source(value);
    session
        .get("requestId")
        .or_else(|| session.get("requestID"))
        .or_else(|| session.get("request_id"))
        .or_else(|| value.get("requestId"))
        .or_else(|| value.get("requestID"))
        .or_else(|| value.get("request_id"))
        .or_else(|| {
            value
                .get("incomingCall")
                .and_then(|call| call.get("requestId"))
        })
        .or_else(|| {
            value
                .get("incoming_call")
                .and_then(|call| call.get("request_id"))
        })
        .and_then(|request_id| request_id.as_str())
        .map(|request_id| request_id.to_string())
}

fn start_media_session_poll_loop(app: AppHandle) {
    thread::Builder::new()
        .name("openburnbar-media-session-poll".to_string())
        .spawn(move || {
            let mut last_phase: Option<String> = None;
            let mut last_request_id: Option<String> = None;
            let mut capability_absent = false;
            loop {
                match call_daemon_method_with_timeout(
                    "daemon.media.session.state",
                    None,
                    Duration::from_secs(2),
                ) {
                    Ok(state) => {
                        capability_absent = false;
                        let phase = media_phase(&state);
                        let request_id = media_request_id(&state);
                        if phase != last_phase {
                            let _ = app.emit("media-call-state-changed", state.clone());
                        }
                        if matches!(phase.as_deref(), Some("ringing") | Some("incoming"))
                            && request_id.is_some()
                            && request_id != last_request_id
                        {
                            let _ = app.emit("media-incoming-call", state.clone());
                        }
                        last_phase = phase;
                        last_request_id = request_id;
                    }
                    Err(error) => {
                        let lower = error.to_lowercase();
                        let is_absent = lower.contains("unknown")
                            || lower.contains("unsupported")
                            || lower.contains("not implemented")
                            || lower.contains("no such method");
                        if !capability_absent && is_absent {
                            capability_absent = true;
                            let _ = app.emit(
                                "media-call-state-changed",
                                serde_json::json!({
                                    "phase": "capability-absent",
                                    "capabilityAbsent": true,
                                    "error": error
                                }),
                            );
                        }
                    }
                }
                thread::sleep(Duration::from_millis(500));
            }
        })
        .expect("failed to spawn media session poll loop");
}

// ───────────────── Tool approval respond ─────────────────
// Wire: approval.respond (BurnBarRPCMethod.approvalRespond)
// Params: BurnBarApprovalRespondRequest { response: BurnBarApprovalResponse }
// respondedAt is Foundation reference-date seconds (f64), matching the extension.
#[tauri::command]
fn tool_approval_respond(
    approval_id: String,
    decision: String,
    note: Option<String>,
) -> Result<serde_json::Value, String> {
    let decision = match decision.as_str() {
        "approve" | "reject" | "cancel" => decision,
        other => {
            return Err(format!(
                "approval decision must be approve|reject|cancel, got {other}"
            ))
        }
    };
    if approval_id.trim().is_empty() {
        return Err("approvalID is required".into());
    }
    let responded_at = foundation_reference_date_seconds();
    call_daemon_method(
        "approval.respond",
        Some(serde_json::json!({
            "response": {
                "approvalID": approval_id,
                "clientID": "linux-shell",
                "decision": decision,
                "note": note,
                "respondedAt": responded_at
            }
        })),
    )
}

// ───────────────── Memory set status ─────────────────
// Wire: remember → daemon.memory.remember, reject/forget → daemon.memory.forget,
// audit → daemon.memory.audit_trail. "approve" is an alias for remember and
// requires non-empty text/body (fail-closed; never invent placeholder text).
#[tauri::command]
fn memory_set_status(
    action: String,
    payload: serde_json::Value,
) -> Result<serde_json::Value, String> {
    match action.as_str() {
        "approve" | "remember" => {
            let text = payload
                .get("text")
                .and_then(|v| v.as_str())
                .or_else(|| payload.get("body").and_then(|v| v.as_str()))
                .unwrap_or("")
                .trim()
                .to_string();
            if text.is_empty() {
                return Err(
                    "memory remember requires non-empty text/body (fail-closed; no placeholder)".into(),
                );
            }
            // Reject invented placeholder patterns from older shell versions.
            if text.starts_with("approved:") {
                return Err(
                    "memory remember refuses invented approved:<id> placeholders".into(),
                );
            }
            call_daemon_method(
                "daemon.memory.remember",
                Some(serde_json::json!({
                    "text": text,
                    "projectPath": payload.get("projectPath").cloned().unwrap_or(serde_json::Value::Null),
                    "kind": payload.get("kind").and_then(|v| v.as_str()).unwrap_or("note"),
                    "scope": payload.get("scope").and_then(|v| v.as_str()).unwrap_or("personal"),
                    "tags": payload.get("tags").cloned().unwrap_or_else(|| serde_json::json!([])),
                    "confidence": payload.get("confidence").and_then(|v| v.as_f64()).unwrap_or(1.0),
                    "sourcePath": payload.get("sourcePath").cloned().unwrap_or(serde_json::Value::Null)
                })),
            )
        }
        "reject" | "forget" => {
            let memory_id = payload
                .get("memoryID")
                .or_else(|| payload.get("memoryId"))
                .or_else(|| payload.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if memory_id.is_empty() {
                return Err("memory reject requires memoryID".into());
            }
            call_daemon_method(
                "daemon.memory.forget",
                Some(serde_json::json!({
                    "memoryID": memory_id,
                    "projectPath": payload.get("projectPath").cloned().unwrap_or(serde_json::Value::Null),
                    "requireCloudDelete": payload.get("requireCloudDelete").and_then(|v| v.as_bool()).unwrap_or(false)
                })),
            )
        }
        "audit" => call_daemon_method(
            "daemon.memory.audit_trail",
            Some(serde_json::json!({
                "projectPath": payload.get("projectPath").cloned().unwrap_or(serde_json::Value::Null),
                "limit": payload.get("limit").and_then(|v| v.as_u64()).unwrap_or(50)
            })),
        ),
        other => Err(format!(
            "memory_set_status action must be approve|reject|audit (or remember|forget), got {other}"
        )),
    }
}

// ───────────────── Computer Use wrappers ─────────────────
// Wire bodies MUST match BurnBarComputerUseContracts.swift exactly.
// Params are typed allowlisted structs (deny_unknown_fields).

const CU_MAX_ARGS_BYTES: usize = 64 * 1024;
const CU_CLIENT_ID: &str = "linux-shell";
const CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS: f64 = 5.0 * 60.0;
const CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS: f64 = 30.0;
const CU_LOCAL_AUTH_MAX_GRANT_DURATION_SECONDS: f64 = 30.0 * 60.0;
const CU_BROKER_RPC_TIMEOUT: Duration = Duration::from_secs(5);
// The daemon's interactive phone + polkit flow may take up to two minutes.
// Keep the shell outside that budget so a successful daemon operation is not
// abandoned while the local owner prompt is still visible.
const CU_INTERACTIVE_AUTH_RPC_TIMEOUT: Duration = Duration::from_secs(135);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ComputerUseSessionBrokerRPCContract {
    readiness_method: &'static str,
    acquire_method: &'static str,
    status_method: &'static str,
    session_start_method: &'static str,
    session_status_method: &'static str,
}

const CU_SESSION_BROKER_RPC_CONTRACT: ComputerUseSessionBrokerRPCContract =
    ComputerUseSessionBrokerRPCContract {
        readiness_method: "daemon.computer_use.session_grant.readiness",
        acquire_method: "daemon.computer_use.session_grant.acquire",
        status_method: "daemon.computer_use.session_grant.status",
        session_start_method: "daemon.computer_use.session.start",
        session_status_method: "daemon.computer_use.approval.pending",
    };

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ComputerUseSessionAuthorityState {
    Available,
    WaitingPhone,
    WaitingLocalOwner,
    Authorized,
    Expired,
    Rejected,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ComputerUseSessionAuthorityStatus {
    state: ComputerUseSessionAuthorityState,
    expires_at: Option<f64>,
    detail: Option<String>,
    session_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ComputerUseDaemonSessionGrantState {
    Unavailable,
    AwaitingPhone,
    AwaitingDesktopOwner,
    Ready,
    Denied,
    Expired,
    Consumed,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionGrantStatus {
    challenge_id: String,
    session_intent_id: String,
    state: ComputerUseDaemonSessionGrantState,
    issued_at: f64,
    expires_at: f64,
    denial_reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionGrantReadiness {
    available: bool,
    reason: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionStartResponse {
    session_id: String,
    manifest_hash_hex: String,
    started_at: f64,
    entitlement_product_id: String,
    action_cap: u32,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDesktopOwnerAuthorizationRequest {
    method: String,
}

/// Renderer-safe request. Phone proof and local-owner results deliberately do
/// not exist on this type; a native broker implementation must acquire and
/// retain them outside the webview process.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseBrokerSessionStartRequest {
    mode: String,
    trust_mode: String,
    #[serde(default)]
    scope_rule_ids: Vec<String>,
    phone_viewer_node_id: Option<String>,
    mac_host_node_id: Option<String>,
    action_cap: Option<u32>,
    session_timeout_seconds: Option<u32>,
    client_id: String,
    run_id: String,
    run_call_id: String,
    run_generation: u64,
    desktop_owner_authorization_request: ComputerUseDesktopOwnerAuthorizationRequest,
}

#[derive(Clone, Debug)]
struct ActiveComputerUseBrokerFlow {
    request: ComputerUseBrokerSessionStartRequest,
    challenge_id: Option<String>,
    session_intent_id: Option<String>,
    status: ComputerUseSessionAuthorityStatus,
    start_in_progress: bool,
}

static COMPUTER_USE_BROKER_FLOW: OnceLock<Mutex<Option<ActiveComputerUseBrokerFlow>>> =
    OnceLock::new();

fn computer_use_broker_flow() -> &'static Mutex<Option<ActiveComputerUseBrokerFlow>> {
    COMPUTER_USE_BROKER_FLOW.get_or_init(|| Mutex::new(None))
}

trait ComputerUseSessionBroker: Send + Sync {
    #[cfg(test)]
    fn rpc_contract(&self) -> ComputerUseSessionBrokerRPCContract;
    fn status(&self) -> ComputerUseSessionAuthorityStatus;
    fn start(
        &self,
        request: ComputerUseBrokerSessionStartRequest,
    ) -> Result<ComputerUseSessionAuthorityStatus, String>;
}

struct DaemonComputerUseSessionBroker;

impl ComputerUseSessionBroker for DaemonComputerUseSessionBroker {
    #[cfg(test)]
    fn rpc_contract(&self) -> ComputerUseSessionBrokerRPCContract {
        CU_SESSION_BROKER_RPC_CONTRACT
    }

    fn status(&self) -> ComputerUseSessionAuthorityStatus {
        computer_use_broker_status_with(call_computer_use_broker_daemon_method)
    }

    fn start(
        &self,
        request: ComputerUseBrokerSessionStartRequest,
    ) -> Result<ComputerUseSessionAuthorityStatus, String> {
        validate_computer_use_broker_request(&request)?;
        Ok(computer_use_broker_acquire_with(
            request,
            call_computer_use_broker_daemon_method,
        ))
    }
}

fn validate_computer_use_broker_request(
    request: &ComputerUseBrokerSessionStartRequest,
) -> Result<(), String> {
    if request.mode != "browser" {
        return Err("Linux Computer Use authorization supports browser mode only".into());
    }
    validate_cu_trust_mode(&request.trust_mode)?;
    if request.run_id.trim().is_empty() || request.run_call_id.trim().is_empty() {
        return Err("computer use session start requires an exact runId and runCallId".into());
    }
    if request.client_id != CU_CLIENT_ID {
        return Err("computer use session start requires the linux-shell client".into());
    }
    if request.scope_rule_ids.len() > 256
        || request
            .scope_rule_ids
            .iter()
            .any(|value| !is_bounded_computer_use_identifier(value))
        || request
            .action_cap
            .is_some_and(|value| value == 0 || value > 10_000)
        || request
            .session_timeout_seconds
            .is_some_and(|value| value == 0 || value > 24 * 60 * 60)
    {
        return Err("computer use session start contains invalid bounded metadata".into());
    }
    if request.desktop_owner_authorization_request.method != "linux_desktop_owner" {
        return Err("computer use session start requires linux_desktop_owner authorization".into());
    }
    Ok(())
}

fn is_bounded_computer_use_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value
            .chars()
            .all(|character| character.is_ascii() && character != '\n' && character != '\r')
}

fn safe_computer_use_detail(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii() && !character.is_ascii_control() {
                character
            } else {
                ' '
            }
        })
        .take(512)
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn unavailable_computer_use_broker_status(
    detail: impl AsRef<str>,
) -> ComputerUseSessionAuthorityStatus {
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Unavailable,
        expires_at: None,
        detail: Some(safe_computer_use_detail(detail.as_ref())),
        session_id: None,
    }
}

fn available_computer_use_broker_status() -> ComputerUseSessionAuthorityStatus {
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Available,
        expires_at: None,
        detail: Some("Ready to request paired-phone Computer Use authorization.".into()),
        session_id: None,
    }
}

fn computer_use_session_request_wire(
    request: &ComputerUseBrokerSessionStartRequest,
    challenge_id: Option<&str>,
) -> serde_json::Value {
    serde_json::json!({
        "mode": request.mode,
        "trustMode": request.trust_mode,
        "scopeRuleIds": request.scope_rule_ids,
        "phoneViewerNodeId": request.phone_viewer_node_id,
        "macHostNodeId": request.mac_host_node_id,
        "actionCap": request.action_cap.unwrap_or(50),
        "sessionTimeoutSeconds": request.session_timeout_seconds.unwrap_or(1800),
        "clientID": request.client_id,
        "runID": request.run_id,
        "runCallID": request.run_call_id,
        "runGeneration": request.run_generation,
        "grantChallengeId": challenge_id,
        "desktopOwnerAuthorizationRequest": request.desktop_owner_authorization_request,
    })
}

fn computer_use_session_grant_acquire_wire(
    request: &ComputerUseBrokerSessionStartRequest,
) -> serde_json::Value {
    serde_json::json!({
        "sessionRequest": computer_use_session_request_wire(request, None),
    })
}

fn call_computer_use_broker_daemon_method(
    method: &str,
    params: serde_json::Value,
    timeout: Duration,
) -> Result<serde_json::Value, String> {
    call_daemon_method_with_timeout(method, Some(params), timeout)
}

fn decode_computer_use_grant_status(
    value: serde_json::Value,
    expected_challenge_id: Option<&str>,
    expected_session_intent_id: Option<&str>,
) -> Result<ComputerUseDaemonSessionGrantStatus, String> {
    let decoded: ComputerUseDaemonSessionGrantStatus = serde_json::from_value(value)
        .map_err(|_| "Computer Use broker returned malformed status metadata".to_string())?;
    if !is_bounded_computer_use_identifier(&decoded.challenge_id)
        || !is_sha256_hex(&decoded.session_intent_id)
        || !decoded.issued_at.is_finite()
        || !decoded.expires_at.is_finite()
        || decoded.expires_at <= decoded.issued_at
        || decoded.expires_at - decoded.issued_at > CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS
        || expected_challenge_id.is_some_and(|value| value != decoded.challenge_id)
        || expected_session_intent_id.is_some_and(|value| value != decoded.session_intent_id)
    {
        return Err("Computer Use broker returned mismatched status metadata".into());
    }
    Ok(decoded)
}

fn public_computer_use_grant_status(
    status: &ComputerUseDaemonSessionGrantStatus,
) -> ComputerUseSessionAuthorityStatus {
    let state = match status.state {
        ComputerUseDaemonSessionGrantState::AwaitingPhone
        | ComputerUseDaemonSessionGrantState::Ready => {
            ComputerUseSessionAuthorityState::WaitingPhone
        }
        ComputerUseDaemonSessionGrantState::AwaitingDesktopOwner => {
            ComputerUseSessionAuthorityState::WaitingLocalOwner
        }
        ComputerUseDaemonSessionGrantState::Denied
        | ComputerUseDaemonSessionGrantState::Consumed => {
            ComputerUseSessionAuthorityState::Rejected
        }
        ComputerUseDaemonSessionGrantState::Expired => ComputerUseSessionAuthorityState::Expired,
        ComputerUseDaemonSessionGrantState::Unavailable => {
            ComputerUseSessionAuthorityState::Unavailable
        }
    };
    ComputerUseSessionAuthorityStatus {
        state,
        expires_at: Some(status.expires_at),
        detail: status
            .denial_reason
            .as_deref()
            .map(safe_computer_use_detail),
        session_id: None,
    }
}

fn update_computer_use_broker_flow(
    expected_challenge_id: Option<&str>,
    update: impl FnOnce(&mut ActiveComputerUseBrokerFlow),
) -> bool {
    let Ok(mut guard) = computer_use_broker_flow().lock() else {
        return false;
    };
    let Some(flow) = guard.as_mut() else {
        return false;
    };
    if expected_challenge_id.is_some_and(|expected| flow.challenge_id.as_deref() != Some(expected))
    {
        return false;
    }
    update(flow);
    true
}

fn claim_computer_use_broker_start(
    expected_challenge_id: &str,
    waiting_owner: ComputerUseSessionAuthorityStatus,
) -> Result<(), ComputerUseSessionAuthorityStatus> {
    let Ok(mut guard) = computer_use_broker_flow().lock() else {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization state is unavailable.",
        ));
    };
    let Some(flow) = guard.as_mut() else {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization changed before session start.",
        ));
    };
    if flow.challenge_id.as_deref() != Some(expected_challenge_id) {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization changed before session start.",
        ));
    }
    if flow.start_in_progress || flow.status.state == ComputerUseSessionAuthorityState::Authorized {
        return Err(flow.status.clone());
    }
    flow.start_in_progress = true;
    flow.status = waiting_owner;
    Ok(())
}

fn computer_use_broker_acquire_with<F>(
    request: ComputerUseBrokerSessionStartRequest,
    caller: F,
) -> ComputerUseSessionAuthorityStatus
where
    F: Fn(&str, serde_json::Value, Duration) -> Result<serde_json::Value, String>,
{
    let requesting = ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::WaitingPhone,
        expires_at: None,
        detail: Some("Requesting approval from the paired phone.".into()),
        session_id: None,
    };
    {
        let Ok(mut guard) = computer_use_broker_flow().lock() else {
            return unavailable_computer_use_broker_status(
                "Computer Use authorization state is unavailable.",
            );
        };
        if let Some(active) = guard.as_ref() {
            if matches!(
                active.status.state,
                ComputerUseSessionAuthorityState::WaitingPhone
                    | ComputerUseSessionAuthorityState::WaitingLocalOwner
            ) {
                if active.request == request {
                    return active.status.clone();
                }
                return ComputerUseSessionAuthorityStatus {
                    state: ComputerUseSessionAuthorityState::Rejected,
                    expires_at: active.status.expires_at,
                    detail: Some(
                        "A different Computer Use authorization request is already active.".into(),
                    ),
                    session_id: None,
                };
            }
        }
        *guard = Some(ActiveComputerUseBrokerFlow {
            request: request.clone(),
            challenge_id: None,
            session_intent_id: None,
            status: requesting.clone(),
            start_in_progress: false,
        });
    }

    let raw = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.acquire_method,
        computer_use_session_grant_acquire_wire(&request),
        CU_BROKER_RPC_TIMEOUT,
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization is unavailable.",
            );
            update_computer_use_broker_flow(None, |flow| flow.status = unavailable.clone());
            return unavailable;
        }
    };
    let decoded = match decode_computer_use_grant_status(raw, None, None) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization returned invalid metadata.",
            );
            update_computer_use_broker_flow(None, |flow| flow.status = unavailable.clone());
            return unavailable;
        }
    };
    let public = public_computer_use_grant_status(&decoded);
    update_computer_use_broker_flow(None, |flow| {
        flow.challenge_id = Some(decoded.challenge_id.clone());
        flow.session_intent_id = Some(decoded.session_intent_id.clone());
        flow.status = public.clone();
    });
    public
}

fn computer_use_start_failure_status(error: &str) -> ComputerUseSessionAuthorityStatus {
    let normalized = error.to_ascii_lowercase();
    if normalized.contains("expired") {
        return ComputerUseSessionAuthorityStatus {
            state: ComputerUseSessionAuthorityState::Expired,
            expires_at: None,
            detail: Some("The Computer Use authorization expired before session start.".into()),
            session_id: None,
        };
    }
    if normalized.contains("unavailable")
        || normalized.contains("timed out")
        || normalized.contains("connection")
        || normalized.contains("no such file")
    {
        return unavailable_computer_use_broker_status(
            "Computer Use session authorization is unavailable.",
        );
    }
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Rejected,
        expires_at: None,
        detail: Some("Linux desktop-owner authorization was not completed.".into()),
        session_id: None,
    }
}

fn decode_computer_use_session_start(
    value: serde_json::Value,
) -> Result<ComputerUseSessionAuthorityStatus, String> {
    let decoded: ComputerUseDaemonSessionStartResponse = serde_json::from_value(value)
        .map_err(|_| "Computer Use session start returned malformed metadata".to_string())?;
    if !is_bounded_computer_use_identifier(&decoded.session_id)
        || !is_sha256_hex(&decoded.manifest_hash_hex)
        || !decoded.started_at.is_finite()
        || !is_bounded_computer_use_identifier(&decoded.entitlement_product_id)
        || decoded.action_cap == 0
        || decoded.action_cap > 10_000
    {
        return Err("Computer Use session start returned invalid metadata".into());
    }
    Ok(ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Authorized,
        expires_at: None,
        detail: None,
        session_id: Some(decoded.session_id),
    })
}

fn computer_use_broker_status_with<F>(caller: F) -> ComputerUseSessionAuthorityStatus
where
    F: Fn(&str, serde_json::Value, Duration) -> Result<serde_json::Value, String>,
{
    let snapshot = {
        let Ok(guard) = computer_use_broker_flow().lock() else {
            return unavailable_computer_use_broker_status(
                "Computer Use authorization state is unavailable.",
            );
        };
        guard.clone()
    };
    let Some(snapshot) = snapshot else {
        return match caller(
            CU_SESSION_BROKER_RPC_CONTRACT.readiness_method,
            serde_json::json!({}),
            CU_BROKER_RPC_TIMEOUT,
        ) {
            Ok(value) => {
                match serde_json::from_value::<ComputerUseDaemonSessionGrantReadiness>(value) {
                    Ok(readiness) if readiness.available && readiness.reason == "ready" => {
                        available_computer_use_broker_status()
                    }
                    Ok(readiness) => {
                        unavailable_computer_use_broker_status(match readiness.reason.as_str() {
                            "transport_unavailable" => {
                                "Paired-phone Computer Use transport is unavailable."
                            }
                            "proof_validator_unavailable" => {
                                "Paired-phone proof validation is unavailable."
                            }
                            "pairing_unavailable" => "No trusted paired controller is available.",
                            _ => "Paired-phone Computer Use authorization is unavailable.",
                        })
                    }
                    Err(_) => unavailable_computer_use_broker_status(
                        "Computer Use readiness returned malformed metadata.",
                    ),
                }
            }
            Err(_) => unavailable_computer_use_broker_status(
                "Computer Use readiness could not be verified.",
            ),
        };
    };
    {
        let flow = &snapshot;
        if flow.start_in_progress
            || matches!(
                flow.status.state,
                ComputerUseSessionAuthorityState::Expired
                    | ComputerUseSessionAuthorityState::Rejected
                    | ComputerUseSessionAuthorityState::Unavailable
            )
        {
            return flow.status.clone();
        }
    }
    if snapshot.status.state == ComputerUseSessionAuthorityState::Authorized {
        let Some(session_id) = snapshot.status.session_id.as_deref() else {
            return unavailable_computer_use_broker_status(
                "Authorized Computer Use state is missing its session identifier.",
            );
        };
        return match caller(
            CU_SESSION_BROKER_RPC_CONTRACT.session_status_method,
            serde_json::json!({ "sessionId": session_id }),
            CU_BROKER_RPC_TIMEOUT,
        ) {
            Ok(value)
                if value
                    .get("sessionActive")
                    .and_then(serde_json::Value::as_bool)
                    == Some(true) =>
            {
                snapshot.status
            }
            Ok(value)
                if value
                    .get("sessionActive")
                    .and_then(serde_json::Value::as_bool)
                    == Some(false) =>
            {
                if let Ok(mut guard) = computer_use_broker_flow().lock() {
                    *guard = None;
                }
                ComputerUseSessionAuthorityStatus {
                    state: ComputerUseSessionAuthorityState::Expired,
                    expires_at: None,
                    detail: Some("The authorized Computer Use session is no longer active.".into()),
                    session_id: None,
                }
            }
            Ok(_) => unavailable_computer_use_broker_status(
                "Computer Use session status returned malformed metadata.",
            ),
            Err(_) => unavailable_computer_use_broker_status(
                "Computer Use session state could not be revalidated.",
            ),
        };
    }
    let Some(challenge_id) = snapshot.challenge_id.as_deref() else {
        return snapshot.status;
    };
    let raw = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.status_method,
        serde_json::json!({ "challengeId": challenge_id }),
        CU_BROKER_RPC_TIMEOUT,
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization status is unavailable.",
            );
            update_computer_use_broker_flow(Some(challenge_id), |flow| {
                flow.status = unavailable.clone()
            });
            return unavailable;
        }
    };
    let decoded = match decode_computer_use_grant_status(
        raw,
        Some(challenge_id),
        snapshot.session_intent_id.as_deref(),
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization returned invalid status metadata.",
            );
            update_computer_use_broker_flow(Some(challenge_id), |flow| {
                flow.status = unavailable.clone()
            });
            return unavailable;
        }
    };
    if decoded.state != ComputerUseDaemonSessionGrantState::Ready {
        let public = public_computer_use_grant_status(&decoded);
        update_computer_use_broker_flow(Some(challenge_id), |flow| flow.status = public.clone());
        return public;
    }

    let waiting_owner = ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::WaitingLocalOwner,
        expires_at: Some(decoded.expires_at),
        detail: Some("Waiting for Linux desktop-owner authorization.".into()),
        session_id: None,
    };
    if let Err(current_status) = claim_computer_use_broker_start(challenge_id, waiting_owner) {
        return current_status;
    }

    let final_wire = computer_use_session_request_wire(&snapshot.request, Some(challenge_id));
    let final_status = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.session_start_method,
        final_wire,
        CU_INTERACTIVE_AUTH_RPC_TIMEOUT,
    ) {
        Ok(value) => decode_computer_use_session_start(value).unwrap_or_else(|_| {
            unavailable_computer_use_broker_status(
                "Computer Use session start returned invalid metadata.",
            )
        }),
        Err(error) => computer_use_start_failure_status(&error),
    };
    update_computer_use_broker_flow(Some(challenge_id), |flow| {
        flow.start_in_progress = false;
        flow.status = final_status.clone();
    });
    final_status
}

fn detect_linux_package_channel() -> String {
    detect_linux_package_facts().channel
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct LinuxPackageFacts {
    channel: String,
    manager: String,
    evidence: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct LinuxRuntimeFacts {
    os: String,
    architecture: String,
    kernel: Option<String>,
    session_type: Option<String>,
    desktop: Option<String>,
    display_server: Option<String>,
}

const DIAGNOSTICS_INCLUDED: [&str; 4] = [
    "shell version",
    "daemon health (ok, version, protocol, socket path)",
    "package channel and runtime facts",
    "export schema and file permissions",
];

const DIAGNOSTICS_EXCLUDED: [&str; 4] = [
    "provider API keys and credentials",
    "socket auth tokens",
    "provider response payloads",
    "user session content",
];

fn normalized_package_channel(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "appimage" => Some("appimage"),
        "deb" => Some("deb"),
        "rpm" => Some("rpm"),
        _ => None,
    }
}

fn package_manager_for_channel(channel: &str) -> &'static str {
    match channel {
        "deb" => "dpkg",
        "rpm" => "rpm",
        "appimage" => "appimage",
        _ => "unknown",
    }
}

fn command_reports_installed(command: &str, args: &[&str]) -> bool {
    Command::new(command)
        .args(args)
        .output()
        .map(|output| {
            output.status.success()
                && !String::from_utf8_lossy(&output.stdout)
                    .to_ascii_lowercase()
                    .contains("not installed")
        })
        .unwrap_or(false)
}

fn deb_package_reports_installed(command: &str, package_id: &str) -> bool {
    Command::new(command)
        .args(["-W", "-f=${Status}", package_id])
        .output()
        .map(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("install ok installed")
        })
        .unwrap_or(false)
}

fn package_query_ids() -> [&'static str; 2] {
    // The release smoke path historically emitted both names. Keep the probe
    // explicit instead of accepting arbitrary package-manager input.
    ["openburnbar", "open-burn-bar"]
}

fn detect_linux_package_facts() -> LinuxPackageFacts {
    if let Ok(channel) = std::env::var("OPENBURNBAR_PACKAGE_CHANNEL") {
        if let Some(channel) = normalized_package_channel(&channel) {
            return LinuxPackageFacts {
                channel: channel.to_string(),
                manager: package_manager_for_channel(channel).to_string(),
                evidence: "OPENBURNBAR_PACKAGE_CHANNEL".to_string(),
            };
        }
    }
    if first_non_empty_env(&["APPIMAGE", "APPDIR"]).is_some() {
        return LinuxPackageFacts {
            channel: "appimage".to_string(),
            manager: "appimage".to_string(),
            evidence: "APPIMAGE/APPDIR".to_string(),
        };
    }

    for package_id in package_query_ids() {
        if deb_package_reports_installed("/usr/bin/dpkg-query", package_id)
            || deb_package_reports_installed("/bin/dpkg-query", package_id)
        {
            return LinuxPackageFacts {
                channel: "deb".to_string(),
                manager: "dpkg".to_string(),
                evidence: format!("dpkg-query:{package_id}"),
            };
        }
    }
    for package_id in package_query_ids() {
        if command_reports_installed("/usr/bin/rpm", &["-q", package_id])
            || command_reports_installed("/bin/rpm", &["-q", package_id])
        {
            return LinuxPackageFacts {
                channel: "rpm".to_string(),
                manager: "rpm".to_string(),
                evidence: format!("rpm:{package_id}"),
            };
        }
    }
    if first_non_empty_env(&["FLATPAK_ID"]).is_some() {
        return LinuxPackageFacts {
            channel: "unknown".to_string(),
            manager: "flatpak".to_string(),
            evidence: "FLATPAK_ID (unsupported update channel)".to_string(),
        };
    }
    LinuxPackageFacts {
        channel: "unknown".to_string(),
        manager: "unknown".to_string(),
        evidence: "no-installed-package-evidence".to_string(),
    }
}

fn sanitized_runtime_fact(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 128 || value.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(value.to_string())
}

fn runtime_env_fact(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .and_then(|value| sanitized_runtime_fact(&value))
}

fn linux_kernel_release() -> Option<String> {
    fs::read_to_string("/proc/sys/kernel/osrelease")
        .ok()
        .and_then(|value| sanitized_runtime_fact(&value))
}

fn linux_runtime_facts() -> LinuxRuntimeFacts {
    let session_type = runtime_env_fact("XDG_SESSION_TYPE");
    let display_server = session_type.as_deref().and_then(|session| {
        if session.eq_ignore_ascii_case("wayland") {
            Some("wayland".to_string())
        } else if session.eq_ignore_ascii_case("x11") || session.eq_ignore_ascii_case("xorg") {
            Some("x11".to_string())
        } else {
            None
        }
    });
    LinuxRuntimeFacts {
        os: std::env::consts::OS.to_string(),
        architecture: std::env::consts::ARCH.to_string(),
        kernel: linux_kernel_release(),
        session_type,
        desktop: runtime_env_fact("XDG_CURRENT_DESKTOP"),
        display_server,
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseLocalAuthProof {
    proof_id: String,
    device_id: String,
    signed_intent_hash: String,
    authenticated_at: f64,
    expires_at: f64,
    signature_ed25519: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseLocalAuthGrantBinding {
    request_id: String,
    runtime: String,
    thread_id: String,
    preset: String,
    capabilities: Vec<String>,
    trust_mode: String,
    delivery_mode: String,
    requested_at: f64,
    expires_at: f64,
    grant_duration_seconds: f64,
    source_device_id: String,
    client_intent_id: String,
    local_authentication_satisfied: bool,
}

#[derive(Clone, Debug)]
struct ValidatedComputerUseLocalAuthTransport {
    proof: ComputerUseLocalAuthProof,
    source_device_id: String,
    intent_hash_hex: String,
    binding: ComputerUseLocalAuthGrantBinding,
}

#[cfg(test)]
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseSessionStartParams {
    /// ComputerUseMode raw: agent_watch | browser | system
    mode: String,
    /// ComputerUseTrustMode raw: manual | step | trusted
    trust_mode: String,
    #[serde(default)]
    scope_rule_ids: Vec<String>,
    phone_viewer_node_id: Option<String>,
    mac_host_node_id: Option<String>,
    action_cap: Option<u32>,
    session_timeout_seconds: Option<u32>,
    /// BurnBarClientID; defaults to linux-shell
    client_id: Option<String>,
    run_id: Option<String>,
    run_call_id: Option<String>,
    run_generation: Option<u64>,
    desktop_owner_authorization_request: Option<ComputerUseDesktopOwnerAuthorizationRequest>,
    local_auth_proof: Option<ComputerUseLocalAuthProof>,
    source_device_id: Option<String>,
    intent_hash_hex: Option<String>,
    local_auth_grant_binding: Option<ComputerUseLocalAuthGrantBinding>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseInvokeParams {
    session_id: String,
    /// BurnBarToolInvocation — required nested object (not flat tool/args).
    invocation: ComputerUseInvocationParams,
    local_auth_proof: Option<ComputerUseLocalAuthProof>,
    source_device_id: Option<String>,
    intent_hash_hex: Option<String>,
    local_auth_grant_binding: Option<ComputerUseLocalAuthGrantBinding>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseInvocationParams {
    call_id: String,
    run_id: String,
    tool: String,
    #[serde(default)]
    arguments: serde_json::Value,
    requested_by: Option<String>,
    /// Foundation reference-date seconds when provided; shell fills if absent.
    requested_at: Option<f64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseApprovalPendingParams {
    session_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseApprovalRespondParams {
    session_id: Option<String>,
    /// HermesRealtimeRelayApprovalResponse fields (nested under `response` on the wire).
    approval_id: String,
    decision: String,
    responded_by: Option<String>,
    responded_at: Option<f64>,
    note: Option<String>,
    request_hash_blake3: Option<String>,
    authority: Option<ComputerUseApprovalAuthority>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseApprovalAuthority {
    peer_node_id: String,
    counter: u64,
    timestamp: f64,
    intent_hash_blake3: String,
    signature_ed25519: String,
    attestation_hash_blake3: Option<String>,
    key_kind: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseAuditExportParams {
    session_id: String,
    include_screenshots: Option<bool>,
    anchor_open_timestamps: Option<bool>,
}

#[cfg(test)]
fn validate_cu_mode(mode: &str) -> Result<(), String> {
    match mode {
        "agent_watch" | "browser" | "system" => Ok(()),
        other => Err(format!(
            "computer use mode must be agent_watch|browser|system, got {other}"
        )),
    }
}

fn validate_cu_trust_mode(mode: &str) -> Result<(), String> {
    match mode {
        "manual" | "step" | "trusted" => Ok(()),
        other => Err(format!(
            "computer use trustMode must be manual|step|trusted, got {other}"
        )),
    }
}

fn validate_cu_approval_decision(decision: &str) -> Result<(), String> {
    match decision {
        "approve" | "reject" | "reject_and_halt" => Ok(()),
        other => Err(format!(
            "computer use approval decision must be approve|reject|reject_and_halt, got {other}"
        )),
    }
}

fn validate_cu_panic_source(source: &str) -> Result<(), String> {
    match source {
        "hotkey"
        | "phone_gesture"
        | "mac_lock"
        | "remote_config"
        | "accessibility_revoked"
        | "stalled"
        | "revoked" => Ok(()),
        other => Err(format!(
            "computer use panic source must be a ComputerUsePanicSource raw value, got {other}"
        )),
    }
}

fn cap_json_value_size(value: &serde_json::Value, label: &str) -> Result<(), String> {
    let encoded = serde_json::to_vec(value).map_err(|e| e.to_string())?;
    if encoded.len() > CU_MAX_ARGS_BYTES {
        return Err(format!(
            "{label} exceeds {CU_MAX_ARGS_BYTES} byte shell cap (got {})",
            encoded.len()
        ));
    }
    Ok(())
}

fn release_computer_use_local_auth_required() -> bool {
    !cfg!(debug_assertions)
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn canonical_local_auth_json_number(value: f64) -> Result<serde_json::Value, String> {
    if !value.is_finite() {
        return Err("computer use local-auth canonical number is not finite".into());
    }
    if value.fract() == 0.0 && value >= i64::MIN as f64 && value <= i64::MAX as f64 {
        return Ok(serde_json::json!(value as i64));
    }
    serde_json::Number::from_f64(value)
        .map(serde_json::Value::Number)
        .ok_or_else(|| "computer use local-auth canonical number is invalid".to_string())
}

fn canonical_local_auth_binding_hash_hex(
    binding: &ComputerUseLocalAuthGrantBinding,
) -> Result<String, String> {
    if !binding.requested_at.is_finite()
        || !binding.expires_at.is_finite()
        || !binding.grant_duration_seconds.is_finite()
    {
        return Err("computer use local-auth grant binding contains a non-finite number".into());
    }

    let mut capabilities = binding.capabilities.clone();
    capabilities.sort();
    let mut canonical = BTreeMap::<String, serde_json::Value>::new();
    canonical.insert("capabilities".into(), serde_json::json!(capabilities));
    canonical.insert(
        "clientIntentId".into(),
        serde_json::json!(binding.client_intent_id),
    );
    canonical.insert(
        "deliveryMode".into(),
        serde_json::json!(binding.delivery_mode),
    );
    canonical.insert(
        "expiresAt".into(),
        canonical_local_auth_json_number(binding.expires_at)?,
    );
    canonical.insert(
        "grantDurationSeconds".into(),
        canonical_local_auth_json_number(binding.grant_duration_seconds)?,
    );
    canonical.insert(
        "localAuthenticationSatisfied".into(),
        serde_json::json!(binding.local_authentication_satisfied),
    );
    canonical.insert("preset".into(), serde_json::json!(binding.preset));
    canonical.insert("requestId".into(), serde_json::json!(binding.request_id));
    canonical.insert(
        "requestedAt".into(),
        canonical_local_auth_json_number(binding.requested_at)?,
    );
    canonical.insert("runtime".into(), serde_json::json!(binding.runtime));
    canonical.insert(
        "sourceDeviceId".into(),
        serde_json::json!(binding.source_device_id),
    );
    canonical.insert("threadId".into(), serde_json::json!(binding.thread_id));
    canonical.insert("trustMode".into(), serde_json::json!(binding.trust_mode));

    let bytes = serde_json::to_vec(&canonical)
        .map_err(|error| format!("computer use local-auth canonicalization failed: {error}"))?;
    let digest = Sha256::digest(bytes);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
fn canonical_computer_use_session_intent_id(
    params: &ComputerUseSessionStartParams,
) -> Result<String, String> {
    let mut scope_rule_ids = params.scope_rule_ids.clone();
    scope_rule_ids.sort();
    let mut canonical = BTreeMap::<String, serde_json::Value>::new();
    canonical.insert(
        "actionCap".into(),
        serde_json::json!(params.action_cap.unwrap_or(50)),
    );
    canonical.insert(
        "clientId".into(),
        serde_json::json!(params.client_id.as_deref().unwrap_or(CU_CLIENT_ID)),
    );
    if let Some(value) = params.mac_host_node_id.as_ref() {
        canonical.insert("macHostNodeId".into(), serde_json::json!(value));
    }
    canonical.insert("mode".into(), serde_json::json!(params.mode));
    if let Some(value) = params.phone_viewer_node_id.as_ref() {
        canonical.insert("phoneViewerNodeId".into(), serde_json::json!(value));
    }
    if let Some(value) = params.run_id.as_ref() {
        canonical.insert("runId".into(), serde_json::json!(value));
    }
    if let Some(value) = params.run_call_id.as_ref() {
        canonical.insert("runCallId".into(), serde_json::json!(value));
    }
    if let Some(value) = params.run_generation {
        canonical.insert("runGeneration".into(), serde_json::json!(value));
    }
    if let Some(value) = params.desktop_owner_authorization_request.as_ref() {
        canonical.insert(
            "desktopOwnerAuthorizationMethod".into(),
            serde_json::json!(value.method),
        );
    }
    canonical.insert("scopeRuleIds".into(), serde_json::json!(scope_rule_ids));
    canonical.insert(
        "sessionTimeoutSeconds".into(),
        serde_json::json!(params.session_timeout_seconds.unwrap_or(1800)),
    );
    canonical.insert("trustMode".into(), serde_json::json!(params.trust_mode));
    canonical.insert("version".into(), serde_json::json!(2));
    let bytes = serde_json::to_vec(&canonical)
        .map_err(|error| format!("computer use session intent canonicalization failed: {error}"))?;
    let digest = Sha256::digest(bytes);
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn acquire_computer_use_local_auth_transport(
    proof: Option<ComputerUseLocalAuthProof>,
    source_device_id: Option<String>,
    intent_hash_hex: Option<String>,
    binding: Option<ComputerUseLocalAuthGrantBinding>,
    required: bool,
    now: f64,
) -> Result<Option<ValidatedComputerUseLocalAuthTransport>, String> {
    let has_any_field = proof.is_some()
        || source_device_id.is_some()
        || intent_hash_hex.is_some()
        || binding.is_some();
    if !has_any_field {
        return if required {
            Err(
                "computer use requires a fresh phone-signed local-auth proof in release builds"
                    .into(),
            )
        } else {
            Ok(None)
        };
    }

    let proof = proof.ok_or_else(|| {
        "computer use local-auth transport is incomplete: localAuthProof is missing".to_string()
    })?;
    let source_device_id = source_device_id
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            "computer use local-auth transport is incomplete: sourceDeviceId is missing".to_string()
        })?;
    let binding = binding.ok_or_else(|| {
        "computer use local-auth transport is incomplete: localAuthGrantBinding is missing"
            .to_string()
    })?;
    cap_json_value_size(
        &serde_json::to_value(&proof).map_err(|error| error.to_string())?,
        "localAuthProof",
    )?;
    cap_json_value_size(
        &serde_json::to_value(&binding).map_err(|error| error.to_string())?,
        "localAuthGrantBinding",
    )?;

    if !now.is_finite()
        || !proof.authenticated_at.is_finite()
        || !proof.expires_at.is_finite()
        || !binding.requested_at.is_finite()
        || !binding.expires_at.is_finite()
        || !binding.grant_duration_seconds.is_finite()
    {
        return Err("computer use local-auth proof contains a non-finite timestamp".into());
    }
    if proof.proof_id.trim().is_empty()
        || proof.device_id.trim().is_empty()
        || proof.signature_ed25519.trim().is_empty()
    {
        return Err("computer use local-auth proof contains an empty required field".into());
    }
    if !is_sha256_hex(&proof.signed_intent_hash) {
        return Err(
            "computer use local-auth proof signedIntentHash must be 64 hex characters".into(),
        );
    }
    if proof.device_id != source_device_id || binding.source_device_id != source_device_id {
        return Err("computer use local-auth source device binding does not match".into());
    }
    if !binding.local_authentication_satisfied {
        return Err("computer use local-auth grant does not record user authentication".into());
    }
    if proof.authenticated_at > now + CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS {
        return Err("computer use local-auth proof is dated in the future".into());
    }
    if proof.expires_at <= now {
        return Err("computer use local-auth proof has expired".into());
    }
    if proof.expires_at <= proof.authenticated_at
        || proof.expires_at - proof.authenticated_at > CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS
        || now - proof.authenticated_at > CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS
    {
        return Err("computer use local-auth proof lifetime is invalid".into());
    }
    if binding.requested_at > now + CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS
        || binding.expires_at <= now
        || binding.expires_at <= binding.requested_at
        || binding.grant_duration_seconds <= 0.0
        || binding.grant_duration_seconds > CU_LOCAL_AUTH_MAX_GRANT_DURATION_SECONDS
        || binding.expires_at > binding.requested_at + binding.grant_duration_seconds
    {
        return Err("computer use local-auth grant lifetime is invalid".into());
    }

    let expected_hash = canonical_local_auth_binding_hash_hex(&binding)?;
    if !proof
        .signed_intent_hash
        .eq_ignore_ascii_case(&expected_hash)
    {
        return Err("computer use local-auth proof is bound to a different grant".into());
    }
    if let Some(intent_hash_hex) = intent_hash_hex {
        if !is_sha256_hex(&intent_hash_hex) || !intent_hash_hex.eq_ignore_ascii_case(&expected_hash)
        {
            return Err("computer use local-auth intent hash hint does not match the grant".into());
        }
    }

    Ok(Some(ValidatedComputerUseLocalAuthTransport {
        proof,
        source_device_id,
        intent_hash_hex: expected_hash,
        binding,
    }))
}

fn append_computer_use_local_auth_fields(
    object: &mut serde_json::Map<String, serde_json::Value>,
    transport: Option<ValidatedComputerUseLocalAuthTransport>,
) -> Result<(), String> {
    let Some(transport) = transport else {
        return Ok(());
    };
    object.insert(
        "localAuthProof".into(),
        serde_json::to_value(transport.proof).map_err(|error| error.to_string())?,
    );
    object.insert(
        "sourceDeviceId".into(),
        serde_json::json!(transport.source_device_id),
    );
    object.insert(
        "intentHashHex".into(),
        serde_json::json!(transport.intent_hash_hex),
    );
    object.insert(
        "localAuthGrantBinding".into(),
        serde_json::to_value(transport.binding).map_err(|error| error.to_string())?,
    );
    Ok(())
}

fn require_computer_use_grant_capability(
    transport: &ValidatedComputerUseLocalAuthTransport,
    capability: &str,
) -> Result<(), String> {
    if transport
        .binding
        .capabilities
        .iter()
        .any(|candidate| candidate == capability)
    {
        Ok(())
    } else {
        Err(format!(
            "computer use local-auth grant does not authorize {capability}"
        ))
    }
}

#[cfg(test)]
fn validate_computer_use_start_grant(
    transport: &ValidatedComputerUseLocalAuthTransport,
    mode: &str,
    trust_mode: &str,
    expected_session_intent_id: &str,
) -> Result<(), String> {
    if transport.binding.trust_mode != trust_mode {
        return Err("computer use local-auth grant trust mode does not match the session".into());
    }
    match mode {
        "browser" => require_computer_use_grant_capability(transport, "desktop_browser"),
        "system" => require_computer_use_grant_capability(transport, "desktop_system_input"),
        "agent_watch" => require_computer_use_grant_capability(transport, "accessibility_inspect"),
        _ => Err("computer use local-auth grant received an unsupported mode".into()),
    }?;
    if transport.binding.client_intent_id != expected_session_intent_id {
        return Err("computer use local-auth grant is bound to a different session intent".into());
    }
    Ok(())
}

fn validate_computer_use_invoke_grant(
    transport: &ValidatedComputerUseLocalAuthTransport,
    tool: &str,
) -> Result<(), String> {
    if tool.starts_with("browser_") {
        require_computer_use_grant_capability(transport, "desktop_browser")
    } else if tool.starts_with("mac_input_") {
        require_computer_use_grant_capability(transport, "desktop_system_input")
    } else if tool == "mac_inspect_accessibility" {
        require_computer_use_grant_capability(transport, "accessibility_inspect")
    } else {
        Err("computer use invoke received a non-Computer-Use tool".into())
    }
}

#[cfg(test)]
fn computer_use_session_start_wire(
    params: ComputerUseSessionStartParams,
    require_local_auth: bool,
    now: f64,
) -> Result<serde_json::Value, String> {
    validate_cu_mode(&params.mode)?;
    validate_cu_trust_mode(&params.trust_mode)?;
    if require_local_auth
        && params.mode == "browser"
        && params
            .desktop_owner_authorization_request
            .as_ref()
            .is_none_or(|request| request.method != "linux_desktop_owner")
    {
        return Err(
            "release Browser Computer Use requires linux_desktop_owner authorization".into(),
        );
    }
    let expected_session_intent_id = canonical_computer_use_session_intent_id(&params)?;
    let local_auth = acquire_computer_use_local_auth_transport(
        params.local_auth_proof,
        params.source_device_id,
        params.intent_hash_hex,
        params.local_auth_grant_binding,
        require_local_auth,
        now,
    )?;
    if let Some(local_auth) = local_auth.as_ref() {
        validate_computer_use_start_grant(
            local_auth,
            &params.mode,
            &params.trust_mode,
            &expected_session_intent_id,
        )?;
    }
    let client_id = params
        .client_id
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    let mut payload = serde_json::json!({
        "mode": params.mode,
        "trustMode": params.trust_mode,
        "scopeRuleIds": params.scope_rule_ids,
        "phoneViewerNodeId": params.phone_viewer_node_id,
        "macHostNodeId": params.mac_host_node_id,
        "actionCap": params.action_cap.unwrap_or(50),
        "sessionTimeoutSeconds": params.session_timeout_seconds.unwrap_or(1800),
        "clientID": client_id,
        "runID": params.run_id,
        "runCallID": params.run_call_id,
        "runGeneration": params.run_generation,
        "desktopOwnerAuthorizationRequest": params.desktop_owner_authorization_request
    });
    append_computer_use_local_auth_fields(
        payload
            .as_object_mut()
            .ok_or_else(|| "computer use session payload must be an object".to_string())?,
        local_auth,
    )?;
    Ok(payload)
}

fn computer_use_invoke_wire(
    params: ComputerUseInvokeParams,
    require_local_auth: bool,
    now: f64,
) -> Result<serde_json::Value, String> {
    if params.session_id.trim().is_empty() {
        return Err("computer_use_invoke requires sessionId".into());
    }
    let invocation = params.invocation;
    if invocation.call_id.trim().is_empty()
        || invocation.run_id.trim().is_empty()
        || invocation.tool.trim().is_empty()
    {
        return Err("computer_use_invoke.invocation requires callID, runID, and tool".into());
    }
    cap_json_value_size(&invocation.arguments, "invocation.arguments")?;
    let local_auth = acquire_computer_use_local_auth_transport(
        params.local_auth_proof,
        params.source_device_id,
        params.intent_hash_hex,
        params.local_auth_grant_binding,
        require_local_auth,
        now,
    )?;
    if let Some(local_auth) = local_auth.as_ref() {
        validate_computer_use_invoke_grant(local_auth, &invocation.tool)?;
    }
    let requested_by = invocation
        .requested_by
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    let requested_at = invocation
        .requested_at
        .unwrap_or_else(foundation_reference_date_seconds);
    let mut payload = serde_json::json!({
        "sessionId": params.session_id,
        "invocation": {
            "callID": invocation.call_id,
            "runID": invocation.run_id,
            "tool": invocation.tool,
            "arguments": invocation.arguments,
            "requestedBy": requested_by,
            "requestedAt": requested_at
        }
    });
    append_computer_use_local_auth_fields(
        payload
            .as_object_mut()
            .ok_or_else(|| "computer use invoke payload must be an object".to_string())?,
        local_auth,
    )?;
    Ok(payload)
}

#[tauri::command]
async fn computer_use_session_authority_status() -> ComputerUseSessionAuthorityStatus {
    tauri::async_runtime::spawn_blocking(|| DaemonComputerUseSessionBroker.status())
        .await
        .unwrap_or_else(|_| {
            unavailable_computer_use_broker_status("Computer Use authorization status task failed.")
        })
}

#[tauri::command]
async fn computer_use_session_start(
    params: ComputerUseBrokerSessionStartRequest,
) -> Result<ComputerUseSessionAuthorityStatus, String> {
    // The concrete daemon/relay broker is intentionally replaceable. Until it
    // responds, production stays unavailable rather than accepting
    // renderer-created proof. The interactive session start occurs only after
    // daemon status reports the opaque challenge ready.
    tauri::async_runtime::spawn_blocking(move || DaemonComputerUseSessionBroker.start(params))
        .await
        .map_err(|error| format!("computer_use_authority_broker_join_failed:{error}"))?
}

#[tauri::command]
fn computer_use_invoke(params: ComputerUseInvokeParams) -> Result<serde_json::Value, String> {
    let payload = computer_use_invoke_wire(
        params,
        release_computer_use_local_auth_required(),
        foundation_reference_date_seconds(),
    )?;
    call_daemon_method("daemon.computer_use.invoke", Some(payload))
}

#[tauri::command]
fn computer_use_approval_pending(
    params: Option<ComputerUseApprovalPendingParams>,
) -> Result<serde_json::Value, String> {
    // ComputerUseApprovalPendingRequest { sessionId? } — no limit field.
    let session_id = params
        .and_then(|params| params.session_id)
        .filter(|value| !value.trim().is_empty());
    let filtered = session_id.is_some();
    let response = call_daemon_method(
        "daemon.computer_use.approval.pending",
        Some(serde_json::json!({ "sessionId": session_id })),
    )?;
    validate_computer_use_approval_pending_response(response, filtered)
}

fn validate_computer_use_approval_pending_response(
    response: serde_json::Value,
    filtered: bool,
) -> Result<serde_json::Value, String> {
    if filtered
        && response
            .get("sessionActive")
            .and_then(serde_json::Value::as_bool)
            .is_none()
    {
        return Err(
            "filtered Computer Use approval poll is missing authoritative sessionActive"
                .to_string(),
        );
    }
    Ok(response)
}

#[tauri::command]
fn computer_use_approval_respond(
    params: ComputerUseApprovalRespondParams,
) -> Result<serde_json::Value, String> {
    let payload = computer_use_approval_respond_wire(
        params,
        release_computer_use_local_auth_required(),
        foundation_reference_date_seconds(),
    )?;
    call_daemon_method("daemon.computer_use.approval.respond", Some(payload))
}

fn computer_use_approval_respond_wire(
    params: ComputerUseApprovalRespondParams,
    signed_authority_required: bool,
    now: f64,
) -> Result<serde_json::Value, String> {
    validate_cu_approval_decision(&params.decision)?;
    if params.approval_id.trim().is_empty() {
        return Err("computer_use_approval_respond requires approvalId".into());
    }
    let session_id = params.session_id.filter(|value| !value.trim().is_empty());
    let responded_by = params
        .responded_by
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    let responded_at = params.responded_at.unwrap_or(now);
    if !responded_at.is_finite() {
        return Err("computer use approval respondedAt must be finite".into());
    }

    let has_signed_field = params.request_hash_blake3.is_some() || params.authority.is_some();
    if signed_authority_required || has_signed_field {
        if session_id.is_none() {
            return Err("computer use approval requires an exact sessionId".into());
        }
        let request_hash = params.request_hash_blake3.as_deref().ok_or_else(|| {
            "computer use approval requires requestHashBlake3 from the pending request".to_string()
        })?;
        if !is_sha256_hex(request_hash) {
            return Err("computer use approval requestHashBlake3 must be 64 hex characters".into());
        }
        let authority = params.authority.as_ref().ok_or_else(|| {
            "computer use approval requires fresh signed phone authority".to_string()
        })?;
        if authority.peer_node_id.trim().is_empty()
            || authority.signature_ed25519.trim().is_empty()
            || authority.peer_node_id != responded_by
        {
            return Err("computer use approval authority identity is invalid".into());
        }
        if authority.counter == 0 {
            return Err("computer use approval authority counter must be positive".into());
        }
        if authority.counter > 9_007_199_254_740_991 {
            return Err(
                "computer use approval authority counter exceeds the JavaScript safe integer range"
                    .into(),
            );
        }
        if !authority.timestamp.is_finite()
            || (now - authority.timestamp).abs() > CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS
            || (responded_at - authority.timestamp).abs() > CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS
        {
            return Err("computer use approval authority timestamp is stale".into());
        }
        if !is_sha256_hex(&authority.intent_hash_blake3) {
            return Err(
                "computer use approval authority intentHashBlake3 must be 64 hex characters".into(),
            );
        }
        if let Some(key_kind) = authority.key_kind.as_deref() {
            if key_kind != "ed25519" && key_kind != "se-p256" {
                return Err("computer use approval authority keyKind is invalid".into());
            }
        }
    }

    // ComputerUseApprovalRespondRequest { sessionId?, response: HermesRealtimeRelayApprovalResponse }
    Ok(serde_json::json!({
        "sessionId": session_id,
        "response": {
            "approvalId": params.approval_id,
            "decision": params.decision,
            "respondedBy": responded_by,
            "respondedAt": responded_at,
            "note": params.note,
            "requestHashBlake3": params.request_hash_blake3,
            "authority": params.authority
        }
    }))
}

#[tauri::command]
fn computer_use_panic_halt(
    session_id: Option<String>,
    source: Option<String>,
) -> Result<serde_json::Value, String> {
    let session_id = session_id.unwrap_or_else(|| "*".to_string());
    let source = source.unwrap_or_else(|| "hotkey".to_string());
    if session_id.trim().is_empty() {
        return Err("computer_use_panic_halt requires sessionId".into());
    }
    validate_cu_panic_source(&source)?;
    request_computer_use_panic_halt(session_id, source)
}

#[tauri::command]
fn computer_use_audit_export(
    params: ComputerUseAuditExportParams,
) -> Result<serde_json::Value, String> {
    if params.session_id.trim().is_empty() {
        return Err("computer_use_audit_export requires sessionId".into());
    }
    // ComputerUseAuditExportRequest { sessionId, includeScreenshots, anchorOpenTimestamps }
    call_daemon_method(
        "daemon.computer_use.audit_export",
        Some(serde_json::json!({
            "sessionId": params.session_id,
            "includeScreenshots": params.include_screenshots.unwrap_or(true),
            "anchorOpenTimestamps": params.anchor_open_timestamps.unwrap_or(false)
        })),
    )
}

/// Apple Foundation reference-date seconds since 2001-01-01 UTC.
/// Matches extension `toBurnBarTimestamp`: `Date.now()/1000 - 978307200`.
fn foundation_reference_date_seconds() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    unix - 978_307_200.0
}

fn tray_number(value: &serde_json::Value, keys: &[&str]) -> Option<f64> {
    keys.iter()
        .find_map(|key| value.get(*key))
        .and_then(|value| {
            value
                .as_f64()
                .or_else(|| value.as_u64().map(|number| number as f64))
                .or_else(|| value.as_i64().map(|number| number as f64))
        })
}

/// Format the most recent daemon usage events for the native tray. The daemon
/// has returned both a top-level array and an `{ events: [...] }` envelope in
/// older protocol versions, so the shell deliberately accepts both shapes.
fn tray_usage_text(value: &serde_json::Value) -> String {
    let events = value
        .as_array()
        .or_else(|| value.get("events").and_then(serde_json::Value::as_array))
        .or_else(|| value.get("rows").and_then(serde_json::Value::as_array));
    let Some(events) = events else {
        return "Usage: unavailable".to_string();
    };
    let (tokens, cost) = events.iter().fold((0.0, 0.0), |(tokens, cost), event| {
        (
            tokens + tray_number(event, &["tokens", "totalTokens", "tokenCount"]).unwrap_or(0.0),
            cost + tray_number(event, &["costUsd", "cost", "estimatedCostUsd"]).unwrap_or(0.0),
        )
    });
    format!(
        "Recent usage: {} tokens - ${:.2}",
        format_compact_number(tokens),
        cost
    )
}

fn format_compact_number(number: f64) -> String {
    if number >= 1_000_000.0 {
        format!("{:.1}M", number / 1_000_000.0)
    } else if number >= 1_000.0 {
        format!("{:.1}K", number / 1_000.0)
    } else {
        format!("{:.0}", number)
    }
}

fn tray_update_text(status: &update_feed::LinuxUpdateStatus) -> String {
    match status.state.as_str() {
        "available" => format!(
            "Update available: {}",
            status.latest_version.as_deref().unwrap_or("new version")
        ),
        "current" => "Updates: up to date".to_string(),
        "unavailable" => "Updates: feed unavailable".to_string(),
        "invalid" => "Updates: feed rejected".to_string(),
        state => format!("Updates: {state}"),
    }
}

fn emit_tray_route(app: &AppHandle, route: &str) {
    let _ = open_dashboard(app.clone());
    let _ = app.emit("tray-route", route.to_string());
}

fn refresh_tray_status_items(
    status_item: MenuItem<tauri::Wry>,
    usage_item: MenuItem<tauri::Wry>,
    update_item: MenuItem<tauri::Wry>,
) {
    tauri::async_runtime::spawn(async move {
        let health = tauri::async_runtime::spawn_blocking(probe_daemon_health)
            .await
            .unwrap_or_default();
        let status_text = if health.ok {
            format!(
                "Daemon: connected{}",
                health
                    .daemon_version
                    .as_deref()
                    .map(|version| format!(" - {version}"))
                    .unwrap_or_default()
            )
        } else {
            "Daemon: offline".to_string()
        };
        let _ = status_item.set_text(status_text);

        let usage = tauri::async_runtime::spawn_blocking(|| usage_summary().ok())
            .await
            .ok()
            .flatten();
        let _ = usage_item.set_text(
            usage
                .as_ref()
                .map(tray_usage_text)
                .unwrap_or_else(|| "Usage: unavailable".to_string()),
        );

        let update = update_status().await;
        let _ = update_item.set_text(tray_update_text(&update));
    });
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open_i = MenuItemBuilder::with_id("open", "Open dashboard").build(app)?;
    let chat_i = MenuItemBuilder::with_id("chat", "Open chat").build(app)?;
    let usage_i = MenuItemBuilder::with_id("usage", "Open usage").build(app)?;
    let updates_i = MenuItemBuilder::with_id("updates", "Open updates").build(app)?;
    let settings_i = MenuItemBuilder::with_id("settings", "Open settings").build(app)?;
    let status_i = MenuItemBuilder::with_id("status", "Daemon: checking...")
        .enabled(false)
        .build(app)?;
    let recent_usage_i = MenuItemBuilder::with_id("recent-usage", "Usage: checking...")
        .enabled(false)
        .build(app)?;
    let update_state_i = MenuItemBuilder::with_id("update-state", "Updates: checking...")
        .enabled(false)
        .build(app)?;
    let refresh_i = MenuItemBuilder::with_id("refresh", "Refresh status").build(app)?;
    let health_i = MenuItemBuilder::with_id("health", "Reconnect daemon").build(app)?;
    let quit_i = MenuItemBuilder::with_id("quit", "Quit OpenBurnBar").build(app)?;
    let menu = MenuBuilder::new(app)
        .items(&[&open_i, &chat_i, &usage_i, &updates_i, &settings_i])
        .separator()
        .items(&[&status_i, &recent_usage_i, &update_state_i])
        .separator()
        .items(&[&refresh_i, &health_i, &quit_i])
        .build()?;

    let status_for_events = status_i.clone();
    let usage_for_events = recent_usage_i.clone();
    let update_for_events = update_state_i.clone();
    refresh_tray_status_items(status_i, recent_usage_i, update_state_i);

    let _tray = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("OpenBurnBar — Linux desktop assistant")
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "open" => emit_tray_route(app, "overview"),
            "chat" => emit_tray_route(app, "chat"),
            "usage" => emit_tray_route(app, "insights"),
            "updates" => emit_tray_route(app, "updates"),
            "settings" => emit_tray_route(app, "settings"),
            "refresh" => refresh_tray_status_items(
                status_for_events.clone(),
                usage_for_events.clone(),
                update_for_events.clone(),
            ),
            "health" => {
                let health = daemon_health();
                let _ = app.emit("daemon-health", health);
                refresh_tray_status_items(
                    status_for_events.clone(),
                    usage_for_events.clone(),
                    update_for_events.clone(),
                );
            }
            "quit" => quit_app(app.clone()),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                emit_tray_route(app, "overview");
            }
        })
        .build(app)?;
    Ok(())
}

/// Installs the process-wide `tracing` subscriber for the desktop shell.
///
/// Idempotent: `try_init` returns `Err` if a global subscriber is already set,
/// which we swallow, so calling this more than once (or alongside a host that
/// already initialized tracing) is a safe no-op rather than a panic. Verbosity
/// is controlled by the standard `RUST_LOG` env var (e.g.
/// `RUST_LOG=openburnbar_linux_desktop=debug`); when unset it defaults to
/// `info`.
fn init_tracing() {
    use tracing_subscriber::{fmt, EnvFilter};

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    // Discard the result: an existing subscriber (double-init) is not an error.
    let _ = fmt().with_env_filter(filter).with_target(true).try_init();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let initial_route = std::env::args()
        .skip(1)
        .find_map(|arg| validated_deep_link_route(&arg).map(str::to_string));
    store_initial_deep_link_route(initial_route);

    // Fast-exit CLI flags before booting the GUI: a GTK/WebKit app launched
    // headless (packaging smoke, CI) would otherwise spin forever on `--version`.
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--version" | "-V" => {
                println!("OpenBurnBar {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--daemon-health" => {
                let health = probe_daemon_health();
                println!(
                    "{}",
                    serde_json::to_string(&health).unwrap_or_else(|error| {
                        format!(r#"{{"ok":false,"error":"health serialization failed: {error}"}}"#)
                    })
                );
                std::process::exit(if health.ok { 0 } else { 1 });
            }
            "--help" | "-h" => {
                println!(
                    "OpenBurnBar Linux desktop shell\n\nUsage: openburnbar-linux-desktop [--version] [--daemon-health] [--help]"
                );
                std::process::exit(0);
            }
            _ => {}
        }
    }

    let startup_messages = match single_instance::startup_messages_from_args(
        std::env::args().skip(1),
        validated_deep_link_route,
    ) {
        Ok(messages) => messages,
        Err(error) => {
            eprintln!("openburnbar: refusing startup arguments: {error}");
            return;
        }
    };
    let instance = match single_instance::acquire(
        &single_instance::directory(linux_support_dir),
        &startup_messages,
    ) {
        Ok(instance) => instance,
        Err(error) => {
            eprintln!("openburnbar: single-instance startup unavailable: {error}");
            return;
        }
    };
    let (instance_guard, instance_receiver) = match instance {
        single_instance::Acquire::Primary { guard, receiver } => (guard, receiver),
        single_instance::Acquire::Forwarded => return,
    };

    // Install the process-wide tracing subscriber so the remote stack's
    // `tracing::info!/warn!` events (and Tauri/tao/wry diagnostics) actually go
    // somewhere. Placed after the `--version`/`--help` fast-exit so probe output
    // stays clean. Verbosity follows the standard `RUST_LOG` env var, defaulting
    // to `info`; `try_init` makes a double-init (or a host that already set a
    // subscriber) a no-op instead of a panic.
    init_tracing();

    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            daemon_health,
            runtime_capabilities,
            gateway_probe,
            gateway_chat_stream,
            gateway_chat_cancel,
            open_external_url,
            open_update_url,
            open_dashboard,
            initial_deep_link_route,
            quit_app,
            tray_degraded,
            record_perf_sample,
            measure_perf_operation,
            onboarding_snapshot,
            onboarding_action,
            onboarding_reset,
            subscription_start,
            subscription_resume,
            subscription_stop,
            usage_summary,
            provider_catalog,
            session_list,
            session_search,
            chat_thread_list,
            chat_thread_get,
            chat_message_append,
            usage_insights,
            mission_list,
            mission_get,
            mission_create,
            mission_approval_decision,
            mission_cancel,
            config_snapshot,
            config_update,
            provider_credential_slot_upsert,
            provider_credential_slot_remove,
            provider_model_variant_upsert,
            provider_model_variant_remove,
            provider_model_alias_upsert,
            provider_model_alias_remove,
            provider_custom_model_upsert,
            provider_custom_model_remove,
            provider_model_display_name_set,
            provider_model_display_name_clear,
            proxy_route_log_recent,
            proxy_route_log_clear,
            notification_config_get,
            notification_config_update,
            notification_health,
            notification_command,
            db_status,
            project_list,
            project_get,
            project_upsert,
            project_delete,
            project_reassign,
            memory_boundaries,
            memory_review_inbox,
            memory_forget,
            database_workspace_status,
            database_index_project,
            database_watch_project,
            database_code_search,
            database_code_context_pack,
            database_recovery_bundle_export,
            database_recovery_bundle_import,
            account_status,
            account_begin_sign_in,
            account_cancel_sign_in,
            account_rotate_identity,
            account_sign_out,
            membership_status,
            membership_checkout_url,
            membership_restore,
            app_version_info,
            update_status,
            export_diagnostics,
            session_env,
            media_status,
            media_session_state,
            media_accept_call,
            media_decline_call,
            media_end_call,
            media_capability_get,
            media_file_offer_list,
            media_file_accept,
            media_file_decline,
            media_file_send,
            tool_approval_respond,
            memory_set_status,
            computer_use_session_authority_status,
            computer_use_session_start,
            computer_use_invoke,
            computer_use_approval_pending,
            computer_use_approval_respond,
            computer_use_panic_halt,
            computer_use_audit_export,
            integrations_status,
            smarthub_command
        ])
        .setup(move |app| {
            app.manage(instance_guard);
            start_single_instance_dispatcher(app.handle().clone(), instance_receiver);
            start_packaged_daemon_lifecycle(app.handle().clone());
            if let Err(e) = build_tray(app.handle()) {
                TRAY_INIT_FAILED.store(true, Ordering::Relaxed);
                eprintln!("tray init degraded: {e}");
            }
            register_computer_use_panic_shortcuts(app.handle());
            start_media_session_poll_loop(app.handle().clone());
            media::start_media_socket_reader(app.handle().clone());
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let RunEvent::WindowEvent { label, event, .. } = event {
                if label == "main" {
                    if let WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        if let Some(window) = app_handle.get_webview_window("main") {
                            let _ = window.hide();
                        }
                    }
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    static COMPUTER_USE_BROKER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn valid_google_pkce_url() -> String {
        format!(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=123456789012-desktop.apps.googleusercontent.com&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcallback&code_challenge={}&code_challenge_method=S256&state={}&scope=openid%20email%20profile",
            "c".repeat(43),
            "s".repeat(43)
        )
    }

    fn computer_use_broker_test_guard() -> std::sync::MutexGuard<'static, ()> {
        let guard = COMPUTER_USE_BROKER_TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap();
        *computer_use_broker_flow().lock().unwrap() = None;
        guard
    }

    #[test]
    fn project_upsert_validation_requires_canonical_identity_fields() {
        let error = validate_project_upsert_payload(&serde_json::json!({
            "projectSlug": "apollo",
            "displayName": "Apollo",
            "id": "project-apollo"
        }))
        .expect_err("summary is required by BurnBarReviewProjectSnapshot");
        assert_eq!(error, "project.summary must be a non-empty string");

        validate_project_upsert_payload(&serde_json::json!({
            "projectSlug": "apollo",
            "displayName": "Apollo",
            "summary": "Controller project",
            "id": "project-apollo"
        }))
        .expect("canonical identity fields should validate");
    }

    #[test]
    fn project_upsert_validation_rejects_non_object_payloads() {
        let error = validate_project_upsert_payload(&serde_json::json!("apollo"))
            .expect_err("project payload must be an object");
        assert_eq!(error, "project must be a JSON object");
    }

    #[test]
    fn project_lifecycle_validation_rejects_noncanonical_identifiers() {
        assert!(validate_project_slug("Apollo", "projectSlug").is_err());
        assert!(validate_project_slug("apollo/child", "projectSlug").is_err());
        assert!(validate_project_identifier("project apollo", "project.id").is_err());
        assert!(validate_project_identifier("project-apollo", "project.id").is_ok());
        assert!(project_reassign("apollo".to_string(), "apollo".to_string()).is_err());
    }

    #[test]
    fn packaged_daemon_launcher_resolution_uses_only_fixed_package_paths() {
        use std::cell::RefCell;
        use std::ffi::OsStr;

        let inspected = RefCell::new(Vec::new());
        let appimage = resolve_packaged_daemon_launcher_with(
            Some(OsStr::new("/tmp/.mount_OpenBurnBar")),
            false,
            |path, kind| {
                inspected.borrow_mut().push((path.to_path_buf(), kind));
                kind == DaemonLauncherKind::AppImage
            },
        );
        assert_eq!(
            appimage,
            Some(PathBuf::from(
                "/tmp/.mount_OpenBurnBar/usr/libexec/openburnbar-daemon-launch"
            ))
        );
        assert_eq!(
            inspected.into_inner(),
            vec![(
                PathBuf::from("/tmp/.mount_OpenBurnBar/usr/libexec/openburnbar-daemon-launch"),
                DaemonLauncherKind::AppImage
            )]
        );

        let inspected = RefCell::new(Vec::new());
        let system = resolve_packaged_daemon_launcher_with(
            Some(OsStr::new("untrusted-relative-root")),
            true,
            |path, kind| {
                inspected.borrow_mut().push((path.to_path_buf(), kind));
                kind == DaemonLauncherKind::SystemPackage
            },
        );
        assert_eq!(system, Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER)));
        assert_eq!(
            inspected.into_inner(),
            vec![(
                PathBuf::from(SYSTEM_DAEMON_LAUNCHER),
                DaemonLauncherKind::SystemPackage
            )]
        );

        let development = resolve_packaged_daemon_launcher_with(None, false, |_, _| {
            panic!("development builds must not inspect a system launcher")
        });
        assert_eq!(development, None);
    }

    #[test]
    fn daemon_lifecycle_does_not_spawn_when_authenticated_daemon_is_live() {
        let outcome = ensure_daemon_running_with(
            Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER)),
            || true,
            |_| panic!("already-live daemon must not spawn a launcher"),
            || panic!("already-live daemon must not sleep"),
            3,
        );
        assert_eq!(outcome, DaemonStartupOutcome::AlreadyRunning);
    }

    #[test]
    fn daemon_lifecycle_spawns_fixed_launcher_and_waits_for_readiness() {
        use std::cell::{Cell, RefCell};

        let probes = Cell::new(0usize);
        let sleeps = Cell::new(0usize);
        let spawned = RefCell::new(None);
        let outcome = ensure_daemon_running_with(
            Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER)),
            || {
                let probe = probes.get();
                probes.set(probe + 1);
                probe >= 2
            },
            |path| {
                *spawned.borrow_mut() = Some(path.to_path_buf());
                Ok(())
            },
            || sleeps.set(sleeps.get() + 1),
            4,
        );
        assert_eq!(outcome, DaemonStartupOutcome::Started);
        assert_eq!(
            spawned.into_inner(),
            Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER))
        );
        assert_eq!(probes.get(), 3);
        assert_eq!(sleeps.get(), 1);
    }

    #[test]
    fn daemon_lifecycle_reports_spawn_failure_without_retrying() {
        use std::cell::Cell;

        let probes = Cell::new(0usize);
        let outcome = ensure_daemon_running_with(
            Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER)),
            || {
                probes.set(probes.get() + 1);
                false
            },
            |_| Err("permission denied".to_string()),
            || panic!("spawn failures must not enter the readiness loop"),
            4,
        );
        assert_eq!(
            outcome,
            DaemonStartupOutcome::SpawnFailed("permission denied".to_string())
        );
        assert_eq!(probes.get(), 1);
    }

    #[test]
    fn daemon_lifecycle_readiness_timeout_is_strictly_bounded() {
        use std::cell::Cell;

        let probes = Cell::new(0usize);
        let sleeps = Cell::new(0usize);
        let outcome = ensure_daemon_running_with(
            Some(PathBuf::from(SYSTEM_DAEMON_LAUNCHER)),
            || {
                probes.set(probes.get() + 1);
                false
            },
            |_| Ok(()),
            || sleeps.set(sleeps.get() + 1),
            3,
        );
        assert_eq!(outcome, DaemonStartupOutcome::ReadinessTimedOut);
        assert_eq!(probes.get(), 4);
        assert_eq!(sleeps.get(), 2);
    }

    #[test]
    fn account_identity_rotation_uses_bounded_multi_stage_auth_timeout() {
        let response = account_rotate_identity_with(|method, params, timeout| {
            assert_eq!(method, "daemon.auth.rotate_identity");
            assert_eq!(params, None);
            assert_eq!(timeout, ACCOUNT_ROTATE_IDENTITY_RPC_TIMEOUT);
            assert!(timeout > Duration::from_secs(120));
            assert!(timeout <= Duration::from_secs(150));
            Ok(serde_json::json!({ "ok": true }))
        })
        .unwrap();

        assert_eq!(response["ok"], true);
    }

    fn computer_use_broker_request_fixture() -> ComputerUseBrokerSessionStartRequest {
        serde_json::from_value(serde_json::json!({
            "mode": "browser",
            "trustMode": "step",
            "clientId": "linux-shell",
            "runId": "run-1",
            "runCallId": "call-1",
            "runGeneration": 7,
            "desktopOwnerAuthorizationRequest": { "method": "linux_desktop_owner" }
        }))
        .unwrap()
    }

    fn computer_use_grant_status_fixture(state: &str) -> serde_json::Value {
        serde_json::json!({
            "challengeId": "challenge-opaque-1",
            "sessionIntentId": "a".repeat(64),
            "state": state,
            "issuedAt": 800_000_000.0,
            "expiresAt": 800_000_300.0,
            "denialReason": null
        })
    }

    #[test]
    fn diagnostics_bundle_is_metadata_only_and_has_a_safe_preview_contract() {
        let health = DaemonHealth {
            ok: false,
            daemon_version: Some("1.2.3".to_string()),
            protocol_version: Some(7),
            socket_path: Some("/run/user/1000/openburnbar/daemon.sock".to_string()),
            error: Some("socket auth token should never be serialized".to_string()),
            ..Default::default()
        };
        let package = LinuxPackageFacts {
            channel: "unknown".to_string(),
            manager: "unknown".to_string(),
            evidence: "no-installed-package-evidence".to_string(),
        };
        let runtime = LinuxRuntimeFacts {
            os: "linux".to_string(),
            architecture: "x86_64".to_string(),
            kernel: Some("6.8.0".to_string()),
            session_type: Some("wayland".to_string()),
            desktop: Some("GNOME".to_string()),
            display_server: Some("wayland".to_string()),
        };
        let bundle = diagnostics_bundle(42, &health, &package, &runtime);
        let encoded = serde_json::to_string(&bundle).unwrap();
        assert!(!encoded.contains("packageChannel"));
        assert!(!encoded.contains("socket auth token should never be serialized"));
        assert!(encoded.contains("provider API keys and credentials"));
        assert!(encoded.contains("runtime"));

        let preview = diagnostics_preview(encoded.len());
        assert_eq!(preview["schemaVersion"], 1);
        assert_eq!(preview["fileMode"], "0600");
        assert_eq!(preview["byteCount"], encoded.len());
        assert!(preview["included"].as_array().unwrap().len() >= 4);
        assert!(preview["excluded"].as_array().unwrap().len() >= 4);
    }

    #[test]
    fn package_channel_override_is_strict_and_unknown_is_not_promoted_to_appimage() {
        assert_eq!(normalized_package_channel(" DEB "), Some("deb"));
        assert_eq!(normalized_package_channel("rpm"), Some("rpm"));
        assert_eq!(normalized_package_channel("appimage"), Some("appimage"));
        assert_eq!(normalized_package_channel("flatpak"), None);
        assert_eq!(package_manager_for_channel("unknown"), "unknown");
    }

    #[test]
    fn runtime_facts_reject_control_input_and_normalize_display_server() {
        assert_eq!(
            sanitized_runtime_fact("  GNOME  "),
            Some("GNOME".to_string())
        );
        assert_eq!(sanitized_runtime_fact("bad\nvalue"), None);
        assert_eq!(sanitized_runtime_fact(&"x".repeat(129)), None);

        let session = Some("x11".to_string());
        let display_server = session.as_deref().and_then(|value| {
            if value.eq_ignore_ascii_case("wayland") {
                Some("wayland".to_string())
            } else if value.eq_ignore_ascii_case("x11") || value.eq_ignore_ascii_case("xorg") {
                Some("x11".to_string())
            } else {
                None
            }
        });
        assert_eq!(display_server.as_deref(), Some("x11"));
    }

    // BurnBarMissionApproveRequest/CancelRequest decode `missionID` (capital ID,
    // Swift property name verbatim — no CodingKeys remap) plus a non-optional
    // `actor`. A rename on either side makes the daemon's Codable decode throw,
    // silently breaking approvals. This test pins the wire shape.
    #[test]
    fn mission_decision_wire_contract_is_pinned() {
        let (method, params) = mission_decision_wire("m-42", "approve");
        assert_eq!(method, "daemon.mission.approve");
        assert_eq!(params["missionID"], "m-42");
        assert_eq!(params["actor"], "linux-shell");
        assert!(params.get("missionId").is_none());
        assert!(params.get("id").is_none());

        let (method, params) = mission_decision_wire("m-43", "deny");
        assert_eq!(method, "daemon.mission.cancel");
        assert_eq!(params["missionID"], "m-43");
        assert_eq!(params["actor"], "linux-shell");
    }

    #[test]
    fn exact_thread_chat_wire_contract_is_pinned() {
        let (method, params) = chat_thread_list_wire(Some("release".into()), 40);
        assert_eq!(method, "daemon.chat.thread.list");
        assert_eq!(params["query"], "release");
        assert_eq!(params["limit"], 40);

        let (_, params) = chat_thread_list_wire(None, 100);
        assert!(params.get("query").is_none());
        assert_eq!(params["limit"], 100);

        let (method, params) = chat_thread_get_wire("thread-42".into(), 500, None, None);
        assert_eq!(method, "daemon.chat.thread.get");
        assert_eq!(params["threadID"], "thread-42");
        assert_eq!(params["maxMessages"], 500);
        assert!(params.get("threadId").is_none());

        let (_, params) = chat_thread_get_wire(
            "thread-42".into(),
            500,
            Some("2026-07-10T12:00:00.000Z".into()),
            Some("message-42".into()),
        );
        assert_eq!(params["beforeTimestamp"], "2026-07-10T12:00:00.000Z");
        assert_eq!(params["beforeMessageID"], "message-42");

        let source = include_str!("lib.rs");
        assert!(source.contains("daemon.chat.message.append"));
        assert!(source.contains("fn chat_message_append"));
    }

    #[test]
    fn gateway_endpoint_is_fixed_to_loopback_health_authority() {
        let mut health = DaemonHealth {
            ok: true,
            gateway_enabled: Some(true),
            gateway_host: Some("127.0.0.1".into()),
            gateway_port: Some(8642),
            ..Default::default()
        };
        let endpoint = gateway_endpoint_from_health(&health, "/v1/chat/completions").unwrap();
        assert_eq!(
            endpoint.as_str(),
            "http://127.0.0.1:8642/v1/chat/completions"
        );

        health.gateway_host = Some("api.example.com".into());
        assert_eq!(
            gateway_endpoint_from_health(&health, "/v1/chat/completions").unwrap_err(),
            "gateway_non_loopback_host_refused"
        );
        health.gateway_host = Some("127.0.0.1@evil.example".into());
        assert!(gateway_endpoint_from_health(&health, "/health").is_err());
    }

    #[test]
    fn gateway_proxy_request_validation_is_bounded_and_role_allowlisted() {
        let valid = GatewayProxyRequest {
            request_id: "request-123".into(),
            model: "hermes".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "hello".into(),
            }],
        };
        assert!(validate_gateway_request(&valid).is_ok());

        let invalid_role = GatewayProxyRequest {
            request_id: "request-124".into(),
            model: "hermes".into(),
            messages: vec![GatewayProxyMessage {
                role: "developer".into(),
                content: "hello".into(),
            }],
        };
        assert_eq!(
            validate_gateway_request(&invalid_role).unwrap_err(),
            "gateway_invalid_message_role"
        );

        let invalid_id = GatewayProxyRequest {
            request_id: "../../escape".into(),
            model: "hermes".into(),
            messages: valid.messages,
        };
        assert_eq!(
            validate_gateway_request(&invalid_id).unwrap_err(),
            "gateway_invalid_request_id"
        );
    }

    #[test]
    fn external_url_validation_is_https_and_stripe_host_allowlisted() {
        assert_eq!(
            validate_external_url("https://checkout.stripe.com/c/pay/cs_live_123").unwrap(),
            "https://checkout.stripe.com/c/pay/cs_live_123"
        );
        assert_eq!(
            validate_external_url("https://buy.stripe.com/test_123?prefilled_email=a%40b.test")
                .unwrap(),
            "https://buy.stripe.com/test_123?prefilled_email=a%40b.test"
        );
        for refused in [
            "http://checkout.stripe.com/c/pay/cs_live_123",
            "https://checkout.stripe.com.evil.example/c/pay/cs_live_123",
            "https://user@checkout.stripe.com/c/pay/cs_live_123",
            "https://127.0.0.1/c/pay/cs_live_123",
            "file:///etc/passwd",
            "javascript:alert(1)",
        ] {
            assert!(validate_external_url(refused).is_err(), "{refused}");
        }
    }

    #[test]
    fn auth_url_validation_is_exact_google_pkce_endpoint_only() {
        let valid = valid_google_pkce_url();
        assert_eq!(validate_auth_url(&valid).unwrap(), valid);
        for refused in [
            valid.replacen("https://", "http://", 1),
            valid.replacen("accounts.google.com", "accounts.google.com.evil.example", 1),
            valid.replacen("https://", "https://user@", 1),
            valid.replacen("/o/oauth2/v2/auth", "/o/oauth2/auth", 1),
            valid.replacen("accounts.google.com", "accounts.google.com:444", 1),
            valid.replacen(
                "code_challenge_method=S256",
                "code_challenge_method=plain",
                1,
            ),
            valid.replacen(
                "redirect_uri=http%3A%2F%2F127.0.0.1",
                "redirect_uri=http%3A%2F%2Flocalhost",
                1,
            ),
            format!("{valid}&state=duplicate"),
            format!("{valid}&prompt=consent"),
            "file:///etc/passwd".to_string(),
        ] {
            assert!(validate_auth_url(&refused).is_err(), "{refused}");
        }
    }

    #[test]
    fn auth_url_validation_requires_complete_pkce_query() {
        let valid = valid_google_pkce_url();
        for required in [
            "client_id",
            "response_type",
            "redirect_uri",
            "code_challenge",
            "code_challenge_method",
            "state",
            "scope",
        ] {
            let mut url = reqwest::Url::parse(&valid).unwrap();
            let retained = url
                .query_pairs()
                .filter(|(name, _)| name != required)
                .map(|(name, value)| (name.into_owned(), value.into_owned()))
                .collect::<Vec<_>>();
            url.query_pairs_mut().clear().extend_pairs(retained);
            assert!(
                validate_auth_url(url.as_str()).is_err(),
                "missing {required}"
            );
        }
    }

    #[test]
    fn failed_auth_browser_launch_cancels_the_daemon_operation() {
        let mut cancelled = None;
        let result = finish_account_browser_launch(
            serde_json::json!({
                "operationID": "operation-1",
                "authorizationURL": valid_google_pkce_url(),
                "expiresAt": "2026-07-11T22:00:00Z"
            }),
            |_| Err("auth_url_open_failed".to_string()),
            |operation_id| {
                cancelled = Some(operation_id.to_string());
                Ok(())
            },
            || panic!("successful cancellation must not query auth status"),
        );

        assert_eq!(result.unwrap_err(), "auth_url_open_failed");
        assert_eq!(cancelled.as_deref(), Some("operation-1"));
    }

    #[test]
    fn failed_auth_browser_launch_preserves_operation_when_cancel_fails() {
        let result = finish_account_browser_launch(
            serde_json::json!({
                "operationID": "operation-1",
                "authorizationURL": valid_google_pkce_url(),
                "expiresAt": "2026-07-11T22:00:00Z"
            }),
            |_| Err("auth_url_open_failed".to_string()),
            |operation_id| {
                assert_eq!(operation_id, "operation-1");
                Err("daemon_unavailable".to_string())
            },
            || {
                Ok(serde_json::json!({
                    "state": "authorizing",
                    "authorizationOperationID": "operation-1",
                    "authorizationExpiresAt": "2026-07-11T22:05:00Z"
                }))
            },
        )
        .unwrap();

        assert_eq!(result["operationID"], "operation-1");
        assert_eq!(result["expiresAt"], "2026-07-11T22:05:00Z");
        assert_eq!(result["nativeBrowserLaunchFailed"], true);
        assert_eq!(result["cancelRetryRequired"], true);
        assert_eq!(result["cancelStatusVerified"], true);
        assert!(result.get("authorizationURL").is_none());
    }

    #[test]
    fn successful_auth_browser_launch_does_not_return_the_url_to_the_renderer() {
        let mut launched = None;
        let result = finish_account_browser_launch(
            serde_json::json!({
                "operationID": "operation-1",
                "authorizationURL": valid_google_pkce_url(),
                "expiresAt": "2026-07-11T22:00:00Z"
            }),
            |url| {
                launched = Some(url);
                Ok(())
            },
            |_| panic!("successful launch must not cancel"),
            || panic!("successful launch must not query auth status"),
        )
        .unwrap();

        assert!(launched.is_some());
        assert!(result.get("authorizationURL").is_none());
        assert_eq!(
            result
                .get("operationID")
                .and_then(serde_json::Value::as_str),
            Some("operation-1")
        );
    }

    #[test]
    fn trusted_cli_candidates_are_fixed_absolute_package_paths() {
        let source = include_str!("lib.rs");
        assert!(source.contains("/usr/bin/openburnbar-cli"));
        assert!(source.contains("/usr/local/bin/openburnbar-cli"));
        assert!(source.contains("/opt/openburnbar/bin/openburnbar-cli"));
        assert!(!source.contains("Command::new(\"openburnbar-cli\")"));
    }

    #[test]
    fn smarthub_cli_operations_are_fixed_and_allowlisted() {
        assert_eq!(
            smart_hub_cli_args("discover").unwrap(),
            &["devices", "discover", "smarthub", "--json"]
        );
        assert_eq!(
            smart_hub_cli_args("status").unwrap(),
            &["devices", "iot", "smarthub", "status", "--json"]
        );
        assert_eq!(
            smart_hub_cli_args("cast_status").unwrap(),
            &["devices", "iot", "cast", "status", "--json"]
        );
        assert_eq!(
            smart_hub_cli_args("homeassistant_status").unwrap(),
            &["devices", "iot", "homeassistant", "status", "--json"]
        );
        assert_eq!(
            smart_hub_cli_args("parity").unwrap(),
            &["devices", "parity", "--json"]
        );
        for rejected in [
            "",
            "list",
            "status --json",
            "../../bin/evil",
            "status\n--json",
        ] {
            assert_eq!(
                smart_hub_cli_args(rejected).unwrap_err(),
                "smarthub_operation_not_allowlisted",
                "unexpectedly accepted {rejected:?}"
            );
        }
    }

    #[test]
    fn computer_use_panic_shortcuts_parse() {
        assert!(tauri_plugin_global_shortcut::Builder::<tauri::Wry>::new()
            .with_shortcuts(COMPUTER_USE_PANIC_SHORTCUTS)
            .is_ok());
    }

    fn computer_use_local_auth_fixture() -> (
        ComputerUseLocalAuthProof,
        ComputerUseLocalAuthGrantBinding,
        f64,
    ) {
        let binding = ComputerUseLocalAuthGrantBinding {
            request_id: "request-1".into(),
            runtime: "hermes".into(),
            thread_id: "thread-1".into(),
            preset: "desktop".into(),
            capabilities: vec![
                "workspace_read".into(),
                "desktop_file_export".into(),
                "desktop_browser".into(),
            ],
            trust_mode: "manual".into(),
            delivery_mode: "live_then_queued".into(),
            requested_at: 800_000_000.123,
            expires_at: 800_000_300.123,
            grant_duration_seconds: 1800.0,
            source_device_id: "android-device-1".into(),
            client_intent_id: "intent-1".into(),
            local_authentication_satisfied: true,
        };
        let intent_hash = canonical_local_auth_binding_hash_hex(&binding).unwrap();
        let proof = ComputerUseLocalAuthProof {
            proof_id: "proof-1".into(),
            device_id: "android-device-1".into(),
            signed_intent_hash: intent_hash,
            authenticated_at: 800_000_000.123,
            expires_at: 800_000_300.123,
            signature_ed25519: "AA==".into(),
        };
        (proof, binding, 800_000_050.123)
    }

    fn computer_use_session_start_fixture() -> (ComputerUseSessionStartParams, f64) {
        let (proof, binding, now) = computer_use_local_auth_fixture();
        let mut params = ComputerUseSessionStartParams {
            mode: "browser".into(),
            trust_mode: "manual".into(),
            scope_rule_ids: vec!["https://example.com/*".into()],
            phone_viewer_node_id: Some("android-device-1".into()),
            mac_host_node_id: None,
            action_cap: Some(50),
            session_timeout_seconds: Some(1800),
            client_id: Some("linux-shell".into()),
            run_id: Some("run-1".into()),
            run_call_id: Some("call-1".into()),
            run_generation: Some(7),
            desktop_owner_authorization_request: Some(
                ComputerUseDesktopOwnerAuthorizationRequest {
                    method: "linux_desktop_owner".into(),
                },
            ),
            local_auth_proof: Some(proof),
            source_device_id: Some("android-device-1".into()),
            intent_hash_hex: None,
            local_auth_grant_binding: Some(binding),
        };
        let session_intent_id = canonical_computer_use_session_intent_id(&params).unwrap();
        let binding = params.local_auth_grant_binding.as_mut().unwrap();
        binding.client_intent_id = session_intent_id;
        let intent_hash = canonical_local_auth_binding_hash_hex(binding).unwrap();
        params.local_auth_proof.as_mut().unwrap().signed_intent_hash = intent_hash;
        (params, now)
    }

    fn computer_use_invoke_fixture() -> (ComputerUseInvokeParams, f64) {
        let (proof, binding, now) = computer_use_local_auth_fixture();
        (
            ComputerUseInvokeParams {
                session_id: "session-1".into(),
                invocation: ComputerUseInvocationParams {
                    call_id: "call-1".into(),
                    run_id: "run-1".into(),
                    tool: "browser_click".into(),
                    arguments: serde_json::json!({ "selector": "button[type=submit]" }),
                    requested_by: Some("linux-shell".into()),
                    requested_at: Some(800_000_050.123),
                },
                local_auth_proof: Some(proof),
                source_device_id: Some("android-device-1".into()),
                intent_hash_hex: None,
                local_auth_grant_binding: Some(binding),
            },
            now,
        )
    }

    #[test]
    fn computer_use_invoke_renderer_shape_uses_lower_camel_ids() {
        let params: ComputerUseInvokeParams = serde_json::from_value(serde_json::json!({
            "sessionId": "session-1",
            "invocation": {
                "callId": "call-1",
                "runId": "run-1",
                "tool": "browser_screenshot",
                "arguments": {},
                "requestedBy": "linux-shell",
                "requestedAt": 800000050.123
            }
        }))
        .expect("Tauri renderer request must use lower-camel serde keys");
        assert_eq!(params.session_id, "session-1");
        assert_eq!(params.invocation.call_id, "call-1");
        assert_eq!(params.invocation.run_id, "run-1");
        assert!(
            serde_json::from_value::<ComputerUseInvokeParams>(serde_json::json!({
                "sessionId": "session-1",
                "invocation": {
                    "callID": "call-1",
                    "runID": "run-1",
                    "tool": "browser_screenshot",
                    "arguments": {}
                }
            }))
            .is_err()
        );
    }

    #[test]
    fn computer_use_local_auth_canonical_hash_matches_android_and_swift_golden() {
        let (_, mut binding, _) = computer_use_local_auth_fixture();
        binding.capabilities = vec!["workspace_read".into(), "desktop_file_export".into()];
        assert_eq!(
            canonical_local_auth_binding_hash_hex(&binding).unwrap(),
            "9a394d7c9670840210f85747d42ef54eb5025fe38c9e4d9528837b4c875c922e"
        );
        let (params, _) = computer_use_session_start_fixture();
        assert_eq!(
            canonical_computer_use_session_intent_id(&params).unwrap(),
            "555334e1ee5f0855971b88ab018bb32a1b10bfe269579986c93aa4524a0fd566"
        );
    }

    #[test]
    fn computer_use_start_emits_complete_phone_signed_local_auth_wire_fields() {
        let (params, now) = computer_use_session_start_fixture();
        let payload = computer_use_session_start_wire(params, true, now).unwrap();
        let expected_hash = payload["localAuthProof"]["signedIntentHash"]
            .as_str()
            .unwrap()
            .to_string();

        assert_eq!(payload["runID"], "run-1");
        assert_eq!(payload["runCallID"], "call-1");
        assert_eq!(payload["runGeneration"], 7);
        assert_eq!(
            payload["desktopOwnerAuthorizationRequest"]["method"],
            "linux_desktop_owner"
        );
        assert_eq!(payload["sourceDeviceId"], "android-device-1");
        assert_eq!(payload["localAuthProof"]["proofId"], "proof-1");
        assert_eq!(payload["intentHashHex"], expected_hash);
        assert_eq!(
            payload["localAuthGrantBinding"]["capabilities"],
            serde_json::json!(["workspace_read", "desktop_file_export", "desktop_browser"])
        );
        assert_eq!(
            payload["localAuthGrantBinding"]["localAuthenticationSatisfied"],
            true
        );
        assert!(payload.get("local_auth_proof").is_none());
    }

    #[test]
    fn computer_use_broker_request_rejects_renderer_authority_material() {
        let safe = serde_json::json!({
            "mode": "browser",
            "trustMode": "step",
            "clientId": "linux-shell",
            "runId": "run-1",
            "runCallId": "call-1",
            "runGeneration": 7,
            "desktopOwnerAuthorizationRequest": { "method": "linux_desktop_owner" }
        });
        let request: ComputerUseBrokerSessionStartRequest =
            serde_json::from_value(safe.clone()).unwrap();
        validate_computer_use_broker_request(&request).unwrap();

        for forbidden in [
            "grantChallengeId",
            "challengeId",
            "sessionIntentId",
            "localAuthProof",
            "signatureEd25519",
            "password",
            "localAuthenticationSatisfied",
            "authorized",
        ] {
            let mut poisoned = safe.clone();
            poisoned[forbidden] = serde_json::json!(true);
            assert!(
                serde_json::from_value::<ComputerUseBrokerSessionStartRequest>(poisoned).is_err()
            );
        }

        let mut forged_owner = safe;
        forged_owner["desktopOwnerAuthorizationRequest"]["localAuthenticationSatisfied"] =
            serde_json::json!(true);
        assert!(
            serde_json::from_value::<ComputerUseBrokerSessionStartRequest>(forged_owner).is_err()
        );
    }

    #[test]
    fn computer_use_broker_is_typed_and_interactive_timeout_is_safe() {
        let broker = DaemonComputerUseSessionBroker;
        assert!(CU_INTERACTIVE_AUTH_RPC_TIMEOUT > Duration::from_secs(120));
        assert!(CU_INTERACTIVE_AUTH_RPC_TIMEOUT > CU_BROKER_RPC_TIMEOUT);
        assert_eq!(
            broker.rpc_contract(),
            ComputerUseSessionBrokerRPCContract {
                readiness_method: "daemon.computer_use.session_grant.readiness",
                acquire_method: "daemon.computer_use.session_grant.acquire",
                status_method: "daemon.computer_use.session_grant.status",
                session_start_method: "daemon.computer_use.session.start",
                session_status_method: "daemon.computer_use.approval.pending"
            }
        );

        let encoded = [
            ComputerUseSessionAuthorityState::Available,
            ComputerUseSessionAuthorityState::WaitingPhone,
            ComputerUseSessionAuthorityState::WaitingLocalOwner,
            ComputerUseSessionAuthorityState::Authorized,
            ComputerUseSessionAuthorityState::Expired,
            ComputerUseSessionAuthorityState::Rejected,
            ComputerUseSessionAuthorityState::Unavailable,
        ]
        .into_iter()
        .map(|state| serde_json::to_value(state).unwrap())
        .collect::<Vec<_>>();
        assert_eq!(
            encoded,
            serde_json::json!([
                "available",
                "waiting_phone",
                "waiting_local_owner",
                "authorized",
                "expired",
                "rejected",
                "unavailable"
            ])
            .as_array()
            .unwrap()
            .clone()
        );
    }

    #[test]
    fn computer_use_broker_keeps_challenge_native_and_starts_once_when_ready() {
        let _guard = computer_use_broker_test_guard();
        let calls = Mutex::new(Vec::<(String, serde_json::Value, Duration)>::new());
        let request = computer_use_broker_request_fixture();
        let acquired =
            computer_use_broker_acquire_with(request.clone(), |method, params, timeout| {
                calls
                    .lock()
                    .unwrap()
                    .push((method.to_string(), params, timeout));
                Ok(computer_use_grant_status_fixture("awaiting_phone"))
            });
        assert_eq!(
            acquired.state,
            ComputerUseSessionAuthorityState::WaitingPhone
        );
        let renderer_status = serde_json::to_value(&acquired).unwrap().to_string();
        assert!(!renderer_status.contains("challenge-opaque-1"));
        assert!(!renderer_status.contains("sessionIntentId"));

        let authorized = computer_use_broker_status_with(|method, params, timeout| {
            calls
                .lock()
                .unwrap()
                .push((method.to_string(), params, timeout));
            match method {
                "daemon.computer_use.session_grant.status" => {
                    Ok(computer_use_grant_status_fixture("ready"))
                }
                "daemon.computer_use.session.start" => Ok(serde_json::json!({
                    "sessionId": "session-1",
                    "manifestHashHex": "b".repeat(64),
                    "startedAt": 800_000_100.0,
                    "entitlementProductId": "openburnbar.computer-use",
                    "actionCap": 50
                })),
                other => panic!("unexpected broker method: {other}"),
            }
        });
        assert_eq!(
            authorized.state,
            ComputerUseSessionAuthorityState::Authorized
        );
        assert_eq!(authorized.session_id.as_deref(), Some("session-1"));

        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 3);
        assert_eq!(calls[0].0, "daemon.computer_use.session_grant.acquire");
        assert_eq!(calls[0].2, CU_BROKER_RPC_TIMEOUT);
        assert_eq!(calls[0].1.as_object().unwrap().len(), 1);
        assert!(calls[0].1.get("runtime").is_none());
        assert!(calls[0].1.get("threadId").is_none());
        assert!(calls[0].1.get("preset").is_none());
        assert!(calls[0].1.get("capabilities").is_none());
        assert_eq!(calls[1].0, "daemon.computer_use.session_grant.status");
        assert_eq!(calls[1].2, CU_BROKER_RPC_TIMEOUT);
        assert_eq!(calls[2].0, "daemon.computer_use.session.start");
        assert_eq!(calls[2].2, CU_INTERACTIVE_AUTH_RPC_TIMEOUT);
        assert_eq!(
            calls[0].1["sessionRequest"]["grantChallengeId"],
            serde_json::Value::Null
        );
        assert_eq!(calls[2].1["grantChallengeId"], "challenge-opaque-1");
        for (_, payload, _) in calls.iter() {
            let encoded = payload.to_string();
            assert!(!encoded.contains("localAuthProof"));
            assert!(!encoded.contains("signatureEd25519"));
            assert!(!encoded.contains("password"));
            assert!(!encoded.contains("localAuthenticationSatisfied"));
        }

        let stable = computer_use_broker_status_with(|method, params, timeout| {
            assert_eq!(method, "daemon.computer_use.approval.pending");
            assert_eq!(params, serde_json::json!({ "sessionId": "session-1" }));
            assert_eq!(timeout, CU_BROKER_RPC_TIMEOUT);
            Ok(serde_json::json!({ "requests": [], "sessionActive": true }))
        });
        assert_eq!(stable.state, ComputerUseSessionAuthorityState::Authorized);

        let ended = computer_use_broker_status_with(|_, _, _| {
            Ok(serde_json::json!({ "requests": [], "sessionActive": false }))
        });
        assert_eq!(ended.state, ComputerUseSessionAuthorityState::Expired);
        assert!(ended.session_id.is_none());
    }

    #[test]
    fn computer_use_broker_concurrent_status_polls_claim_session_start_once() {
        use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
        use std::sync::{Arc, Barrier};

        let _guard = computer_use_broker_test_guard();
        let request = computer_use_broker_request_fixture();
        let acquired = computer_use_broker_acquire_with(request, |_, _, _| {
            Ok(computer_use_grant_status_fixture("awaiting_phone"))
        });
        assert_eq!(
            acquired.state,
            ComputerUseSessionAuthorityState::WaitingPhone
        );

        let status_barrier = Arc::new(Barrier::new(2));
        let start_count = Arc::new(AtomicUsize::new(0));
        let mut polls = Vec::new();
        for _ in 0..2 {
            let status_barrier = Arc::clone(&status_barrier);
            let start_count = Arc::clone(&start_count);
            polls.push(thread::spawn(move || {
                computer_use_broker_status_with(|method, _, _| match method {
                    "daemon.computer_use.session_grant.status" => {
                        status_barrier.wait();
                        Ok(computer_use_grant_status_fixture("ready"))
                    }
                    "daemon.computer_use.session.start" => {
                        start_count.fetch_add(1, AtomicOrdering::SeqCst);
                        thread::sleep(Duration::from_millis(50));
                        Ok(serde_json::json!({
                            "sessionId": "session-concurrent",
                            "manifestHashHex": "b".repeat(64),
                            "startedAt": 800_000_100.0,
                            "entitlementProductId": "openburnbar.computer-use",
                            "actionCap": 50
                        }))
                    }
                    other => panic!("unexpected broker method: {other}"),
                })
            }));
        }

        let statuses = polls
            .into_iter()
            .map(|poll| poll.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(start_count.load(AtomicOrdering::SeqCst), 1);
        assert!(statuses
            .iter()
            .any(|status| { status.state == ComputerUseSessionAuthorityState::Authorized }));
        assert!(statuses
            .iter()
            .any(|status| { status.state == ComputerUseSessionAuthorityState::WaitingLocalOwner }));
    }

    #[test]
    fn computer_use_broker_fails_closed_on_malformed_or_mismatched_status() {
        let _guard = computer_use_broker_test_guard();
        let idle = computer_use_broker_status_with(|method, params, timeout| {
            assert_eq!(method, "daemon.computer_use.session_grant.readiness");
            assert_eq!(params, serde_json::json!({}));
            assert_eq!(timeout, CU_BROKER_RPC_TIMEOUT);
            Ok(serde_json::json!({ "available": true, "reason": "ready" }))
        });
        assert_eq!(idle.state, ComputerUseSessionAuthorityState::Available);
        assert!(idle.session_id.is_none());

        let unavailable = computer_use_broker_status_with(|_, _, _| {
            Ok(serde_json::json!({
                "available": false,
                "reason": "transport_unavailable"
            }))
        });
        assert_eq!(
            unavailable.state,
            ComputerUseSessionAuthorityState::Unavailable
        );

        let request = computer_use_broker_request_fixture();
        let absent = computer_use_broker_acquire_with(request.clone(), |_, _, _| {
            Err("empty daemon response".into())
        });
        assert_eq!(absent.state, ComputerUseSessionAuthorityState::Unavailable);

        *computer_use_broker_flow().lock().unwrap() = None;
        let malformed = computer_use_broker_acquire_with(request.clone(), |_, _, _| {
            Ok(serde_json::json!({ "state": "awaiting_phone" }))
        });
        assert_eq!(
            malformed.state,
            ComputerUseSessionAuthorityState::Unavailable
        );

        *computer_use_broker_flow().lock().unwrap() = None;
        let acquired = computer_use_broker_acquire_with(request, |_, _, _| {
            Ok(computer_use_grant_status_fixture("awaiting_phone"))
        });
        assert_eq!(
            acquired.state,
            ComputerUseSessionAuthorityState::WaitingPhone
        );
        let mismatched = computer_use_broker_status_with(|_, _, _| {
            let mut status = computer_use_grant_status_fixture("ready");
            status["challengeId"] = serde_json::json!("different-challenge");
            Ok(status)
        });
        assert_eq!(
            mismatched.state,
            ComputerUseSessionAuthorityState::Unavailable
        );
        assert!(mismatched.session_id.is_none());
    }

    #[test]
    fn computer_use_release_browser_start_requires_owner_authorization_request() {
        let (mut params, now) = computer_use_session_start_fixture();
        params.desktop_owner_authorization_request = None;
        assert!(computer_use_session_start_wire(params, true, now)
            .unwrap_err()
            .contains("requires linux_desktop_owner"));
    }

    #[test]
    fn computer_use_owner_authorization_method_is_part_of_the_session_intent() {
        let (params, _) = computer_use_session_start_fixture();
        let owner_bound = canonical_computer_use_session_intent_id(&params).unwrap();

        let mut missing = params.clone();
        missing.desktop_owner_authorization_request = None;
        assert_ne!(
            canonical_computer_use_session_intent_id(&missing).unwrap(),
            owner_bound
        );

        let mut retargeted = params;
        retargeted
            .desktop_owner_authorization_request
            .as_mut()
            .unwrap()
            .method = "other_owner_method".into();
        assert_ne!(
            canonical_computer_use_session_intent_id(&retargeted).unwrap(),
            owner_bound
        );
    }

    #[test]
    fn computer_use_invoke_emits_the_verified_session_grant_transport() {
        let (params, now) = computer_use_invoke_fixture();
        let payload = computer_use_invoke_wire(params, true, now).unwrap();

        assert_eq!(payload["sessionId"], "session-1");
        assert_eq!(payload["invocation"]["callID"], "call-1");
        assert_eq!(payload["localAuthProof"]["deviceId"], "android-device-1");
        assert_eq!(payload["sourceDeviceId"], "android-device-1");
        assert_eq!(payload["localAuthGrantBinding"]["requestId"], "request-1");
    }

    #[test]
    fn computer_use_release_transport_fails_closed_without_a_proof() {
        let (mut start, now) = computer_use_session_start_fixture();
        start.local_auth_proof = None;
        start.source_device_id = None;
        start.local_auth_grant_binding = None;
        assert!(computer_use_session_start_wire(start, true, now)
            .unwrap_err()
            .contains("requires a fresh phone-signed local-auth proof"));

        let (mut invoke, now) = computer_use_invoke_fixture();
        invoke.local_auth_proof = None;
        invoke.source_device_id = None;
        invoke.local_auth_grant_binding = None;
        assert!(computer_use_invoke_wire(invoke, true, now)
            .unwrap_err()
            .contains("requires a fresh phone-signed local-auth proof"));
    }

    #[test]
    fn computer_use_filtered_pending_response_requires_authoritative_session_state() {
        let active = serde_json::json!({ "requests": [], "sessionActive": true });
        let inactive = serde_json::json!({ "requests": [], "sessionActive": false });
        let legacy = serde_json::json!({ "requests": [] });

        assert_eq!(
            validate_computer_use_approval_pending_response(active.clone(), true).unwrap(),
            active
        );
        assert_eq!(
            validate_computer_use_approval_pending_response(inactive.clone(), true).unwrap(),
            inactive
        );
        assert!(
            validate_computer_use_approval_pending_response(legacy.clone(), true)
                .unwrap_err()
                .contains("missing authoritative sessionActive")
        );
        assert_eq!(
            validate_computer_use_approval_pending_response(legacy.clone(), false).unwrap(),
            legacy
        );
    }

    #[test]
    fn computer_use_local_auth_transport_rejects_partial_mismatched_and_expired_proofs() {
        let (mut partial, now) = computer_use_session_start_fixture();
        partial.local_auth_proof = None;
        assert!(computer_use_session_start_wire(partial, true, now)
            .unwrap_err()
            .contains("localAuthProof is missing"));

        let (mut mismatched, now) = computer_use_session_start_fixture();
        mismatched
            .local_auth_grant_binding
            .as_mut()
            .unwrap()
            .runtime = "different-runtime".into();
        assert!(computer_use_session_start_wire(mismatched, true, now)
            .unwrap_err()
            .contains("bound to a different grant"));

        let (expired, _) = computer_use_session_start_fixture();
        assert!(
            computer_use_session_start_wire(expired, true, 800_000_301.0)
                .unwrap_err()
                .contains("has expired")
        );

        let (mut under_scoped, now) = computer_use_session_start_fixture();
        let under_scoped_hash = {
            let binding = under_scoped.local_auth_grant_binding.as_mut().unwrap();
            binding.capabilities = vec!["workspace_read".into()];
            canonical_local_auth_binding_hash_hex(binding).unwrap()
        };
        under_scoped
            .local_auth_proof
            .as_mut()
            .unwrap()
            .signed_intent_hash = under_scoped_hash;
        assert!(computer_use_session_start_wire(under_scoped, true, now)
            .unwrap_err()
            .contains("does not authorize desktop_browser"));

        let (mut trust_escalation, now) = computer_use_session_start_fixture();
        trust_escalation.trust_mode = "trusted".into();
        assert!(computer_use_session_start_wire(trust_escalation, true, now)
            .unwrap_err()
            .contains("trust mode does not match"));

        let (mut retargeted, now) = computer_use_session_start_fixture();
        retargeted.run_id = Some("run-2".into());
        assert!(computer_use_session_start_wire(retargeted, true, now)
            .unwrap_err()
            .contains("bound to a different session intent"));

        let (mut stale_generation, now) = computer_use_session_start_fixture();
        stale_generation.run_generation = Some(8);
        assert!(computer_use_session_start_wire(stale_generation, true, now)
            .unwrap_err()
            .contains("bound to a different session intent"));

        let (mut stale_call, now) = computer_use_session_start_fixture();
        stale_call.run_call_id = Some("replacement-call".into());
        assert!(computer_use_session_start_wire(stale_call, true, now)
            .unwrap_err()
            .contains("bound to a different session intent"));
    }

    #[test]
    fn onboarding_rpc_wire_names_match_the_swift_contract() {
        assert_eq!(
            DAEMON_ONBOARDING_SNAPSHOT_METHOD,
            "daemon.onboarding.snapshot"
        );
        assert_eq!(DAEMON_ONBOARDING_ACTION_METHOD, "daemon.onboarding.action");
        assert_eq!(DAEMON_ONBOARDING_RESET_METHOD, "daemon.onboarding.reset");
    }

    #[test]
    fn subscription_rpc_wire_names_match_the_swift_contract() {
        assert_eq!(DAEMON_SUBSCRIPTION_START_METHOD, "subscription.start");
        assert_eq!(DAEMON_SUBSCRIPTION_RESUME_METHOD, "subscription.resume");
        assert_eq!(DAEMON_SUBSCRIPTION_STOP_METHOD, "subscription.stop");
    }

    #[test]
    fn runtime_capability_catalog_has_unique_ids_and_known_evaluators() {
        let catalog: RuntimeCapabilityCatalog =
            serde_json::from_str(RUNTIME_CAPABILITY_CATALOG).unwrap();
        assert_eq!(catalog.schema_version, 1);
        let mut ids = std::collections::HashSet::new();
        for capability in catalog.capabilities {
            assert!(ids.insert(capability.id));
            assert!(matches!(
                capability.evaluator.as_str(),
                "always"
                    | "daemon"
                    | "gateway"
                    | "media"
                    | "trusted-cli"
                    | "secret-service"
                    | "kwallet"
                    | "portal"
                    | "tray"
                    | "x11-overlay"
                    | "unavailable"
            ));
        }
        assert!(ids.len() >= 20);
    }

    #[test]
    fn mercury_runtime_capability_follows_daemon_probe() {
        let definition = RuntimeCapabilityDefinition {
            id: "media.mercury".to_string(),
            domain: "platform".to_string(),
            evaluator: "media".to_string(),
            unavailable_reason: "Mercury is unavailable.".to_string(),
            substitute: None,
        };
        let available = RuntimeMediaCapability {
            available: true,
            codecs_known: true,
            source: "daemon-media-probe".to_string(),
            detail: Some("VP9 is available.".to_string()),
        };
        let entry = evaluate_runtime_capability(
            definition,
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            Some(&available),
        )
        .unwrap();
        assert_eq!(entry.state, "available");
        assert_eq!(entry.source, "daemon-media-probe");
        assert_eq!(entry.reason, "VP9 is available.");
    }

    #[test]
    fn mercury_runtime_capability_is_degraded_without_confirmed_codecs() {
        let definition = RuntimeCapabilityDefinition {
            id: "media.mercury".to_string(),
            domain: "platform".to_string(),
            evaluator: "media".to_string(),
            unavailable_reason: "Mercury is unavailable.".to_string(),
            substitute: None,
        };
        let degraded = RuntimeMediaCapability {
            available: true,
            codecs_known: false,
            source: "daemon-media-probe".to_string(),
            detail: None,
        };
        let entry = evaluate_runtime_capability(
            definition,
            &DaemonHealth::default(),
            Some("x11"),
            true,
            Some(&degraded),
        )
        .unwrap();
        assert_eq!(entry.state, "degraded");
        assert!(entry.reason.contains("capture codec support"));
    }

    #[test]
    fn mercury_runtime_capability_fails_closed_without_an_available_probe() {
        let definition = || RuntimeCapabilityDefinition {
            id: "media.mercury".to_string(),
            domain: "platform".to_string(),
            evaluator: "media".to_string(),
            unavailable_reason: "Mercury is unavailable.".to_string(),
            substitute: None,
        };
        let unavailable = RuntimeMediaCapability {
            available: false,
            codecs_known: true,
            source: "daemon-media-probe".to_string(),
            detail: Some("Media socket is unavailable.".to_string()),
        };

        let explicit = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            Some(&unavailable),
        )
        .unwrap();
        assert_eq!(explicit.state, "unavailable");
        assert_eq!(explicit.reason, "Media socket is unavailable.");

        let missing = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
        )
        .unwrap();
        assert_eq!(missing.state, "unavailable");
        assert_eq!(missing.reason, "Mercury is unavailable.");
    }
    #[test]
    fn computer_use_approval_release_wire_requires_signed_phone_authority() {
        let result = computer_use_approval_respond_wire(
            ComputerUseApprovalRespondParams {
                session_id: Some("session-1".into()),
                approval_id: "approval-1".into(),
                decision: "approve".into(),
                responded_by: Some("linux-shell".into()),
                responded_at: None,
                note: None,
                request_hash_blake3: None,
                authority: None,
            },
            true,
            800_000_000.0,
        );
        assert!(result.unwrap_err().contains("requestHashBlake3"));
    }

    #[test]
    fn computer_use_approval_wire_preserves_signed_authority_fields() {
        let hash = "a".repeat(64);
        let payload = computer_use_approval_respond_wire(
            ComputerUseApprovalRespondParams {
                session_id: Some("session-1".into()),
                approval_id: "approval-1".into(),
                decision: "approve".into(),
                responded_by: Some("android-phone-1".into()),
                responded_at: Some(800_000_000.0),
                note: Some("approved".into()),
                request_hash_blake3: Some(hash.clone()),
                authority: Some(ComputerUseApprovalAuthority {
                    peer_node_id: "android-phone-1".into(),
                    counter: 42,
                    timestamp: 800_000_000.0,
                    intent_hash_blake3: hash.clone(),
                    signature_ed25519: "AA==".into(),
                    attestation_hash_blake3: None,
                    key_kind: Some("ed25519".into()),
                }),
            },
            true,
            800_000_000.0,
        )
        .unwrap();

        assert_eq!(payload["sessionId"], "session-1");
        assert_eq!(payload["response"]["requestHashBlake3"], hash);
        assert_eq!(payload["response"]["authority"]["counter"], 42);
        assert_eq!(
            payload["response"]["authority"]["peerNodeId"],
            "android-phone-1"
        );
        assert_eq!(payload["response"]["respondedAt"], 800_000_000.0);
    }

    #[test]
    fn tray_usage_text_accepts_array_and_envelope_shapes() {
        let rows = serde_json::json!([
            {"tokens": 1_250, "costUsd": 0.11},
            {"totalTokens": 2_750, "estimatedCostUsd": 0.24}
        ]);
        assert_eq!(tray_usage_text(&rows), "Recent usage: 4.0K tokens - $0.35");

        let envelope = serde_json::json!({"events": [{"tokenCount": 12, "cost": 0.03}]});
        assert_eq!(
            tray_usage_text(&envelope),
            "Recent usage: 12 tokens - $0.03"
        );
        assert_eq!(
            tray_usage_text(&serde_json::json!({"error": "offline"})),
            "Usage: unavailable"
        );
    }

    #[test]
    fn tray_update_text_is_honest_for_each_feed_state() {
        let mut status = update_feed::LinuxUpdateStatus {
            state: "unavailable".into(),
            current_version: "0.1.0".into(),
            latest_version: None,
            channel: None,
            published_at: None,
            notes: None,
            artifact: None,
            instructions: None,
            package_channel: None,
            channel_info: None,
            signature_state: "unknown".into(),
            feed_freshness: "unknown".into(),
            feed_age_seconds: None,
            checked_at_unix_seconds: 0,
            compatibility: None,
            reason: Some("offline".into()),
        };
        assert_eq!(tray_update_text(&status), "Updates: feed unavailable");

        status.state = "current".into();
        assert_eq!(tray_update_text(&status), "Updates: up to date");

        status.state = "available".into();
        status.latest_version = Some("0.2.0".into());
        assert_eq!(tray_update_text(&status), "Update available: 0.2.0");
    }

    #[test]
    fn deep_link_decoder_allows_registered_routes_only() {
        assert_eq!(
            validated_deep_link_route("openburnbar://dashboard"),
            Some("overview")
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://membership/success"),
            Some("account")
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://route/chat"),
            Some("chat")
        );
        assert_eq!(validated_deep_link_route("https://example.com/chat"), None);
        assert_eq!(
            validated_deep_link_route("openburnbar://chat?prompt=secret"),
            None
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://chat#fragment"),
            None
        );
        assert_eq!(validated_deep_link_route("openburnbar://unknown"), None);
    }

    #[test]
    fn database_code_bounds_reject_blank_queries_and_clamp_reads() {
        assert!(bounded_code_query("   ".to_string()).is_err());
        assert_eq!(
            bounded_code_query("  symbol  ".to_string()).unwrap(),
            "symbol"
        );
        assert_eq!(
            bounded_code_query("a".repeat(600)).unwrap().chars().count(),
            512
        );
        assert_eq!(bounded_code_limit(Some(0), 20), 1);
        assert_eq!(bounded_code_limit(Some(999), 20), 50);
        assert_eq!(bounded_code_limit(None, 10), 10);
        assert_eq!(bounded_context_bytes(Some(999_999)), 24_000);
        assert_eq!(bounded_context_bytes(Some(1)), 1_024);
    }

    #[test]
    fn database_recovery_bundle_inputs_are_bounded_and_native_only() {
        assert_eq!(bounded_recovery_path("/tmp/recovery.obb".to_string()).unwrap(), "/tmp/recovery.obb");
        assert!(bounded_recovery_path("relative.obb".to_string()).is_err());
        assert!(bounded_recovery_path("/tmp/recovery\n.obb".to_string()).is_err());
        assert!(bounded_recovery_passphrase("correct horse battery staple".to_string()).is_ok());
        assert!(bounded_recovery_passphrase("   ".to_string()).is_err());
        assert!(bounded_recovery_passphrase("a\0b".to_string()).is_err());
        assert!(bounded_recovery_passphrase("x".repeat(4_097)).is_err());
    }
}
