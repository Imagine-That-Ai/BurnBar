const CU_MAX_ARGS_BYTES: usize = 64 * 1024;
const CU_CLIENT_ID: &str = "linux-shell";
const CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS: f64 = 5.0 * 60.0;
const CU_LOCAL_AUTH_MAX_CLOCK_SKEW_SECONDS: f64 = 30.0;
const CU_LOCAL_AUTH_MAX_GRANT_DURATION_SECONDS: f64 = 30.0 * 60.0;
const CU_BROKER_RPC_TIMEOUT: Duration = Duration::from_secs(5);
// The daemon's interactive phone + polkit flow may take up to two minutes.
// Keep the shell outside that budget so a successful daemon operation is not
// abandoned while the local owner prompt is still visible.
const CU_INTERACTIVE_AUTH_RPC_TIMEOUT: Duration = Duration::from_secs(135);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ComputerUseSessionBrokerRPCContract {
    readiness_method: &'static str,
    acquire_method: &'static str,
    status_method: &'static str,
    session_start_method: &'static str,
    session_status_method: &'static str,
}

const CU_SESSION_BROKER_RPC_CONTRACT: ComputerUseSessionBrokerRPCContract =
    ComputerUseSessionBrokerRPCContract {
        readiness_method: "daemon.computer_use.session_grant.readiness",
        acquire_method: "daemon.computer_use.session_grant.acquire",
        status_method: "daemon.computer_use.session_grant.status",
        session_start_method: "daemon.computer_use.session.start",
        session_status_method: "daemon.computer_use.approval.pending",
    };

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum ComputerUseSessionAuthorityState {
    Available,
    WaitingPhone,
    WaitingLocalOwner,
    Authorized,
    Expired,
    Rejected,
    Unavailable,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ComputerUseSessionAuthorityStatus {
    state: ComputerUseSessionAuthorityState,
    expires_at: Option<f64>,
    detail: Option<String>,
    session_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum ComputerUseDaemonSessionGrantState {
    Unavailable,
    AwaitingPhone,
    AwaitingDesktopOwner,
    Ready,
    Denied,
    Expired,
    Consumed,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionGrantStatus {
    challenge_id: String,
    session_intent_id: String,
    state: ComputerUseDaemonSessionGrantState,
    issued_at: f64,
    expires_at: f64,
    denial_reason: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionGrantReadiness {
    available: bool,
    reason: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDaemonSessionStartResponse {
    session_id: String,
    manifest_hash_hex: String,
    started_at: f64,
    entitlement_product_id: String,
    action_cap: u32,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseDesktopOwnerAuthorizationRequest {
    method: String,
}

/// Renderer-safe request. Phone proof and local-owner results deliberately do
/// not exist on this type; a native broker implementation must acquire and
/// retain them outside the webview process.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ComputerUseBrokerSessionStartRequest {
    mode: String,
    trust_mode: String,
    #[serde(default)]
    scope_rule_ids: Vec<String>,
    phone_viewer_node_id: Option<String>,
    mac_host_node_id: Option<String>,
    action_cap: Option<u32>,
    session_timeout_seconds: Option<u32>,
    client_id: String,
    run_id: String,
    run_call_id: String,
    run_generation: u64,
    desktop_owner_authorization_request: ComputerUseDesktopOwnerAuthorizationRequest,
}

#[derive(Clone, Debug)]
struct ActiveComputerUseBrokerFlow {
    request: ComputerUseBrokerSessionStartRequest,
    challenge_id: Option<String>,
    session_intent_id: Option<String>,
    status: ComputerUseSessionAuthorityStatus,
    start_in_progress: bool,
}

static COMPUTER_USE_BROKER_FLOW: OnceLock<Mutex<Option<ActiveComputerUseBrokerFlow>>> =
    OnceLock::new();

fn computer_use_broker_flow() -> &'static Mutex<Option<ActiveComputerUseBrokerFlow>> {
    COMPUTER_USE_BROKER_FLOW.get_or_init(|| Mutex::new(None))
}

trait ComputerUseSessionBroker: Send + Sync {
    #[cfg(test)]
    fn rpc_contract(&self) -> ComputerUseSessionBrokerRPCContract;
    fn status(&self) -> ComputerUseSessionAuthorityStatus;
    fn start(
        &self,
        request: ComputerUseBrokerSessionStartRequest,
    ) -> Result<ComputerUseSessionAuthorityStatus, String>;
}

struct DaemonComputerUseSessionBroker;

impl ComputerUseSessionBroker for DaemonComputerUseSessionBroker {
    #[cfg(test)]
    fn rpc_contract(&self) -> ComputerUseSessionBrokerRPCContract {
        CU_SESSION_BROKER_RPC_CONTRACT
    }

    fn status(&self) -> ComputerUseSessionAuthorityStatus {
        computer_use_broker_status_with(call_computer_use_broker_daemon_method)
    }

    fn start(
        &self,
        request: ComputerUseBrokerSessionStartRequest,
    ) -> Result<ComputerUseSessionAuthorityStatus, String> {
        validate_computer_use_broker_request(&request)?;
        Ok(computer_use_broker_acquire_with(
            request,
            call_computer_use_broker_daemon_method,
        ))
    }
}

fn validate_computer_use_broker_request(
    request: &ComputerUseBrokerSessionStartRequest,
) -> Result<(), String> {
    if request.mode != "browser" && request.mode != "system" {
        return Err("Linux Computer Use authorization supports browser or system mode".into());
    }
    validate_cu_trust_mode(&request.trust_mode)?;
    if request.run_id.trim().is_empty() || request.run_call_id.trim().is_empty() {
        return Err("computer use session start requires an exact runId and runCallId".into());
    }
    if request.client_id != CU_CLIENT_ID {
        return Err("computer use session start requires the linux-shell client".into());
    }
    if request.scope_rule_ids.len() > 256
        || request
            .scope_rule_ids
            .iter()
            .any(|value| !is_bounded_computer_use_identifier(value))
        || request
            .action_cap
            .is_some_and(|value| value == 0 || value > 10_000)
        || request
            .session_timeout_seconds
            .is_some_and(|value| value == 0 || value > 24 * 60 * 60)
    {
        return Err("computer use session start contains invalid bounded metadata".into());
    }
    if request.desktop_owner_authorization_request.method != "linux_desktop_owner" {
        return Err("computer use session start requires linux_desktop_owner authorization".into());
    }
    Ok(())
}

fn is_bounded_computer_use_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 512
        && value
            .chars()
            .all(|character| character.is_ascii() && character != '\n' && character != '\r')
}

fn safe_computer_use_detail(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii() && !character.is_ascii_control() {
                character
            } else {
                ' '
            }
        })
        .take(512)
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn unavailable_computer_use_broker_status(
    detail: impl AsRef<str>,
) -> ComputerUseSessionAuthorityStatus {
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Unavailable,
        expires_at: None,
        detail: Some(safe_computer_use_detail(detail.as_ref())),
        session_id: None,
    }
}

fn available_computer_use_broker_status() -> ComputerUseSessionAuthorityStatus {
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Available,
        expires_at: None,
        detail: Some("Ready to request paired-phone Computer Use authorization.".into()),
        session_id: None,
    }
}

