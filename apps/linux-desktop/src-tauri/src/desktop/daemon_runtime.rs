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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeComputerUseSystemCapability {
    available: bool,
    capture_ready: bool,
    input_ready: bool,
    active: bool,
    reason: String,
    source: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeComputerUsePendingSnapshot {
    system_capability: Option<RuntimeComputerUseSystemCapability>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeTextExpansionCapability {
    registration: String,
    supports_external_expansion: bool,
    detail: String,
}

const RUNTIME_CAPABILITY_CATALOG: &str =
    include_str!("../../../../../packaging/linux/runtime-capability-catalog.json");

fn evaluate_runtime_capability(
    definition: RuntimeCapabilityDefinition,
    health: &DaemonHealth,
    session_type: Option<&str>,
    has_session_bus: bool,
    media: Option<&RuntimeMediaCapability>,
    system_computer_use: Option<&RuntimeComputerUseSystemCapability>,
    text_expansion: Option<&RuntimeTextExpansionCapability>,
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
        "computer-use-system" => match system_computer_use {
            Some(capability)
                if capability.available && capability.capture_ready && capability.input_ready =>
            {
                available(
                    if capability.active {
                        "PipeWire capture and Linux input are live for the active System Computer Use session."
                    } else {
                        "PipeWire capture and Linux input passed daemon runtime preflight."
                    },
                    &capability.source,
                )
            }
            Some(capability) => (
                "unavailable".to_string(),
                format!("{}: {}", definition.unavailable_reason, capability.reason),
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
        "text-expansion" => match text_expansion {
            Some(capability) if capability.supports_external_expansion => available(
                &capability.detail,
                "daemon-text-expansion-status",
            ),
            Some(capability) => (
                "unavailable".to_string(),
                format!(
                    "{} ({})",
                    capability.detail, capability.registration
                ),
                "daemon-text-expansion-status".to_string(),
            ),
            None => unavailable(),
        },
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
    let text_expansion = health
        .ok
        .then(|| {
            call_daemon_method_with_timeout(
                "daemon.text_expansion.engine.status",
                None,
                Duration::from_secs(2),
            )
        })
        .and_then(Result::ok)
        .and_then(|value| serde_json::from_value::<RuntimeTextExpansionCapability>(value).ok());
    let system_computer_use = health
        .ok
        .then(|| {
            call_daemon_method_with_timeout(
                "daemon.computer_use.approval.pending",
                Some(serde_json::json!({})),
                Duration::from_secs(2),
            )
        })
        .and_then(Result::ok)
        .and_then(|value| serde_json::from_value::<RuntimeComputerUsePendingSnapshot>(value).ok())
        .and_then(|snapshot| snapshot.system_capability);
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
                system_computer_use.as_ref(),
                text_expansion.as_ref(),
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
    // Keep settings/status on the same bounded, process-group-aware path as
    // the SmartHub surface. `Command::output()` would wait forever on a
    // broken adapter and retain unbounded stdout/stderr in memory.
    let command = run_smarthub_cli(
        "parity".to_string(),
        cli,
        tokio_util::sync::CancellationToken::new(),
    )?;
    let rows = serde_json::from_value::<Vec<DeviceParityRow>>(command.payload)
        .map_err(|e| format!("Invalid devices parity JSON: {e}"))?;
    Ok(IntegrationsStatusPayload {
        integrations: rows.into_iter().filter_map(map_parity_row).collect(),
    })
}

/// Execute one of the existing Linux SmartHub/device CLI contracts.
///
/// This intentionally does not become a generic CLI bridge. Every operation
/// has a fixed argv, the executable must be the root-owned packaged binary,
/// and the response is drained concurrently and bounded before it reaches the
/// renderer. The cancellation token kills the child instead of merely hiding
/// a stale promise in the renderer.
fn run_smarthub_cli(
    operation: String,
    cli: PathBuf,
    cancellation: tokio_util::sync::CancellationToken,
) -> Result<SmartHubCommandPayload, String> {
    let args = smart_hub_cli_args(operation.as_str())?;
    let mut child = Command::new(cli)
        .process_group(0)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "openburnbar_cli_smarthub_launch_failed".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "openburnbar_cli_smarthub_output_unavailable".to_string())?;
    let output_too_large = Arc::new(AtomicBool::new(false));
    let output_too_large_for_reader = output_too_large.clone();
    let reader = thread::spawn(move || {
        let mut bounded = stdout.take((SMART_HUB_MAX_OUTPUT_BYTES + 1) as u64);
        let mut bytes = Vec::new();
        let result = bounded.read_to_end(&mut bytes);
        // Treat a reader that reaches the hard cap as oversized even when the
        // child closes the pipe before the extra sentinel byte arrives (for
        // example after SIGPIPE). This keeps failure classification stable
        // across Linux libc/process scheduling variants.
        if bytes.len() >= SMART_HUB_MAX_OUTPUT_BYTES {
            output_too_large_for_reader.store(true, Ordering::Release);
        }
        result.map(|_| bytes)
    });

    let deadline = Instant::now() + SMART_HUB_TIMEOUT;
    let status = loop {
        if cancellation.is_cancelled() {
            terminate_smarthub_child(&mut child);
            let _ = reader.join();
            return Err("openburnbar_cli_smarthub_cancelled".to_string());
        }
        if output_too_large.load(Ordering::Acquire) {
            terminate_smarthub_child(&mut child);
            let _ = reader.join();
            return Err("openburnbar_cli_smarthub_output_too_large".to_string());
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                terminate_smarthub_child(&mut child);
                let _ = reader.join();
                return Err("openburnbar_cli_smarthub_timeout".to_string());
            }
            Ok(None) => thread::sleep(Duration::from_millis(25)),
            Err(_) => {
                terminate_smarthub_child(&mut child);
                let _ = reader.join();
                return Err("openburnbar_cli_smarthub_wait_failed".to_string());
            }
        }
    };
    let stdout = reader
        .join()
        .map_err(|_| "openburnbar_cli_smarthub_output_failed".to_string())?
        .map_err(|_| "openburnbar_cli_smarthub_output_failed".to_string())?;
    if output_too_large.load(Ordering::Acquire) || stdout.len() >= SMART_HUB_MAX_OUTPUT_BYTES {
        return Err("openburnbar_cli_smarthub_output_too_large".to_string());
    }
    if !status.success() {
        return Err("openburnbar_cli_smarthub_command_failed".to_string());
    }
    let payload = serde_json::from_slice::<serde_json::Value>(&stdout)
        .map_err(|_| "openburnbar_cli_smarthub_invalid_json".to_string())?;
    validate_smart_hub_payload_shape(operation.as_str(), &payload)?;
    validate_smart_hub_json_value(&payload, 0)?;
    Ok(SmartHubCommandPayload { operation, payload })
}

#[tauri::command]
async fn smarthub_command(
    operation: String,
    request_id: Option<String>,
) -> Result<SmartHubCommandPayload, String> {
    let operation = validate_smart_hub_operation(operation)?;
    let request_id =
        request_id.unwrap_or_else(|| format!("smarthub-{}", uuid::Uuid::new_v4().simple()));
    validate_smart_hub_request_id(&request_id)?;
    let cli = trusted_openburnbar_cli()?;
    let cancellation = tokio_util::sync::CancellationToken::new();
    {
        let mut requests = smart_hub_cancellations()
            .lock()
            .map_err(|_| "smarthub_cancellation_registry_poisoned")?;
        if requests.contains_key(&request_id) {
            return Err("smarthub_duplicate_request_id".to_string());
        }
        requests.insert(request_id.clone(), cancellation.clone());
    }
    let result = tauri::async_runtime::spawn_blocking(move || {
        run_smarthub_cli(operation, cli, cancellation)
    })
    .await
    .map_err(|_| "openburnbar_cli_smarthub_worker_failed".to_string())?;
    if let Ok(mut requests) = smart_hub_cancellations().lock() {
        requests.remove(&request_id);
    }
    result
}

#[tauri::command]
fn smarthub_cancel(request_id: String) -> Result<(), String> {
    validate_smart_hub_request_id(&request_id)?;
    let requests = smart_hub_cancellations()
        .lock()
        .map_err(|_| "smarthub_cancellation_registry_poisoned")?;
    if let Some(cancellation) = requests.get(&request_id) {
        cancellation.cancel();
    }
    Ok(())
}
