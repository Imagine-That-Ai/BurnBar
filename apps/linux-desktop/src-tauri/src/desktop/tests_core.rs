    static COMPUTER_USE_BROKER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    fn valid_google_pkce_url() -> String {
        format!(
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=123456789012-desktop.apps.googleusercontent.com&response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152%2Fcallback&code_challenge={}&code_challenge_method=S256&state={}&scope=openid%20email%20profile",
            "c".repeat(43),
            "s".repeat(43)
        )
    }

    struct AutostartTestRoot(PathBuf);

    impl std::ops::Deref for AutostartTestRoot {
        type Target = Path;

        fn deref(&self) -> &Self::Target {
            &self.0
        }
    }

    impl Drop for AutostartTestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn autostart_test_root() -> AutostartTestRoot {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-autostart-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(root.join("autostart")).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::set_permissions(root.join("autostart"), fs::Permissions::from_mode(0o700)).unwrap();
        AutostartTestRoot(root)
    }

    fn write_autostart_test_file(path: &Path, content: &str, mode: u32) {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(path)
            .unwrap();
        file.write_all(content.as_bytes()).unwrap();
        file.sync_all().unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn launch_at_login_template_only_toggles_native_enable_keys() {
        let disabled = render_autostart_entry(PACKAGED_AUTOSTART_TEMPLATE, false).unwrap();
        assert_eq!(autostart_exec(&disabled).unwrap(), PACKAGED_AUTOSTART_EXEC);
        assert!(!autostart_enabled(&disabled).unwrap());
        assert!(disabled.lines().any(|line| line == "Hidden=true"));

        let enabled = render_autostart_entry(&disabled, true).unwrap();
        assert_eq!(autostart_exec(&enabled).unwrap(), PACKAGED_AUTOSTART_EXEC);
        assert!(autostart_enabled(&enabled).unwrap());
        assert!(!enabled.lines().any(|line| line == "Hidden=true"));
    }

    #[test]
    fn tray_navigation_entries_resolve_to_registered_shell_routes() {
        let expected = [
            ("open", "overview"),
            ("summary", "overview"),
            ("providers", "providers"),
            ("quick-switch", "providers"),
            ("chat", "chat"),
            ("mercury", "mercury"),
            ("usage", "insights"),
            ("updates", "updates"),
            ("settings", "settings"),
        ];

        for (menu_id, route) in expected {
            assert_eq!(tray_route_for_menu_id(menu_id), Some(route));
        }
        assert_eq!(tray_route_for_menu_id("refresh"), None);
        assert_eq!(tray_route_for_menu_id("quit"), None);
    }

    #[test]
    fn export_destination_specs_are_allowlisted_and_extension_specific() {
        let privacy = export_destination_dialog_spec(ExportDestinationKind::LinuxPrivacy);
        assert_eq!(privacy.file_name, "openburnbar-privacy-export.obb");
        assert_eq!(privacy.extension, "obb");
        let account = export_destination_dialog_spec(ExportDestinationKind::AccountCloud);
        assert_eq!(account.file_name, "openburnbar-account-export.json");
        assert_eq!(account.extension, "json");

        let root = std::env::temp_dir().join(format!(
            "openburnbar-export-destination-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&root).unwrap();
        assert!(validate_export_destination(&root.join("privacy.obb"), ExportDestinationKind::LinuxPrivacy).is_ok());
        assert!(validate_export_destination(&root.join("account.json"), ExportDestinationKind::AccountCloud).is_ok());
        assert!(validate_export_destination(&root.join("privacy.json"), ExportDestinationKind::LinuxPrivacy).is_err());
        assert!(validate_export_destination(&root.join("account.obb"), ExportDestinationKind::AccountCloud).is_err());
        assert!(validate_export_destination(&root.join("../account.json"), ExportDestinationKind::AccountCloud).is_err());
        assert!(validate_export_destination(&root.join(".account.json"), ExportDestinationKind::AccountCloud).is_err());
        assert!(validate_export_destination(&root.join("account name.json"), ExportDestinationKind::AccountCloud).is_err());
        assert!(validate_export_destination(
            Path::new("/tmp/openburnbar-account-export.json"),
            ExportDestinationKind::AccountCloud
        ).is_ok());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn recovery_bundle_picker_validates_safe_obb_paths() {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-recovery-picker-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&root).unwrap();
        assert!(validate_recovery_bundle_picker_path(&root.join("backup.obb")).is_ok());
        assert!(validate_recovery_bundle_picker_path(&root.join("backup.json")).is_err());
        assert!(validate_recovery_bundle_picker_path(&root.join("backup name.obb")).is_err());
        assert!(validate_recovery_bundle_picker_path(&root.join("../backup.obb")).is_err());
        assert!(validate_recovery_bundle_picker_path(&root.join(".backup.obb")).is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn launch_at_login_uses_embedded_template_when_packaged_entry_is_missing() {
        let root = autostart_test_root();
        let user_path = root.join("autostart/openburnbar.desktop");
        let missing_packaged_path = root.join("missing/openburnbar.desktop");

        let packaged = packaged_autostart_content(&missing_packaged_path).unwrap();
        assert_eq!(packaged, PACKAGED_AUTOSTART_TEMPLATE);
        let rendered = render_autostart_entry(&packaged, true).unwrap();
        write_autostart_test_file(&user_path, &rendered, 0o600);

        let status = launch_at_login_status_with_paths(&user_path, &missing_packaged_path).unwrap();
        assert!(status.enabled);
        assert!(status.user_override);
        assert_eq!(status.source, "user");
    }

    #[test]
    fn launch_at_login_rejects_arbitrary_exec_and_unsafe_paths() {
        let arbitrary = PACKAGED_AUTOSTART_TEMPLATE.replace(
            "Exec=openburnbar-linux-desktop --background",
            "Exec=/tmp/attacker --shell",
        );
        assert!(render_autostart_entry(&arbitrary, true).is_err());
        assert!(validate_safe_absolute_path(Path::new("../.config"), "home").is_err());
        assert!(validate_safe_absolute_path(Path::new("relative/.config"), "home").is_err());
    }

    #[test]
    fn account_export_request_validation_is_bounded_and_allows_all_domains() {
        assert!(validate_account_export_request(&serde_json::json!({
            "destinationPath": "/tmp/account-export.json"
        })).is_ok());
        assert!(validate_account_export_request(&serde_json::json!({
            "destinationPath": "/tmp/account-export.json",
            "domains": []
        })).is_ok());
        assert!(validate_account_export_request(&serde_json::json!({
            "destinationPath": "/tmp/account-export.json",
            "domains": ["usage_spend", "devices"]
        })).is_ok());
        for request in [
            serde_json::json!({"destinationPath": "relative.json"}),
            serde_json::json!({"destinationPath": "/tmp/account.json "}),
            serde_json::json!({"destinationPath": "/tmp/account.json", "domains": [null]}),
            serde_json::json!({"destinationPath": "/tmp/account.json", "domains": [" usage_spend"]}),
            serde_json::json!({"destinationPath": "/tmp/account.json", "domains": (0..25).map(|i| format!("domain_{i}")).collect::<Vec<_>>()})
        ] {
            assert!(validate_account_export_request(&request).is_err(), "request should be rejected: {request}");
        }
    }

    #[test]
    fn launch_at_login_status_prefers_owner_checked_user_override() {
        let root = autostart_test_root();
        let user_path = root.join("autostart/openburnbar.desktop");
        let packaged_path = root.join("packaged.desktop");
        write_autostart_test_file(&packaged_path, PACKAGED_AUTOSTART_TEMPLATE, 0o644);

        let packaged = launch_at_login_status_with_paths(&user_path, &packaged_path).unwrap();
        assert!(packaged.enabled);
        assert!(!packaged.user_override);
        assert_eq!(packaged.source, "packaged");

        let disabled = render_autostart_entry(PACKAGED_AUTOSTART_TEMPLATE, false).unwrap();
        write_autostart_test_file(&user_path, &disabled, 0o600);
        let user = launch_at_login_status_with_paths(&user_path, &packaged_path).unwrap();
        assert!(!user.enabled);
        assert!(user.user_override);
        assert_eq!(user.source, "user");

        let metadata = fs::metadata(&user_path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn launch_at_login_atomic_write_rejects_symlink_destination() {
        let root = autostart_test_root();
        let target = root.join("target.desktop");
        write_autostart_test_file(&target, PACKAGED_AUTOSTART_TEMPLATE, 0o600);
        let link = root.join("autostart/openburnbar.desktop");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let content = render_autostart_entry(PACKAGED_AUTOSTART_TEMPLATE, false).unwrap();
        assert_eq!(
            write_autostart_entry(&link, content.as_bytes()).unwrap_err(),
            "autostart_entry_unsafe"
        );
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
    fn membership_rpc_uses_canonical_names_and_degrades_unsupported_methods() {
        assert_eq!(MEMBERSHIP_STATUS_METHOD, "daemon.membership.status");
        assert_eq!(MEMBERSHIP_CHECKOUT_METHOD, "daemon.membership.checkoutUrl");
        assert_eq!(MEMBERSHIP_PORTAL_METHOD, "daemon.membership.portalUrl");
        assert_eq!(MEMBERSHIP_RESTORE_METHOD, "daemon.membership.restore");

        let unsupported =
            "Unsupported OpenBurnBar RPC method 'daemon.membership.status'.".to_string();
        assert!(daemon_method_is_capability_absent(&unsupported));
        assert_eq!(
            membership_rpc_error(unsupported),
            "membership_capability_absent"
        );

        let not_found = "RPC method not found: daemon.membership.restore".to_string();
        assert_eq!(
            membership_rpc_error(not_found),
            "membership_capability_absent"
        );

        let actionable = "Membership checkout requires a connected account.".to_string();
        assert!(!daemon_method_is_capability_absent(&actionable));
        assert_eq!(membership_rpc_error(actionable.clone()), actionable);

        let account_error = "Membership tier is unsupported for this account.".to_string();
        assert!(!daemon_method_is_capability_absent(&account_error));
        assert_eq!(membership_rpc_error(account_error.clone()), account_error);
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
    fn provider_catalog_wire_response_keeps_canonical_catalog_separate_from_config() {
        let response = compose_provider_catalog_response(
            serde_json::json!({"snapshot": {"providers": [{"providerID": "openai"}]}}),
            Ok(serde_json::json!({
                "catalog": {"providers": [{"id": "openai", "models": [{"id": "gpt-5.5"}]}]}
            })),
            Ok(serde_json::json!({"snapshots": [{"providerID": "openai", "buckets": []}]})),
        );

        assert_eq!(response["catalogAvailable"], serde_json::Value::Bool(true));
        assert_eq!(
            response["config"]["snapshot"]["providers"][0]["providerID"],
            "openai"
        );
        assert_eq!(
            response["catalog"]["catalog"]["providers"][0]["models"][0]["id"],
            "gpt-5.5"
        );
        assert!(response.get("catalogError").is_none());
        assert_eq!(response["quotaAvailable"], serde_json::Value::Bool(true));
        assert_eq!(response["quota"]["snapshots"][0]["providerID"], "openai");
    }

    #[test]
    fn provider_catalog_wire_response_preserves_config_when_catalog_is_unavailable() {
        let response = compose_provider_catalog_response(
            serde_json::json!({"snapshot": {"providers": [{"providerID": "openai"}]}}),
            Err("daemon.catalog unavailable".to_string()),
            Err("daemon quota unavailable".to_string()),
        );

        assert_eq!(response["catalogAvailable"], serde_json::Value::Bool(false));
        assert_eq!(response["catalogError"], "daemon.catalog unavailable");
        assert_eq!(
            response["config"]["snapshot"]["providers"][0]["providerID"],
            "openai"
        );
        assert!(response.get("catalog").is_none());
        assert_eq!(response["quotaAvailable"], serde_json::Value::Bool(false));
        assert_eq!(response["quotaError"], "daemon quota unavailable");
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
        assert!(!encoded.contains("socketPath"));
        assert!(!encoded.contains("/run/user/1000"));
        assert!(encoded.contains("provider API keys and credentials"));
        assert!(encoded.contains("runtime"));
        assert!(encoded.contains("renderer"));
        assert!(encoded.contains("support.diagnostics.export"));

        let preview = diagnostics_preview(encoded.len());
        assert_eq!(preview["schemaVersion"], 1);
        assert_eq!(preview["fileMode"], "0600");
        assert_eq!(preview["byteCount"], encoded.len());
        assert!(preview["included"].as_array().unwrap().len() >= 4);
        assert!(preview["excluded"].as_array().unwrap().len() >= 4);
    }

    #[test]
    fn diagnostics_versions_are_allowlisted_before_export() {
        assert_eq!(
            safe_diagnostic_version(Some("1.2.3")),
            Some("1.2.3".to_string())
        );
        assert_eq!(
            safe_diagnostic_version(Some("v1.2.3+linux")),
            Some("v1.2.3+linux".to_string())
        );
        assert_eq!(safe_diagnostic_version(Some("/tmp/secret")), None);
        assert_eq!(safe_diagnostic_version(Some("1.2.3\nsecret")), None);
        assert_eq!(safe_diagnostic_version(Some(&"x".repeat(65))), None);
    }

    #[test]
    fn diagnostics_export_uses_unique_private_atomic_files() {
        let root =
            std::env::temp_dir().join(format!("openburnbar-diagnostics-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        ensure_private_diagnostics_dir(&root).unwrap();

        let first = write_private_diagnostics_json(&root, 42, br#"{"ok":true}"#).unwrap();
        let second = write_private_diagnostics_json(&root, 42, br#"{"ok":false}"#).unwrap();
        assert_ne!(first, second);
        assert_eq!(fs::read(&first).unwrap(), br#"{"ok":true}"#);
        assert_eq!(fs::read(&second).unwrap(), br#"{"ok":false}"#);
        assert_eq!(
            fs::metadata(&first).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&second).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(fs::read_dir(&root).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".partial")));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn diagnostics_export_supports_user_selected_owner_only_destination() {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-diagnostics-destination-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).unwrap();
        let destination = root.join("support-report.json");

        let path = write_diagnostics_json_at(&destination, br#"{"ok":true}"#).unwrap();
        assert_eq!(path, destination);
        assert_eq!(fs::read(&path).unwrap(), br#"{"ok":true}"#);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(fs::read_dir(&root).unwrap().all(|entry| !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".partial")));

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn diagnostics_destination_rejects_traversal_symlinks_and_invalid_names() {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-diagnostics-destination-invalid-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir_all(&root).unwrap();
        let target = root.join("target.json");
        fs::write(&target, br#"{"secret":true}"#).unwrap();
        let link = root.join("linked.json");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        assert!(validate_diagnostics_destination(&root.join("report.json")).is_ok());
        assert!(validate_diagnostics_destination(&root.join("../report.json")).is_err());
        assert!(validate_diagnostics_destination(&root.join("report.txt")).is_err());
        assert!(validate_diagnostics_destination(&root.join(".report.json")).is_err());
        assert!(validate_diagnostics_destination(&link).is_err());
        assert!(write_diagnostics_json_at(&link, br#"{"ok":false}"#).is_err());

        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn diagnostics_export_rejects_symlinked_support_directory() {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-diagnostics-link-{}",
            uuid::Uuid::new_v4()
        ));
        let real = root.join("real");
        let link = root.join("link");
        fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let error = ensure_private_diagnostics_dir(&link).unwrap_err();
        assert!(error.contains("real directory"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn package_channel_override_is_strict_and_unknown_is_not_promoted_to_appimage() {
        assert_eq!(normalized_package_channel(" DEB "), Some("deb"));
        assert_eq!(normalized_package_channel("rpm"), Some("rpm"));
        assert_eq!(normalized_package_channel(" Arch "), Some("arch"));
        assert_eq!(normalized_package_channel("appimage"), Some("appimage"));
        assert_eq!(normalized_package_channel("flatpak"), None);
        assert_eq!(package_manager_for_channel("arch"), "pacman");
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
    fn question_answer_wire_is_bounded_and_pins_canonical_actor() {
        let (method, params) = question_answer_wire(" q-1 ", " Ship it ", Some(" option-a "))
            .expect("valid question answer");
        assert_eq!(method, "daemon.question.answer");
        assert_eq!(params["questionID"], "q-1");
        assert_eq!(params["answeredBy"], "linux-shell");
        assert_eq!(params["answer"], "Ship it");
        assert_eq!(params["selectedOptionID"], "option-a");
        assert_eq!(params["markFollowupDone"], true);
        assert!(question_answer_wire("", "answer", None).is_err());
        assert!(question_answer_wire("q-1", "   ", None).is_err());
        assert!(question_answer_wire("q-1", &"x".repeat(16_385), None).is_err());
        assert!(question_answer_wire("q-1", "answer", Some(&"x".repeat(257))).is_err());
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

        let source = include_str!("daemon_data_commands.rs");
        assert!(source.contains("daemon.chat.message.append"));
        assert!(source.contains("fn chat_message_append"));
    }

    #[test]
    fn initial_and_forwarded_deep_link_drains_have_distinct_owners() {
        let initial = Mutex::new(Some("overview".to_string()));
        let forwarded = Mutex::new(vec!["chat".to_string(), "settings".to_string()]);

        assert_eq!(
            take_initial_deep_link_route(&initial).as_deref(),
            Some("overview")
        );
        assert_eq!(take_initial_deep_link_route(&initial), None);
        assert_eq!(
            take_forwarded_deep_link_route(&forwarded).as_deref(),
            Some("chat")
        );
        assert_eq!(
            take_forwarded_deep_link_route(&forwarded).as_deref(),
            Some("settings")
        );
        assert_eq!(take_forwarded_deep_link_route(&forwarded), None);
    }

    #[test]
    fn notification_action_bootstrap_drains_bounded_queue_and_marks_renderer_ready() {
        let queue = Mutex::new(Vec::new());
        let ready = AtomicBool::new(false);
        for index in 0..(FORWARDED_NOTIFICATION_ACTION_QUEUE_MAX + 1) {
            queue_notification_action(
                &queue,
                serde_json::json!({"notificationId": format!("n-{index}")}),
            );
        }

        let pending = take_notification_actions_from(&queue, &ready);
        assert_eq!(pending.len(), FORWARDED_NOTIFICATION_ACTION_QUEUE_MAX);
        assert_eq!(pending[0]["notificationId"], "n-1");
        assert!(ready.load(Ordering::Acquire));
        assert!(take_notification_actions_from(&queue, &ready).is_empty());
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
                attachments: vec![],
            }],
        };
        assert!(validate_gateway_request(&valid).is_ok());

        let invalid_role = GatewayProxyRequest {
            request_id: "request-124".into(),
            model: "hermes".into(),
            messages: vec![GatewayProxyMessage {
                role: "developer".into(),
                content: "hello".into(),
                attachments: vec![],
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
    fn chat_attachment_policy_allows_only_bounded_text_document_types() {
        assert_eq!(
            canonical_chat_attachment_mime("notes.md", "application/octet-stream").unwrap(),
            "text/markdown"
        );
        assert_eq!(
            canonical_chat_attachment_mime("data.json", "application/json").unwrap(),
            "application/json"
        );
        assert_eq!(
            canonical_chat_attachment_mime("brief.pdf", "application/pdf").unwrap(),
            "application/pdf"
        );
        assert_eq!(
            canonical_chat_attachment_mime("notes.md", "application/pdf").unwrap_err(),
            "chat_attachment_type_mismatch"
        );
        assert_eq!(
            canonical_chat_attachment_mime("secret.exe", "application/octet-stream").unwrap_err(),
            "chat_attachment_unsupported_type"
        );
        assert!(validate_chat_attachment_file_name("../notes.md").is_err());
        assert!(validate_chat_attachment_file_name("notes/secret.md").is_err());
        assert!(validate_chat_attachment_file_name("notes\0.md").is_err());
    }

    #[test]
    fn chat_attachment_gateway_payload_is_text_only_and_consumes_private_refs() {
        let root = std::env::temp_dir().join(format!("openburnbar-chat-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let path = root.join("attachment.bin");
        fs::write(&path, b"hello from attachment").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let mut hasher = Sha256::new();
        hasher.update(b"hello from attachment");
        let sha256 = format!("{:x}", hasher.finalize());
        let id = format!("attachment-{}", uuid::Uuid::new_v4().simple());
        chat_attachments().lock().unwrap().insert(
            id.clone(),
            StoredChatAttachment {
                path: path.clone(),
                file_name: "notes.md".into(),
                mime_type: "text/markdown".into(),
                byte_size: b"hello from attachment".len(),
                sha256,
            },
        );
        let request = GatewayProxyRequest {
            request_id: "request-attachment".into(),
            model: "hermes".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "Summarize this".into(),
                attachments: vec![GatewayAttachmentReference { attachment_id: id }],
            }],
        };
        let payload = gateway_messages_payload(&request).unwrap();
        let content = payload[0]["content"].as_str().unwrap();
        assert!(content.contains("[Attachment: notes.md]"));
        assert!(content.contains("hello from attachment"));
        assert!(!content.contains(path.to_string_lossy().as_ref()));
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn chat_attachment_gateway_rejects_pdf_with_explicit_capability_error() {
        let root = std::env::temp_dir().join(format!("openburnbar-chat-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let path = root.join("attachment.bin");
        fs::write(&path, b"%PDF-1.7").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let id = format!("attachment-{}", uuid::Uuid::new_v4().simple());
        let mut hasher = Sha256::new();
        hasher.update(b"%PDF-1.7");
        chat_attachments().lock().unwrap().insert(
            id.clone(),
            StoredChatAttachment {
                path: path.clone(),
                file_name: "brief.pdf".into(),
                mime_type: "application/pdf".into(),
                byte_size: 8,
                sha256: format!("{:x}", hasher.finalize()),
            },
        );
        let request = GatewayProxyRequest {
            request_id: "request-pdf".into(),
            model: "hermes".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "Read this".into(),
                attachments: vec![GatewayAttachmentReference { attachment_id: id }],
            }],
        };
        assert_eq!(
            gateway_messages_payload(&request).unwrap_err(),
            "gateway_attachment_unsupported:application/pdf"
        );
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn chat_attachment_gateway_encodes_native_image_only_with_explicit_capability() {
        let root = std::env::temp_dir().join(format!("openburnbar-chat-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let path = root.join("attachment.bin");
        let bytes = b"png-bytes";
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let id = format!("attachment-{}", uuid::Uuid::new_v4().simple());
        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let sha256 = format!("{:x}", hasher.finalize());
        chat_attachments().lock().unwrap().insert(
            id.clone(),
            StoredChatAttachment {
                path: path.clone(),
                file_name: "photo.png".into(),
                mime_type: "image/png".into(),
                byte_size: bytes.len(),
                sha256,
            },
        );
        let request = GatewayProxyRequest {
            request_id: "request-image".into(),
            model: "vision-model".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "Inspect this".into(),
                attachments: vec![GatewayAttachmentReference { attachment_id: id }],
            }],
        };
        let without_capability = gateway_messages_payload(&request).unwrap_err();
        assert_eq!(
            without_capability,
            "gateway_attachment_unsupported:image/png"
        );
        assert!(!path.exists());

        let path = root.join("attachment-2.bin");
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let id = format!("attachment-{}", uuid::Uuid::new_v4().simple());
        chat_attachments().lock().unwrap().insert(
            id.clone(),
            StoredChatAttachment {
                path: path.clone(),
                file_name: "photo.png".into(),
                mime_type: "image/png".into(),
                byte_size: bytes.len(),
                sha256: format!("{:x}", Sha256::digest(bytes)),
            },
        );
        let request = GatewayProxyRequest {
            request_id: "request-image-supported".into(),
            model: "vision-model".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "Inspect this".into(),
                attachments: vec![GatewayAttachmentReference { attachment_id: id }],
            }],
        };
        let native = HashMap::from([("image/png".to_string(), Some(1024usize))]);
        let payload = gateway_messages_payload_with_native_mime_types(&request, &native).unwrap();
        let parts = payload[0]["content"].as_array().unwrap();
        assert_eq!(parts[0]["type"], "text");
        assert_eq!(parts[1]["type"], "image_url");
        assert_eq!(
            parts[1]["image_url"]["url"],
            format!("data:image/png;base64,{}", BASE64_STANDARD.encode(bytes))
        );
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn chat_attachment_gateway_enforces_native_model_size_limit() {
        let root = std::env::temp_dir().join(format!("openburnbar-chat-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let path = root.join("attachment.bin");
        let bytes = b"png-bytes";
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let id = format!("attachment-{}", uuid::Uuid::new_v4().simple());
        chat_attachments().lock().unwrap().insert(
            id.clone(),
            StoredChatAttachment {
                path: path.clone(),
                file_name: "photo.png".into(),
                mime_type: "image/png".into(),
                byte_size: bytes.len(),
                sha256: format!("{:x}", Sha256::digest(bytes)),
            },
        );
        let request = GatewayProxyRequest {
            request_id: "request-image-too-large".into(),
            model: "vision-model".into(),
            messages: vec![GatewayProxyMessage {
                role: "user".into(),
                content: "Inspect this".into(),
                attachments: vec![GatewayAttachmentReference { attachment_id: id }],
            }],
        };
        let native = HashMap::from([("image/png".to_string(), Some(4usize))]);
        assert_eq!(
            gateway_messages_payload_with_native_mime_types(&request, &native).unwrap_err(),
            "gateway_attachment_too_large:image/png"
        );
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn gateway_model_capability_matching_honors_modalities_and_mime_wildcards() {
        let capabilities = GatewayModelIOCapabilities {
            input_modalities: vec!["text".into(), "image".into()],
            accepted_input_mime_types: vec!["image/*".into()],
            image_max_bytes: Some(4 * 1024 * 1024),
        };
        assert_eq!(
            gateway_model_accepts_attachment("image/png", &capabilities),
            (true, Some(4 * 1024 * 1024))
        );
        assert_eq!(
            gateway_model_accepts_attachment("application/pdf", &capabilities),
            (false, None)
        );
        let pdf_capabilities = GatewayModelIOCapabilities {
            input_modalities: vec!["text".into(), "pdf".into()],
            accepted_input_mime_types: Vec::new(),
            image_max_bytes: None,
        };
        assert_eq!(
            gateway_model_accepts_attachment("application/pdf", &pdf_capabilities),
            (true, None)
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
        assert_eq!(
            validate_external_url("https://billing.stripe.com/p/session/test_123").unwrap(),
            "https://billing.stripe.com/p/session/test_123"
        );
        for refused in [
            "http://checkout.stripe.com/c/pay/cs_live_123",
            "https://checkout.stripe.com.evil.example/c/pay/cs_live_123",
            "https://user@checkout.stripe.com/c/pay/cs_live_123",
            "https://billing.stripe.com:444/p/session/member_123",
            "https://billing.stripe.com.evil.example/p/session/member_123",
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
        let source = include_str!("daemon_runtime.rs");
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
            smart_hub_cli_args("test").unwrap(),
            &["devices", "iot", "smarthub", "status", "--json"]
        );
        assert_eq!(
            smart_hub_cli_args("cast").unwrap(),
            &["devices", "iot", "cast", "status", "--json"]
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
        assert_eq!(
            smart_hub_cli_args("device").unwrap(),
            &["devices", "pixel-clock", "control", "--json"]
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
    fn smarthub_request_validation_rejects_injection_and_bounds_payloads() {
        assert_eq!(
            validate_smart_hub_operation("status --json".to_string()).unwrap_err(),
            "smarthub_operation_not_allowlisted"
        );
        assert_eq!(
            validate_smart_hub_request_id("../../tmp").unwrap_err(),
            "smarthub_invalid_request_id"
        );
        assert_eq!(
            validate_smart_hub_request_id(&"a".repeat(SMART_HUB_MAX_REQUEST_ID_BYTES + 1))
                .unwrap_err(),
            "smarthub_invalid_request_id"
        );
        assert_eq!(
            validate_smart_hub_json_value(&serde_json::json!("bad\u{0000}text"), 0).unwrap_err(),
            "openburnbar_cli_smarthub_payload_invalid_text"
        );
        assert_eq!(
            validate_smart_hub_json_value(
                &serde_json::Value::Array(vec![
                    serde_json::Value::Null;
                    SMART_HUB_MAX_JSON_ITEMS + 1
                ]),
                0
            )
            .unwrap_err(),
            "openburnbar_cli_smarthub_payload_too_many_items"
        );
    }
