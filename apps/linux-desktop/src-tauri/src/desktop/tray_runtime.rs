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

/// Format the daemon's authoritative all-time ledger projection for the native
/// tray. Recent usage rows are intentionally ignored because they are bounded.
fn tray_usage_text(value: &serde_json::Value) -> String {
    let Some(totals) = value
        .get("projection")
        .and_then(|projection| projection.get("totals"))
    else {
        return "Usage: unavailable".to_string();
    };
    let Some(tokens) = tray_number(totals, &["totalTokens"]) else {
        return "Usage: unavailable".to_string();
    };
    let Some(cost) = tray_number(totals, &["cost"]) else {
        return "Usage: unavailable".to_string();
    };
    format!(
        "Usage: {} tokens - ${:.2}",
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

fn tray_daemon_status_text(health: &DaemonHealth) -> String {
    if health.ok {
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
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TrayReconnectHandlerAck {
    schema_version: u32,
    action: &'static str,
    handler_event_id: String,
    daemon_health_request_id: String,
    status_item_logical_id: &'static str,
    handler_started_epoch_ms: u64,
    handler_completed_epoch_ms: u64,
    daemon_connected: bool,
    status_update_succeeded: bool,
    status_label: String,
}

fn unix_epoch_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

fn append_tray_reconnect_handler_ack(
    output_dir: &Path,
    ack: &TrayReconnectHandlerAck,
) -> Result<(), String> {
    fs::create_dir_all(output_dir).map_err(|error| error.to_string())?;
    let path = output_dir.join("tray-reconnect-handler-acks.jsonl");
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|error| error.to_string())?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())?;
    let mut line = serde_json::to_vec(ack).map_err(|error| error.to_string())?;
    line.push(b'\n');
    file.write_all(&line).map_err(|error| error.to_string())?;
    file.sync_data().map_err(|error| error.to_string())
}

fn record_tray_reconnect_handler_ack(ack: &TrayReconnectHandlerAck) {
    let Some(output_dir) = std::env::var_os("OPENBURNBAR_EVIDENCE_OUT")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
    else {
        return;
    };
    if let Err(error) = append_tray_reconnect_handler_ack(&output_dir, ack) {
        tracing::error!(
            event = "tray_reconnect_handler_ack_failed",
            %error,
            path = %output_dir.display()
        );
    }
}

fn emit_tray_route(app: &AppHandle, route: &str) {
    let _ = open_dashboard(app.clone());
    let _ = app.emit("tray-route", route.to_string());
}

fn tray_route_for_menu_id(id: &str) -> Option<&'static str> {
    match id {
        "open" | "summary" => Some("overview"),
        "providers" | "quick-switch" => Some("providers"),
        "chat" => Some("chat"),
        "mercury" => Some("mercury"),
        "usage" => Some("insights"),
        "updates" => Some("updates"),
        "settings" => Some("settings"),
        _ => None,
    }
}

const TRAY_STATUS_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

fn try_begin_tray_refresh(gate: &AtomicBool) -> bool {
    gate.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_ok()
}

struct TrayRefreshGuard(Arc<AtomicBool>);

impl Drop for TrayRefreshGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

async fn refresh_tray_status_items_async(
    status_item: MenuItem<tauri::Wry>,
    usage_item: MenuItem<tauri::Wry>,
    update_item: MenuItem<tauri::Wry>,
    gate: Arc<AtomicBool>,
) {
    if !try_begin_tray_refresh(&gate) {
        return;
    }
    let _refresh_guard = TrayRefreshGuard(gate);

    let health = tauri::async_runtime::spawn_blocking(probe_daemon_health)
        .await
        .unwrap_or_default();
    let _ = status_item.set_text(tray_daemon_status_text(&health));

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
}

fn refresh_tray_status_items(
    status_item: MenuItem<tauri::Wry>,
    usage_item: MenuItem<tauri::Wry>,
    update_item: MenuItem<tauri::Wry>,
    gate: Arc<AtomicBool>,
) {
    tauri::async_runtime::spawn(refresh_tray_status_items_async(
        status_item,
        usage_item,
        update_item,
        gate,
    ));
}

fn start_tray_status_refresh_loop(
    status_item: MenuItem<tauri::Wry>,
    usage_item: MenuItem<tauri::Wry>,
    update_item: MenuItem<tauri::Wry>,
    gate: Arc<AtomicBool>,
) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(TRAY_STATUS_REFRESH_INTERVAL).await;
            refresh_tray_status_items_async(
                status_item.clone(),
                usage_item.clone(),
                update_item.clone(),
                gate.clone(),
            )
            .await;
        }
    });
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open_i = MenuItemBuilder::with_id("open", "Open dashboard").build(app)?;
    let summary_i = MenuItemBuilder::with_id("summary", "Summary").build(app)?;
    let providers_i = MenuItemBuilder::with_id("providers", "Providers").build(app)?;
    let chat_i = MenuItemBuilder::with_id("chat", "Open chat").build(app)?;
    let mercury_i = MenuItemBuilder::with_id("mercury", "Mercury").build(app)?;
    let quick_switch_i = MenuItemBuilder::with_id("quick-switch", "Quick Switch").build(app)?;
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
        .items(&[
            &open_i,
            &summary_i,
            &providers_i,
            &chat_i,
            &mercury_i,
            &quick_switch_i,
            &usage_i,
            &updates_i,
            &settings_i,
        ])
        .separator()
        .items(&[&status_i, &recent_usage_i, &update_state_i])
        .separator()
        .items(&[&refresh_i, &health_i, &quit_i])
        .build()?;

    let status_for_events = status_i.clone();
    let usage_for_events = recent_usage_i.clone();
    let update_for_events = update_state_i.clone();
    let tray_refresh_gate = Arc::new(AtomicBool::new(false));
    refresh_tray_status_items(
        status_i.clone(),
        recent_usage_i.clone(),
        update_state_i.clone(),
        tray_refresh_gate.clone(),
    );
    let status_for_loop = status_i.clone();
    let usage_for_loop = recent_usage_i.clone();
    let update_for_loop = update_state_i.clone();
    let gate_for_events = tray_refresh_gate.clone();

    let _tray = TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("OpenBurnBar — Linux desktop assistant")
        .on_menu_event(move |app, event| match event.id.as_ref() {
            id if tray_route_for_menu_id(id).is_some() => {
                // Quick Switch is the Linux-native equivalent of the macOS
                // provider/model switcher entry; the provider workspace owns
                // the picker and keeps route validation centralized.
                emit_tray_route(app, tray_route_for_menu_id(id).unwrap())
            }
            "refresh" => refresh_tray_status_items(
                status_for_events.clone(),
                usage_for_events.clone(),
                update_for_events.clone(),
                gate_for_events.clone(),
            ),
            "health" => {
                let handler_started_epoch_ms = unix_epoch_millis();
                let handler_event_id =
                    format!("tray-health-{}", uuid::Uuid::new_v4().simple());
                if let Err(error) = status_for_events.set_text("Daemon: reconnecting...") {
                    tracing::warn!(
                        event = "tray_reconnect_pending_status_update_failed",
                        %error
                    );
                }
                let (health, daemon_health_request_id) =
                    probe_daemon_health_with_receipt(Duration::from_secs(5), false);
                let status_label = tray_daemon_status_text(&health);
                let status_update_succeeded =
                    match status_for_events.set_text(status_label.clone()) {
                        Ok(()) => true,
                        Err(error) => {
                            tracing::error!(
                                event = "tray_reconnect_final_status_update_failed",
                                %error
                            );
                            false
                        }
                    };
                let handler_completed_epoch_ms = unix_epoch_millis();
                record_tray_reconnect_handler_ack(&TrayReconnectHandlerAck {
                    schema_version: 1,
                    action: "reconnect-daemon",
                    handler_event_id,
                    daemon_health_request_id,
                    status_item_logical_id: "status",
                    handler_started_epoch_ms,
                    handler_completed_epoch_ms,
                    daemon_connected: health.ok,
                    status_update_succeeded,
                    status_label,
                });
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
                emit_tray_route(app, "overview");
            }
        })
        .build(app)?;
    start_tray_status_refresh_loop(
        status_for_loop,
        usage_for_loop,
        update_for_loop,
        tray_refresh_gate,
    );
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

