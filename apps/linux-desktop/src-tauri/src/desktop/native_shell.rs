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
    take_initial_deep_link_route(initial_deep_link_route_store())
}

fn take_initial_deep_link_route(initial: &Mutex<Option<String>>) -> Option<String> {
    initial.lock().ok().and_then(|mut route| route.take())
}

#[tauri::command]
fn forwarded_deep_link_route() -> Option<String> {
    take_forwarded_deep_link_route(forwarded_route_queue())
}

fn take_forwarded_deep_link_route(forwarded: &Mutex<Vec<String>>) -> Option<String> {
    forwarded
        .lock()
        .ok()
        .and_then(|mut routes| routes.first().cloned().map(|_| routes.remove(0)))
}

#[tauri::command]
fn initial_notification_actions() -> Vec<serde_json::Value> {
    take_initial_notification_actions()
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

static TRAY_INIT_FAILED: AtomicBool = AtomicBool::new(false);
const COMPUTER_USE_PANIC_SHORTCUTS: [&str; 2] = ["Ctrl+Alt+Super+Period", "Ctrl+Alt+Shift+Period"];
const OPEN_DASHBOARD_SHORTCUT: &str = "Ctrl+Alt+Super+O";
const SUMMON_PET_SHORTCUT: &str = "Ctrl+Alt+Super+P";
const PET_SUMMON_EVENT_PAYLOAD: &str = "native-shortcut";

const NATIVE_SHORTCUT_BINDINGS: [(&str, &str); 4] = [
    ("computer-use-panic", COMPUTER_USE_PANIC_SHORTCUTS[0]),
    (
        "computer-use-panic-fallback",
        COMPUTER_USE_PANIC_SHORTCUTS[1],
    ),
    ("open-dashboard", OPEN_DASHBOARD_SHORTCUT),
    ("summon-pet", SUMMON_PET_SHORTCUT),
];

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum NativeShortcutBackend {
    X11,
    Wayland,
    Unknown,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum NativeShortcutBindingState {
    Registered,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeShortcutBindingStatus {
    id: String,
    shortcut: String,
    state: NativeShortcutBindingState,
    degraded_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeShortcutStatus {
    available: bool,
    registered: bool,
    backend: NativeShortcutBackend,
    shortcuts: Vec<String>,
    bindings: Vec<NativeShortcutBindingStatus>,
    #[serde(rename = "portalAvailable")]
    portal_available: bool,
    #[serde(rename = "portalReason")]
    portal_reason: Option<String>,
    degraded_reason: Option<String>,
}

static NATIVE_SHORTCUT_STATUS: OnceLock<Mutex<NativeShortcutStatus>> = OnceLock::new();

fn native_shortcut_status_store() -> &'static Mutex<NativeShortcutStatus> {
    NATIVE_SHORTCUT_STATUS.get_or_init(|| {
        Mutex::new(NativeShortcutStatus {
            available: false,
            registered: false,
            backend: native_shortcut_backend(),
            shortcuts: vec![
                COMPUTER_USE_PANIC_SHORTCUTS[0].to_string(),
                COMPUTER_USE_PANIC_SHORTCUTS[1].to_string(),
                OPEN_DASHBOARD_SHORTCUT.to_string(),
                SUMMON_PET_SHORTCUT.to_string(),
            ],
            bindings: native_shortcut_bindings(
                NativeShortcutBindingState::Unavailable,
                Some("native_shortcuts_not_initialized".to_string()),
            ),
            portal_available: false,
            portal_reason: Some("native_shortcuts_portal_not_probed".to_string()),
            degraded_reason: Some("native_shortcuts_not_initialized".to_string()),
        })
    })
}

fn native_shortcut_bindings(
    state: NativeShortcutBindingState,
    reason: Option<String>,
) -> Vec<NativeShortcutBindingStatus> {
    NATIVE_SHORTCUT_BINDINGS
        .iter()
        .map(|(id, shortcut)| NativeShortcutBindingStatus {
            id: (*id).to_string(),
            shortcut: (*shortcut).to_string(),
            state,
            degraded_reason: reason.clone(),
        })
        .collect()
}

fn native_shortcut_backend_from_env(
    session_type: Option<&str>,
    wayland_display: Option<&str>,
    x11_display: Option<&str>,
) -> NativeShortcutBackend {
    let session_type = session_type.unwrap_or_default().trim().to_ascii_lowercase();
    if session_type == "wayland" || wayland_display.is_some_and(|value| !value.trim().is_empty()) {
        return NativeShortcutBackend::Wayland;
    }
    if session_type == "x11" || x11_display.is_some_and(|value| !value.trim().is_empty()) {
        return NativeShortcutBackend::X11;
    }
    NativeShortcutBackend::Unknown
}

fn native_shortcut_backend() -> NativeShortcutBackend {
    native_shortcut_backend_from_env(
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var("WAYLAND_DISPLAY").ok().as_deref(),
        std::env::var("DISPLAY").ok().as_deref(),
    )
}

fn bounded_shortcut_error(error: impl std::fmt::Display) -> String {
    let normalized = error
        .to_string()
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    normalized.chars().take(256).collect()
}

fn native_shortcut_registration_reason(
    backend: NativeShortcutBackend,
    error: Option<&str>,
) -> String {
    match (backend, error) {
        (NativeShortcutBackend::Wayland, Some(error)) => {
            format!("native_shortcuts_wayland_backend_unavailable:{error}")
        }
        (NativeShortcutBackend::X11, Some(error)) => {
            format!("native_shortcuts_x11_registration_failed:{error}")
        }
        (NativeShortcutBackend::Unknown, Some(error)) => {
            format!("native_shortcuts_backend_unknown:{error}")
        }
        (NativeShortcutBackend::Wayland, None) => {
            "native_shortcuts_wayland_backend_unavailable".to_string()
        }
        (NativeShortcutBackend::X11, None) => "native_shortcuts_x11_unavailable".to_string(),
        (NativeShortcutBackend::Unknown, None) => "native_shortcuts_backend_unknown".to_string(),
    }
}

/// Parse the portal's introspection response without trusting any other
/// interface. The portal is capability evidence only: registration still
/// requires the asynchronous CreateSession/BindShortcuts flow, which is not
/// provided by Tauri's global-shortcut backend on Linux Wayland yet.
fn wayland_global_shortcuts_portal_present(introspection: &str) -> bool {
    const INTERFACE: &str = "org.freedesktop.portal.GlobalShortcuts";
    introspection.lines().any(|line| {
        let mut tokens = line.split_whitespace();
        matches!(tokens.next(), Some("interface"))
            && tokens
                .next()
                .is_some_and(|token| {
                    token.trim_matches(|character| matches!(character, '{' | '}' | ':' | ';'))
                        == INTERFACE
                })
    })
}

fn bounded_portal_probe_error(error: impl std::fmt::Display) -> String {
    let normalized = error
        .to_string()
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    normalized.chars().take(160).collect()
}

fn read_bounded_child_stdout(child: &mut Child) -> String {
    const MAX_OUTPUT_BYTES: u64 = 64 * 1024;
    let mut bytes = Vec::new();
    if let Some(stdout) = child.stdout.as_mut() {
        let mut bounded = stdout.take(MAX_OUTPUT_BYTES);
        let _ = bounded.read_to_end(&mut bytes);
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn probe_wayland_global_shortcuts_portal() -> (bool, Option<String>) {
    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
        return (
            false,
            Some("native_shortcuts_portal_session_bus_unavailable".to_string()),
        );
    }

    let mut child = match Command::new("gdbus")
        .args([
            "introspect",
            "--session",
            "--dest",
            "org.freedesktop.portal.Desktop",
            "--object-path",
            "/org/freedesktop/portal/desktop",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            return (
                false,
                Some(format!(
                    "native_shortcuts_portal_probe_unavailable:{}",
                    bounded_portal_probe_error(error)
                )),
            )
        }
    };

    let deadline = Instant::now() + Duration::from_millis(500);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                // `try_wait` has already reaped the child on Unix. Read the
                // bounded pipe directly instead of calling wait_with_output a
                // second time, which can lose the introspection response.
                let output = read_bounded_child_stdout(&mut child);
                if status.success() && wayland_global_shortcuts_portal_present(&output) {
                    return (
                        true,
                        Some(
                            "native_shortcuts_portal_interface_present_registration_pending"
                                .to_string(),
                        ),
                    );
                }
                return (
                    false,
                    Some("native_shortcuts_portal_interface_unavailable".to_string()),
                );
            }
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return (
                    false,
                    Some("native_shortcuts_portal_probe_timeout".to_string()),
                );
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return (
                    false,
                    Some(format!(
                        "native_shortcuts_portal_probe_failed:{}",
                        bounded_portal_probe_error(error)
                    )),
                );
            }
        }
    }
}