fn computer_use_session_request_wire(
    request: &ComputerUseBrokerSessionStartRequest,
    challenge_id: Option<&str>,
) -> serde_json::Value {
    serde_json::json!({
        "mode": request.mode,
        "trustMode": request.trust_mode,
        "scopeRuleIds": request.scope_rule_ids,
        "phoneViewerNodeId": request.phone_viewer_node_id,
        "macHostNodeId": request.mac_host_node_id,
        "actionCap": request.action_cap.unwrap_or(50),
        "sessionTimeoutSeconds": request.session_timeout_seconds.unwrap_or(1800),
        "clientID": request.client_id,
        "runID": request.run_id,
        "runCallID": request.run_call_id,
        "runGeneration": request.run_generation,
        "grantChallengeId": challenge_id,
        "desktopOwnerAuthorizationRequest": request.desktop_owner_authorization_request,
    })
}

fn computer_use_session_grant_acquire_wire(
    request: &ComputerUseBrokerSessionStartRequest,
) -> serde_json::Value {
    serde_json::json!({
        "sessionRequest": computer_use_session_request_wire(request, None),
    })
}

fn call_computer_use_broker_daemon_method(
    method: &str,
    params: serde_json::Value,
    timeout: Duration,
) -> Result<serde_json::Value, String> {
    call_daemon_method_with_timeout(method, Some(params), timeout)
}

