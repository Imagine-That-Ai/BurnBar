//! Per-user single-instance ownership and local IPC for the Linux shell.
//!
//! The owner holds a 0600 lock and Unix socket. A second launch sends only
//! validated route or notification-action data to the owner and exits.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

pub(crate) const PROTOCOL_VERSION: u8 = 1;
const MAX_FRAME_BYTES: usize = 16 * 1024;
// A launcher can acquire the lock before the primary listener thread is ready.
// Keep forwarding bounded, but allow normal desktop startup to finish.
const FORWARD_RETRY_ATTEMPTS: usize = 40;
const FORWARD_RETRY_DELAY: Duration = Duration::from_millis(50);
const LOCK_NAME: &str = "openburnbar-linux-desktop.lock";
const SOCKET_NAME: &str = "openburnbar-linux-desktop.sock";
const DEEP_LINK_SCHEME_PREFIX: &str = "openburnbar://";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum Message {
    Focus,
    Route {
        route: String,
    },
    NotificationAction {
        action: String,
        #[serde(default = "empty_json_object")]
        payload: serde_json::Value,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct Frame {
    protocol: u8,
    message: Message,
}

fn empty_json_object() -> serde_json::Value {
    serde_json::json!({})
}

/// URI schemes are case-insensitive. Normalize only the surrounding command
/// line whitespace and keep the rest of the URI opaque for the authoritative
/// validator in `lib.rs`; malformed OpenBurnBar URIs must be rejected rather
/// than silently downgraded to a focus launch.
fn deep_link_argument(argument: &str) -> Option<&str> {
    let trimmed = argument.trim();
    trimmed
        .get(..DEEP_LINK_SCHEME_PREFIX.len())
        .filter(|prefix| prefix.eq_ignore_ascii_case(DEEP_LINK_SCHEME_PREFIX))
        .map(|_| trimmed)
}

pub(crate) fn notification_action_route(action: &str) -> Option<&'static str> {
    let route = match action {
        "open" | "overview" | "dashboard" => Some("overview"),
        "insights" | "usage" => Some("insights"),
        "chat" | "reply" => Some("chat"),
        "database" => Some("database"),
        "providers" | "models" => Some("providers"),
        "projects" => Some("projects"),
        "missions" => Some("missions"),
        "memory" => Some("memory"),
        "computer-use" | "computer_use" => Some("computer-use"),
        "mercury" => Some("mercury"),
        "smarthub" | "smart-hub" => Some("smarthub"),
        "settings" => Some("settings"),
        "updates" => Some("updates"),
        "account" => Some("account"),
        "activity" | "logs" => Some("activity"),
        "support" => Some("support"),
        "onboarding" => Some("onboarding"),
        "pet" => Some("pet"),
        "text-expansion" | "text_expansion" => Some("text-expansion"),
        _ => None,
    }?;
    // Keep relaunch actions tied to the same closed route registry as direct
    // route messages. A future alias cannot silently steer the renderer to a
    // route that the shell does not advertise.
    is_registered_shell_route(route).then_some(route)
}

fn is_registered_shell_route(route: &str) -> bool {
    matches!(
        route,
        "overview"
            | "insights"
            | "database"
            | "providers"
            | "projects"
            | "missions"
            | "activity"
            | "chat"
            | "memory"
            | "settings"
            | "account"
            | "updates"
            | "support"
            | "onboarding"
            | "pet"
            | "text-expansion"
            | "computer-use"
            | "mercury"
            | "smarthub"
    )
}

fn validate_message(message: &Message) -> Result<(), String> {
    match message {
        Message::Focus => Ok(()),
        Message::Route { route } if is_registered_shell_route(route) => Ok(()),
        Message::Route { .. } => Err("single_instance_route_not_registered".to_string()),
        Message::NotificationAction { action, payload } => {
            if notification_action_route(action).is_none() {
                return Err("single_instance_notification_action_not_allowed".to_string());
            }
            if !payload.is_object() {
                return Err("single_instance_notification_payload_must_be_object".to_string());
            }
            let size = serde_json::to_vec(payload)
                .map_err(|_| "single_instance_notification_payload_invalid".to_string())?
                .len();
            if size > MAX_FRAME_BYTES / 2 {
                return Err("single_instance_notification_payload_too_large".to_string());
            }
            Ok(())
        }
    }
}

fn frame_for_message(message: Message) -> Result<Vec<u8>, String> {
    validate_message(&message)?;
    let bytes = serde_json::to_vec(&Frame {
        protocol: PROTOCOL_VERSION,
        message,
    })
    .map_err(|_| "single_instance_frame_encode_failed".to_string())?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err("single_instance_frame_too_large".to_string());
    }
    Ok(bytes)
}

