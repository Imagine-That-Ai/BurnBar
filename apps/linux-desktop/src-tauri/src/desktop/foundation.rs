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

const SMART_HUB_MAX_OPERATION_BYTES: usize = 64;
const SMART_HUB_MAX_REQUEST_ID_BYTES: usize = 96;
const SMART_HUB_MAX_OUTPUT_BYTES: usize = 512 * 1024;
const SMART_HUB_MAX_JSON_DEPTH: usize = 8;
const SMART_HUB_MAX_JSON_ITEMS: usize = 128;
const SMART_HUB_MAX_JSON_STRING_BYTES: usize = 32 * 1024;
const SMART_HUB_TIMEOUT: Duration = Duration::from_secs(8);

static SMART_HUB_CANCELLATIONS: OnceLock<
    Mutex<HashMap<String, tokio_util::sync::CancellationToken>>,
> = OnceLock::new();

fn smart_hub_cancellations() -> &'static Mutex<HashMap<String, tokio_util::sync::CancellationToken>>
{
    SMART_HUB_CANCELLATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The Linux CLI is the existing SmartHub contract. Keep this operation map
/// intentionally closed: the renderer can request a known operation, never an
/// arbitrary executable or argument vector.
fn smart_hub_cli_args(operation: &str) -> Result<&'static [&'static str], String> {
    match operation {
        "discover" => Ok(&["devices", "discover", "smarthub", "--json"]),
        "status" => Ok(&["devices", "iot", "smarthub", "status", "--json"]),
        // The Linux CLI has one safe bridge probe. Keep `test` as a typed
        // product operation without exposing a shell command or free-form args.
        "test" => Ok(&["devices", "iot", "smarthub", "status", "--json"]),
        "cast" | "cast_status" => Ok(&["devices", "iot", "cast", "status", "--json"]),
        "homeassistant_status" => Ok(&["devices", "iot", "homeassistant", "status", "--json"]),
        // `pixel-clock control` is a fixed, simulator-safe device probe. It
        // never accepts a device id, URL, or user-supplied HTTP body.
        "device" | "pixel_clock_control" => Ok(&["devices", "pixel-clock", "control", "--json"]),
        "parity" => Ok(&["devices", "parity", "--json"]),
        _ => Err("smarthub_operation_not_allowlisted".to_string()),
    }
}

fn validate_smart_hub_operation(operation: String) -> Result<String, String> {
    let operation = operation.trim().to_string();
    if operation.is_empty() || operation.len() > SMART_HUB_MAX_OPERATION_BYTES {
        return Err("smarthub_operation_invalid".to_string());
    }
    smart_hub_cli_args(&operation)?;
    Ok(operation)
}

fn validate_smart_hub_request_id(request_id: &str) -> Result<(), String> {
    if request_id.is_empty()
        || request_id.len() > SMART_HUB_MAX_REQUEST_ID_BYTES
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err("smarthub_invalid_request_id".to_string());
    }
    Ok(())
}

fn validate_smart_hub_json_value(value: &serde_json::Value, depth: usize) -> Result<(), String> {
    if depth > SMART_HUB_MAX_JSON_DEPTH {
        return Err("openburnbar_cli_smarthub_payload_too_deep".to_string());
    }
    match value {
        serde_json::Value::String(text) => {
            if text.len() > SMART_HUB_MAX_JSON_STRING_BYTES
                || text.chars().any(|character| {
                    character.is_control() && !matches!(character, '\n' | '\r' | '\t')
                })
            {
                return Err("openburnbar_cli_smarthub_payload_invalid_text".to_string());
            }
        }
        serde_json::Value::Array(items) => {
            if items.len() > SMART_HUB_MAX_JSON_ITEMS {
                return Err("openburnbar_cli_smarthub_payload_too_many_items".to_string());
            }
            for item in items {
                validate_smart_hub_json_value(item, depth + 1)?;
            }
        }
        serde_json::Value::Object(fields) => {
            if fields.len() > SMART_HUB_MAX_JSON_ITEMS {
                return Err("openburnbar_cli_smarthub_payload_too_many_fields".to_string());
            }
            for (key, item) in fields {
                if key.len() > 256
                    || key.chars().any(|character| {
                        character.is_control() && !matches!(character, '\n' | '\r' | '\t')
                    })
                {
                    return Err("openburnbar_cli_smarthub_payload_invalid_key".to_string());
                }
                validate_smart_hub_json_value(item, depth + 1)?;
            }
        }
        serde_json::Value::Null | serde_json::Value::Bool(_) | serde_json::Value::Number(_) => {}
    }
    Ok(())
}

