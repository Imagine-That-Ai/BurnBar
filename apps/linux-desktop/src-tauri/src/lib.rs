use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_global_shortcut::{Code, Modifiers, ShortcutState};
use tauri_plugin_shell::ShellExt;

mod media;
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
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum MissionApprovalDecision { Approve, Deny }

impl MissionApprovalDecision {
    fn parse(decision: &str) -> Result<Self, String> {
        match decision {
            "approve" => Ok(Self::Approve),
            "deny" => Ok(Self::Deny),
            _ => Err("Mission approval decision must be exactly 'approve' or 'deny'.".to_string()),
        }
    }
}

fn mission_decision_wire(id: &str, decision: MissionApprovalDecision) -> (&'static str, serde_json::Value) {
    let method = match decision {
        MissionApprovalDecision::Approve => "daemon.mission.approve",
        MissionApprovalDecision::Deny => "daemon.mission.cancel",
    };
    (
        method,
        serde_json::json!({"missionID": id, "actor": "linux-shell"}),
    )
}

fn mission_pending_approval<'a>(mission_list: &'a serde_json::Value, mission_id: &str) -> Option<&'a serde_json::Value> {
    mission_list.get("pendingApprovals").or_else(|| mission_list.get("approvals"))
        .or_else(|| mission_list.get("questions")).and_then(|value| value.as_array())
        .and_then(|approvals| approvals.iter().find(|approval| {
            approval.get("missionId").or_else(|| approval.get("mission_id"))
                .and_then(|value| value.as_str()) == Some(mission_id)
        }))
}

fn mission_approval_is_high_risk(approval: &serde_json::Value) -> bool {
    approval.get("risk").or_else(|| approval.get("severity"))
        .and_then(|value| value.as_str())
        .map(|risk| risk.to_ascii_lowercase().contains("high")).unwrap_or(false)
}

#[tauri::command]
fn mission_approval_decision(id: String, decision: String) -> Result<serde_json::Value, String> {
    let id = id.trim();
    if id.is_empty() { return Err("Mission id is required for approval decisions.".to_string()); }
    let decision = MissionApprovalDecision::parse(&decision)?;
    let mission_list = mission_list()?;
    let approval = mission_pending_approval(&mission_list, id).ok_or_else(||
        "Mission approval decision rejected: no matching pending approval.".to_string())?;
    if decision == MissionApprovalDecision::Approve && mission_approval_is_high_risk(approval) {
        return Err("High-risk mission approval requires trusted-device step-up and cannot be approved from the Linux shell.".to_string());
    }
    let (method, params) = mission_decision_wire(id, decision);
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

// ───────────────── P08: account status ─────────────────
// Derived from daemon.config.get (cloud/sync subtree) — no daemon.account.* RPC.
#[tauri::command]
fn account_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.config.get", None)
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
    let package_channel = detect_linux_package_channel();
    Ok(serde_json::json!({
        "shellVersion": shell_version,
        "daemonVersion": daemon_version,
        "packageChannel": package_channel
    }))
}

#[tauri::command]
async fn update_status() -> update_feed::LinuxUpdateStatus {
    let package_channel = detect_linux_package_channel();
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

fn detect_linux_package_channel() -> String {
    if let Ok(channel) = std::env::var("OPENBURNBAR_PACKAGE_CHANNEL") {
        let channel = channel.trim().to_ascii_lowercase();
        if matches!(channel.as_str(), "appimage" | "deb" | "rpm") {
            return channel;
        }
    }
    if Command::new("dpkg-query")
        .args(["-W", "-f=${Status}", "open-burn-bar"])
        .output()
        .map(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("install ok installed")
        })
        .unwrap_or(false)
    {
        return "deb".to_string();
    }
    if Command::new("rpm")
        .args(["-q", "open-burn-bar"])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
    {
        return "rpm".to_string();
    }
    "appimage".to_string()
}

#[derive(Debug, Deserialize)]
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
    local_auth_proof: Option<serde_json::Value>,
    source_device_id: Option<String>,
    intent_hash_hex: Option<String>,
    local_auth_grant_binding: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseInvokeParams {
    session_id: String,
    /// BurnBarToolInvocation — required nested object (not flat tool/args).
    invocation: ComputerUseInvocationParams,
}

#[derive(Debug, Deserialize)]
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
    note: Option<String>,
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

#[tauri::command]
fn computer_use_session_start(
    params: ComputerUseSessionStartParams,
) -> Result<serde_json::Value, String> {
    validate_cu_mode(&params.mode)?;
    validate_cu_trust_mode(&params.trust_mode)?;
    let client_id = params
        .client_id
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    // ComputerUseSessionStartRequest — required: mode, trustMode, clientID (+ defaults).
    call_daemon_method(
        "daemon.computer_use.session.start",
        Some(serde_json::json!({
            "mode": params.mode,
            "trustMode": params.trust_mode,
            "scopeRuleIds": params.scope_rule_ids,
            "phoneViewerNodeId": params.phone_viewer_node_id,
            "macHostNodeId": params.mac_host_node_id,
            "actionCap": params.action_cap.unwrap_or(50),
            "sessionTimeoutSeconds": params.session_timeout_seconds.unwrap_or(1800),
            "clientID": client_id,
            "runID": params.run_id,
            "localAuthProof": params.local_auth_proof,
            "sourceDeviceId": params.source_device_id,
            "intentHashHex": params.intent_hash_hex,
            "localAuthGrantBinding": params.local_auth_grant_binding
        })),
    )
}