fn parse_frame(bytes: &[u8]) -> Result<Message, String> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME_BYTES {
        return Err("single_instance_frame_size_invalid".to_string());
    }
    let frame: Frame = serde_json::from_slice(bytes)
        .map_err(|_| "single_instance_frame_invalid_json".to_string())?;
    if frame.protocol != PROTOCOL_VERSION {
        return Err("single_instance_protocol_unsupported".to_string());
    }
    validate_message(&frame.message)?;
    Ok(frame.message)
}

pub(crate) fn startup_messages_from_args<I, F>(
    args: I,
    deep_link_validator: F,
) -> Result<Vec<Message>, String>
where
    I: IntoIterator<Item = String>,
    F: Fn(&str) -> Option<&'static str>,
{
    let arguments = args.into_iter().collect::<Vec<_>>();
    let mut messages = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if let Some(deep_link) = deep_link_argument(argument) {
            let route = deep_link_validator(deep_link)
                .ok_or_else(|| "single_instance_deep_link_rejected".to_string())?;
            messages.push(Message::Route {
                route: route.to_string(),
            });
            index += 1;
            continue;
        }

        let action = if argument == "--notification-action" {
            index += 1;
            arguments
                .get(index)
                .cloned()
                .ok_or_else(|| "single_instance_notification_action_missing".to_string())?
        } else if let Some(value) = argument.strip_prefix("--notification-action=") {
            value.to_string()
        } else if argument == "--notification-payload"
            || argument.starts_with("--notification-payload=")
        {
            // A payload is meaningful only when it is attached to the action
            // immediately before it. Silently ignoring an orphan payload
            // would turn a malformed notification relaunch into a plain
            // focus launch and lose the user's intended destination.
            return Err("single_instance_notification_payload_without_action".to_string());
        } else {
            index += 1;
            continue;
        };
        if action.trim() != action || notification_action_route(&action).is_none() {
            return Err("single_instance_notification_action_not_allowed".to_string());
        }
        index += 1;

        let mut payload = empty_json_object();
        if let Some(next) = arguments.get(index) {
            let raw = if next == "--notification-payload" {
                index += 1;
                arguments
                    .get(index)
                    .ok_or_else(|| "single_instance_notification_payload_missing".to_string())?
            } else {
                match next.strip_prefix("--notification-payload=") {
                    Some(raw) => raw,
                    None => "",
                }
            };
            let has_payload_argument =
                next == "--notification-payload" || next.starts_with("--notification-payload=");
            if has_payload_argument {
                payload = serde_json::from_str(raw)
                    .map_err(|_| "single_instance_notification_payload_invalid".to_string())?;
                index += 1;
            }
        }
        let message = Message::NotificationAction { action, payload };
        validate_message(&message)?;
        messages.push(message);
    }

    if messages.is_empty() {
        messages.push(Message::Focus);
    }
    Ok(messages)
}

pub(crate) fn directory(fallback: fn() -> PathBuf) -> PathBuf {
    for key in [
        "OPENBURNBAR_SINGLE_INSTANCE_DIR",
        "BURNBAR_SINGLE_INSTANCE_DIR",
    ] {
        if let Ok(value) = std::env::var(key) {
            if !value.trim().is_empty() {
                return PathBuf::from(value.trim());
            }
        }
    }
    if let Ok(value) = std::env::var("XDG_RUNTIME_DIR") {
        if !value.trim().is_empty() {
            return PathBuf::from(value.trim()).join("openburnbar");
        }
    }
    fallback()
}

fn paths(directory: &Path) -> (PathBuf, PathBuf) {
    (directory.join(LOCK_NAME), directory.join(SOCKET_NAME))
}

fn ensure_directory(directory: &Path) -> Result<(), String> {
    fs::create_dir_all(directory)
        .map_err(|_| "single_instance_directory_unavailable".to_string())?;
    let metadata = fs::symlink_metadata(directory)
        .map_err(|_| "single_instance_directory_unavailable".to_string())?;
    if !metadata.is_dir() {
        return Err("single_instance_directory_not_directory".to_string());
    }
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err("single_instance_directory_owner_invalid".to_string());
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| "single_instance_directory_permissions_invalid".to_string())?;
    }
    Ok(())
}