fn decode_computer_use_grant_status(
    value: serde_json::Value,
    expected_challenge_id: Option<&str>,
    expected_session_intent_id: Option<&str>,
) -> Result<ComputerUseDaemonSessionGrantStatus, String> {
    let decoded: ComputerUseDaemonSessionGrantStatus = serde_json::from_value(value)
        .map_err(|_| "Computer Use broker returned malformed status metadata".to_string())?;
    if !is_bounded_computer_use_identifier(&decoded.challenge_id)
        || !is_sha256_hex(&decoded.session_intent_id)
        || !decoded.issued_at.is_finite()
        || !decoded.expires_at.is_finite()
        || decoded.expires_at <= decoded.issued_at
        || decoded.expires_at - decoded.issued_at > CU_LOCAL_AUTH_MAX_PROOF_LIFETIME_SECONDS
        || expected_challenge_id.is_some_and(|value| value != decoded.challenge_id)
        || expected_session_intent_id.is_some_and(|value| value != decoded.session_intent_id)
    {
        return Err("Computer Use broker returned mismatched status metadata".into());
    }
    Ok(decoded)
}

fn public_computer_use_grant_status(
    status: &ComputerUseDaemonSessionGrantStatus,
) -> ComputerUseSessionAuthorityStatus {
    let state = match status.state {
        ComputerUseDaemonSessionGrantState::AwaitingPhone
        | ComputerUseDaemonSessionGrantState::Ready => {
            ComputerUseSessionAuthorityState::WaitingPhone
        }
        ComputerUseDaemonSessionGrantState::AwaitingDesktopOwner => {
            ComputerUseSessionAuthorityState::WaitingLocalOwner
        }
        ComputerUseDaemonSessionGrantState::Denied
        | ComputerUseDaemonSessionGrantState::Consumed => {
            ComputerUseSessionAuthorityState::Rejected
        }
        ComputerUseDaemonSessionGrantState::Expired => ComputerUseSessionAuthorityState::Expired,
        ComputerUseDaemonSessionGrantState::Unavailable => {
            ComputerUseSessionAuthorityState::Unavailable
        }
    };
    ComputerUseSessionAuthorityStatus {
        state,
        expires_at: Some(status.expires_at),
        detail: status
            .denial_reason
            .as_deref()
            .map(safe_computer_use_detail),
        session_id: None,
    }
}

fn update_computer_use_broker_flow(
    expected_challenge_id: Option<&str>,
    update: impl FnOnce(&mut ActiveComputerUseBrokerFlow),
) -> bool {
    let Ok(mut guard) = computer_use_broker_flow().lock() else {
        return false;
    };
    let Some(flow) = guard.as_mut() else {
        return false;
    };
    if expected_challenge_id.is_some_and(|expected| flow.challenge_id.as_deref() != Some(expected))
    {
        return false;
    }
    update(flow);
    true
}

fn claim_computer_use_broker_start(
    expected_challenge_id: &str,
    waiting_owner: ComputerUseSessionAuthorityStatus,
) -> Result<(), ComputerUseSessionAuthorityStatus> {
    let Ok(mut guard) = computer_use_broker_flow().lock() else {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization state is unavailable.",
        ));
    };
    let Some(flow) = guard.as_mut() else {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization changed before session start.",
        ));
    };
    if flow.challenge_id.as_deref() != Some(expected_challenge_id) {
        return Err(unavailable_computer_use_broker_status(
            "Computer Use authorization changed before session start.",
        ));
    }
    if flow.start_in_progress || flow.status.state == ComputerUseSessionAuthorityState::Authorized {
        return Err(flow.status.clone());
    }
    flow.start_in_progress = true;
    flow.status = waiting_owner;
    Ok(())
}

