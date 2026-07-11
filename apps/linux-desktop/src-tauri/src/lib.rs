use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;
use tauri::ipc::Channel;
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_global_shortcut::{Code, Modifiers, ShortcutState};
use tauri_plugin_shell::ShellExt;

mod desktop_notifications;
mod media;
mod native_shell;
mod update_feed;

use desktop_notifications::{native_notification_capabilities, native_notification_show};
use native_shell::{
    build_tray, handle_secondary_launch, native_shell_ready, native_shell_set_login_start,
    native_shell_snapshot, native_status_close, native_status_route, native_status_show,
    native_status_snapshot, native_tray_update, LaunchIntent, NativeShellState,
};

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
        let text = String::from_utf8(bytes.to_vec()).map_err(|_| "gateway_invalid_utf8")?;
        on_event
            .send(text)
            .map_err(|_| "gateway_renderer_disconnected".to_string())?;
    }
    Ok(())
}

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
    let socket_path = linux_socket_path();
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
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

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
    if let Some(token) = read_auth_token() {
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeLinuxAppCheckStatus {
    state: String,
    trust_class: String,
    expires_at: Option<String>,
}

fn linux_app_check_expiry_is_future(value: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|expires_at| expires_at.with_timezone(&chrono::Utc) > chrono::Utc::now())
        .unwrap_or(false)
}

const RUNTIME_CAPABILITY_CATALOG: &str =
    include_str!("../../../../packaging/linux/runtime-capability-catalog.json");