fn prepare_socket_path(socket_path: &Path) -> Result<(), String> {
    use std::os::unix::ffi::OsStrExt;
    if socket_path.as_os_str().as_bytes().len() >= 108 {
        return Err("single_instance_socket_path_too_long".to_string());
    }
    match fs::symlink_metadata(socket_path) {
        Ok(metadata) => {
            use std::os::unix::fs::{FileTypeExt, MetadataExt};
            if !metadata.file_type().is_socket() {
                return Err("single_instance_socket_path_not_socket".to_string());
            }
            if metadata.uid() != unsafe { libc::geteuid() } {
                return Err("single_instance_socket_owner_invalid".to_string());
            }
            fs::remove_file(socket_path)
                .map_err(|_| "single_instance_socket_path_stale".to_string())?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("single_instance_socket_path_unavailable".to_string()),
    }
    Ok(())
}

fn open_lock(lock_path: &Path) -> Result<fs::File, String> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let file = fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(lock_path)
        .map_err(|_| "single_instance_lock_unavailable".to_string())?;
    let metadata = file
        .metadata()
        .map_err(|_| "single_instance_lock_unavailable".to_string())?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err("single_instance_lock_identity_invalid".to_string());
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| "single_instance_lock_permissions_invalid".to_string())?;
    }
    Ok(file)
}

fn try_lock(file: &fs::File) -> Result<bool, String> {
    let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if result == 0 {
        return Ok(true);
    }
    if std::io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK) {
        return Ok(false);
    }
    Err("single_instance_lock_failed".to_string())
}

fn send_message(socket_path: &Path, message: &Message) -> Result<(), String> {
    let bytes = frame_for_message(message.clone())?;
    for attempt in 0..FORWARD_RETRY_ATTEMPTS {
        match UnixStream::connect(socket_path) {
            Ok(mut stream) => {
                stream
                    .set_write_timeout(Some(Duration::from_millis(250)))
                    .map_err(|_| "single_instance_forward_timeout".to_string())?;
                stream
                    .write_all(&bytes)
                    .map_err(|_| "single_instance_forward_failed".to_string())?;
                return Ok(());
            }
            Err(_) if attempt + 1 < FORWARD_RETRY_ATTEMPTS => thread::sleep(FORWARD_RETRY_DELAY),
            Err(_) => break,
        }
    }
    Err("single_instance_primary_unreachable".to_string())
}

fn spawn_listener(
    listener: UnixListener,
    sender: Sender<Message>,
    stop: Arc<AtomicBool>,
) -> Result<(), String> {
    listener
        .set_nonblocking(true)
        .map_err(|_| "single_instance_listener_setup_failed".to_string())?;
    thread::Builder::new()
        .name("openburnbar-single-instance".to_string())
        .spawn(move || {
            while stop.load(Ordering::Relaxed) {
                let (mut stream, _) = match listener.accept() {
                    Ok(connection) => connection,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(25));
                        continue;
                    }
                    Err(_) => break,
                };
                // The listener is nonblocking so the accept loop can honor
                // shutdown, but accepted streams must be blocking while we
                // drain a bounded frame. Some Unix implementations inherit
                // O_NONBLOCK here; without resetting it, a client can race
                // into a BrokenPipe before its frame is written.
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
                let mut bytes = Vec::with_capacity(MAX_FRAME_BYTES);
                let result = Read::by_ref(&mut stream)
                    .take((MAX_FRAME_BYTES + 1) as u64)
                    .read_to_end(&mut bytes);
                if result.is_ok() && bytes.len() <= MAX_FRAME_BYTES {
                    if let Ok(message) = parse_frame(&bytes) {
                        let _ = sender.send(message);
                    }
                }
            }
        })
        .map(|_| ())
        .map_err(|_| "single_instance_listener_setup_failed".to_string())
}

#[derive(Debug)]
pub(crate) struct Guard {
    _lock_file: fs::File,
    socket_path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.stop.store(false, Ordering::Relaxed);
        let is_socket = fs::symlink_metadata(&self.socket_path)
            .map(|metadata| {
                use std::os::unix::fs::{FileTypeExt, MetadataExt};
                metadata.file_type().is_socket() && metadata.uid() == unsafe { libc::geteuid() }
            })
            .unwrap_or(false);
        if is_socket {
            let _ = fs::remove_file(&self.socket_path);
        }
    }
}

#[derive(Debug)]
pub(crate) enum Acquire {
    Primary {
        guard: Guard,
        receiver: Receiver<Message>,
    },
    Forwarded,
}