fn computer_use_broker_acquire_with<F>(
    request: ComputerUseBrokerSessionStartRequest,
    caller: F,
) -> ComputerUseSessionAuthorityStatus
where
    F: Fn(&str, serde_json::Value, Duration) -> Result<serde_json::Value, String>,
{
    let requesting = ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::WaitingPhone,
        expires_at: None,
        detail: Some("Requesting approval from the paired phone.".into()),
        session_id: None,
    };
    {
        let Ok(mut guard) = computer_use_broker_flow().lock() else {
            return unavailable_computer_use_broker_status(
                "Computer Use authorization state is unavailable.",
            );
        };
        if let Some(active) = guard.as_ref() {
            if matches!(
                active.status.state,
                ComputerUseSessionAuthorityState::WaitingPhone
                    | ComputerUseSessionAuthorityState::WaitingLocalOwner
            ) {
                if active.request == request {
                    return active.status.clone();
                }
                return ComputerUseSessionAuthorityStatus {
                    state: ComputerUseSessionAuthorityState::Rejected,
                    expires_at: active.status.expires_at,
                    detail: Some(
                        "A different Computer Use authorization request is already active.".into(),
                    ),
                    session_id: None,
                };
            }
        }
        *guard = Some(ActiveComputerUseBrokerFlow {
            request: request.clone(),
            challenge_id: None,
            session_intent_id: None,
            status: requesting.clone(),
            start_in_progress: false,
        });
    }

    let raw = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.acquire_method,
        computer_use_session_grant_acquire_wire(&request),
        CU_BROKER_RPC_TIMEOUT,
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization is unavailable.",
            );
            update_computer_use_broker_flow(None, |flow| flow.status = unavailable.clone());
            return unavailable;
        }
    };
    let decoded = match decode_computer_use_grant_status(raw, None, None) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization returned invalid metadata.",
            );
            update_computer_use_broker_flow(None, |flow| flow.status = unavailable.clone());
            return unavailable;
        }
    };
    let public = public_computer_use_grant_status(&decoded);
    update_computer_use_broker_flow(None, |flow| {
        flow.challenge_id = Some(decoded.challenge_id.clone());
        flow.session_intent_id = Some(decoded.session_intent_id.clone());
        flow.status = public.clone();
    });
    public
}

fn computer_use_start_failure_status(error: &str) -> ComputerUseSessionAuthorityStatus {
    let normalized = error.to_ascii_lowercase();
    if normalized.contains("expired") {
        return ComputerUseSessionAuthorityStatus {
            state: ComputerUseSessionAuthorityState::Expired,
            expires_at: None,
            detail: Some("The Computer Use authorization expired before session start.".into()),
            session_id: None,
        };
    }
    if normalized.contains("unavailable")
        || normalized.contains("timed out")
        || normalized.contains("connection")
        || normalized.contains("no such file")
    {
        return unavailable_computer_use_broker_status(
            "Computer Use session authorization is unavailable.",
        );
    }
    ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Rejected,
        expires_at: None,
        detail: Some("Linux desktop-owner authorization was not completed.".into()),
        session_id: None,
    }
}

fn decode_computer_use_session_start(
    value: serde_json::Value,
) -> Result<ComputerUseSessionAuthorityStatus, String> {
    let decoded: ComputerUseDaemonSessionStartResponse = serde_json::from_value(value)
        .map_err(|_| "Computer Use session start returned malformed metadata".to_string())?;
    if !is_bounded_computer_use_identifier(&decoded.session_id)
        || !is_sha256_hex(&decoded.manifest_hash_hex)
        || !decoded.started_at.is_finite()
        || !is_bounded_computer_use_identifier(&decoded.entitlement_product_id)
        || decoded.action_cap == 0
        || decoded.action_cap > 10_000
    {
        return Err("Computer Use session start returned invalid metadata".into());
    }
    Ok(ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::Authorized,
        expires_at: None,
        detail: None,
        session_id: Some(decoded.session_id),
    })
}

