
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
// Canonical wire: daemon.membership.status (BurnBarRPCMethod.membershipStatus).
// Older packaged daemons may not implement the contract yet; preserve the
// existing capability-absent UX instead of exposing a raw method-not-found
// failure as a generic membership error.
const MEMBERSHIP_STATUS_METHOD: &str = "daemon.membership.status";
const MEMBERSHIP_CHECKOUT_METHOD: &str = "daemon.membership.checkoutUrl";
const MEMBERSHIP_RESTORE_METHOD: &str = "daemon.membership.restore";

/// Return true only for errors that mean the daemon does not implement the
/// requested wire method. Authentication, cloud, and transport failures must
/// remain actionable errors rather than being mislabeled as an absent feature.
fn daemon_method_is_capability_absent(error: &str) -> bool {
    let lower = error.to_ascii_lowercase();
    let mentions_method = lower.contains("method") || lower.contains("rpc");
    mentions_method
        && (lower.contains("unsupported")
            || lower.contains("unrecognized")
            || lower.contains("not implemented")
            || lower.contains("no such method")
            || lower.contains("invalid method")
            || lower.contains("unknown")
            || lower.contains("not found"))
}

fn membership_rpc_error(error: String) -> String {
    if daemon_method_is_capability_absent(&error) {
        "membership_capability_absent".to_string()
    } else {
        error
    }
}

#[tauri::command]
fn membership_status() -> Result<serde_json::Value, String> {
    call_daemon_method(MEMBERSHIP_STATUS_METHOD, None).map_err(membership_rpc_error)
}

// ───────────────── P10: membership checkout URL ─────────────────
// Canonical wire: daemon.membership.checkoutUrl. Tier-C StoreKit substitute:
// the daemon mints the Stripe URL; the React layer opens it externally.
#[tauri::command]
fn membership_checkout_url() -> Result<serde_json::Value, String> {
    call_daemon_method(
        MEMBERSHIP_CHECKOUT_METHOD,
        Some(serde_json::json!({
            "success_url": "openburnbar://membership/success",
            "cancel_url": "openburnbar://membership/cancel"
        })),
    )
    .map_err(membership_rpc_error)
}

// ───────────────── P10: membership restore ─────────────────
// Canonical wire: daemon.membership.restore (BurnBarRPCMethod.membershipRestore).
// Older daemons reject it; the UI presents the membership capability as absent
// and keeps fixture mode usable.
#[tauri::command]
fn membership_restore() -> Result<serde_json::Value, String> {
    call_daemon_method(MEMBERSHIP_RESTORE_METHOD, None).map_err(membership_rpc_error)
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
            "daemonVersion": safe_diagnostic_version(health.daemon_version.as_deref()),
            "protocolVersion": health.protocol_version.filter(|version| *version <= 1_000_000),
        },
        "package": package,
        "runtime": runtime,
        "renderer": {
            "shell": "tauri",
            "webview": "webkitgtk",
            "capabilities": ["support.diagnostics.export", "support.diagnostics.preview"],
        },
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

fn safe_diagnostic_version(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty()
        || value.len() > 64
        || !value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-' | '+')
        })
    {
        return None;
    }
    Some(value.to_string())
}

fn ensure_private_diagnostics_dir(dir: &Path) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let metadata = fs::symlink_metadata(dir).map_err(|e| e.to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("Diagnostics support directory must be a real directory.".to_string());
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let mode = fs::symlink_metadata(dir)
        .map_err(|e| e.to_string())?
        .permissions()
        .mode();
    if mode & 0o077 != 0 {
        return Err("Diagnostics support directory is not owner-only.".to_string());
    }
    Ok(())
}

fn write_private_diagnostics_json(dir: &Path, stamp: u64, json: &[u8]) -> Result<PathBuf, String> {
    let id = uuid::Uuid::new_v4().simple().to_string();
    let filename = format!("diagnostics-{stamp}-{id}.json");
    let path = dir.join(&filename);
    let partial = dir.join(format!(".{filename}.partial"));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&partial)
            .map_err(|e| e.to_string())?;
        file.write_all(json).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::set_permissions(&partial, fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(&partial, &path).map_err(|e| e.to_string())?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
        Ok(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&partial);
    }
    result
}

