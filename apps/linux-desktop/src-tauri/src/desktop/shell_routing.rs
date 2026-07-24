const GATEWAY_MAX_MESSAGES: usize = 256;
const GATEWAY_MAX_CONTENT_BYTES: usize = 1_048_576;
const GATEWAY_MAX_RESPONSE_BYTES: usize = 16_777_216;
/// Linux chat attachments are deliberately narrower than the macOS workspace
/// policy. The renderer never receives the stored bytes back: it gets an
/// opaque, single-use reference owned by this process.
const CHAT_ATTACHMENT_MAX_BYTES: usize = 10 * 1024 * 1024;
const CHAT_ATTACHMENT_MAX_TOTAL_BYTES: usize = 10 * 1024 * 1024;
const CHAT_ATTACHMENT_MAX_REFS_PER_MESSAGE: usize = 8;
const CHAT_ATTACHMENT_MAX_NAME_BYTES: usize = 240;
const CHAT_ATTACHMENT_MAX_REGISTRY_BYTES: usize = 80 * 1024 * 1024;
const DAEMON_ONBOARDING_SNAPSHOT_METHOD: &str = "daemon.onboarding.snapshot";
const DAEMON_ONBOARDING_ACTION_METHOD: &str = "daemon.onboarding.action";
const DAEMON_ONBOARDING_RESET_METHOD: &str = "daemon.onboarding.reset";
const DAEMON_SUBSCRIPTION_START_METHOD: &str = "subscription.start";
const DAEMON_SUBSCRIPTION_RESUME_METHOD: &str = "subscription.resume";
const DAEMON_SUBSCRIPTION_STOP_METHOD: &str = "subscription.stop";
const DAEMON_RUN_RESUME_METHOD: &str = "run.resume";
const DAEMON_USAGE_HISTORY_METHOD: &str = "daemon.usage.history";

static INITIAL_DEEP_LINK_ROUTE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
static FORWARDED_ROUTE_QUEUE: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
static FORWARDED_NOTIFICATION_ACTION_QUEUE: OnceLock<Mutex<Vec<serde_json::Value>>> =
    OnceLock::new();
static NOTIFICATION_ACTIONS_READY: AtomicBool = AtomicBool::new(false);
const SINGLE_INSTANCE_NOTIFICATION_ID_MAX_BYTES: usize = 96;
const FORWARDED_NOTIFICATION_ACTION_QUEUE_MAX: usize = 16;

fn initial_deep_link_route_store() -> &'static Mutex<Option<String>> {
    INITIAL_DEEP_LINK_ROUTE.get_or_init(|| Mutex::new(None))
}

fn forwarded_route_queue() -> &'static Mutex<Vec<String>> {
    FORWARDED_ROUTE_QUEUE.get_or_init(|| Mutex::new(Vec::new()))
}

fn forwarded_notification_action_queue() -> &'static Mutex<Vec<serde_json::Value>> {
    FORWARDED_NOTIFICATION_ACTION_QUEUE.get_or_init(|| Mutex::new(Vec::new()))
}

/// Accept only the routes registered by the Linux shell. External URLs,
/// credentials, query strings, and fragments are deliberately rejected at the
/// native boundary before they can influence renderer navigation.
fn canonical_shell_route(value: &str) -> Option<&'static str> {
    match value {
        "overview" => Some("overview"),
        "insights" => Some("insights"),
        "database" => Some("database"),
        "providers" => Some("providers"),
        "projects" => Some("projects"),
        "missions" => Some("missions"),
        "activity" => Some("activity"),
        "chat" => Some("chat"),
        "memory" => Some("memory"),
        "settings" => Some("settings"),
        "account" => Some("account"),
        "updates" => Some("updates"),
        "support" => Some("support"),
        "onboarding" => Some("onboarding"),
        "pet" => Some("pet"),
        "text-expansion" => Some("text-expansion"),
        "computer-use" => Some("computer-use"),
        "mercury" => Some("mercury"),
        "smarthub" => Some("smarthub"),
        _ => None,
    }
}

fn validated_deep_link_route(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.scheme() != "openburnbar"
        || url.username() != ""
        || url.password().is_some()
        || url.port().is_some()
        || url.fragment().is_some()
    {
        return None;
    }
    let host = url.host_str()?;
    let path = url.path().trim_matches('/');
    let static_route = match (host, path) {
        ("dashboard", "") | ("overview", "") => Some("overview"),
        ("chat", "") => Some("chat"),
        ("insights", "" | "today" | "year") => Some("insights"),
        ("membership", "" | "success" | "cancel") => Some("account"),
        ("route", route) => canonical_shell_route(route),
        ("settings", "") => Some("settings"),
        ("updates", "") => Some("updates"),
        ("database", "") => Some("database"),
        ("providers", "") if url.query().is_none() => Some("providers"),
        ("projects", "") => Some("projects"),
        ("missions", "") => Some("missions"),
        ("activity", "") => Some("activity"),
        ("memory", "") => Some("memory"),
        ("support", "") => Some("support"),
        ("onboarding", "") => Some("onboarding"),
        ("pet", "") => Some("pet"),
        ("text-expansion", "") => Some("text-expansion"),
        ("computer-use", "") => Some("computer-use"),
        ("mercury", "") => Some("mercury"),
        ("smarthub", "") => Some("smarthub"),
        _ => None,
    };
    if let Some(route) = static_route {
        return url.query().is_none().then(|| route.to_string());
    }

    if host != "providers" || !path.is_empty() {
        return None;
    }
    let mut provider_id: Option<String> = None;
    let mut model_id: Option<String> = None;
    for (key, value) in url.query_pairs() {
        let value = value.trim();
        if value.is_empty() || value.len() > 256 {
            return None;
        }
        match key.as_ref() {
            "provider" if provider_id.is_none() => provider_id = Some(value.to_string()),
            "model" if model_id.is_none() => model_id = Some(value.to_string()),
            _ => return None,
        }
    }
    let provider_id = provider_id?;
    let mut destination = reqwest::Url::parse("openburnbar://providers").ok()?;
    {
        let mut query = destination.query_pairs_mut();
        query.append_pair("provider", &provider_id);
        if let Some(model_id) = model_id {
            query.append_pair("model", &model_id);
        }
    }
    Some(format!("providers?{}", destination.query()?))
}

