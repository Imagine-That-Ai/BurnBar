    #[test]
    fn smarthub_payload_shape_matches_each_typed_operation() {
        for operation in ["discover", "parity"] {
            assert!(validate_smart_hub_payload_shape(operation, &serde_json::json!([])).is_ok());
            assert_eq!(
                validate_smart_hub_payload_shape(operation, &serde_json::json!({})).unwrap_err(),
                "openburnbar_cli_smarthub_payload_shape_invalid"
            );
        }

        for operation in [
            "status",
            "test",
            "cast",
            "cast_status",
            "homeassistant_status",
            "device",
            "pixel_clock_control",
        ] {
            assert!(validate_smart_hub_payload_shape(operation, &serde_json::json!({})).is_ok());
            for malformed in [serde_json::json!([]), serde_json::Value::Null] {
                assert_eq!(
                    validate_smart_hub_payload_shape(operation, &malformed).unwrap_err(),
                    "openburnbar_cli_smarthub_payload_shape_invalid",
                    "unexpectedly accepted malformed {operation} payload: {malformed}"
                );
            }
        }
    }

    #[test]
    fn smarthub_termination_kills_a_helper_process_group() {
        let mut child = Command::new("/bin/sh")
            .process_group(0)
            .arg("-c")
            .arg("sleep 30")
            .stdout(Stdio::piped())
            .spawn()
            .expect("test shell should start");
        terminate_smarthub_child(&mut child);
        assert!(child
            .try_wait()
            .expect("test shell status should be readable")
            .is_some());
    }

    #[test]
    fn smarthub_cli_rejects_oversized_output_before_json_decode() {
        // Use a helper that ignores the fixed SmartHub argv and emits one byte
        // beyond the cap. `/usr/bin/yes` is not portable here because GNU yes
        // treats the fixed `--json` argument as an option and exits early.
        let helper = std::env::temp_dir().join(format!(
            "openburnbar-smarthub-oversize-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::write(
            &helper,
            format!(
                "#!/bin/sh\nexec /usr/bin/head -c {} /dev/zero\n",
                SMART_HUB_MAX_OUTPUT_BYTES + 1
            ),
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        let result = run_smarthub_cli(
            "parity".to_string(),
            helper.clone(),
            tokio_util::sync::CancellationToken::new(),
        );
        let _ = fs::remove_file(helper);
        assert_eq!(
            result.unwrap_err(),
            "openburnbar_cli_smarthub_output_too_large"
        );
    }

    #[test]
    fn smarthub_cancel_cancels_only_the_registered_request() {
        let request_id = "smarthub-test-cancel".to_string();
        let token = tokio_util::sync::CancellationToken::new();
        smart_hub_cancellations()
            .lock()
            .unwrap()
            .insert(request_id.clone(), token.clone());
        smarthub_cancel(request_id.clone()).unwrap();
        assert!(token.is_cancelled());
        smart_hub_cancellations()
            .lock()
            .unwrap()
            .remove(&request_id);
        assert_eq!(
            smarthub_cancel("smarthub/../../other".to_string()).unwrap_err(),
            "smarthub_invalid_request_id"
        );
    }

    #[test]
    fn computer_use_panic_shortcuts_parse() {
        assert!(tauri_plugin_global_shortcut::Builder::<tauri::Wry>::new()
            .with_shortcuts(COMPUTER_USE_PANIC_SHORTCUTS)
            .is_ok());
        assert!(tauri_plugin_global_shortcut::Builder::<tauri::Wry>::new()
            .with_shortcut(OPEN_DASHBOARD_SHORTCUT)
            .is_ok());
        assert!(tauri_plugin_global_shortcut::Builder::<tauri::Wry>::new()
            .with_shortcut(SUMMON_PET_SHORTCUT)
            .is_ok());
    }

    #[test]
    fn native_shortcut_backend_detection_is_explicit_for_linux_sessions() {
        assert_eq!(
            native_shortcut_backend_from_env(Some("wayland"), Some("wayland-0"), None),
            NativeShortcutBackend::Wayland
        );
        assert_eq!(
            native_shortcut_backend_from_env(Some("x11"), None, Some(":0")),
            NativeShortcutBackend::X11
        );
        assert_eq!(
            native_shortcut_backend_from_env(None, None, None),
            NativeShortcutBackend::Unknown
        );
        assert_eq!(
            native_shortcut_registration_reason(NativeShortcutBackend::Wayland, None),
            "native_shortcuts_wayland_backend_unavailable"
        );
    }

    #[test]
    fn native_shortcut_binding_status_keeps_partial_registration_visible() {
        let bindings = native_shortcut_bindings(
            NativeShortcutBindingState::Unavailable,
            Some("native_shortcuts_backend_unknown".to_string()),
        );
        assert_eq!(bindings.len(), NATIVE_SHORTCUT_BINDINGS.len());
        assert_eq!(bindings[0].id, "computer-use-panic");
        assert_eq!(bindings[2].shortcut, OPEN_DASHBOARD_SHORTCUT);
        assert_eq!(bindings[3].id, "summon-pet");
        assert_eq!(bindings[3].shortcut, SUMMON_PET_SHORTCUT);
        assert!(bindings
            .iter()
            .all(|binding| binding.state == NativeShortcutBindingState::Unavailable));
        assert!(bounded_shortcut_error("line\nfeed").contains("line feed"));
        assert!(bounded_shortcut_error("x".repeat(300)).len() <= 256);
    }

    #[test]
    fn wayland_shortcut_portal_probe_requires_the_exact_global_shortcuts_interface() {
        let introspection = r#"
            interface org.freedesktop.portal.GlobalShortcuts {
                CreateSession(a{sv}) -> (o)
            }
        "#;
        assert!(wayland_global_shortcuts_portal_present(introspection));
        assert!(!wayland_global_shortcuts_portal_present(
            "interface org.freedesktop.portal.ScreenCast { }"
        ));
        assert!(!wayland_global_shortcuts_portal_present(
            "interface org.freedesktop.portal.GlobalShortcutsExperimental { }"
        ));
    }

    #[test]
    fn wayland_shortcut_portal_mapping_is_fixed_and_partial_bindings_are_visible() {
        assert_eq!(
            wayland_portal_trigger("computer-use-panic"),
            Some("<Control><Alt><Super>period")
        );
        assert_eq!(
            wayland_portal_trigger("computer-use-panic-fallback"),
            Some("<Control><Alt><Shift>period")
        );
        assert_eq!(wayland_portal_trigger("open-dashboard"), Some("<Control><Alt><Super>O"));
        assert_eq!(wayland_portal_trigger("summon-pet"), Some("<Control><Alt><Super>P"));
        assert_eq!(wayland_portal_trigger("renderer-supplied"), None);

        let bindings = portal_binding_status(
            vec!["open-dashboard".to_string()],
            Some("portal_binding_not_returned".to_string()),
        );
        assert_eq!(bindings.len(), NATIVE_SHORTCUT_BINDINGS.len());
        assert_eq!(bindings[2].state, NativeShortcutBindingState::Registered);
        assert_eq!(bindings[0].state, NativeShortcutBindingState::Degraded);
        assert_eq!(
            bindings[0].degraded_reason.as_deref(),
            Some("portal_binding_not_returned")
        );
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
    fn activity_session_replay_and_resume_use_the_canonical_run_rpc() {
        assert_eq!(DAEMON_RUN_RESUME_METHOD, "run.resume");
        assert_eq!(
            session_resume_params("Codex:session-1".to_string(), "print").unwrap(),
            serde_json::json!({"sessionID": "Codex:session-1", "mode": "print"})
        );
        assert_eq!(
            validated_session_id(" session-1 ".to_string()).unwrap(),
            "session-1"
        );
        assert_eq!(
            validated_session_id("\n".to_string()).unwrap_err(),
            "session_id_must_not_be_empty"
        );
        assert_eq!(
            validated_session_id("bad\u{0000}id".to_string()).unwrap_err(),
            "session_id_invalid"
        );
    }

    #[test]
    fn activity_session_history_uses_the_explicit_daemon_history_rpc() {
        assert_eq!(DAEMON_USAGE_HISTORY_METHOD, "daemon.usage.history");
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
                    | "text-expansion"
                    | "computer-use-system"
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
    fn text_expansion_runtime_capability_follows_daemon_signed_engine_status() {
        let definition = RuntimeCapabilityDefinition {
            id: "text-expansion.system".to_string(),
            domain: "platform".to_string(),
            evaluator: "text-expansion".to_string(),
            unavailable_reason: "System expansion is unavailable.".to_string(),
            substitute: Some("Use in-app expansion.".to_string()),
        };
        let supported = RuntimeTextExpansionCapability {
            registration: "registered".to_string(),
            supports_external_expansion: true,
            detail: "Signed IBus engine is registered.".to_string(),
        };
        let available = evaluate_runtime_capability(
            definition,
            &DaemonHealth::default(),
            Some("x11"),
            true,
            None,
            None,
            Some(&supported),
        )
        .unwrap();
        assert_eq!(available.state, "available");
        assert_eq!(available.source, "daemon-text-expansion-status");
        assert_eq!(available.reason, "Signed IBus engine is registered.");

        let unavailable = RuntimeTextExpansionCapability {
            registration: "engine_missing".to_string(),
            supports_external_expansion: false,
            detail: "The signed engine is not installed.".to_string(),
        };
        let blocked = evaluate_runtime_capability(
            RuntimeCapabilityDefinition {
                id: "text-expansion.system".to_string(),
                domain: "platform".to_string(),
                evaluator: "text-expansion".to_string(),
                unavailable_reason: "System expansion is unavailable.".to_string(),
                substitute: Some("Use in-app expansion.".to_string()),
            },
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
            None,
            Some(&unavailable),
        )
        .unwrap();
        assert_eq!(blocked.state, "unavailable");
        assert!(blocked.reason.contains("engine_missing"));
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
            None,
        )
        .unwrap();
        assert_eq!(missing.state, "unavailable");
        assert_eq!(missing.reason, "Mercury is unavailable.");
    }

    #[test]
    fn system_computer_use_capability_requires_both_live_prerequisites() {
        let definition = || RuntimeCapabilityDefinition {
            id: "computer-use.system".to_string(),
            domain: "platform".to_string(),
            evaluator: "computer-use-system".to_string(),
            unavailable_reason: "System Computer Use is unavailable.".to_string(),
            substitute: None,
        };
        let ready = RuntimeComputerUseSystemCapability {
            available: true,
            capture_ready: true,
            input_ready: true,
            active: false,
            reason: "capture_and_input_ready".to_string(),
            source: "linux-system-runtime".to_string(),
        };
        let available = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
            Some(&ready),
            None,
        )
        .unwrap();
        assert_eq!(available.state, "available");

        let capture_missing = RuntimeComputerUseSystemCapability {
            available: false,
            capture_ready: false,
            input_ready: true,
            active: false,
            reason: "pipewire_vp9_capture_unavailable".to_string(),
            source: "linux-system-runtime".to_string(),
        };
        let blocked = evaluate_runtime_capability(
            definition(),
            &DaemonHealth::default(),
            Some("wayland"),
            true,
            None,
            Some(&capture_missing),
            None,
        )
        .unwrap();
        assert_eq!(blocked.state, "unavailable");
        assert!(blocked.reason.contains("pipewire_vp9_capture_unavailable"));
    }

    #[test]
    fn pet_companion_status_requires_x11_and_display() {
        let available = pet_companion_status_for_env(Some("X11"), Some("GNOME"), Some(":0"));
        assert_eq!(available.state, "available");
        assert_eq!(available.compositor, "GNOME/x11");
        assert!(available.overlay_supported);
        assert!(available.click_through_supported);
        assert_eq!(available.window_contract, "tauri-x11-companion-v1");

        let missing_display = pet_companion_status_for_env(Some("x11"), Some("KDE"), None);
        assert_eq!(missing_display.state, "degraded");
        assert!(!missing_display.overlay_supported);
        assert!(missing_display.reason.contains("no DISPLAY"));
    }

    #[test]
    fn pet_companion_status_keeps_wayland_and_unknown_sessions_fail_closed() {
        let wayland = pet_companion_status_for_env(Some("wayland"), Some("GNOME"), Some(":0"));
        assert_eq!(wayland.state, "degraded");
        assert!(!wayland.overlay_supported);
        assert!(!wayland.click_through_supported);
        assert!(wayland.reason.contains("Wayland"));

        let unknown = pet_companion_status_for_env(None, None, Some(":0"));
        assert_eq!(unknown.state, "unavailable");
        assert_eq!(unknown.compositor, "unknown/unknown");
        assert_eq!(unknown.window_contract, "none");
    }

    #[test]
    fn pet_asset_reader_accepts_only_root_level_glbs() {
        assert!(pet_asset_name_is_safe("kawaii-aurora-fox-actions.glb"));
        assert!(!pet_asset_name_is_safe("../secret.glb"));
        assert!(!pet_asset_name_is_safe("nested/pet.glb"));
        assert!(!pet_asset_name_is_safe("pet.gltf"));
        assert!(!pet_asset_name_is_safe("pet.glb/extra"));
    }

    #[test]
    fn pet_asset_path_rejects_symlinks_and_out_of_root_paths() {
        let root = std::env::temp_dir().join(format!("openburnbar-pet-root-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let asset = root.join("pet.glb");
        fs::write(&asset, b"glTF").unwrap();
        assert_eq!(pet_asset_path(&root, "pet.glb").unwrap(), asset.canonicalize().unwrap());
        assert!(pet_asset_path(&root, "../pet.glb").is_err());
        let _ = fs::remove_dir_all(root);
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
    fn usage_summary_composition_requires_authoritative_projection() {
        let response = compose_usage_summary_response(
            serde_json::json!({"projection": {"totals": {"totalTokens": 4_000, "cost": 0.35}}}),
            serde_json::json!({"usage": [{"inputTokens": 12}]}),
        )
        .unwrap();
        assert_eq!(response["projection"]["totals"]["totalTokens"], 4_000);
        assert_eq!(response["recent"]["usage"][0]["inputTokens"], 12);
        assert!(compose_usage_summary_response(
            serde_json::json!({"error": "unsupported"}),
            serde_json::json!({"usage": []}),
        )
        .is_err());
    }

    #[test]
    fn tray_usage_text_uses_projection_instead_of_bounded_recent_rows() {
        let envelope = serde_json::json!({
            "projection": {"totals": {"totalTokens": 4_000, "cost": 0.35}},
            "recent": {"usage": [{"totalTokens": 12, "cost": 0.03}]}
        });
        assert_eq!(
            tray_usage_text(&envelope),
            "Usage: 4.0K tokens - $0.35"
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
    fn tray_refresh_gate_serializes_requests_and_uses_a_bounded_interval() {
        assert_eq!(TRAY_STATUS_REFRESH_INTERVAL, Duration::from_secs(30));
        let gate = Arc::new(AtomicBool::new(false));
        assert!(try_begin_tray_refresh(&gate));
        assert!(!try_begin_tray_refresh(&gate));

        let guard = TrayRefreshGuard(gate.clone());
        drop(guard);
        assert!(try_begin_tray_refresh(&gate));
    }

    #[test]
    fn tray_reconnect_ack_is_structured_owner_only_and_handler_causal() {
        let root = std::env::temp_dir().join(format!(
            "openburnbar-tray-reconnect-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let ack = TrayReconnectHandlerAck {
            schema_version: 1,
            action: "reconnect-daemon",
            handler_event_id: "tray-health-0123456789abcdef0123456789abcdef".into(),
            daemon_health_request_id: "health-123456789".into(),
            status_item_logical_id: "status",
            handler_started_epoch_ms: 100,
            handler_completed_epoch_ms: 125,
            daemon_connected: true,
            status_update_succeeded: true,
            status_label: "Daemon: connected - 1.2.3".into(),
        };

        append_tray_reconnect_handler_ack(&root, &ack).unwrap();
        let path = root.join("tray-reconnect-handler-acks.jsonl");
        let metadata = fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        let lines = fs::read_to_string(&path).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(lines.trim()).unwrap();
        assert_eq!(parsed["schemaVersion"], 1);
        assert_eq!(parsed["action"], "reconnect-daemon");
        assert_eq!(
            parsed["handlerEventId"],
            "tray-health-0123456789abcdef0123456789abcdef"
        );
        assert_eq!(parsed["daemonHealthRequestId"], "health-123456789");
        assert_eq!(parsed["statusItemLogicalId"], "status");
        assert_eq!(parsed["handlerStartedEpochMs"], 100);
        assert_eq!(parsed["handlerCompletedEpochMs"], 125);
        assert_eq!(parsed["daemonConnected"], true);
        assert_eq!(parsed["statusUpdateSucceeded"], true);
        assert_eq!(parsed["statusLabel"], "Daemon: connected - 1.2.3");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn daemon_health_response_requires_matching_id_and_protocol() {
        let request_id = "health-123456789";
        let response = serde_json::json!({
            "id": request_id,
            "protocolVersion": 1,
            "result": {
                "ok": true
            }
        });
        assert_eq!(
            validated_daemon_health_result(&response, request_id).unwrap()["ok"],
            true
        );

        let mismatched_id = serde_json::json!({
            "id": "health-stale",
            "protocolVersion": 1,
            "result": {
                "ok": true
            }
        });
        assert!(validated_daemon_health_result(&mismatched_id, request_id)
            .unwrap_err()
            .contains("id mismatch"));

        let unsupported_protocol = serde_json::json!({
            "id": request_id,
            "protocolVersion": 2,
            "result": {
                "ok": true
            }
        });
        assert!(
            validated_daemon_health_result(&unsupported_protocol, request_id)
                .unwrap_err()
                .contains("protocol version")
        );

        let malformed_error_with_success = serde_json::json!({
            "id": request_id,
            "protocolVersion": 1,
            "error": {
                "message": 1
            },
            "result": {
                "ok": true
            }
        });
        assert!(
            validated_daemon_health_result(&malformed_error_with_success, request_id)
                .unwrap_err()
                .contains("Malformed health response error")
        );

        let non_object_result = serde_json::json!({
            "id": request_id,
            "protocolVersion": 1,
            "error": null,
            "result": true
        });
        assert!(
            validated_daemon_health_result(&non_object_result, request_id)
                .unwrap_err()
                .contains("must be an object")
        );
    }

    #[test]
    fn tray_daemon_status_uses_the_direct_health_result() {
        let mut health = DaemonHealth::default();
        assert_eq!(tray_daemon_status_text(&health), "Daemon: offline");
        health.ok = true;
        health.daemon_version = Some("1.2.3".into());
        assert_eq!(
            tray_daemon_status_text(&health),
            "Daemon: connected - 1.2.3"
        );
    }

    #[test]
    fn desktop_wallpaper_backend_detection_is_explicit_and_command_gated() {
        let available = |name: &str| {
            matches!(
                name,
                "gsettings"
                    | "plasma-apply-wallpaperimage"
                    | "swaymsg"
                    | "hyprctl"
                    | "hyprpaper"
            )
        };
        assert_eq!(
            desktop_backend_from_env_with(Some("GNOME"), available),
            DesktopWallpaperBackend::Gnome
        );
        assert_eq!(
            desktop_backend_from_env_with(Some("KDE;Plasma"), available),
            DesktopWallpaperBackend::Kde
        );
        assert_eq!(
            desktop_backend_from_env_with(Some("XFCE"), available),
            DesktopWallpaperBackend::Unsupported
        );
        assert_eq!(
            desktop_backend_from_env_with(Some("sway"), available),
            DesktopWallpaperBackend::Sway
        );
        assert_eq!(
            desktop_backend_from_env_with(Some("Hyprland"), available),
            DesktopWallpaperBackend::Hyprland
        );
        assert_eq!(
            desktop_backend_from_env_with(Some("Hyprland"), |name| name == "hyprctl"),
            DesktopWallpaperBackend::Unsupported
        );
    }

    #[test]
    fn desktop_wallpaper_commands_are_absolute_allowlisted_and_not_path_resolved() {
        let source = include_str!("wallpaper_runtime.rs");
        for command in ["swaymsg", "hyprctl", "hyprpaper"] {
            assert!(source.contains(&format!("/usr/bin/{command}")));
            assert!(trusted_wallpaper_executable(command).is_none() || command_available(command));
        }
        assert!(trusted_wallpaper_executable("sh").is_none());
        assert!(!source.contains("Command::new(\"swaymsg\")"));
        assert!(!source.contains("Command::new(\"hyprctl\")"));
    }

    #[test]
    fn desktop_wallpaper_theme_contract_is_bounded_and_uses_app_palette() {
        assert_eq!(WALLPAPER_THEMES.len(), 11);
        assert!(wallpaper_theme_is_valid("auroraTeal"));
        assert!(!wallpaper_theme_is_valid("../../etc/passwd"));
        let svg = theme_svg("auroraTeal").unwrap();
        assert!(svg.starts_with("<svg "));
        assert!(svg.contains("#0d5a64"));
        assert!(theme_svg("unknown").is_err());
    }

    #[test]
    fn desktop_wallpaper_file_uri_escapes_user_paths_without_shell_fragments() {
        let uri = file_uri(Path::new("/home/alberto/My Wallpaper #1.svg")).unwrap();
        assert_eq!(uri, "file:///home/alberto/My%20Wallpaper%20%231.svg");
        assert!(!uri.contains(' '));
        assert!(!uri.contains('#'));
    }

    #[test]
    fn desktop_wallpaper_restore_uri_decoding_is_local_and_bounded() {
        assert_eq!(
            percent_decode_file_uri("file:///home/alberto/My%20Wallpaper%20%231.svg"),
            Some(PathBuf::from("/home/alberto/My Wallpaper #1.svg"))
        );
        assert!(percent_decode_file_uri("file://remote/share/wallpaper.png").is_none());
        assert!(percent_decode_file_uri("file:///home/alberto/%ZZ.png").is_none());
    }

    #[test]
    fn desktop_wallpaper_status_distinguishes_ready_applied_and_unsupported() {
        let ready = wallpaper_status_from_state(DesktopWallpaperBackend::Gnome, None, None);
        assert!(ready.available);
        assert_eq!(ready.state, "ready");
        let applied = wallpaper_status_from_state(
            DesktopWallpaperBackend::Kde,
            Some(DesktopWallpaperState {
                backend: DesktopWallpaperBackend::Kde,
                theme: "midnight".into(),
                path: "/tmp/midnight.svg".into(),
                previous: None,
            }),
            None,
        );
        assert_eq!(applied.state, "applied");
        assert_eq!(applied.theme.as_deref(), Some("midnight"));
        assert!(!applied.restore_available);
        let restorable = wallpaper_status_from_state(
            DesktopWallpaperBackend::Gnome,
            Some(DesktopWallpaperState {
                backend: DesktopWallpaperBackend::Gnome,
                theme: "midnight".into(),
                path: "/tmp/midnight.svg".into(),
                previous: Some(DesktopWallpaperPreviousState {
                    backend: DesktopWallpaperBackend::Gnome,
                    path: "/tmp/original.png".into(),
                    dark_path: None,
                }),
            }),
            None,
        );
        assert!(restorable.restore_available);
        let unsupported = wallpaper_status_from_state(
            DesktopWallpaperBackend::Unsupported,
            None,
            Some("wallpaper_backend_unsupported".into()),
        );
        assert!(!unsupported.available);
        assert_eq!(unsupported.state, "degraded");

        let sway = wallpaper_status_from_state(DesktopWallpaperBackend::Sway, None, None);
        assert!(sway.available);
        assert_eq!(sway.state, "ready");
    }

    #[test]
    fn background_start_is_opt_in_and_does_not_change_foreground_launches() {
        assert!(should_start_in_background(&["--background".into()]));
        assert!(should_start_in_background(&[
            "openburnbar://settings".into(),
            "--background".into()
        ]));
        assert!(!should_start_in_background(&[]));
        assert!(!should_start_in_background(&["--background=true".into()]));
        assert!(should_hide_startup_window(true, true));
        assert!(!should_hide_startup_window(true, false));
        assert!(!should_hide_startup_window(false, true));
    }

    #[test]
    fn webkit_safe_mode_defaults_to_headless_or_vm_friendly_path() {
        assert!(should_enable_webkit_safe_mode(false, None));
        assert!(!should_enable_webkit_safe_mode(true, None));
    }

    #[test]
    fn webkit_safe_mode_override_is_explicit_and_case_insensitive() {
        assert!(should_enable_webkit_safe_mode(true, Some("YES")));
        assert!(!should_enable_webkit_safe_mode(false, Some("off")));
        assert!(!should_enable_webkit_safe_mode(true, Some("unexpected")));
    }

    #[test]
    fn deep_link_decoder_allows_registered_routes_only() {
        assert_eq!(
            validated_deep_link_route("openburnbar://dashboard"),
            Some("overview".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://membership"),
            Some("account".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://membership/success"),
            Some("account".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://insights/today"),
            Some("insights".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://route/computer-use"),
            Some("computer-use".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://route/chat"),
            Some("chat".to_string())
        );
        assert_eq!(
            validated_deep_link_route(
                "openburnbar://providers?provider=openai%2Fteam&model=gpt-5.2+codex"
            ),
            Some("providers?provider=openai%2Fteam&model=gpt-5.2+codex".to_string())
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://providers?provider=openai&admin=true"),
            None
        );
        assert_eq!(
            validated_deep_link_route("openburnbar://providers?model=gpt-5"),
            None
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
    fn relaunch_notification_actions_use_the_direct_native_event_contract() {
        let payload = serde_json::json!({
            "notificationId": "agent-reply-42",
            "threadId": "thread-42"
        });
        assert_eq!(
            notification_action_event("reply", &payload),
            Some(serde_json::json!({
                "notificationId": "agent-reply-42",
                "route": "chat",
                "action": "reply",
                "payload": payload,
            }))
        );

        let fallback = notification_action_event("settings", &serde_json::json!({})).unwrap();
        assert_eq!(fallback["notificationId"], "single-instance-settings");
        assert_eq!(fallback["route"], "settings");
        assert_eq!(fallback["action"], "open");
        assert_eq!(
            notification_action_event("execute", &serde_json::json!({})),
            None
        );
        assert_eq!(
            notification_action_event("chat", &serde_json::json!(["not-an-object"])),
            None
        );
    }

    #[test]
    fn relaunch_notification_ids_reject_unsafe_values_and_use_route_fallback() {
        let event = notification_action_event(
            "chat",
            &serde_json::json!({"notification_id": "agent/reply", "threadId": "thread-9"}),
        )
        .unwrap();
        assert_eq!(event["notificationId"], "single-instance-chat");

        let event = notification_action_event(
            "chat",
            &serde_json::json!({"notification_id": "agent-reply-9"}),
        )
        .unwrap();
        assert_eq!(event["notificationId"], "agent-reply-9");
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
        assert_eq!(
            bounded_recovery_path("/tmp/recovery.obb".to_string()).unwrap(),
            "/tmp/recovery.obb"
        );
        assert!(bounded_recovery_path("relative.obb".to_string()).is_err());
        assert!(bounded_recovery_path("/tmp/recovery\n.obb".to_string()).is_err());
        assert!(bounded_recovery_passphrase("correct horse battery staple".to_string()).is_ok());
        assert!(bounded_recovery_passphrase("   ".to_string()).is_err());
        assert!(bounded_recovery_passphrase("a\0b".to_string()).is_err());
        assert!(bounded_recovery_passphrase("x".repeat(4_097)).is_err());
    }

    #[test]
    fn mission_decision_rejects_unknown_values() {
        assert_eq!(MissionApprovalDecision::parse("approve"), Ok(MissionApprovalDecision::Approve));
        assert_eq!(MissionApprovalDecision::parse("deny"), Ok(MissionApprovalDecision::Deny));
        assert!(MissionApprovalDecision::parse("not-deny-means-approve").is_err());
        assert!(MissionApprovalDecision::parse("APPROVE").is_err());
    }

    #[test]
    fn mission_resume_wire_is_bounded_and_daemon_gated() {
        assert!(mission_resume_wire("  ").is_err());
        assert!(mission_resume_wire(&"m".repeat(257)).is_err());
        let (method, params) = mission_resume_wire("m-1").expect("valid mission id");
        assert_eq!(method, "daemon.mission.packet.dispatch");
        assert_eq!(params["missionID"], "m-1");
        assert_eq!(params["actor"], "linux-shell");
        assert_eq!(params["packet"]["missionID"], "m-1");
        assert_eq!(params["packet"]["workerName"], "linux-shell");
        assert_eq!(params["packet"]["status"], "queued");
        assert_eq!(params["packet"]["metadata"]["action"], "resume");
        assert_eq!(params["packet"]["metadata"]["source"], "linux-shell");
        assert!(params["packet"]["id"].as_str().unwrap().starts_with("linux-resume-"));
    }

    // Pins the REAL `daemon.mission.list` wire shape: the daemon returns
    // BurnBarMissionListResponse { missions: [BurnBarMissionSnapshot] } where
    // each snapshot carries `id` (bare string), `status` ("awaiting_approval"
    // when decidable) and `approval: { approved, ... }`. There are no top-level
    // pendingApprovals/approvals/questions arrays in that contract.
    #[test]
    fn mission_pending_approval_matches_daemon_mission_list_contract() {
        let mission_list = serde_json::json!({"missions": [
            {"id": "m-1", "status": "awaiting_approval",
             "approval": {"approved": false, "approvedAt": null, "approvedBy": null, "note": null},
             "title": "Deploy packet", "projectSlug": "burnbar", "metadata": {}},
            {"id": "m-2", "status": "approved",
             "approval": {"approved": true, "approvedBy": "operator"},
             "title": "Already decided", "projectSlug": "burnbar", "metadata": {}},
            {"id": "m-3", "status": "in_progress",
             "approval": {"approved": true},
             "title": "Running", "projectSlug": "burnbar", "metadata": {}}
        ]});
        let approval = mission_pending_approval(&mission_list, "m-1").expect("pending approval");
        assert_eq!(approval["id"], "m-1");
        // Already-decided or running missions are not decidable from the shell.
        assert!(mission_pending_approval(&mission_list, "m-2").is_none());
        assert!(mission_pending_approval(&mission_list, "m-3").is_none());
        assert!(mission_pending_approval(&mission_list, "attacker-chosen-mission-id").is_none());
        // An empty daemon response fails closed.
        assert!(mission_pending_approval(&serde_json::json!({"missions": []}), "m-1").is_none());
    }

    #[test]
    fn mission_pending_approval_requires_matching_pending_mission() {
        // Flat approval-feed fallback (shell fixtures / future daemon payloads).
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
        // Mission snapshots carry risk in metadata: the daemon's enterprise policy
        // key (BurnBarEnterprisePolicyMetadataKey.defaultPacketRiskLevel) or plain
        // risk/severity entries.
        assert!(mission_approval_is_high_risk(&serde_json::json!(
            {"id": "m-1", "metadata": {"enterprise_default_packet_risk_level": "high"}}
        )));
        assert!(mission_approval_is_high_risk(&serde_json::json!(
            {"id": "m-1", "metadata": {"risk": "HIGH"}}
        )));
        assert!(!mission_approval_is_high_risk(&serde_json::json!(
            {"id": "m-1", "metadata": {"enterprise_default_packet_risk_level": "low"}}
        )));
        assert!(!mission_approval_is_high_risk(&serde_json::json!(
            {"id": "m-1", "status": "awaiting_approval", "approval": {"approved": false}, "metadata": {}}
        )));
    }