fn validate_smart_hub_payload_shape(
    operation: &str,
    payload: &serde_json::Value,
) -> Result<(), String> {
    let expects_array = matches!(operation, "discover" | "parity");
    let valid_shape = if expects_array {
        payload.is_array()
    } else {
        // Every non-list operation maps to SmartHubStatusResult in the
        // renderer. Reject scalar/null payloads at the native boundary so a
        // malformed CLI response cannot masquerade as a degraded status.
        payload.is_object()
    };
    if !valid_shape {
        return Err("openburnbar_cli_smarthub_payload_shape_invalid".to_string());
    }
    Ok(())
}

/// Kill the whole CLI process group, not only the direct child. Discovery
/// adapters can launch helpers (for example Avahi); killing only the parent
/// leaves stdout open and makes the bounded reader wait forever.
fn terminate_smarthub_child(child: &mut Child) {
    let process_group = child.id() as libc::pid_t;
    if process_group > 0 {
        // The child is started in its own process group below. A failed group
        // kill is harmless because the direct-child fallback still runs.
        unsafe {
            let _ = libc::kill(-process_group, libc::SIGKILL);
        }
    }
    let _ = child.kill();
    let _ = child.wait();
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

const PACKAGED_AUTOSTART_PATH: &str = "/etc/xdg/autostart/openburnbar.desktop";
const PACKAGED_AUTOSTART_EXEC: &str = "/usr/bin/openburnbar-linux-desktop --background";
const AUTOSTART_MAX_BYTES: u64 = 64 * 1024;

/// The packaged desktop entry is the only executable template the renderer is
/// allowed to select. Login-at-startup preferences only toggle the entry's
/// standard enable/hidden keys; they never accept a command, path, or shell
/// fragment from the renderer.
const PACKAGED_AUTOSTART_TEMPLATE: &str =
    include_str!("../../../../../packaging/linux/autostart/openburnbar.desktop");

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LaunchAtLoginStatus {
    enabled: bool,
    user_override: bool,
    source: String,
    path: String,
    detail: Option<String>,
}

fn validate_safe_absolute_path(path: &Path, label: &str) -> Result<PathBuf, String> {
    let text = path
        .to_str()
        .ok_or_else(|| format!("{label}_path_invalid"))?;
    if !path.is_absolute()
        || text.len() > 4096
        || text.chars().any(char::is_control)
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(format!("{label}_path_unsafe"));
    }
    Ok(path.to_path_buf())
}

fn linux_config_home() -> Result<PathBuf, String> {
    if let Some(xdg) = first_non_empty_env(&["XDG_CONFIG_HOME"]) {
        return validate_safe_absolute_path(Path::new(&xdg), "xdg_config_home");
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "home_path_unavailable".to_string())?;
    let home = validate_safe_absolute_path(&home, "home")?;
    Ok(home.join(".config"))
}

/// Check a path component-by-component without following a symlink. Missing
/// components may be created with owner-only permissions for user preferences.
fn ensure_autostart_directory_chain(path: &Path, create: bool) -> Result<bool, String> {
    let path = validate_safe_absolute_path(path, "autostart_directory")?;
    if path == Path::new("/") {
        return Ok(true);
    }
    match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err("autostart_directory_unsafe".to_string());
            }
            // A symlink in any parent is also rejected. This canonical check
            // is intentionally strict because the setting changes a desktop
            // startup boundary.
            if fs::canonicalize(&path).map_err(|_| "autostart_directory_unsafe".to_string())?
                != path
            {
                return Err("autostart_directory_unsafe".to_string());
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && create => {
            let parent = path
                .parent()
                .ok_or_else(|| "autostart_directory_unsafe".to_string())?;
            if !ensure_autostart_directory_chain(parent, true)? {
                return Err("autostart_directory_unsafe".to_string());
            }
            fs::create_dir(&path).map_err(|_| "autostart_directory_create_failed".to_string())?;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700))
                .map_err(|_| "autostart_directory_create_failed".to_string())?;
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("autostart_directory_unavailable".to_string()),
    }
}

fn ensure_user_autostart_parent(create: bool) -> Result<Option<PathBuf>, String> {
    let config_home = linux_config_home()?;
    if !ensure_autostart_directory_chain(&config_home, create)? {
        return Ok(None);
    }
    let config_metadata = fs::symlink_metadata(&config_home)
        .map_err(|_| "autostart_directory_unavailable".to_string())?;
    let uid = unsafe { libc::geteuid() };
    if config_metadata.uid() != uid || config_metadata.permissions().mode() & 0o022 != 0 {
        return Err("autostart_directory_unsafe".to_string());
    }
    let autostart_dir = config_home.join("autostart");
    if !ensure_autostart_directory_chain(&autostart_dir, create)? {
        return Ok(None);
    }
    let metadata = fs::symlink_metadata(&autostart_dir)
        .map_err(|_| "autostart_directory_unavailable".to_string())?;
    if metadata.uid() != uid || metadata.permissions().mode() & 0o022 != 0 {
        return Err("autostart_directory_unsafe".to_string());
    }
    Ok(Some(autostart_dir))
}