fn valid_single_instance_notification_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= SINGLE_INSTANCE_NOTIFICATION_ID_MAX_BYTES
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
}

/// Normalize relaunch/second-instance notification actions to the same event
/// envelope emitted by the direct freedesktop adapter. Action aliases are
/// route selectors, not arbitrary renderer commands; unsupported values never
/// produce an event. Payloads remain bounded by `single_instance` validation
/// and are carried only as opaque JSON for a route-specific surface to inspect.
fn notification_action_event(
    action: &str,
    payload: &serde_json::Value,
) -> Option<serde_json::Value> {
    if !payload.is_object() {
        return None;
    }
    let route = single_instance::notification_action_route(action)?;
    let notification_id = ["notificationId", "notification_id"]
        .iter()
        .find_map(|key| payload.get(*key).and_then(serde_json::Value::as_str))
        .map(str::trim)
        .filter(|value| valid_single_instance_notification_id(value))
        .map(str::to_string)
        .unwrap_or_else(|| format!("single-instance-{route}"));
    let event_action = if action == "reply" { "reply" } else { "open" };

    Some(serde_json::json!({
        "notificationId": notification_id,
        "route": route,
        // Linux's Reply action opens the owning chat surface. It preserves
        // intent for the renderer without pretending to provide macOS-style
        // inline text input.
        "action": event_action,
        "payload": payload,
    }))
}

fn store_initial_deep_link_route(route: Option<String>) {
    if let Some(mut slot) = initial_deep_link_route_store().lock().ok() {
        *slot = route;
    }
}

fn route_from_single_instance_message(message: &single_instance::Message) -> Option<String> {
    match message {
        single_instance::Message::Focus => Some("overview".to_string()),
        single_instance::Message::Route { route } => Some(route.clone()),
        single_instance::Message::NotificationAction { action, .. } => {
            single_instance::notification_action_route(action).map(str::to_string)
        }
    }
}

fn store_forwarded_route(route: String) {
    if let Ok(mut routes) = forwarded_route_queue().lock() {
        routes.push(route);
        if routes.len() > 16 {
            let excess = routes.len() - 16;
            routes.drain(0..excess);
        }
    }
}

#[cfg(test)]
fn queue_notification_action(queue: &Mutex<Vec<serde_json::Value>>, event: serde_json::Value) {
    let Ok(mut queued) = queue.lock() else {
        return;
    };
    queue_notification_action_locked(&mut queued, event);
}

fn queue_notification_action_locked(queued: &mut Vec<serde_json::Value>, event: serde_json::Value) {
    queued.push(event);
    if queued.len() > FORWARDED_NOTIFICATION_ACTION_QUEUE_MAX {
        let excess = queued.len() - FORWARDED_NOTIFICATION_ACTION_QUEUE_MAX;
        queued.drain(0..excess);
    }
}

/// Deliver a notification action immediately once the renderer has installed
/// its listener; otherwise retain a bounded copy for the bootstrap command.
/// Emitting before the listener exists loses Reply intent (the route may still
/// be forwarded, but the composer-focus action is gone).
pub(crate) fn emit_notification_action(app: &AppHandle, event: serde_json::Value) {
    let queue = forwarded_notification_action_queue();
    let Ok(mut queued) = queue.lock() else {
        return;
    };
    if !NOTIFICATION_ACTIONS_READY.load(Ordering::Acquire) {
        queue_notification_action_locked(&mut queued, event);
        return;
    }
    drop(queued);
    let _ = app.emit("notification-action", event);
}

fn take_notification_actions_from(
    queue: &Mutex<Vec<serde_json::Value>>,
    ready: &AtomicBool,
) -> Vec<serde_json::Value> {
    let Ok(mut queued) = queue.lock() else {
        return Vec::new();
    };
    let pending = std::mem::take(&mut *queued);
    // Keep the state transition under the same mutex as the drain. An action
    // arriving concurrently cannot be lost between taking the queue and
    // marking the renderer ready.
    ready.store(true, Ordering::Release);
    pending
}

fn take_initial_notification_actions() -> Vec<serde_json::Value> {
    take_notification_actions_from(
        forwarded_notification_action_queue(),
        &NOTIFICATION_ACTIONS_READY,
    )
}

fn start_single_instance_dispatcher(app: AppHandle, receiver: Receiver<single_instance::Message>) {
    let _ = thread::Builder::new()
        .name("openburnbar-single-instance-dispatch".to_string())
        .spawn(move || {
            while let Ok(message) = receiver.recv() {
                if let Some(route) = route_from_single_instance_message(&message) {
                    store_forwarded_route(route.clone());
                    emit_tray_route(&app, &route);
                }
                if let single_instance::Message::NotificationAction { action, payload } = message {
                    if let Some(event) = notification_action_event(&action, &payload) {
                        emit_notification_action(&app, event);
                    }
                }
            }
        });
}