fn evaluate_runtime_capability(
    definition: RuntimeCapabilityDefinition,
    health: &DaemonHealth,
    session_type: Option<&str>,
    has_session_bus: bool,
    media: Option<&RuntimeMediaCapability>,
    app_check: Option<&RuntimeLinuxAppCheckStatus>,
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
        "app-check" => match app_check {
            Some(status)
                if status.state == "ready"
                    && status.trust_class == "linux_lower_trust"
                    && status
                        .expires_at
                        .as_deref()
                        .map(linux_app_check_expiry_is_future)
                        .unwrap_or(false) => (
                "available".to_string(),
                format!(
                    "The daemon holds a current lower-trust Linux App Check token{}.",
                    status
                        .expires_at
                        .as_deref()
                        .map(|value| format!(" through {value}"))
                        .unwrap_or_default()
                ),
                "daemon-app-check-status".to_string(),
            ),
            Some(status) if status.state == "acquiring" => (
                "degraded".to_string(),
                "The daemon is acquiring a fresh Linux App Check token.".to_string(),
                "daemon-app-check-status".to_string(),
            ),
            Some(status) => (
                "blocked".to_string(),
                format!(
                    "{} Trust class remains {}.",
                    definition.unavailable_reason, status.trust_class
                ),
                "daemon-app-check-status".to_string(),
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
    let (media, app_check) = if health.ok {
        std::thread::scope(|scope| {
            let media = scope.spawn(|| {
                call_daemon_method_with_timeout(
                    "daemon.media.capability.get",
                    Some(serde_json::json!({})),
                    Duration::from_secs(2),
                )
                .ok()
                .and_then(|value| serde_json::from_value::<RuntimeMediaCapability>(value).ok())
            });
            let app_check = scope.spawn(|| {
                call_daemon_method_with_timeout(
                    "daemon.cloud.app_check.status",
                    Some(serde_json::json!({})),
                    Duration::from_secs(2),
                )
                .ok()
                .and_then(|value| serde_json::from_value::<RuntimeLinuxAppCheckStatus>(value).ok())
            });
            (
                media.join().unwrap_or(None),
                app_check.join().unwrap_or(None),
            )
        })
    } else {
        (None, None)
    };
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
                app_check.as_ref(),
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

fn serialize_runtime_capabilities(manifest: &RuntimeCapabilityManifest) -> Result<String, String> {
    serde_json::to_string(manifest)
        .map_err(|error| format!("runtime_capability_serialization_failed:{error}"))
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

fn validate_account_auth_url(raw_url: &str) -> Result<String, String> {
    if raw_url.len() > 2_048 {
        return Err("account_auth_url_too_long".to_string());
    }
    let url = reqwest::Url::parse(raw_url).map_err(|_| "account_auth_url_invalid".to_string())?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || !matches!(url.port(), None | Some(443))
        || url.host_str() != Some("burnbar.ai")
        || url.path() != "/link"
        || url.fragment().is_some()
    {
        return Err("account_auth_url_origin_refused".to_string());
    }
    let query_items = url.query_pairs().collect::<Vec<_>>();
    if query_items.len() != 2 {
        return Err("account_auth_url_query_refused".to_string());
    }
    let flows = query_items
        .iter()
        .filter_map(|(key, value)| (key == "flow").then_some(value.as_ref()))
        .collect::<Vec<_>>();
    let codes = query_items
        .iter()
        .filter_map(|(key, value)| (key == "code").then_some(value.as_ref()))
        .collect::<Vec<_>>();
    if flows.as_slice() != ["desktop_auth"]
        || codes.len() != 1
        || !is_canonical_account_user_code(codes[0])
    {
        return Err("account_auth_url_query_refused".to_string());
    }
    Ok(url.to_string())
}

fn is_canonical_account_user_code(code: &str) -> bool {
    let bytes = code.as_bytes();
    bytes.len() == 9
        && bytes[4] == b'-'
        && bytes.iter().enumerate().all(|(index, byte)| {
            index == 4
                || matches!(
                    byte,
                    b'A'..=b'H' | b'J'..=b'K' | b'M'..=b'N' | b'P'..=b'Z' | b'2'..=b'9'
                )
        })
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
fn open_account_auth_url(app: AppHandle, url: String) -> Result<(), String> {
    let validated = validate_account_auth_url(&url)?;
    // reason: tauri-plugin-shell retains this Tauri 2 API while the app keeps URL validation native.
    #[allow(deprecated)]
    app.shell()
        .open(validated, None)
        .map_err(|_| "account_auth_url_open_failed".to_string())
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

// Approved polling can perform three sequential 30-second cloud operations:
// device poll, custom-token exchange, and profile lookup. The shell timeout must
// remain outside that daemon budget so it never reports failure while the daemon
// is still completing a successful sign-in.
const ACCOUNT_RPC_TIMEOUT: Duration = Duration::from_secs(100);
const MEMBERSHIP_RPC_TIMEOUT: Duration = Duration::from_secs(100);
const PROVIDER_EXTERNAL_AUTH_RPC_TIMEOUT: Duration = Duration::from_secs(15);

async fn call_provider_external_auth_daemon_method(
    method: &'static str,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        call_daemon_method_with_timeout(method, Some(params), PROVIDER_EXTERNAL_AUTH_RPC_TIMEOUT)
    })
    .await
    .map_err(|error| format!("provider_external_auth_rpc_join_failed:{error}"))?
}

async fn call_account_daemon_method(
    method: &'static str,
    params: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        call_daemon_method_with_timeout(method, params, ACCOUNT_RPC_TIMEOUT)
    })
    .await
    .map_err(|error| format!("account_rpc_join_failed:{error}"))?
}

async fn call_membership_daemon_method(
    method: &'static str,
    params: Option<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        call_daemon_method_with_timeout(method, params, MEMBERSHIP_RPC_TIMEOUT)
    })
    .await
    .map_err(|error| format!("membership_rpc_join_failed:{error}"))?
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

fn computer_use_panic_hotkey_evidence(
    chord: &str,
    response: &Result<serde_json::Value, String>,
) -> serde_json::Value {
    match response {
        Ok(result) => {
            let session_id = result
                .get("sessionId")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let ended_at_present = result.get("endedAt").is_some_and(|value| !value.is_null());
            let audit_head_present = result
                .get("auditHeadHashHex")
                .and_then(serde_json::Value::as_str)
                .is_some();
            let passed = session_id == "*" && ended_at_present && audit_head_present;
            serde_json::json!({
                "schemaVersion": 1,
                "passed": passed,
                "daemonAccepted": passed,
                "source": "hotkey",
                "chord": chord,
                "sessionId": session_id,
                "endedAtPresent": ended_at_present,
                "auditHeadPresent": audit_head_present,
                "result": result,
            })
        }
        Err(error) => serde_json::json!({
            "schemaVersion": 1,
            "passed": false,
            "daemonAccepted": false,
            "source": "hotkey",
            "chord": chord,
            "error": error,
        }),
    }
}

fn write_computer_use_panic_hotkey_evidence(
    chord: &str,
    response: &Result<serde_json::Value, String>,
) {
    let out_dir = match std::env::var("OPENBURNBAR_EVIDENCE_OUT") {
        Ok(value) if !value.trim().is_empty() => PathBuf::from(value),
        _ => return,
    };
    if let Err(error) = fs::create_dir_all(&out_dir) {
        eprintln!("computer_use_global_panic_hotkey_evidence_failed: {error}");
        return;
    }
    let payload = computer_use_panic_hotkey_evidence(chord, response);
    let target = out_dir.join("native-global-panic-shortcut-response.json");
    let temporary = out_dir.join(".native-global-panic-shortcut-response.json.tmp");
    let serialized = match serde_json::to_vec_pretty(&payload) {
        Ok(value) => value,
        Err(error) => {
            eprintln!("computer_use_global_panic_hotkey_evidence_failed: {error}");
            return;
        }
    };
    if let Err(error) =
        fs::write(&temporary, serialized).and_then(|()| fs::rename(&temporary, &target))
    {
        let _ = fs::remove_file(&temporary);
        eprintln!("computer_use_global_panic_hotkey_evidence_failed: {error}");
    }
}

fn trigger_computer_use_panic_hotkey(chord: &'static str) {
    thread::spawn(move || {
        let response = request_computer_use_panic_halt("*".to_string(), "hotkey".to_string());
        write_computer_use_panic_hotkey_evidence(chord, &response);
        if let Err(error) = response {
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
            if shortcut.matches(meta_chord, Code::Period) {
                trigger_computer_use_panic_hotkey("Ctrl+Alt+Super+Period");
            } else if shortcut.matches(shift_chord, Code::Period) {
                trigger_computer_use_panic_hotkey("Ctrl+Alt+Shift+Period");
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
async fn provider_external_auth_status(
    provider_id: String,
    auth_method_id: Option<String>,
    flow_id: Option<String>,
) -> Result<serde_json::Value, String> {
    let (method, params) = provider_external_auth_status_wire(provider_id, auth_method_id, flow_id);
    call_provider_external_auth_daemon_method(method, params).await
}

fn provider_external_auth_status_wire(
    provider_id: String,
    auth_method_id: Option<String>,
    flow_id: Option<String>,
) -> (&'static str, serde_json::Value) {
    (
        "daemon.provider.external_auth.status",
        serde_json::json!({
            "providerID": provider_id,
            "authMethodID": auth_method_id,
            "flowID": flow_id
        }),
    )
}

#[tauri::command]
async fn provider_external_auth_start(
    provider_id: String,
    auth_method_id: String,
) -> Result<serde_json::Value, String> {
    let (method, params) = provider_external_auth_start_wire(provider_id, auth_method_id);
    call_provider_external_auth_daemon_method(method, params).await
}

fn provider_external_auth_start_wire(
    provider_id: String,
    auth_method_id: String,
) -> (&'static str, serde_json::Value) {
    (
        "daemon.provider.external_auth.start",
        serde_json::json!({
            "providerID": provider_id,
            "authMethodID": auth_method_id
        }),
    )
}

#[tauri::command]
async fn provider_external_auth_cancel(flow_id: String) -> Result<serde_json::Value, String> {
    let (method, params) = provider_external_auth_cancel_wire(flow_id);
    call_provider_external_auth_daemon_method(method, params).await
}

fn provider_external_auth_cancel_wire(flow_id: String) -> (&'static str, serde_json::Value) {
    (
        "daemon.provider.external_auth.cancel",
        serde_json::json!({ "flowID": flow_id }),
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
            "limit": 100
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

// ───────────────── P08: account status and browser authorization ─────────────────
#[tauri::command]
async fn account_status() -> Result<serde_json::Value, String> {
    call_account_daemon_method("daemon.account.status", None).await
}

#[tauri::command]
async fn account_device_auth_start() -> Result<serde_json::Value, String> {
    call_account_daemon_method("daemon.account.device_auth.start", None).await
}

#[tauri::command]
async fn account_device_auth_poll(flow_id: String) -> Result<serde_json::Value, String> {
    call_account_daemon_method(
        "daemon.account.device_auth.poll",
        Some(serde_json::json!({ "flow_id": flow_id })),
    )
    .await
}

#[tauri::command]
async fn account_device_auth_cancel(flow_id: String) -> Result<serde_json::Value, String> {
    call_account_daemon_method(
        "daemon.account.device_auth.cancel",
        Some(serde_json::json!({ "flow_id": flow_id })),
    )
    .await
}

#[tauri::command]
async fn account_sign_out() -> Result<serde_json::Value, String> {
    call_account_daemon_method("daemon.account.sign_out", None).await
}

// ───────────────── P10: membership status ─────────────────
// Proposed wire: daemon.membership.status. Older daemons reject it; the TS
// store treats unknown-method errors as capability-absent, not fatal UI spam.
#[tauri::command]
async fn membership_status() -> Result<serde_json::Value, String> {
    call_membership_daemon_method("daemon.membership.status", None).await
}

// ───────────────── P10: membership checkout URL ─────────────────
// Proposed wire: daemon.membership.checkoutUrl. Tier-C StoreKit substitute:
// the daemon mints the Stripe URL; the React layer opens it externally.
#[tauri::command]
async fn membership_checkout_url() -> Result<serde_json::Value, String> {
    call_membership_daemon_method(
        "daemon.membership.checkoutUrl",
        Some(serde_json::json!({
            "success_url": "openburnbar://membership/success",
            "cancel_url": "openburnbar://membership/cancel"
        })),
    )
    .await
}

// ───────────────── P10: membership restore ─────────────────
// Proposed wire: daemon.membership.restore. Older daemons reject it; the UI
// presents the membership capability as absent and keeps fixture mode usable.
#[tauri::command]
async fn membership_restore() -> Result<serde_json::Value, String> {
    call_membership_daemon_method("daemon.membership.restore", None).await
}

// ───────────────── P09: app version info ─────────────────
// Local: shell version from compile-time env, daemon version from health probe.
#[tauri::command]
fn app_version_info() -> Result<serde_json::Value, String> {
    let shell_version = env!("CARGO_PKG_VERSION");
    let daemon_version = probe_daemon_health()
        .daemon_version
        .unwrap_or_else(|| "unknown".to_string());
    let package_channel =
        std::env::var("OPENBURNBAR_PACKAGE_CHANNEL").unwrap_or_else(|_| "unknown".to_string());
    Ok(serde_json::json!({
        "shellVersion": shell_version,
        "daemonVersion": daemon_version,
        "packageChannel": package_channel
    }))
}

#[tauri::command]
async fn update_status() -> update_feed::LinuxUpdateStatus {
    let package_channel =
        std::env::var("OPENBURNBAR_PACKAGE_CHANNEL").unwrap_or_else(|_| "unknown".to_string());
    update_feed::check_linux_update(env!("CARGO_PKG_VERSION"), &package_channel).await
}

// ───────────────── P09: redacted diagnostics export ─────────────────
// Writes a JSON bundle to the support dir. Redaction is structural: this
// command only persists shell/health metadata — it never reads provider
// payloads, tokens, or socket auth material. File mode is 0600.
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
    let bundle = serde_json::json!({
        "exportedAt": stamp,
        "shellVersion": env!("CARGO_PKG_VERSION"),
        "daemonHealth": {
            "ok": health.ok,
            "daemonVersion": health.daemon_version,
            "protocolVersion": health.protocol_version,
            "socketPath": health.socket_path,
        },
        "included": [
            "shell version",
            "daemon health (ok, version, protocol, socket path)",
            "perf sample names and durations"
        ],
        "excluded": [
            "provider API keys and credentials",
            "socket auth tokens",
            "provider response payloads",
            "user session content"
        ]
    });
    let json = serde_json::to_string_pretty(&bundle).map_err(|e| e.to_string())?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .map_err(|e| e.to_string())?;
    file.write_all(json.as_bytes()).map_err(|e| e.to_string())?;
    Ok(serde_json::json!({ "path": path.display().to_string() }))
}

// ───────────────── P11: session env ─────────────────
// Reads XDG env vars for real pet-tier detection (not hardcoded).
#[tauri::command]
fn session_env() -> serde_json::Value {
    serde_json::json!({
        "xdg_session_type": std::env::var("XDG_SESSION_TYPE").ok(),
        "xdg_current_desktop": std::env::var("XDG_CURRENT_DESKTOP").ok(),
        "native_notification_evidence": std::env::var("OPENBURNBAR_NATIVE_NOTIFICATION_EVIDENCE")
            .map(|value| value == "1")
            .unwrap_or(false),
    })
}

// ───────────────── P12: Mercury media ─────────────────
#[tauri::command]
fn media_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.media.status", None)
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

fn computer_use_session_start_wire(
    params: ComputerUseSessionStartParams,
    require_local_auth: bool,
    now: f64,
) -> Result<serde_json::Value, String> {
    validate_cu_mode(&params.mode)?;
    validate_cu_trust_mode(&params.trust_mode)?;
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
        "runGeneration": params.run_generation
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
fn computer_use_session_start(
    params: ComputerUseSessionStartParams,
) -> Result<serde_json::Value, String> {
    let payload = computer_use_session_start_wire(
        params,
        release_computer_use_local_auth_required(),
        foundation_reference_date_seconds(),
    )?;
    call_daemon_method("daemon.computer_use.session.start", Some(payload))
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
            "--runtime-capabilities" => {
                // A fast-exit probe never initializes Tauri's tray. Mark it
                // unavailable so the captured manifest cannot claim a tray
                // capability that this process did not observe.
                TRAY_INIT_FAILED.store(true, Ordering::Relaxed);
                match evaluate_runtime_capabilities()
                    .and_then(|manifest| serialize_runtime_capabilities(&manifest))
                {
                    Ok(manifest) => {
                        println!("{manifest}");
                        std::process::exit(0);
                    }
                    Err(error) => {
                        eprintln!("{error}");
                        std::process::exit(1);
                    }
                }
            }
            "--help" | "-h" => {
                println!(
                    "OpenBurnBar Linux desktop shell\n\nUsage: openburnbar-linux-desktop [--version] [--daemon-health] [--runtime-capabilities] [--help]"
                );
                std::process::exit(0);
            }
            _ => {}
        }
    }

    // Install the process-wide tracing subscriber so the remote stack's
    // `tracing::info!/warn!` events (and Tauri/tao/wry diagnostics) actually go
    // somewhere. Placed after the `--version`/`--help` fast-exit so probe output
    // stays clean. Verbosity follows the standard `RUST_LOG` env var, defaulting
    // to `info`; `try_init` makes a double-init (or a host that already set a
    // subscriber) a no-op instead of a panic.
    init_tracing();

    let launch_intent = LaunchIntent::from_args(std::env::args());

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            handle_secondary_launch(app, args);
        }))
        .plugin(tauri_plugin_shell::init())
        .manage(NativeShellState::new(launch_intent))
        .invoke_handler(tauri::generate_handler![
            daemon_health,
            runtime_capabilities,
            gateway_probe,
            gateway_chat_stream,
            gateway_chat_cancel,
            open_external_url,
            open_account_auth_url,
            open_update_url,
            open_dashboard,
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
            native_shell_ready,
            native_shell_snapshot,
            native_shell_set_login_start,
            native_status_snapshot,
            native_status_show,
            native_status_close,
            native_status_route,
            native_notification_capabilities,
            native_notification_show,
            native_tray_update,
            usage_summary,
            provider_catalog,
            session_list,
            session_search,
            usage_insights,
            mission_list,
            mission_create,
            mission_approval_decision,
            config_snapshot,
            config_update,
            provider_credential_slot_upsert,
            provider_credential_slot_remove,
            provider_external_auth_status,
            provider_external_auth_start,
            provider_external_auth_cancel,
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
            memory_boundaries,
            memory_review_inbox,
            memory_forget,
            database_workspace_status,
            database_index_project,
            database_watch_project,
            account_status,
            account_device_auth_start,
            account_device_auth_poll,
            account_device_auth_cancel,
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
            computer_use_session_start,
            computer_use_invoke,
            computer_use_approval_pending,
            computer_use_approval_respond,
            computer_use_panic_halt,
            computer_use_audit_export,
            integrations_status
        ])
        .setup(|app| {
            if let Err(e) = build_tray(app.handle()) {
                TRAY_INIT_FAILED.store(true, Ordering::Relaxed);
                eprintln!("tray init degraded: {e}");
            }
            register_computer_use_panic_shortcuts(app.handle());
            start_media_session_poll_loop(app.handle().clone());
            media::start_media_socket_reader(app.handle().clone());
            if app.state::<NativeShellState>().background_launch() {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
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
                } else if label == "status" {
                    if let WindowEvent::CloseRequested { api, .. } = event {
                        api.prevent_close();
                        if let Some(window) = app_handle.get_webview_window("status") {
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
    fn provider_external_auth_wire_contract_is_pinned() {
        let (method, params) = provider_external_auth_status_wire(
            "openai".into(),
            Some("openai-codex-oauth".into()),
            Some("flow-1".into()),
        );
        assert_eq!(method, "daemon.provider.external_auth.status");
        assert_eq!(params["providerID"], "openai");
        assert_eq!(params["authMethodID"], "openai-codex-oauth");
        assert_eq!(params["flowID"], "flow-1");
        assert!(params.get("providerId").is_none());

        let (method, params) = provider_external_auth_start_wire(
            "anthropic".into(),
            "anthropic-claude-code-login".into(),
        );
        assert_eq!(method, "daemon.provider.external_auth.start");
        assert_eq!(params["providerID"], "anthropic");
        assert_eq!(params["authMethodID"], "anthropic-claude-code-login");

        let (method, params) = provider_external_auth_cancel_wire("flow-1".into());
        assert_eq!(method, "daemon.provider.external_auth.cancel");
        assert_eq!(params["flowID"], "flow-1");
        assert!(params.get("flowId").is_none());
        assert!(PROVIDER_EXTERNAL_AUTH_RPC_TIMEOUT >= Duration::from_secs(10));
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
    fn account_rpc_timeout_exceeds_three_daemon_network_hops() {
        assert!(ACCOUNT_RPC_TIMEOUT > Duration::from_secs(90));
        assert!(MEMBERSHIP_RPC_TIMEOUT > Duration::from_secs(90));
    }

    #[test]
    fn account_auth_url_validation_is_exact_origin_path_flow_and_code() {
        assert_eq!(
            validate_account_auth_url("https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH")
                .unwrap(),
            "https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH"
        );
        for refused in [
            "http://burnbar.ai/link?flow=desktop_auth",
            "https://www.burnbar.ai/link?flow=desktop_auth",
            "https://burnbar.ai.evil.example/link?flow=desktop_auth",
            "https://user@burnbar.ai/link?flow=desktop_auth",
            "https://burnbar.ai:444/link?flow=desktop_auth",
            "https://burnbar.ai/other?flow=desktop_auth",
            "https://burnbar.ai/link?flow=desktop_auth",
            "https://burnbar.ai/link?flow=remote_mcp",
            "https://burnbar.ai/link?flow=desktop_auth&flow=desktop_auth",
            "https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH&next=https%3A%2F%2Fexample.com",
            "https://burnbar.ai/link?flow=desktop_auth&code=ABCD-EFGH&code=JKMN-PQRS",
            "https://burnbar.ai/link?flow=desktop_auth&code=ABCI-EFGH",
            "https://burnbar.ai/link?flow=desktop_auth&code=abcd-efgh",
            "https://burnbar.ai/link?flow=desktop_auth&code=ABCDEFGH",
            "https://burnbar.ai/link?flow=desktop_auth#fragment",
            "file:///etc/passwd",
            "javascript:alert(1)",
        ] {
            assert!(validate_account_auth_url(refused).is_err(), "{refused}");
        }
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
    fn computer_use_panic_shortcuts_parse() {
        assert!(tauri_plugin_global_shortcut::Builder::<tauri::Wry>::new()
            .with_shortcuts(COMPUTER_USE_PANIC_SHORTCUTS)
            .is_ok());
    }

    #[test]
    fn computer_use_panic_hotkey_evidence_requires_daemon_wide_acceptance() {
        let accepted = computer_use_panic_hotkey_evidence(
            "Ctrl+Alt+Shift+Period",
            &Ok(serde_json::json!({
                "sessionId": "*",
                "endedAt": 1234,
                "auditHeadHashHex": ""
            })),
        );
        assert_eq!(accepted["passed"], true);
        assert_eq!(accepted["daemonAccepted"], true);
        assert_eq!(accepted["source"], "hotkey");

        for refused in [
            Ok(serde_json::json!({
                "sessionId": "one-session",
                "endedAt": 1234,
                "auditHeadHashHex": "abc"
            })),
            Ok(serde_json::json!({
                "sessionId": "*",
                "auditHeadHashHex": ""
            })),
            Err("daemon unavailable".to_string()),
        ] {
            assert_eq!(
                computer_use_panic_hotkey_evidence("Ctrl+Alt+Shift+Period", &refused)["passed"],
                false
            );
        }
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
            "76a01cfd3b2795d2dc664612b76758b5c5c46943f9e2927a5449190764dd0c1e"
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
                    | "app-check"
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
            None,
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
            None,
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
            None,
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
            None,
        )
        .unwrap();
        assert_eq!(missing.state, "unavailable");
        assert_eq!(missing.reason, "Mercury is unavailable.");
    }

    #[test]
    fn linux_app_check_runtime_capability_is_blocked_until_daemon_token_is_ready() {
        let definition = || RuntimeCapabilityDefinition {
            id: "cloud.app-check".to_string(),
            domain: "security".to_string(),
            evaluator: "app-check".to_string(),
            unavailable_reason: "Production Linux App Check attestation is not ready.".to_string(),
            substitute: None,
        };
        let unavailable = RuntimeLinuxAppCheckStatus {
            state: "unavailable".to_string(),
            trust_class: "linux_lower_trust".to_string(),
            expires_at: None,
        };
        let blocked = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
            Some(&unavailable),
        )
        .unwrap();
        assert_eq!(blocked.state, "blocked");
        assert!(blocked.reason.contains("linux_lower_trust"));

        let future_expiry = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        let ready = RuntimeLinuxAppCheckStatus {
            state: "ready".to_string(),
            trust_class: "linux_lower_trust".to_string(),
            expires_at: Some(future_expiry.clone()),
        };
        let available = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
            Some(&ready),
        )
        .unwrap();
        assert_eq!(available.state, "available");
        assert!(available.reason.contains(&future_expiry));

        for invalid in [
            RuntimeLinuxAppCheckStatus {
                state: "ready".to_string(),
                trust_class: "unverified_fixture".to_string(),
                expires_at: Some(future_expiry),
            },
            RuntimeLinuxAppCheckStatus {
                state: "ready".to_string(),
                trust_class: "linux_lower_trust".to_string(),
                expires_at: None,
            },
            RuntimeLinuxAppCheckStatus {
                state: "ready".to_string(),
                trust_class: "linux_lower_trust".to_string(),
                expires_at: Some("not-a-timestamp".to_string()),
            },
            RuntimeLinuxAppCheckStatus {
                state: "ready".to_string(),
                trust_class: "linux_lower_trust".to_string(),
                expires_at: Some("2020-01-01T00:00:00Z".to_string()),
            },
        ] {
            let blocked = evaluate_runtime_capability(
                definition(),
                &DaemonHealth::default(),
                Some("wayland"),
                true,
                None,
                Some(&invalid),
            )
            .unwrap();
            assert_eq!(blocked.state, "blocked");
        }
    }

    #[test]
    fn runtime_capability_cli_serialization_uses_the_manifest_wire_contract() {
        let manifest = RuntimeCapabilityManifest {
            schema_version: 1,
            catalog_version: "test-catalog".to_string(),
            shell_version: "1.2.3".to_string(),
            daemon_version: Some("1.2.3".to_string()),
            daemon_protocol_version: Some(2),
            session_type: Some("wayland".to_string()),
            desktop: Some("GNOME".to_string()),
            capabilities: vec![],
        };
        let encoded: serde_json::Value = serde_json::from_str(
            &serialize_runtime_capabilities(&manifest).expect("manifest should serialize"),
        )
        .expect("serialized manifest should be JSON");
        assert_eq!(encoded["schemaVersion"], 1);
        assert_eq!(encoded["catalogVersion"], "test-catalog");
        assert_eq!(encoded["shellVersion"], "1.2.3");
        assert_eq!(encoded["daemonProtocolVersion"], 2);
        assert_eq!(encoded["sessionType"], "wayland");
        assert_eq!(encoded["desktop"], "GNOME");
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
}