fn computer_use_broker_status_with<F>(caller: F) -> ComputerUseSessionAuthorityStatus
where
    F: Fn(&str, serde_json::Value, Duration) -> Result<serde_json::Value, String>,
{
    let snapshot = {
        let Ok(guard) = computer_use_broker_flow().lock() else {
            return unavailable_computer_use_broker_status(
                "Computer Use authorization state is unavailable.",
            );
        };
        guard.clone()
    };
    let Some(snapshot) = snapshot else {
        return match caller(
            CU_SESSION_BROKER_RPC_CONTRACT.readiness_method,
            serde_json::json!({}),
            CU_BROKER_RPC_TIMEOUT,
        ) {
            Ok(value) => {
                match serde_json::from_value::<ComputerUseDaemonSessionGrantReadiness>(value) {
                    Ok(readiness) if readiness.available && readiness.reason == "ready" => {
                        available_computer_use_broker_status()
                    }
                    Ok(readiness) => {
                        unavailable_computer_use_broker_status(match readiness.reason.as_str() {
                            "transport_unavailable" => {
                                "Paired-phone Computer Use transport is unavailable."
                            }
                            "proof_validator_unavailable" => {
                                "Paired-phone proof validation is unavailable."
                            }
                            "pairing_unavailable" => "No trusted paired controller is available.",
                            _ => "Paired-phone Computer Use authorization is unavailable.",
                        })
                    }
                    Err(_) => unavailable_computer_use_broker_status(
                        "Computer Use readiness returned malformed metadata.",
                    ),
                }
            }
            Err(_) => unavailable_computer_use_broker_status(
                "Computer Use readiness could not be verified.",
            ),
        };
    };
    {
        let flow = &snapshot;
        if flow.start_in_progress
            || matches!(
                flow.status.state,
                ComputerUseSessionAuthorityState::Expired
                    | ComputerUseSessionAuthorityState::Rejected
                    | ComputerUseSessionAuthorityState::Unavailable
            )
        {
            return flow.status.clone();
        }
    }
    if snapshot.status.state == ComputerUseSessionAuthorityState::Authorized {
        let Some(session_id) = snapshot.status.session_id.as_deref() else {
            return unavailable_computer_use_broker_status(
                "Authorized Computer Use state is missing its session identifier.",
            );
        };
        return match caller(
            CU_SESSION_BROKER_RPC_CONTRACT.session_status_method,
            serde_json::json!({ "sessionId": session_id }),
            CU_BROKER_RPC_TIMEOUT,
        ) {
            Ok(value)
                if value
                    .get("sessionActive")
                    .and_then(serde_json::Value::as_bool)
                    == Some(true) =>
            {
                snapshot.status
            }
            Ok(value)
                if value
                    .get("sessionActive")
                    .and_then(serde_json::Value::as_bool)
                    == Some(false) =>
            {
                if let Ok(mut guard) = computer_use_broker_flow().lock() {
                    *guard = None;
                }
                ComputerUseSessionAuthorityStatus {
                    state: ComputerUseSessionAuthorityState::Expired,
                    expires_at: None,
                    detail: Some("The authorized Computer Use session is no longer active.".into()),
                    session_id: None,
                }
            }
            Ok(_) => unavailable_computer_use_broker_status(
                "Computer Use session status returned malformed metadata.",
            ),
            Err(_) => unavailable_computer_use_broker_status(
                "Computer Use session state could not be revalidated.",
            ),
        };
    }
    let Some(challenge_id) = snapshot.challenge_id.as_deref() else {
        return snapshot.status;
    };
    let raw = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.status_method,
        serde_json::json!({ "challengeId": challenge_id }),
        CU_BROKER_RPC_TIMEOUT,
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization status is unavailable.",
            );
            update_computer_use_broker_flow(Some(challenge_id), |flow| {
                flow.status = unavailable.clone()
            });
            return unavailable;
        }
    };
    let decoded = match decode_computer_use_grant_status(
        raw,
        Some(challenge_id),
        snapshot.session_intent_id.as_deref(),
    ) {
        Ok(value) => value,
        Err(_) => {
            let unavailable = unavailable_computer_use_broker_status(
                "Paired-phone Computer Use authorization returned invalid status metadata.",
            );
            update_computer_use_broker_flow(Some(challenge_id), |flow| {
                flow.status = unavailable.clone()
            });
            return unavailable;
        }
    };
    if decoded.state != ComputerUseDaemonSessionGrantState::Ready {
        let public = public_computer_use_grant_status(&decoded);
        update_computer_use_broker_flow(Some(challenge_id), |flow| flow.status = public.clone());
        return public;
    }

    let waiting_owner = ComputerUseSessionAuthorityStatus {
        state: ComputerUseSessionAuthorityState::WaitingLocalOwner,
        expires_at: Some(decoded.expires_at),
        detail: Some("Waiting for Linux desktop-owner authorization.".into()),
        session_id: None,
    };
    if let Err(current_status) = claim_computer_use_broker_start(challenge_id, waiting_owner) {
        return current_status;
    }

    let final_wire = computer_use_session_request_wire(&snapshot.request, Some(challenge_id));
    let final_status = match caller(
        CU_SESSION_BROKER_RPC_CONTRACT.session_start_method,
        final_wire,
        CU_INTERACTIVE_AUTH_RPC_TIMEOUT,
    ) {
        Ok(value) => decode_computer_use_session_start(value).unwrap_or_else(|_| {
            unavailable_computer_use_broker_status(
                "Computer Use session start returned invalid metadata.",
            )
        }),
        Err(error) => computer_use_start_failure_status(&error),
    };
    update_computer_use_broker_flow(Some(challenge_id), |flow| {
        flow.start_in_progress = false;
        flow.status = final_status.clone();
    });
    final_status
}

