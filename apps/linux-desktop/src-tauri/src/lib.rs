use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};

mod media;

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

fn linux_support_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        let trimmed = xdg.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed).join("openburnbar");
        }
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
        .join(".local/share/openburnbar")
}

fn linux_socket_path() -> PathBuf {
    if let Ok(override_path) = std::env::var("OPENBURNBAR_SOCKET_PATH") {
        let trimmed = override_path.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        let trimmed = runtime_dir.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed).join("openburnbar").join("daemon.sock");
        }
    }
    linux_support_dir().join("openburnbar-daemon.sock")
}

fn read_auth_token() -> Option<String> {
    let path = linux_support_dir().join("daemon-socket-auth-token");
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn read_gateway_auth_token() -> Option<String> {
    if let Ok(token) = std::env::var("OPENBURNBAR_GATEWAY_AUTH_TOKEN") {
        let trimmed = token.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    if let Ok(path) = std::env::var("OPENBURNBAR_GATEWAY_AUTH_TOKEN_FILE") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            if let Ok(token) = fs::read_to_string(trimmed) {
                let token = token.trim();
                if !token.is_empty() {
                    return Some(token.to_string());
                }
            }
        }
    }
    fs::read_to_string(linux_support_dir().join("gateway-auth-token"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[tauri::command]
fn gateway_auth_token() -> Option<String> {
    read_gateway_auth_token()
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
    if let Ok(output) = Command::new("openburnbar-cli")
        .args(["health", "--json"])
        .output()
    {
        if output.status.success() {
            if let Ok(mut parsed) = serde_json::from_slice::<DaemonHealth>(&output.stdout) {
                if parsed.socket_path.is_none() {
                    parsed.socket_path = Some(linux_socket_path().display().to_string());
                }
                return parsed;
            }
        }
    }
    probe_daemon_health()
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
        "pixel_clock" => Some("AWTRIX HTTP endpoint, runtime agent, or _http._tcp mDNS".to_string()),
        "google_cast" => Some("avahi-daemon + avahi-utils for _googlecast._tcp discovery".to_string()),
        "awtrix_http" => Some("avahi-daemon + avahi-utils for _http._tcp discovery".to_string()),
        "home_assistant" => Some("OPENBURNBAR_HOME_ASSISTANT_URL and daemon-held Home Assistant token".to_string()),
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
        "control_ok" | "cast_reachable" | "home_assistant_control_ok" | "bridge_control_ok" => "connected",
        "runtime_agent_detected" | "discoverable" | "api_reachable_control_blocked" | "bridge_reachable_control_blocked" => "configured",
        "disabled" => "disabled",
        "blocked" | "blocked_no_runtime_agent_or_device" | "blocked_missing_home_assistant_url"
        | "blocked_home_assistant_api_unreachable" | "blocked_bridge_not_reachable"
        | "blocked_googlecast_control_unreachable" | "blocked_no_googlecast_instances"
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
    let state = map_integration_state(kind, row.status.as_str(), row.blocker.as_deref()).to_string();
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
    let output = Command::new("openburnbar-cli")
        .args(["devices", "parity", "--json"])
        .output()
        .map_err(|e| format!("openburnbar-cli devices parity --json unavailable: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(if stderr.is_empty() {
            "openburnbar-cli devices parity --json failed".to_string()
        } else {
            stderr
        });
    }
    let rows = serde_json::from_slice::<Vec<DeviceParityRow>>(&output.stdout)
        .map_err(|e| format!("Invalid devices parity JSON: {e}"))?;
    Ok(IntegrationsStatusPayload {
        integrations: rows.into_iter().filter_map(map_parity_row).collect(),
    })
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

fn call_daemon_method_report(
    method: &str,
    params: Option<serde_json::Value>,
) -> serde_json::Value {
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
    let package_channel =
        std::env::var("OPENBURNBAR_PACKAGE_CHANNEL").unwrap_or_else(|_| "unknown".to_string());
    Ok(serde_json::json!({
        "shellVersion": shell_version,
        "daemonVersion": daemon_version,
        "packageChannel": package_channel,
        "updateCheck": "unavailable-in-shell"
    }))
}

// ───────────────── P09: redacted diagnostics export ─────────────────
// Writes a JSON bundle to the support dir. Redaction is structural: this
// command only persists shell/health metadata — it never reads provider
// payloads, tokens, or socket auth material.
#[tauri::command]
fn export_diagnostics() -> Result<serde_json::Value, String> {
    let dir = linux_support_dir();
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
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
    fs::write(&path, json).map_err(|e| e.to_string())?;
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

// ───────────────── P12: Mercury media status ─────────────────
// Wire: proposed daemon.media.status. Current Linux daemons may reject this as
// unknown; the TS bridge maps that rejection to the capability-absent state.
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

fn media_phase(value: &serde_json::Value) -> Option<String> {
    value
        .get("phase")
        .or_else(|| value.get("state"))
        .or_else(|| value.get("status"))
        .or_else(|| value.get("activeSession").and_then(|session| session.get("state")))
        .and_then(|phase| phase.as_str())
        .map(|phase| phase.to_string())
}

fn media_request_id(value: &serde_json::Value) -> Option<String> {
    value
        .get("requestId")
        .or_else(|| value.get("request_id"))
        .or_else(|| value.get("incomingCall").and_then(|call| call.get("requestId")))
        .or_else(|| value.get("incoming_call").and_then(|call| call.get("request_id")))
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
                        let phase_changed = phase != last_phase;
                        if phase_changed {
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
                    Err(e) => {
                        let lower = e.to_lowercase();
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
                                    "error": e
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
            "--help" | "-h" => {
                println!(
                    "OpenBurnBar Linux desktop shell\n\nUsage: openburnbar-linux-desktop [--version] [--help]"
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
            gateway_auth_token,
            open_dashboard,
            quit_app,
            tray_degraded,
            record_perf_sample,
            measure_perf_operation,
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
            integrations_status
        ])
        .setup(|app| {
            if let Err(e) = build_tray(app.handle()) {
                TRAY_INIT_FAILED.store(true, Ordering::Relaxed);
                eprintln!("tray init degraded: {e}");
            }
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
}