/// Decide whether WebKit should use its software rendering path.
///
/// Linux package sessions can be launched from a display manager before a
/// DRM render node exists (and Xvfb/UTM sessions never expose one). In that
/// state WebKitGTK may create a GBM context, fail, and leave a blank surface
/// while its fallback is negotiated. Keep the decision deterministic and
/// overrideable for GPU hosts that need to diagnose a compositor issue.
fn should_enable_webkit_safe_mode(
    drm_render_node_present: bool,
    explicit_override: Option<&str>,
) -> bool {
    match explicit_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
        .as_deref()
    {
        Some("1") | Some("true") | Some("yes") | Some("on") => true,
        Some("0") | Some("false") | Some("no") | Some("off") => false,
        _ => !drm_render_node_present,
    }
}

fn linux_drm_render_node_present() -> bool {
    fs::read_dir("/dev/dri")
        .map(|entries| {
            entries.flatten().any(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with("renderD"))
            })
        })
        .unwrap_or(false)
}

/// Configure WebKitGTK before Tauri creates its first window.
///
/// Existing environment values always win. The package-safe mode is only
/// selected automatically when the host has no DRM render node, so ordinary
/// Linux GPU sessions retain native compositing and DMABUF performance.
fn configure_linux_webkit_runtime() {
    if !cfg!(target_os = "linux") {
        return;
    }
    let explicit_override = std::env::var("OPENBURNBAR_WEBKIT_SAFE_MODE").ok();
    if !should_enable_webkit_safe_mode(
        linux_drm_render_node_present(),
        explicit_override.as_deref(),
    ) {
        return;
    }

    if std::env::var_os("WEBKIT_DISABLE_COMPOSITING_MODE").is_none() {
        std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
    }
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

fn should_start_in_background(args: &[String]) -> bool {
    args.iter().any(|arg| arg == "--background")
}

fn should_hide_startup_window(start_in_background: bool, tray_ready: bool) -> bool {
    start_in_background && tray_ready
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let start_in_background = should_start_in_background(&args);
    configure_linux_webkit_runtime();
    let initial_route = args.iter().find_map(|arg| validated_deep_link_route(arg));
    store_initial_deep_link_route(initial_route);

    // Fast-exit CLI flags before booting the GUI: a GTK/WebKit app launched
    // headless (packaging smoke, CI) would otherwise spin forever on `--version`.
    for arg in &args {
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
                    "OpenBurnBar Linux desktop shell\n\nUsage: openburnbar-linux-desktop [--background] [--version] [--daemon-health] [--help]"
                );
                std::process::exit(0);
            }
            _ => {}
        }
    }

    let startup_messages = match single_instance::startup_messages_from_args(
        args.clone().into_iter(),
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

    let sentry_guard = match crate::observability::initialize() {
        Ok(guard) => guard,
        Err(error) => {
            eprintln!("openburnbar: refusing startup: {error}");
            return;
        }
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            daemon_health,
            runtime_capabilities,
            gateway_probe,
            gateway_attachment_capability,
            chat_attachment_upload,
            gateway_chat_stream,
            gateway_chat_cancel,
            open_external_url,
            open_inbox_external_url,
            open_update_url,
            open_dashboard,
            initial_deep_link_route,
            forwarded_deep_link_route,
            initial_notification_actions,
            quit_app,
            launch_at_login_status,
            launch_at_login_set,
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
            session_history,
            session_search,
            session_replay,
            session_resume,
            chat_thread_list,
            chat_thread_get,
            chat_message_append,
            inbox_list,
            inbox_get,
            inbox_presentation_list,
            inbox_presentation_get,
            inbox_presentation_mutate,
            inbox_presentation_mark_all_read,
            inbox_runs_recent,
            inbox_config_get,
            inbox_config_update,
            inbox_run_now,
            inbox_thread_get,
            inbox_reply,
            inbox_plans_list,
            inbox_plans_get,
            inbox_plans_accept,
            inbox_plans_update_step,
            inbox_plans_grade,
            inbox_memory_candidate_approve,
            inbox_plans_remember_step,
            inbox_plans_create_followup,
            inbox_memory_export,
            usage_insights,
            mission_list,
            mission_get,
            mission_health,
            mission_resume,
            question_list,
            question_answer,
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
            linux_privacy_inventory,
            linux_privacy_deletion_preview,
            linux_privacy_deletion_execute,
            linux_privacy_export,
            pick_export_destination,
            linux_privacy_retention_status,
            linux_privacy_retention_apply,
            notification_config_get,
            notification_config_update,
            notification_health,
            notification_command,
            super::native_notifications::native_notification_capabilities,
            super::native_notifications::native_notification_show,
            native_shortcut_status,
            db_status,
            project_list,
            project_get,
            project_upsert,
            project_delete,
            project_reassign,
            project_history,
            memory_boundaries,
            memory_review_inbox,
            memory_forget,
            database_workspace_status,
            database_index_project,
            database_watch_project,
            database_snapshot,
            database_restore,
            pick_database_snapshot_path,
            database_code_search,
            database_code_context_pack,
            database_recovery_bundle_status,
            database_recovery_bundle_export,
            database_recovery_bundle_import,
            pick_recovery_bundle_destination,
            account_status,
            trusted_device_list,
            trusted_device_approve,
            trusted_device_revoke,
            account_export_cloud_data,
            account_delete_cloud_data,
            account_begin_sign_in,
            account_cancel_sign_in,
            account_rotate_identity,
            account_sign_out,
            membership_status,
            membership_checkout_url,
            membership_portal_url,
            membership_restore,
            app_version_info,
            update_status,
            desktop_wallpaper_status,
            desktop_wallpaper_apply,
            desktop_wallpaper_restore,
            export_diagnostics,
            text_expansion_list,
            text_expansion_upsert,
            text_expansion_delete,
            text_expansion_consent_update,
            text_expansion_engine_status,
            text_expansion_engine_start,
            text_expansion_engine_stop,
            text_expansion_engine_expand,
            linux_cloud_sync_status,
            linux_cloud_sync_policy_update,
            linux_cloud_sync_run,
            session_env,
            pet_companion_status,
            pet_asset_read,
            pet_atlas_read,
            media_status,
            media_session_state,
            media_accept_call,
            media_decline_call,
            media_end_call,
            media_capability_get,
            media_viewer_capability_get,
            media_file_offer_list,
            media_file_accept,
            media_file_decline,
            media_file_send,
            pick_media_file,
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
            smarthub_command,
            smarthub_cancel
        ])
        .setup(move |app| {
            app.manage(instance_guard);
            app.manage(sentry_guard);
            start_single_instance_dispatcher(app.handle().clone(), instance_receiver);
            start_packaged_daemon_lifecycle(app.handle().clone());
            let tray_ready = match build_tray(app.handle()) {
                Ok(()) => true,
                Err(error) => {
                    TRAY_INIT_FAILED.store(true, Ordering::Relaxed);
                    eprintln!("tray init degraded: {error}");
                    false
                }
            };
            if should_hide_startup_window(start_in_background, tray_ready) {
                if let Some(window) = app.get_webview_window("main") {
                    if let Err(error) = window.hide() {
                        eprintln!("openburnbar: background startup hide failed: {error}");
                    }
                }
            }
            // Install the global-shortcut manager without a batch of initial
            // bindings. Each binding is registered independently below so a
            // dashboard conflict cannot disable both Computer Use panic paths.
            let app_handle = app.handle().clone();
            if let Err(error) =
                app_handle.plugin(tauri_plugin_global_shortcut::Builder::new().build())
            {
                let reason = format!(
                    "native_shortcuts_plugin_install_failed:{}",
                    bounded_shortcut_error(error)
                );
                eprintln!("computer_use_global_panic_hotkey_degraded: {reason}");
                set_native_shortcut_unavailable(native_shortcut_backend(), reason);
            } else {
                register_computer_use_panic_shortcuts(&app_handle);
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
