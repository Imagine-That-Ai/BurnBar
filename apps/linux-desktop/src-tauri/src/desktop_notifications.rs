#[cfg(all(unix, not(target_os = "macos")))]
use crate::native_shell::deliver_route_action;
use crate::native_shell::{route_action_allowed, NativeDeepLink};
use serde::{Deserialize, Serialize};
#[cfg(all(unix, not(target_os = "macos")))]
use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::AppHandle;

#[cfg(all(unix, not(target_os = "macos")))]
use notify_rust::{get_capabilities, Notification, NotificationResponse, Timeout, Urgency};
#[cfg(all(unix, not(target_os = "macos")))]
use std::thread;

const MAX_NOTIFICATION_ID_BYTES: usize = 96;
const MAX_NOTIFICATION_TITLE_CHARS: usize = 160;
const MAX_NOTIFICATION_BODY_CHARS: usize = 1_024;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NativeNotificationUrgency {
    Low,
    Normal,
    Critical,
}

impl NativeNotificationUrgency {
    #[cfg(all(unix, not(target_os = "macos")))]
    fn as_notify_urgency(self) -> Urgency {
        match self {
            Self::Low => Urgency::Low,
            Self::Normal => Urgency::Normal,
            Self::Critical => Urgency::Critical,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeNotificationRequest {
    pub id: Option<String>,
    pub title: String,
    pub body: String,
    pub route: String,
    pub action: String,
    pub urgency: Option<NativeNotificationUrgency>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeNotificationCapabilities {
    pub available: bool,
    pub actions: bool,
    pub persistence: bool,
    pub body: bool,
    pub body_markup: bool,
    pub server_capabilities: Vec<String>,
    pub degraded_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeNotificationResult {
    pub notification_id: String,
    pub delivered: bool,
    pub actions_attached: bool,
    pub degraded_reason: Option<String>,
}

#[derive(Debug, Clone)]
struct ValidatedNotificationRequest {
    id: String,
    #[cfg(all(unix, not(target_os = "macos")))]
    numeric_id: u32,
    #[cfg(all(unix, not(target_os = "macos")))]
    title: String,
    #[cfg(all(unix, not(target_os = "macos")))]
    body: String,
    link: NativeDeepLink,
    #[cfg(all(unix, not(target_os = "macos")))]
    urgency: NativeNotificationUrgency,
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn normalize_notification_id(
    value: Option<String>,
    title: &str,
    body: &str,
) -> Result<String, String> {
    let fallback = format!("linux-native-{:08x}", stable_notification_id(title, body));
    let id = value
        .map(|raw| raw.trim().to_string())
        .filter(|raw| !raw.is_empty())
        .unwrap_or(fallback);
    if id.len() > MAX_NOTIFICATION_ID_BYTES
        || !id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-')
    {
        return Err("native_notification_id_invalid".to_string());
    }
    Ok(id)
}

fn stable_notification_id(title: &str, body: &str) -> u32 {
    let mut hash: u32 = 0x811c9dc5;
    for byte in title.bytes().chain([0xff]).chain(body.bytes()) {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    hash
}

fn validate_request(
    request: NativeNotificationRequest,
) -> Result<ValidatedNotificationRequest, String> {
    let title = request.title.trim();
    let body = request.body.trim();
    if title.is_empty() || body.is_empty() {
        return Err("native_notification_content_empty".to_string());
    }
    if !route_action_allowed(&request.route, &request.action) {
        return Err("native_notification_route_action_invalid".to_string());
    }
    let title = truncate_chars(title, MAX_NOTIFICATION_TITLE_CHARS);
    let body = truncate_chars(body, MAX_NOTIFICATION_BODY_CHARS);
    let id = normalize_notification_id(request.id, &title, &body)?;
    #[cfg(all(unix, not(target_os = "macos")))]
    let numeric_id = stable_notification_id(&id, "");
    #[cfg(not(all(unix, not(target_os = "macos"))))]
    let _ = request.urgency;
    Ok(ValidatedNotificationRequest {
        id,
        #[cfg(all(unix, not(target_os = "macos")))]
        numeric_id,
        #[cfg(all(unix, not(target_os = "macos")))]
        title,
        #[cfg(all(unix, not(target_os = "macos")))]
        body,
        link: NativeDeepLink {
            route: request.route,
            action: request.action,
        },
        #[cfg(all(unix, not(target_os = "macos")))]
        urgency: request.urgency.unwrap_or(NativeNotificationUrgency::Normal),
    })
}

#[cfg(all(unix, not(target_os = "macos")))]
fn capability_snapshot() -> NativeNotificationCapabilities {
    match get_capabilities() {
        Ok(capabilities) => {
            let set: HashSet<&str> = capabilities.iter().map(String::as_str).collect();
            NativeNotificationCapabilities {
                available: true,
                actions: set.contains("actions"),
                persistence: set.contains("persistence"),
                body: set.contains("body"),
                body_markup: set.contains("body-markup"),
                server_capabilities: capabilities,
                degraded_reason: None,
            }
        }
        Err(error) => NativeNotificationCapabilities {
            available: false,
            actions: false,
            persistence: false,
            body: false,
            body_markup: false,
            server_capabilities: Vec::new(),
            degraded_reason: Some(format!("native_notification_server_unavailable:{error}")),
        },
    }
}

#[cfg(not(all(unix, not(target_os = "macos"))))]
fn capability_snapshot() -> NativeNotificationCapabilities {
    NativeNotificationCapabilities {
        available: false,
        actions: false,
        persistence: false,
        body: false,
        body_markup: false,
        server_capabilities: Vec::new(),
        degraded_reason: Some(
            "native_notification_server_unavailable:unsupported_host".to_string(),
        ),
    }
}

#[cfg(any(test, all(unix, not(target_os = "macos"))))]
#[derive(Debug, Clone, PartialEq, Eq)]
enum NativeNotificationResponse {
    Default,
    Action(String),
    Closed,
}

#[cfg(any(test, all(unix, not(target_os = "macos"))))]
fn should_route_response(response: &NativeNotificationResponse) -> bool {
    match response {
        NativeNotificationResponse::Default => true,
        NativeNotificationResponse::Action(action) => action == "default" || action == "open",
        NativeNotificationResponse::Closed => false,
    }
}

fn evidence_dir() -> Option<PathBuf> {
    std::env::var_os("OPENBURNBAR_EVIDENCE_OUT")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

fn write_evidence_json(file_name: &str, value: serde_json::Value) {
    let Some(out_dir) = evidence_dir() else {
        return;
    };
    let path = out_dir.join(file_name);
    if std::fs::create_dir_all(&out_dir).is_err() {
        return;
    }
    if let Ok(json) = serde_json::to_string_pretty(&value) {
        let _ = std::fs::write(path, format!("{json}\n"));
    }
}

fn evidence_timestamp() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| format!("unix:{}.{:09}", duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or_else(|_| "unix:0.000000000".to_string())
}

fn write_notification_action_evidence(link: &NativeDeepLink, result: &NativeNotificationResult) {
    write_evidence_json(
        "native-notification-action-result.json",
        serde_json::json!({
            "schemaVersion": 1,
            "generatedAt": evidence_timestamp(),
            "passed": result.delivered && result.actions_attached,
            "notificationId": &result.notification_id,
            "delivered": result.delivered,
            "actionsAttached": result.actions_attached,
            "route": &link.route,
            "action": &link.action,
            "degradedReason": &result.degraded_reason,
            "source": "native_notification_show"
        }),
    );
}

#[cfg(all(unix, not(target_os = "macos")))]
fn write_notification_response_evidence(
    link: &NativeDeepLink,
    response: &NativeNotificationResponse,
) {
    write_evidence_json(
        "native-notification-response-result.json",
        serde_json::json!({
            "schemaVersion": 1,
            "generatedAt": evidence_timestamp(),
            "passed": should_route_response(response),
            "route": &link.route,
            "action": &link.action,
            "response": format!("{response:?}"),
            "source": "notify-rust wait_for_response"
        }),
    );
}

#[cfg(all(unix, not(target_os = "macos")))]
fn map_notify_response(response: &NotificationResponse) -> NativeNotificationResponse {
    match response {
        NotificationResponse::Default => NativeNotificationResponse::Default,
        NotificationResponse::Action(action) => NativeNotificationResponse::Action(action.clone()),
        NotificationResponse::Reply(_) | NotificationResponse::Closed(_) => {
            NativeNotificationResponse::Closed
        }
    }
}

#[tauri::command]
pub fn native_notification_capabilities() -> NativeNotificationCapabilities {
    capability_snapshot()
}

#[tauri::command]
pub fn native_notification_show(
    app: AppHandle,
    request: NativeNotificationRequest,
) -> Result<NativeNotificationResult, String> {
    let request = validate_request(request)?;
    let capabilities = capability_snapshot();
    if !capabilities.available {
        let result = NativeNotificationResult {
            notification_id: request.id,
            delivered: false,
            actions_attached: false,
            degraded_reason: capabilities.degraded_reason,
        };
        write_notification_action_evidence(&request.link, &result);
        return Ok(result);
    }

    #[cfg(not(all(unix, not(target_os = "macos"))))]
    {
        let _ = app;
        let result = NativeNotificationResult {
            notification_id: request.id,
            delivered: false,
            actions_attached: false,
            degraded_reason: Some(
                "native_notification_server_unavailable:unsupported_host".to_string(),
            ),
        };
        write_notification_action_evidence(&request.link, &result);
        return Ok(result);
    }

    #[cfg(all(unix, not(target_os = "macos")))]
    {
        return show_notification_linux(app, request, capabilities);
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
fn show_notification_linux(
    app: AppHandle,
    request: ValidatedNotificationRequest,
    capabilities: NativeNotificationCapabilities,
) -> Result<NativeNotificationResult, String> {
    let mut notification = Notification::new();
    notification
        .appname("OpenBurnBar")
        .summary(&request.title)
        .body(&request.body)
        .id(request.numeric_id)
        .timeout(Timeout::Default)
        .urgency(request.urgency.as_notify_urgency());

    if capabilities.actions {
        notification.action("default", "Open");
        notification.action("open", "Open");
    }

    let handle = notification
        .show()
        .map_err(|error| format!("native_notification_show_failed:{error}"))?;
    let link = request.link.clone();
    let app_for_response = app.clone();
    thread::spawn(move || {
        let _ = handle.wait_for_response(|response: &NotificationResponse| {
            let mapped = map_notify_response(response);
            write_notification_response_evidence(&link, &mapped);
            if should_route_response(&mapped) {
                let route = link.route.clone();
                let action = link.action.clone();
                let app_for_route = app_for_response.clone();
                let _ = app_for_response.run_on_main_thread(move || {
                    let _ = deliver_route_action(&app_for_route, &route, &action);
                });
            }
        });
    });

    let result = NativeNotificationResult {
        notification_id: request.id,
        delivered: true,
        actions_attached: capabilities.actions,
        degraded_reason: if capabilities.actions {
            None
        } else {
            Some("native_notification_actions_unavailable".to_string())
        },
    };
    write_notification_action_evidence(&request.link, &result);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(route: &str, action: &str) -> NativeNotificationRequest {
        NativeNotificationRequest {
            id: Some("agent-reply-1".into()),
            title: "Agent replied".into(),
            body: "Done.".into(),
            route: route.into(),
            action: action.into(),
            urgency: None,
        }
    }

    #[test]
    fn notification_payload_is_bounded_and_route_action_locked() {
        let validated = validate_request(request("chat", "open-chat")).unwrap();
        assert_eq!(validated.id, "agent-reply-1");
        assert_eq!(validated.link.route, "chat");
        assert!(validate_request(request("account", "open-chat")).is_err());
    }

    #[test]
    fn notification_rejects_malformed_ids_and_empty_content() {
        let mut bad = request("chat", "open-chat");
        bad.id = Some("agent reply/1".into());
        assert_eq!(
            validate_request(bad).unwrap_err(),
            "native_notification_id_invalid"
        );

        let mut empty = request("chat", "open-chat");
        empty.title = " ".into();
        assert_eq!(
            validate_request(empty).unwrap_err(),
            "native_notification_content_empty"
        );
    }

    #[test]
    fn notification_response_mapping_only_routes_open_actions() {
        assert!(should_route_response(&NativeNotificationResponse::Default));
        assert!(should_route_response(&NativeNotificationResponse::Action(
            "open".into()
        )));
        assert!(!should_route_response(&NativeNotificationResponse::Action(
            "dismiss".into()
        )));
        assert!(!should_route_response(&NativeNotificationResponse::Closed));
    }
}