pub(crate) fn acquire(directory: &Path, startup_messages: &[Message]) -> Result<Acquire, String> {
    ensure_directory(directory)?;
    let (lock_path, socket_path) = paths(directory);
    let lock_file = open_lock(&lock_path)?;
    if !try_lock(&lock_file)? {
        for message in startup_messages {
            send_message(&socket_path, message)?;
        }
        return Ok(Acquire::Forwarded);
    }

    prepare_socket_path(&socket_path)?;
    let listener = UnixListener::bind(&socket_path)
        .map_err(|_| "single_instance_socket_bind_failed".to_string())?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600))
        .map_err(|_| "single_instance_socket_permissions_invalid".to_string())?;
    let (sender, receiver) = mpsc::channel();
    let stop = Arc::new(AtomicBool::new(true));
    spawn_listener(listener, sender, stop.clone())?;
    Ok(Acquire::Primary {
        guard: Guard {
            _lock_file: lock_file,
            socket_path,
            stop,
        },
        receiver,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEMP_DIRECTORY_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn temp_directory() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sequence = TEMP_DIRECTORY_COUNTER.fetch_add(1, Ordering::Relaxed);
        // Keep the Unix socket path below sockaddr_un's 108-byte limit even
        // when a test runner provides a deeply nested TMPDIR.
        let directory =
            PathBuf::from("/tmp").join(format!("obb-si-{}-{nonce}-{sequence}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn cleanup(directory: &Path) {
        let _ = fs::remove_dir_all(directory);
    }

    fn deep_link(value: &str) -> Option<&'static str> {
        match value {
            "openburnbar://route/chat" => Some("chat"),
            "openburnbar://route/settings" => Some("settings"),
            _ => None,
        }
    }

    #[test]
    fn startup_args_preserve_following_deep_links_and_decode_payloads() {
        let messages = startup_messages_from_args(
            vec![
                "--notification-action=chat".to_string(),
                "--notification-payload={\"threadId\":\"thread-42\"}".to_string(),
                "openburnbar://route/settings".to_string(),
            ],
            deep_link,
        )
        .unwrap();
        assert_eq!(
            messages,
            vec![
                Message::NotificationAction {
                    action: "chat".to_string(),
                    payload: serde_json::json!({"threadId":"thread-42"})
                },
                Message::Route {
                    route: "settings".to_string()
                }
            ]
        );
    }

    #[test]
    fn startup_args_accept_case_insensitive_trimmed_deep_links() {
        let messages =
            startup_messages_from_args(vec!["  OPENBURNBAR://route/chat  ".to_string()], |value| {
                value
                    .eq_ignore_ascii_case("openburnbar://route/chat")
                    .then_some("chat")
            })
            .unwrap();
        assert_eq!(
            messages,
            vec![Message::Route {
                route: "chat".into()
            }]
        );
    }

    #[test]
    fn malformed_case_insensitive_deep_links_are_rejected() {
        let result = startup_messages_from_args(
            vec!["OPENBURNBAR://unregistered-route".to_string()],
            |_| None,
        );
        assert_eq!(result.unwrap_err(), "single_instance_deep_link_rejected");
    }

    #[test]
    fn protocol_and_payload_validation_fail_closed() {
        assert_eq!(
            parse_frame(br#"{"protocol":2,"message":{"kind":"focus"}}"#).unwrap_err(),
            "single_instance_protocol_unsupported"
        );
        assert!(startup_messages_from_args(
            vec!["--notification-action=execute".to_string()],
            deep_link
        )
        .is_err());
        assert!(startup_messages_from_args(
            vec![
                "--notification-action=chat".to_string(),
                "--notification-payload=\"secret\"".to_string()
            ],
            deep_link
        )
        .is_err());
        assert!(startup_messages_from_args(
            vec![
                "--notification-action=chat".to_string(),
                "--notification-payload=".to_string()
            ],
            deep_link
        )
        .is_err());
        assert_eq!(
            startup_messages_from_args(
                vec!["--notification-payload={\"threadId\":\"orphan\"}".to_string()],
                deep_link
            )
            .unwrap_err(),
            "single_instance_notification_payload_without_action"
        );
        assert_eq!(
            startup_messages_from_args(
                vec!["--notification-payload".to_string(), "{}".to_string()],
                deep_link
            )
            .unwrap_err(),
            "single_instance_notification_payload_without_action"
        );
        assert!(parse_frame(
            br#"{"protocol":1,"message":{"kind":"route","route":"chat","extra":true}}"#
        )
        .is_err());
    }

    #[test]
    fn notification_action_aliases_resolve_only_to_registered_routes() {
        let aliases = [
            ("open", "overview"),
            ("dashboard", "overview"),
            ("reply", "chat"),
            ("models", "providers"),
            ("computer_use", "computer-use"),
            ("smart-hub", "smarthub"),
            ("text_expansion", "text-expansion"),
            ("support", "support"),
        ];
        for (action, route) in aliases {
            assert_eq!(notification_action_route(action), Some(route));
            assert!(is_registered_shell_route(route));
        }
        for action in ["execute", "open-url", "javascript", ""] {
            assert_eq!(notification_action_route(action), None);
        }
    }

    #[test]
    fn every_notification_action_alias_targets_a_registered_shell_route() {
        // Keep the alias table fail-closed if a future shortcut is added
        // without adding the corresponding renderer route registration.
        for action in [
            "open",
            "overview",
            "dashboard",
            "insights",
            "usage",
            "chat",
            "reply",
            "database",
            "providers",
            "models",
            "projects",
            "missions",
            "memory",
            "computer-use",
            "computer_use",
            "mercury",
            "smarthub",
            "smart-hub",
            "settings",
            "updates",
            "account",
            "activity",
            "logs",
            "support",
            "onboarding",
            "pet",
            "text-expansion",
            "text_expansion",
        ] {
            let route = notification_action_route(action)
                .unwrap_or_else(|| panic!("action alias must remain supported: {action}"));
            assert!(
                is_registered_shell_route(route),
                "unregistered route: {route}"
            );
        }
    }

    #[test]
    fn forwards_while_primary_listener_finishes_starting() {
        let directory = temp_directory();
        let (_, socket_path) = paths(&directory);
        let listener_thread = {
            let socket_path = socket_path.clone();
            thread::spawn(move || {
                // The primary acquires its lock before the listener thread is
                // ready during normal desktop startup.
                thread::sleep(Duration::from_millis(650));
                let listener = UnixListener::bind(&socket_path).unwrap();
                let (mut stream, _) = listener.accept().unwrap();
                let mut bytes = Vec::new();
                stream.read_to_end(&mut bytes).unwrap();
                assert_eq!(parse_frame(&bytes).unwrap(), Message::Focus);
            })
        };

        send_message(&socket_path, &Message::Focus).unwrap();
        listener_thread.join().unwrap();
        cleanup(&directory);
    }

    #[test]
    fn second_launch_forwards_to_the_locked_primary() {
        let directory = temp_directory();
        let primary = acquire(&directory, &[Message::Focus]).unwrap();
        let (guard, receiver) = match primary {
            Acquire::Primary { guard, receiver } => (guard, receiver),
            Acquire::Forwarded => panic!("first launch must own the instance"),
        };
        let result = acquire(
            &directory,
            &[Message::Route {
                route: "chat".to_string(),
            }],
        )
        .unwrap();
        assert!(matches!(result, Acquire::Forwarded));
        assert_eq!(
            receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
            Message::Route {
                route: "chat".to_string()
            }
        );
        drop(guard);
        cleanup(&directory);
    }

    #[test]
    fn malformed_frame_does_not_kill_listener() {
        let directory = temp_directory();
        let primary = acquire(&directory, &[Message::Focus]).unwrap();
        let (guard, receiver) = match primary {
            Acquire::Primary { guard, receiver } => (guard, receiver),
            Acquire::Forwarded => panic!("first launch must own the instance"),
        };
        let (_, socket_path) = paths(&directory);
        let mut malformed = UnixStream::connect(&socket_path).unwrap();
        malformed.write_all(b"not-json").unwrap();
        drop(malformed);
        send_message(
            &socket_path,
            &Message::NotificationAction {
                action: "chat".to_string(),
                payload: serde_json::json!({"threadId":"thread-9"}),
            },
        )
        .unwrap();
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(2)).unwrap(),
            Message::NotificationAction { .. }
        ));
        drop(guard);
        cleanup(&directory);
    }

    #[test]
    fn existing_non_socket_is_never_deleted() {
        let directory = temp_directory();
        let (lock_path, socket_path) = paths(&directory);
        fs::write(&socket_path, b"do not delete").unwrap();
        assert_eq!(
            acquire(&directory, &[Message::Focus]).unwrap_err(),
            "single_instance_socket_path_not_socket"
        );
        assert_eq!(fs::read(&socket_path).unwrap(), b"do not delete");
        let _ = fs::remove_file(lock_path);
        cleanup(&directory);
    }
}