fn user_autostart_path(create_parent: bool) -> Result<Option<PathBuf>, String> {
    Ok(ensure_user_autostart_parent(create_parent)?.map(|dir| dir.join("openburnbar.desktop")))
}

fn read_autostart_entry(path: &Path, require_user_owner: bool) -> Result<Option<String>, String> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("autostart_entry_unavailable".to_string()),
    };
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.nlink() != 1
        || metadata.len() > AUTOSTART_MAX_BYTES
    {
        return Err("autostart_entry_unsafe".to_string());
    }
    if require_user_owner {
        let uid = unsafe { libc::geteuid() };
        if metadata.uid() != uid || metadata.permissions().mode() & 0o022 != 0 {
            return Err("autostart_entry_unsafe".to_string());
        }
    }
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "autostart_entry_unavailable".to_string())?;
    let opened = file
        .metadata()
        .map_err(|_| "autostart_entry_unavailable".to_string())?;
    if opened.file_type().is_symlink()
        || !opened.is_file()
        || opened.nlink() != 1
        || opened.len() > AUTOSTART_MAX_BYTES
    {
        return Err("autostart_entry_unsafe".to_string());
    }
    if require_user_owner {
        let uid = unsafe { libc::geteuid() };
        if opened.uid() != uid || opened.permissions().mode() & 0o022 != 0 {
            return Err("autostart_entry_unsafe".to_string());
        }
    }
    let mut contents = String::new();
    let mut bounded = file.take(AUTOSTART_MAX_BYTES + 1);
    bounded
        .read_to_string(&mut contents)
        .map_err(|_| "autostart_entry_unavailable".to_string())?;
    if contents.len() as u64 > AUTOSTART_MAX_BYTES {
        return Err("autostart_entry_unsafe".to_string());
    }
    Ok(Some(contents))
}

fn autostart_exec(content: &str) -> Result<&str, String> {
    let mut exec = None;
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("Exec=") {
            if exec.replace(value).is_some() {
                return Err("autostart_entry_unsafe".to_string());
            }
        }
    }
    exec.ok_or_else(|| "autostart_entry_unsafe".to_string())
}

fn validate_autostart_template(content: &str) -> Result<(), String> {
    if autostart_exec(content)? != PACKAGED_AUTOSTART_EXEC {
        return Err("autostart_entry_unsafe".to_string());
    }
    if !content.lines().any(|line| line == "Type=Application") {
        return Err("autostart_entry_unsafe".to_string());
    }
    Ok(())
}

fn autostart_enabled(content: &str) -> Result<bool, String> {
    validate_autostart_template(content)?;
    let mut hidden = false;
    let mut gnome_enabled = true;
    let mut saw_hidden = false;
    let mut saw_gnome = false;
    for line in content.lines() {
        if let Some(value) = line.strip_prefix("Hidden=") {
            if saw_hidden {
                return Err("autostart_entry_unsafe".to_string());
            }
            saw_hidden = true;
            hidden = match value {
                "true" => true,
                "false" => false,
                _ => return Err("autostart_entry_unsafe".to_string()),
            };
        } else if let Some(value) = line.strip_prefix("X-GNOME-Autostart-enabled=") {
            if saw_gnome {
                return Err("autostart_entry_unsafe".to_string());
            }
            saw_gnome = true;
            gnome_enabled = match value {
                "true" => true,
                "false" => false,
                _ => return Err("autostart_entry_unsafe".to_string()),
            };
        }
    }
    Ok(!hidden && gnome_enabled)
}

fn render_autostart_entry(template: &str, enabled: bool) -> Result<String, String> {
    validate_autostart_template(template)?;
    let mut rendered = String::with_capacity(template.len() + 16);
    let mut saw_gnome = false;
    let mut saw_hidden = false;
    for line in template.lines() {
        if line.starts_with("X-GNOME-Autostart-enabled=") {
            rendered.push_str("X-GNOME-Autostart-enabled=");
            rendered.push_str(if enabled { "true" } else { "false" });
            saw_gnome = true;
        } else if line.starts_with("Hidden=") {
            saw_hidden = true;
            if !enabled {
                rendered.push_str("Hidden=true");
            } else {
                continue;
            }
        } else {
            rendered.push_str(line);
        }
        rendered.push('\n');
    }
    if !saw_gnome {
        return Err("autostart_entry_unsafe".to_string());
    }
    if !enabled && !saw_hidden {
        rendered.push_str("Hidden=true\n");
    }
    Ok(rendered)
}