fn native_shortcut_portal_status(
    backend: NativeShortcutBackend,
) -> (bool, Option<String>) {
    if backend != NativeShortcutBackend::Wayland {
        return (false, Some("native_shortcuts_portal_not_wayland".to_string()));
    }
    probe_wayland_global_shortcuts_portal()
}

#[tauri::command]
fn native_shortcut_status() -> NativeShortcutStatus {
    native_shortcut_status_store()
        .lock()
        .map(|status| status.clone())
        .unwrap_or(NativeShortcutStatus {
            available: false,
            registered: false,
            backend: NativeShortcutBackend::Unknown,
            shortcuts: Vec::new(),
            bindings: Vec::new(),
            portal_available: false,
            portal_reason: Some("native_shortcuts_state_unavailable".to_string()),
            degraded_reason: Some("native_shortcuts_state_unavailable".to_string()),
        })
}

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

fn handle_native_shortcut(app: &AppHandle<Wry>, shortcut: &Shortcut, event: ShortcutEvent) {
    if event.state != ShortcutState::Pressed {
        return;
    }
    let base = Modifiers::CONTROL | Modifiers::ALT;
    let meta_chord = base | Modifiers::SUPER;
    let shift_chord = base | Modifiers::SHIFT;
    if shortcut.matches(meta_chord, Code::KeyO) {
        emit_tray_route(app, "overview");
    } else if shortcut.matches(meta_chord, Code::KeyP) {
        // The event payload is deliberately fixed. The renderer accepts only
        // this native-origin marker and never treats arbitrary event data as a
        // summon request, keeping the desktop shortcut boundary fail closed.
        emit_tray_route(app, "pet");
        let _ = app.emit("pet-summon", PET_SUMMON_EVENT_PAYLOAD);
    } else if shortcut.matches(meta_chord, Code::Period)
        || shortcut.matches(shift_chord, Code::Period)
    {
        trigger_computer_use_panic_hotkey();
    }
}

