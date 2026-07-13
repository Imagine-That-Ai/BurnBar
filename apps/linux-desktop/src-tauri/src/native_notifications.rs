//! Typed freedesktop notification actions for the Linux shell.
//!
//! The daemon's `notify-send` bridge is intentionally body-only because it has no
//! renderer handle with which to route an action.  The desktop shell owns this
//! adapter: it probes the user's notification server, attaches an action only
//! when the server advertises the `actions` capability, and emits a validated
//! event back to the renderer when the action is invoked.

use serde::{Deserialize, Serialize};
use tauri::AppHandle;
#[cfg(target_os = "linux")]
use tauri::{Emitter, Manager};

const MAX_NOTIFICATION_ID_BYTES: usize = 96;
const MAX_NOTIFICATION_TITLE_CHARS: usize = 160;
const MAX_NOTIFICATION_BODY_CHARS: usize = 1_024;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum NativeNotificationRoute {
    Overview,
    Chat,
    Insights,
    Settings,
    Activity,
    Account,
    Updates,
    Support,
}

impl NativeNotificationRoute {
    fn as_str(self) -> &'static str {
        match self {
            Self::Overview => "overview",
            Self::Chat => "chat",
            Self::Insights => "insights",
            Self::Settings => "settings",
            Self::Activity => "activity",
            Self::Account => "account",
            Self::Updates => "updates",
            Self::Support => "support",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum NativeNotificationAction {
    Open,
}

impl NativeNotificationAction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NativeNotificationUrgency {
    Low,
    Normal,
    Critical,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NativeNotificationRequest {
    pub id: Option<String>,
    pub title: String,
    pub body: String,
    pub route: NativeNotificationRoute,
    pub action: NativeNotificationAction,
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
    title: String,
    body: String,
    route: NativeNotificationRoute,
    action: NativeNotificationAction,
    urgency: NativeNotificationUrgency,
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn stable_notification_id(title: &str, body: &str) -> u32 {
    let mut hash: u32 = 0x811c9dc5;
    for byte in title.bytes().chain([0xff]).chain(body.bytes()) {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    hash
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
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
    {
        return Err("native_notification_id_invalid".to_string());
    }
    Ok(id)
}

fn validate_request(
    request: NativeNotificationRequest,
) -> Result<ValidatedNotificationRequest, String> {
    let title = request.title.trim();
    let body = request.body.trim();
    if title.is_empty() || body.is_empty() {
        return Err("native_notification_content_empty".to_string());
    }
    if title.chars().any(char::is_control) || body.chars().any(char::is_control) {
        return Err("native_notification_control_character".to_string());
    }
    let title = truncate_chars(title, MAX_NOTIFICATION_TITLE_CHARS);
    let body = truncate_chars(body, MAX_NOTIFICATION_BODY_CHARS);
    let id = normalize_notification_id(request.id, &title, &body)?;
    Ok(ValidatedNotificationRequest {
        id,
        title,
        body,
        route: request.route,
        action: request.action,
        urgency: request.urgency.unwrap_or(NativeNotificationUrgency::Normal),
    })
}

#[cfg(target_os = "linux")]
mod linux {
    use super::{NativeNotificationCapabilities, NativeNotificationUrgency};
    use notify_rust::{
        get_capabilities, Notification, NotificationHandle, NotificationResponse, Timeout, Urgency,
    };
    use std::collections::HashSet;

    pub(super) fn capabilities() -> NativeNotificationCapabilities {
        match get_capabilities() {
            Ok(server_capabilities) => {
                let set: HashSet<&str> = server_capabilities.iter().map(String::as_str).collect();
                NativeNotificationCapabilities {
                    available: true,
                    actions: set.contains("actions"),
                    persistence: set.contains("persistence"),
                    body: set.contains("body"),
                    body_markup: set.contains("body-markup"),
                    server_capabilities,
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

    pub(super) fn urgency(value: NativeNotificationUrgency) -> Urgency {
        match value {
            NativeNotificationUrgency::Low => Urgency::Low,
            NativeNotificationUrgency::Normal => Urgency::Normal,
            NativeNotificationUrgency::Critical => Urgency::Critical,
        }
    }

    pub(super) fn show(
        title: &str,
        body: &str,
        id: u32,
        urgency: NativeNotificationUrgency,
        actions: bool,
    ) -> Result<NotificationHandle, String> {
        let mut notification = Notification::new();
        notification
            .appname("OpenBurnBar")
            .summary(title)
            .body(body)
            .id(id)
            .timeout(Timeout::Default)
            .urgency(urgency(urgency));
        if actions {
            // `open` is a stable action identifier; the visible label is kept
            // separate so desktop themes may localize or style it.
            notification.action("open", "Open");
        }
        notification
            .show()
            .map_err(|error| format!("native_notification_show_failed:{error}"))
    }

    pub(super) fn wait_for_response(
        notification: NotificationHandle,
        callback: impl FnOnce(NativeNotificationResponse) + Send + 'static,
    ) {
        std::thread::spawn(move || {
            let _ = notification.wait_for_response(|response: &NotificationResponse| {
                let mapped = match response {
                    NotificationResponse::Default => NativeNotificationResponse::Default,
                    NotificationResponse::Action(action) => {
                        NativeNotificationResponse::Action(action.clone())
                    }
                    NotificationResponse::Reply(_) | NotificationResponse::Closed(_) => {
                        NativeNotificationResponse::Closed
                    }
                };
                callback(mapped);
            });
        });
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(super) enum NativeNotificationResponse {
        Default,
        Action(String),
        Closed,
    }
}

#[cfg(not(target_os = "linux"))]
mod linux {
    use super::{NativeNotificationCapabilities, NativeNotificationUrgency};

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(super) enum NativeNotificationResponse {
        Default,
        Action(String),
        Closed,
    }

    pub(super) fn capabilities() -> NativeNotificationCapabilities {
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

    #[allow(dead_code)]
    pub(super) fn urgency(_value: NativeNotificationUrgency) {}
}

fn capability_snapshot() -> NativeNotificationCapabilities {
    linux::capabilities()
}

fn native_notification_id(id: &str) -> u32 {
    stable_notification_id(id, "")
}

fn should_route_response(response: &linux::NativeNotificationResponse) -> bool {
    match response {
        linux::NativeNotificationResponse::Default => true,
        linux::NativeNotificationResponse::Action(action) => action == "open",
        linux::NativeNotificationResponse::Closed => false,
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
        return Ok(NativeNotificationResult {
            notification_id: request.id,
            delivered: false,
            actions_attached: false,
            degraded_reason: capabilities.degraded_reason,
        });
    }

    #[cfg(target_os = "linux")]
    {
        let actions_attached = capabilities.actions;
        let notification = linux::show(
            &request.title,
            &request.body,
            native_notification_id(&request.id),
            request.urgency,
            actions_attached,
        )?;
        if actions_attached {
            let app_for_response = app.clone();
            let route = request.route.as_str().to_string();
            let action = request.action.as_str().to_string();
            let notification_id = request.id.clone();
            linux::wait_for_response(notification, move |response| {
                if !should_route_response(&response) {
                    return;
                }
                let app_for_route = app_for_response.clone();
                let route = route.clone();
                let action = action.clone();
                let notification_id = notification_id.clone();
                let _ = app_for_route.run_on_main_thread(move || {
                    let _ = app_for_route.emit(
                        "notification-action",
                        serde_json::json!({
                            "notificationId": notification_id,
                            "route": route,
                            "action": action
                        }),
                    );
                });
            });
        }
        return Ok(NativeNotificationResult {
            notification_id: request.id,
            delivered: true,
            actions_attached,
            degraded_reason: if actions_attached {
                None
            } else {
                Some("native_notification_actions_unavailable".to_string())
            },
        });
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = app;
        Ok(NativeNotificationResult {
            notification_id: request.id,
            delivered: false,
            actions_attached: false,
            degraded_reason: Some(
                "native_notification_server_unavailable:unsupported_host".to_string(),
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(route: NativeNotificationRoute) -> NativeNotificationRequest {
        NativeNotificationRequest {
            id: Some("agent-reply-1".into()),
            title: "Agent replied".into(),
            body: "Done.".into(),
            route,
            action: NativeNotificationAction::Open,
            urgency: None,
        }
    }

    #[test]
    fn notification_payload_is_bounded_and_typed() {
        let validated = validate_request(request(NativeNotificationRoute::Chat)).unwrap();
        assert_eq!(validated.id, "agent-reply-1");
        assert_eq!(validated.route.as_str(), "chat");
        assert_eq!(validated.action.as_str(), "open");
    }

    #[test]
    fn notification_rejects_malformed_ids_and_control_characters() {
        let mut bad = request(NativeNotificationRoute::Chat);
        bad.id = Some("agent reply/1".into());
        assert_eq!(
            validate_request(bad).unwrap_err(),
            "native_notification_id_invalid"
        );

        let mut control = request(NativeNotificationRoute::Chat);
        control.body.push('\u{0000}');
        assert_eq!(
            validate_request(control).unwrap_err(),
            "native_notification_control_character"
        );
    }

    #[test]
    fn notification_response_mapping_only_routes_open_actions() {
        assert!(should_route_response(
            &linux::NativeNotificationResponse::Default
        ));
        assert!(should_route_response(
            &linux::NativeNotificationResponse::Action("open".into())
        ));
        assert!(!should_route_response(
            &linux::NativeNotificationResponse::Action("dismiss".into())
        ));
        assert!(!should_route_response(
            &linux::NativeNotificationResponse::Closed
        ));
    }
}