fn write_autostart_entry(path: &Path, content: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "autostart_directory_unsafe".to_string())?;
    let parent_metadata =
        fs::symlink_metadata(parent).map_err(|_| "autostart_directory_unavailable".to_string())?;
    if parent_metadata.file_type().is_symlink()
        || !parent_metadata.is_dir()
        || parent_metadata.uid() != unsafe { libc::geteuid() }
        || parent_metadata.permissions().mode() & 0o022 != 0
    {
        return Err("autostart_directory_unsafe".to_string());
    }
    if let Ok(existing) = fs::symlink_metadata(path) {
        if existing.file_type().is_symlink()
            || !existing.is_file()
            || existing.uid() != unsafe { libc::geteuid() }
            || existing.permissions().mode() & 0o022 != 0
        {
            return Err("autostart_entry_unsafe".to_string());
        }
    }
    let temporary = parent.join(format!(
        ".openburnbar.desktop.{}.tmp",
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&temporary)
            .map_err(|_| "autostart_entry_write_failed".to_string())?;
        file.write_all(content)
            .map_err(|_| "autostart_entry_write_failed".to_string())?;
        file.sync_all()
            .map_err(|_| "autostart_entry_write_failed".to_string())?;
        drop(file);
        fs::rename(&temporary, path).map_err(|_| "autostart_entry_write_failed".to_string())?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|_| "autostart_entry_write_failed".to_string())?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn launch_at_login_status_with_paths(
    user_path: &Path,
    packaged_path: &Path,
) -> Result<LaunchAtLoginStatus, String> {
    let user = read_autostart_entry(user_path, true)?;
    if let Some(content) = user {
        let enabled = autostart_enabled(&content)?;
        return Ok(LaunchAtLoginStatus {
            enabled,
            user_override: true,
            source: "user".to_string(),
            path: user_path.display().to_string(),
            detail: Some(if enabled {
                "User autostart override is enabled.".to_string()
            } else {
                "User autostart override disables the packaged entry.".to_string()
            }),
        });
    }
    let packaged = read_autostart_entry(packaged_path, false)?;
    let Some(content) = packaged else {
        return Ok(LaunchAtLoginStatus {
            enabled: false,
            user_override: false,
            source: "unavailable".to_string(),
            path: user_path.display().to_string(),
            detail: Some("The packaged XDG autostart entry is unavailable.".to_string()),
        });
    };
    let enabled = autostart_enabled(&content)?;
    Ok(LaunchAtLoginStatus {
        enabled,
        user_override: false,
        source: "packaged".to_string(),
        path: user_path.display().to_string(),
        detail: Some("Using the packaged XDG autostart entry.".to_string()),
    })
}

fn packaged_autostart_content(packaged_path: &Path) -> Result<String, String> {
    match read_autostart_entry(packaged_path, false)? {
        Some(content) => Ok(content),
        // Relocatable installs (and development launches) may not have a
        // system-wide /etc/xdg entry, but the trusted entry is compiled into
        // the shell and can be installed as the user's override.
        None => Ok(PACKAGED_AUTOSTART_TEMPLATE.to_string()),
    }
}

#[tauri::command]
fn launch_at_login_status() -> Result<LaunchAtLoginStatus, String> {
    validate_autostart_template(PACKAGED_AUTOSTART_TEMPLATE)?;
    let user_path = user_autostart_path(false)?.unwrap_or_else(|| {
        linux_config_home()
            .unwrap_or_else(|_| PathBuf::from("/"))
            .join("autostart")
            .join("openburnbar.desktop")
    });
    launch_at_login_status_with_paths(&user_path, Path::new(PACKAGED_AUTOSTART_PATH))
}

#[tauri::command]
fn launch_at_login_set(enabled: bool) -> Result<LaunchAtLoginStatus, String> {
    validate_autostart_template(PACKAGED_AUTOSTART_TEMPLATE)?;
    let user_path = user_autostart_path(true)?
        .ok_or_else(|| "autostart_directory_create_failed".to_string())?;
    let packaged = packaged_autostart_content(Path::new(PACKAGED_AUTOSTART_PATH))?;
    let rendered = render_autostart_entry(&packaged, enabled)?;
    write_autostart_entry(&user_path, rendered.as_bytes())?;
    launch_at_login_status_with_paths(&user_path, Path::new(PACKAGED_AUTOSTART_PATH))
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