fn detect_linux_package_channel() -> String {
    detect_linux_package_facts().channel
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct LinuxPackageFacts {
    channel: String,
    manager: String,
    evidence: String,
}

#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct LinuxRuntimeFacts {
    os: String,
    architecture: String,
    kernel: Option<String>,
    session_type: Option<String>,
    desktop: Option<String>,
    display_server: Option<String>,
}

const DIAGNOSTICS_INCLUDED: [&str; 5] = [
    "shell version",
    "daemon health (ok, version, protocol)",
    "package channel and runtime facts",
    "renderer and capability facts",
    "export schema and file permissions",
];

const DIAGNOSTICS_EXCLUDED: [&str; 4] = [
    "provider API keys and credentials",
    "socket auth tokens",
    "provider response payloads",
    "user session content",
];

fn normalized_package_channel(value: &str) -> Option<&'static str> {
    match value.trim().to_ascii_lowercase().as_str() {
        "appimage" => Some("appimage"),
        "arch" => Some("arch"),
        "deb" => Some("deb"),
        "rpm" => Some("rpm"),
        _ => None,
    }
}

fn package_manager_for_channel(channel: &str) -> &'static str {
    match channel {
        "arch" => "pacman",
        "deb" => "dpkg",
        "rpm" => "rpm",
        "appimage" => "appimage",
        _ => "unknown",
    }
}

fn command_reports_installed(command: &str, args: &[&str]) -> bool {
    Command::new(command)
        .args(args)
        .output()
        .map(|output| {
            output.status.success()
                && !String::from_utf8_lossy(&output.stdout)
                    .to_ascii_lowercase()
                    .contains("not installed")
        })
        .unwrap_or(false)
}

fn deb_package_reports_installed(command: &str, package_id: &str) -> bool {
    Command::new(command)
        .args(["-W", "-f=${Status}", package_id])
        .output()
        .map(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("install ok installed")
        })
        .unwrap_or(false)
}

fn package_query_ids() -> [&'static str; 2] {
    // The release smoke path historically emitted both names. Keep the probe
    // explicit instead of accepting arbitrary package-manager input.
    ["openburnbar", "open-burn-bar"]
}

fn detect_linux_package_facts() -> LinuxPackageFacts {
    if let Ok(channel) = std::env::var("OPENBURNBAR_PACKAGE_CHANNEL") {
        if let Some(channel) = normalized_package_channel(&channel) {
            return LinuxPackageFacts {
                channel: channel.to_string(),
                manager: package_manager_for_channel(channel).to_string(),
                evidence: "OPENBURNBAR_PACKAGE_CHANNEL".to_string(),
            };
        }
    }
    if first_non_empty_env(&["APPIMAGE", "APPDIR"]).is_some() {
        return LinuxPackageFacts {
            channel: "appimage".to_string(),
            manager: "appimage".to_string(),
            evidence: "APPIMAGE/APPDIR".to_string(),
        };
    }

    for package_id in package_query_ids() {
        if deb_package_reports_installed("/usr/bin/dpkg-query", package_id)
            || deb_package_reports_installed("/bin/dpkg-query", package_id)
        {
            return LinuxPackageFacts {
                channel: "deb".to_string(),
                manager: "dpkg".to_string(),
                evidence: format!("dpkg-query:{package_id}"),
            };
        }
    }
    for package_id in package_query_ids() {
        if command_reports_installed("/usr/bin/rpm", &["-q", package_id])
            || command_reports_installed("/bin/rpm", &["-q", package_id])
        {
            return LinuxPackageFacts {
                channel: "rpm".to_string(),
                manager: "rpm".to_string(),
                evidence: format!("rpm:{package_id}"),
            };
        }
    }
    for package_id in package_query_ids() {
        if command_reports_installed("/usr/bin/pacman", &["-Q", package_id])
            || command_reports_installed("/bin/pacman", &["-Q", package_id])
        {
            return LinuxPackageFacts {
                channel: "arch".to_string(),
                manager: "pacman".to_string(),
                evidence: format!("pacman:{package_id}"),
            };
        }
    }
    if first_non_empty_env(&["FLATPAK_ID"]).is_some() {
        return LinuxPackageFacts {
            channel: "unknown".to_string(),
            manager: "flatpak".to_string(),
            evidence: "FLATPAK_ID (unsupported update channel)".to_string(),
        };
    }
    LinuxPackageFacts {
        channel: "unknown".to_string(),
        manager: "unknown".to_string(),
        evidence: "no-installed-package-evidence".to_string(),
    }
}