const DIAGNOSTICS_DESTINATION_MAX_BYTES: usize = 4096;

fn validate_diagnostics_destination(path: &Path) -> Result<&Path, String> {
    let path_text = path
        .to_str()
        .ok_or_else(|| "Diagnostics destination must be valid UTF-8.".to_string())?;
    if !path.is_absolute()
        || path_text.len() > DIAGNOSTICS_DESTINATION_MAX_BYTES
        || path_text.chars().any(char::is_control)
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err("Diagnostics destination path is unsafe.".to_string());
    }
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Diagnostics destination must name a JSON file.".to_string())?;
    let stem = filename.strip_suffix(".json").unwrap_or_default();
    if stem.is_empty()
        || filename.len() > 128
        || !stem
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphanumeric())
        || !stem
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err("Diagnostics destination must use a safe .json filename.".to_string());
    }
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| "Diagnostics destination has no parent directory.".to_string())?;
    let parent_metadata = fs::symlink_metadata(parent)
        .map_err(|_| "Diagnostics destination directory is unavailable.".to_string())?;
    if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
        return Err("Diagnostics destination directory must be a real directory.".to_string());
    }
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || metadata.is_dir() {
            return Err("Diagnostics destination must be a regular file.".to_string());
        }
    }
    Ok(parent)
}

/// Writes a user-selected JSON bundle with the same owner-only, atomic file
/// contract as the private support-directory export. The destination comes
/// from the native save dialog, but is still validated at the Rust boundary.
fn write_diagnostics_json_at(path: &Path, json: &[u8]) -> Result<PathBuf, String> {
    let parent = validate_diagnostics_destination(path)?;
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Diagnostics destination must name a JSON file.".to_string())?;
    let partial = parent.join(format!(
        ".{filename}.{}.partial",
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&partial)
            .map_err(|e| e.to_string())?;
        file.write_all(json).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        fs::set_permissions(&partial, fs::Permissions::from_mode(0o600))
            .map_err(|e| e.to_string())?;
        drop(file);
        // `rename` replaces an existing regular file atomically, while never
        // following a symlink at the destination.
        fs::rename(&partial, path).map_err(|e| e.to_string())?;
        Ok(path.to_path_buf())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&partial);
    }
    result
}

// Writes a JSON bundle to a user-selected native destination. Redaction is
// structural: this command only persists shell/health/package/runtime/renderer
// metadata — it never reads provider payloads, tokens, socket auth material,
// socket paths, or raw daemon errors. A private temporary file plus atomic
// rename prevents a crash from leaving a partial bundle that support could
// accidentally share.
#[tauri::command]
async fn export_diagnostics(app: AppHandle) -> Result<serde_json::Value, String> {
    let suggested_dir = linux_support_dir();
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut dialog = app
        .dialog()
        .file()
        .set_title("Save redacted diagnostics")
        .set_file_name(format!("openburnbar-diagnostics-{stamp}.json"))
        .add_filter("OpenBurnBar diagnostics", &["json"])
        .set_can_create_directories(false);
    if suggested_dir.is_dir() {
        dialog = dialog.set_directory(suggested_dir);
    }
    let destination = dialog
        .blocking_save_file()
        .ok_or_else(|| "Diagnostics export cancelled.".to_string())?
        .into_path()
        .map_err(|_| "Native diagnostics export returned an invalid path.".to_string())?;
    validate_diagnostics_destination(&destination)?;

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let health = probe_daemon_health();
    let package = detect_linux_package_facts();
    let runtime = linux_runtime_facts();
    let bundle = diagnostics_bundle(stamp, &health, &package, &runtime);
    let json = serde_json::to_string_pretty(&bundle).map_err(|e| e.to_string())?;
    let preview = diagnostics_preview(json.len());
    let path = write_diagnostics_json_at(&destination, json.as_bytes())?;
    Ok(serde_json::json!({
        "path": path.display().to_string(),
        "preview": preview
    }))
}