#[tauri::command]
fn computer_use_invoke(params: ComputerUseInvokeParams) -> Result<serde_json::Value, String> {
    if params.session_id.trim().is_empty() {
        return Err("computer_use_invoke requires sessionId".into());
    }
    let inv = &params.invocation;
    if inv.call_id.trim().is_empty() || inv.run_id.trim().is_empty() || inv.tool.trim().is_empty() {
        return Err("computer_use_invoke.invocation requires callID, runID, and tool".into());
    }
    cap_json_value_size(&inv.arguments, "invocation.arguments")?;
    let requested_by = inv
        .requested_by
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    let requested_at = inv
        .requested_at
        .unwrap_or_else(foundation_reference_date_seconds);
    // ComputerUseInvokeRequest { sessionId, invocation: BurnBarToolInvocation }
    call_daemon_method(
        "daemon.computer_use.invoke",
        Some(serde_json::json!({
            "sessionId": params.session_id,
            "invocation": {
                "callID": inv.call_id,
                "runID": inv.run_id,
                "tool": inv.tool,
                "arguments": inv.arguments,
                "requestedBy": requested_by,
                "requestedAt": requested_at
            }
        })),
    )
}

#[tauri::command]
fn computer_use_approval_pending(
    params: Option<ComputerUseApprovalPendingParams>,
) -> Result<serde_json::Value, String> {
    // ComputerUseApprovalPendingRequest { sessionId? } — no limit field.
    let session_id = params.and_then(|p| p.session_id);
    call_daemon_method(
        "daemon.computer_use.approval.pending",
        Some(serde_json::json!({ "sessionId": session_id })),
    )
}

#[tauri::command]
fn computer_use_approval_respond(
    params: ComputerUseApprovalRespondParams,
) -> Result<serde_json::Value, String> {
    validate_cu_approval_decision(&params.decision)?;
    if params.approval_id.trim().is_empty() {
        return Err("computer_use_approval_respond requires approvalId".into());
    }
    let responded_by = params
        .responded_by
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| CU_CLIENT_ID.to_string());
    // ComputerUseApprovalRespondRequest { sessionId?, response: HermesRealtimeRelayApprovalResponse }
    call_daemon_method(
        "daemon.computer_use.approval.respond",
        Some(serde_json::json!({
            "sessionId": params.session_id,
            "response": {
                "approvalId": params.approval_id,
                "decision": params.decision,
                "respondedBy": responded_by,
                "respondedAt": foundation_reference_date_seconds(),
                "note": params.note
            }
        })),
    )
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

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open_i = MenuItemBuilder::with_id("open", "Open dashboard").build(app)?;
    let health_i = MenuItemBuilder::with_id("health", "Reconnect daemon").build(app)?;
    let quit_i = MenuItemBuilder::with_id("quit", "Quit OpenBurnBar").build(app)?;
    let menu = MenuBuilder::new(app)
        .items(&[&open_i, &health_i, &quit_i])
        .build()?;

    let _tray = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("OpenBurnBar")
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => {
                let _ = open_dashboard(app.clone());
            }
            "health" => {
                let health = daemon_health();
                let _ = app.emit("daemon-health", health);
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
                let _ = open_dashboard(app.clone());
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
            usage_insights,
            mission_list,
            mission_create,
            mission_approval_decision,
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
            memory_boundaries,
            memory_review_inbox,
            memory_forget,
            database_workspace_status,
            database_index_project,
            database_watch_project,
            account_status,
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

    // BurnBarMissionApproveRequest/CancelRequest decode `missionID` (capital ID,
    // Swift property name verbatim — no CodingKeys remap) plus a non-optional
    // `actor`. A rename on either side makes the daemon's Codable decode throw,
    // silently breaking approvals. This test pins the wire shape.
    #[test]
    fn mission_decision_wire_contract_is_pinned() {
        let (method, params) = mission_decision_wire("m-42", MissionApprovalDecision::Approve);
        assert_eq!(method, "daemon.mission.approve");
        assert_eq!(params["missionID"], "m-42");
        assert_eq!(params["actor"], "linux-shell");
        assert!(params.get("missionId").is_none());
        assert!(params.get("id").is_none());

        let (method, params) = mission_decision_wire("m-43", MissionApprovalDecision::Deny);
        assert_eq!(method, "daemon.mission.cancel");
        assert_eq!(params["missionID"], "m-43");
        assert_eq!(params["actor"], "linux-shell");
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
    fn mission_decision_rejects_unknown_values() {
        assert_eq!(MissionApprovalDecision::parse("approve"), Ok(MissionApprovalDecision::Approve));
        assert_eq!(MissionApprovalDecision::parse("deny"), Ok(MissionApprovalDecision::Deny));
        assert!(MissionApprovalDecision::parse("not-deny-means-approve").is_err());
        assert!(MissionApprovalDecision::parse("APPROVE").is_err());
    }

    #[test]
    fn mission_pending_approval_requires_matching_pending_mission() {
        let mission_list = serde_json::json!({"pendingApprovals": [
            {"id": "approval-1", "missionId": "m-1", "risk": "standard"},
            {"id": "approval-2", "missionId": "m-2", "risk": "high"}
        ]});
        let approval = mission_pending_approval(&mission_list, "m-2").expect("pending approval");
        assert_eq!(approval["id"], "approval-2");
        assert!(mission_pending_approval(&mission_list, "attacker-chosen-mission-id").is_none());
    }

    #[test]
    fn mission_high_risk_detection_matches_daemon_aliases() {
        assert!(mission_approval_is_high_risk(&serde_json::json!({"risk": "high"})));
        assert!(mission_approval_is_high_risk(&serde_json::json!({"severity": "HIGH_RISK"})));
        assert!(!mission_approval_is_high_risk(&serde_json::json!({"risk": "standard"})));
    }
}