fn sanitized_runtime_fact(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 128 || value.chars().any(|c| c.is_control()) {
        return None;
    }
    Some(value.to_string())
}

fn runtime_env_fact(key: &str) -> Option<String> {
    std::env::var(key)
        .ok()
        .and_then(|value| sanitized_runtime_fact(&value))
}

fn linux_kernel_release() -> Option<String> {
    fs::read_to_string("/proc/sys/kernel/osrelease")
        .ok()
        .and_then(|value| sanitized_runtime_fact(&value))
}

fn linux_runtime_facts() -> LinuxRuntimeFacts {
    let session_type = runtime_env_fact("XDG_SESSION_TYPE");
    let display_server = session_type.as_deref().and_then(|session| {
        if session.eq_ignore_ascii_case("wayland") {
            Some("wayland".to_string())
        } else if session.eq_ignore_ascii_case("x11") || session.eq_ignore_ascii_case("xorg") {
            Some("x11".to_string())
        } else {
            None
        }
    });
    LinuxRuntimeFacts {
        os: std::env::consts::OS.to_string(),
        architecture: std::env::consts::ARCH.to_string(),
        kernel: linux_kernel_release(),
        session_type,
        desktop: runtime_env_fact("XDG_CURRENT_DESKTOP"),
        display_server,
    }
}

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

#[cfg(test)]
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
    desktop_owner_authorization_request: Option<ComputerUseDesktopOwnerAuthorizationRequest>,
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

#[cfg(test)]
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

#[cfg(test)]
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
    if let Some(value) = params.desktop_owner_authorization_request.as_ref() {
        canonical.insert(
            "desktopOwnerAuthorizationMethod".into(),
            serde_json::json!(value.method),
        );
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

#[cfg(test)]
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

#[cfg(test)]
fn computer_use_session_start_wire(
    params: ComputerUseSessionStartParams,
    require_local_auth: bool,
    now: f64,
) -> Result<serde_json::Value, String> {
    validate_cu_mode(&params.mode)?;
    validate_cu_trust_mode(&params.trust_mode)?;
    if require_local_auth
        && (params.mode == "browser" || params.mode == "system")
        && params
            .desktop_owner_authorization_request
            .as_ref()
            .is_none_or(|request| request.method != "linux_desktop_owner")
    {
        return Err("release Computer Use requires linux_desktop_owner authorization".into());
    }
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
        "runGeneration": params.run_generation,
        "desktopOwnerAuthorizationRequest": params.desktop_owner_authorization_request
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
async fn computer_use_session_authority_status() -> ComputerUseSessionAuthorityStatus {
    tauri::async_runtime::spawn_blocking(|| DaemonComputerUseSessionBroker.status())
        .await
        .unwrap_or_else(|_| {
            unavailable_computer_use_broker_status("Computer Use authorization status task failed.")
        })
}

#[tauri::command]
async fn computer_use_session_start(
    params: ComputerUseBrokerSessionStartRequest,
) -> Result<ComputerUseSessionAuthorityStatus, String> {
    // The concrete daemon/relay broker is intentionally replaceable. Until it
    // responds, production stays unavailable rather than accepting
    // renderer-created proof. The interactive session start occurs only after
    // daemon status reports the opaque challenge ready.
    tauri::async_runtime::spawn_blocking(move || DaemonComputerUseSessionBroker.start(params))
        .await
        .map_err(|error| format!("computer_use_authority_broker_join_failed:{error}"))?
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