fn set_native_shortcut_unavailable(backend: NativeShortcutBackend, reason: impl Into<String>) {
    let reason = reason.into();
    let (portal_available, portal_reason) = native_shortcut_portal_status(backend);
    if let Ok(mut status) = native_shortcut_status_store().lock() {
        status.available = false;
        status.registered = false;
        status.backend = backend;
        status.bindings = native_shortcut_bindings(
            NativeShortcutBindingState::Unavailable,
            Some(reason.clone()),
        );
        status.portal_available = portal_available;
        status.portal_reason = portal_reason;
        status.degraded_reason = Some(reason);
    }
}

fn register_computer_use_panic_shortcuts(app: &AppHandle) {
    let backend = native_shortcut_backend();
    let Some(global_shortcut) = app.try_state::<GlobalShortcut<Wry>>() else {
        set_native_shortcut_unavailable(
            backend,
            "native_shortcuts_plugin_state_unavailable".to_string(),
        );
        return;
    };

    // global-hotkey currently supports X11 only on Linux. Keep this explicit:
    // Wayland/wlroots sessions must report an unavailable capability instead of
    // claiming success, while the emergency keyboard fallback remains local.
    if backend != NativeShortcutBackend::X11 {
        let reason = native_shortcut_registration_reason(backend, None);
        eprintln!("computer_use_global_panic_hotkey_degraded: {reason}");
        set_native_shortcut_unavailable(backend, reason);
        return;
    }

    let mut bindings = Vec::with_capacity(NATIVE_SHORTCUT_BINDINGS.len());
    for (id, shortcut) in NATIVE_SHORTCUT_BINDINGS {
        let result = global_shortcut.on_shortcut(shortcut, handle_native_shortcut);
        match result {
            Ok(()) => bindings.push(NativeShortcutBindingStatus {
                id: id.to_string(),
                shortcut: shortcut.to_string(),
                state: NativeShortcutBindingState::Registered,
                degraded_reason: None,
            }),
            Err(error) => {
                let detail = bounded_shortcut_error(error);
                let reason = native_shortcut_registration_reason(backend, Some(&detail));
                eprintln!("computer_use_global_panic_hotkey_degraded: {id}: {reason}");
                bindings.push(NativeShortcutBindingStatus {
                    id: id.to_string(),
                    shortcut: shortcut.to_string(),
                    state: NativeShortcutBindingState::Degraded,
                    degraded_reason: Some(reason),
                });
            }
        }
    }

    let registered_count = bindings
        .iter()
        .filter(|binding| binding.state == NativeShortcutBindingState::Registered)
        .count();
    let all_registered = registered_count == bindings.len();
    let any_registered = registered_count > 0;
    if let Ok(mut status) = native_shortcut_status_store().lock() {
        status.available = any_registered;
        status.registered = all_registered;
        status.backend = backend;
        status.bindings = bindings;
        status.portal_available = false;
        status.portal_reason = Some("native_shortcuts_portal_not_wayland".to_string());
        status.degraded_reason = if all_registered {
            None
        } else if any_registered {
            Some("native_shortcuts_partial_registration".to_string())
        } else {
            Some("native_shortcuts_registration_failed".to_string())
        };
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