// ───────────────── P29: text expansion storage ─────────────────
// The renderer reaches the daemon-owned encrypted store through the existing
// authenticated AF_UNIX bridge. No snippet or consent file is persisted by the
// Tauri process.
#[tauri::command]
fn text_expansion_list() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.get", None)
}

#[tauri::command]
fn text_expansion_upsert(snippet: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.text_expansion.upsert",
        Some(serde_json::json!({ "snippet": snippet })),
    )
}

#[tauri::command]
fn text_expansion_delete(id: String) -> Result<serde_json::Value, String> {
    call_daemon_method(
        "daemon.text_expansion.delete",
        Some(serde_json::json!({ "id": id })),
    )
}

#[tauri::command]
fn text_expansion_consent_update(consent: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.consent.update", Some(consent))
}

#[tauri::command]
fn text_expansion_engine_status() -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.engine.status", None)
}

#[tauri::command]
fn text_expansion_engine_start(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.engine.start", Some(request))
}

#[tauri::command]
fn text_expansion_engine_stop(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.engine.stop", Some(request))
}

#[tauri::command]
fn text_expansion_engine_expand(request: serde_json::Value) -> Result<serde_json::Value, String> {
    call_daemon_method("daemon.text_expansion.engine.expand", Some(request))
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

// ───────────────── P30: native pet companion window ─────────────────
//
// Tauri's transparent/always-on-top WebView window is a real native window,
// but Linux only has a predictable input-pass-through contract on X11. Keep
// this probe stricter than the runtime capability catalog: a DISPLAY is
// required before the renderer may offer the native companion action. Wayland
// and unknown sessions stay on the contained, draggable route.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PetCompanionStatus {
    state: String,
    compositor: String,
    session_type: Option<String>,
    desktop: Option<String>,
    overlay_supported: bool,
    click_through_supported: bool,
    window_contract: String,
    reason: String,
    source: String,
}

fn pet_companion_status_for_env(
    session_type: Option<&str>,
    desktop: Option<&str>,
    display: Option<&str>,
) -> PetCompanionStatus {
    let normalized_session = session_type
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_ascii_lowercase);
    let normalized_desktop = desktop
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let display_available = display
        .map(str::trim)
        .is_some_and(|value| !value.is_empty());
    let compositor = format!(
        "{}/{}",
        normalized_desktop.as_deref().unwrap_or("unknown"),
        normalized_session.as_deref().unwrap_or("unknown")
    );

    if normalized_session.as_deref() == Some("x11") && display_available {
        return PetCompanionStatus {
            state: "available".to_string(),
            compositor,
            session_type: normalized_session,
            desktop: normalized_desktop,
            overlay_supported: true,
            click_through_supported: true,
            window_contract: "tauri-x11-companion-v1".to_string(),
            reason: "X11 and DISPLAY are present; Tauri can create the constrained companion window and set input pass-through explicitly.".to_string(),
            source: "tauri-x11-companion-window".to_string(),
        };
    }

    let (state, reason) = match normalized_session.as_deref() {
        Some("wayland") => (
            "degraded",
            "Wayland does not provide a verified cross-compositor click-through contract; use the contained draggable companion window.",
        ),
        Some("x11") => (
            "degraded",
            "The X11 session has no DISPLAY value, so the native companion window is disabled.",
        ),
        _ => (
            "unavailable",
            "The desktop session is unknown, so native companion-window behavior is disabled.",
        ),
    };
    PetCompanionStatus {
        state: state.to_string(),
        compositor,
        session_type: normalized_session,
        desktop: normalized_desktop,
        overlay_supported: false,
        click_through_supported: false,
        window_contract: "none".to_string(),
        reason: reason.to_string(),
        source: "desktop-session-probe".to_string(),
    }
}

#[tauri::command]
fn pet_companion_status() -> PetCompanionStatus {
    pet_companion_status_for_env(
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var("XDG_CURRENT_DESKTOP").ok().as_deref(),
        std::env::var("DISPLAY").ok().as_deref(),
    )
}

// ───────────────── P12: Mercury media ─────────────────
#[tauri::command]
fn media_status() -> Result<serde_json::Value, String> {
    let mut status = call_daemon_method("daemon.media.status", Some(serde_json::json!({})))?;
    let viewer_capability = serde_json::to_value(media::MediaViewer::capability())
        .map_err(|error| format!("media_viewer_capability_encode_failed:{error}"))?;
    let Some(object) = status.as_object_mut() else {
        return Err("media_status_invalid_payload".to_string());
    };
    // Keep the daemon capability and shell-local rendering capability in one
    // typed response. The daemon can capture frames even when this process
    // cannot decode or display them.
    object.insert("viewerCapability".to_string(), viewer_capability);
    Ok(status)
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

/// Return shell-local Mercury viewer capability without asking the daemon to
/// infer whether this process can actually render a VP9 screen-share frame.
#[tauri::command]
fn media_viewer_capability_get() -> Result<serde_json::Value, String> {
    serde_json::to_value(media::MediaViewer::capability())
        .map_err(|error| format!("media_viewer_capability_encode_failed:{error}"))
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
                        if !capability_absent && daemon_method_is_capability_absent(&error) {
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
// Wire: review transitions → daemon.memory.review_status,
// remember/quarantine → daemon.memory.remember, forget → daemon.memory.forget,
// audit → daemon.memory.audit_trail. New-memory approve still requires
// non-empty text/body (fail-closed; never invent placeholder text).
#[tauri::command]
fn memory_set_status(
    action: String,
    payload: serde_json::Value,
) -> Result<serde_json::Value, String> {
    match action.as_str() {
        "approve" | "remember" => {
            if let Some(memory_id) = payload
                .get("memoryID")
                .or_else(|| payload.get("memoryId"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                return call_daemon_method(
                    "daemon.memory.review_status",
                    Some(serde_json::json!({
                        "memoryID": memory_id,
                        "projectPath": payload.get("projectPath").cloned().unwrap_or(serde_json::Value::Null),
                        "status": "approved"
                    })),
                );
            }
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
                    "sourcePath": payload.get("sourcePath").cloned().unwrap_or(serde_json::Value::Null),
                    "reviewStatus": "approved"
                })),
            )
        }
        "quarantine" => {
            let text = payload
                .get("text")
                .and_then(|v| v.as_str())
                .or_else(|| payload.get("body").and_then(|v| v.as_str()))
                .unwrap_or("")
                .trim()
                .to_string();
            if text.is_empty() {
                return Err("memory quarantine requires non-empty text/body".into());
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
                    "sourcePath": payload.get("sourcePath").cloned().unwrap_or(serde_json::Value::Null),
                    "reviewStatus": "quarantined"
                })),
            )
        }
        "reject" => {
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
                "daemon.memory.review_status",
                Some(serde_json::json!({
                    "memoryID": memory_id,
                    "projectPath": payload.get("projectPath").cloned().unwrap_or(serde_json::Value::Null),
                    "status": "rejected"
                })),
            )
        }
        "forget" => {
            let memory_id = payload
                .get("memoryID")
                .or_else(|| payload.get("memoryId"))
                .or_else(|| payload.get("id"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if memory_id.is_empty() {
                return Err("memory forget requires memoryID".into());
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
            "memory_set_status action must be approve|quarantine|reject|forget|audit (or remember), got {other}"
        )),
    }
}

// ───────────────── Computer Use wrappers ─────────────────
// Wire bodies MUST match BurnBarComputerUseContracts.swift exactly.
// Params are typed allowlisted structs (deny_unknown_fields).
